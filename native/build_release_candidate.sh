#!/usr/bin/env bash
# Build from the exact reviewed distribution inputs committed at the release tag.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
tag=${1:?Expected a release tag}
target=${2:?Expected a release target}
case "$target" in macos-aarch64|linux-x86_64|linux-aarch64) ;; *) exit 1 ;; esac
catalog=native/release-inputs.json
entry=$(jq -ce --arg target "$target" '.[$target] | select(.distribution_approved == true)' "$catalog")
review=$(jq -er '.source_review | select(test("^docs/[a-zA-Z0-9./_-]+\\.md$") and (contains("..") | not))' <<< "$entry")
test -f "$review"

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT

download() {
  local input=$1 destination=$2 url expected actual
  shift 2
  url=$(jq -er '.url | select(startswith("https://"))' <<< "$input")
  expected=$(jq -er '.sha256 | select(test("^[0-9a-f]{64}$"))' <<< "$input")
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --max-time 300 --max-filesize 1073741824 --output "$destination" "$@" "$url"
  actual=$(openssl dgst -sha256 -r "$destination" | cut -d ' ' -f 1)
  [[ "$actual" == "$expected" ]]
}

if [[ ${3-} == --install-host-tool ]]; then
  installer=$(jq -ce '.resize2fs_package' <<< "$entry")
  if [[ "$target" == macos-* ]]; then
    jq -e '.url | startswith("https://ghcr.io/v2/homebrew/core/e2fsprogs/blobs/sha256:")' \
      <<< "$installer" >/dev/null
    filename=$(jq -er '.filename | select(test("^e2fsprogs--[0-9.]+[.]arm64_tahoe[.]bottle[.]tar[.]gz$"))' <<< "$installer")
    bottle="$stage/$filename"
    token=$(curl --fail --silent --show-error --proto '=https' --max-time 30 \
      'https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/e2fsprogs:pull' | jq -er .token)
    download "$installer" "$bottle" --header "Authorization: Bearer $token"
    unset token
    HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 brew install "$bottle"
  else
    # apt's unprivileged download account must be able to read the verified file.
    chmod 755 "$stage"
    download "$installer" "$stage/e2fsprogs.deb"
    download "$(jq -ce '.resize2fs_library' <<< "$entry")" "$stage/libext2fs.deb"
    sudo apt-get install -y --allow-downgrades "$stage/e2fsprogs.deb" "$stage/libext2fs.deb"
    chmod 700 "$stage"
  fi
fi

download "$(jq -ce '.runtime' <<< "$entry")" "$stage/runtime.tar.gz"
download "$(jq -ce '.demo' <<< "$entry")" "$stage/demo.smolmachine"
download "$(jq -ce '.notices' "$catalog")" "$stage/third-party-notices.tar.gz"
mkdir -p "$stage/assets"
tar --no-same-owner -xzpf "$stage/runtime.tar.gz" --strip-components=1 -C "$stage/assets"
for template in storage-template overlay-template; do
  zstd --quiet --decompress --sparse "$stage/assets/$template.ext4.zst" -o "$stage/assets/$template.ext4"
done
python3 native/bootstrap.py

if [[ "$target" == macos-* ]]; then
  jq -e '.macos_signing == "ad-hoc"' <<< "$entry" >/dev/null
  mkdir "$stage/build-lib"
  cp -RL "$stage/assets/lib/." "$stage/build-lib/"
  export LIBKRUN_BUNDLE="$stage/build-lib"
fi

cargo build --manifest-path native/Cargo.toml -p smolbox-port --release --locked
if [[ "$target" == macos-* ]]; then
  otool -D "$stage/build-lib/libkrun.dylib" | grep -Fxq '@rpath/libkrun.dylib'
  cp "$stage/build-lib/libkrun.dylib" "$stage/assets/lib/libkrun.dylib"
fi
python3 native/package.py --executable native/target/release/smolbox-port \
  --assets "$stage/assets" --output "$stage/package"
if [[ "$target" == macos-* ]]; then
  for library in "$stage/package/lib/"*.dylib; do
    codesign --verify --strict "$library"
  done
fi

python3 - "$stage/package/package.json" "$catalog" "$target" <<'PYTHON'
import json
import sys

package_path, catalog_path, target = sys.argv[1:]
with open(package_path) as package_file, open(catalog_path) as catalog_file:
    package = json.load(package_file)
    expected_tool = json.load(catalog_file)[target]['resize2fs']
if package['host_tools'] != [expected_tool]:
    sys.exit('The host resize2fs does not match the reviewed release input')
PYTHON

mkdir -p release-output
python3 native/release_bundle.py --tag "$tag" --package "$stage/package" \
  --demo "$stage/demo.smolmachine" --notices "$stage/third-party-notices.tar.gz" \
  --output "release-output/smolbox-embedded-$target.tar.gz" \
  > "release-output/$target.json"
