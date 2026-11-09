#!/usr/bin/env bash
# Build from the exact reviewed distribution inputs committed at the release tag.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
tag=${1:?Expected a release tag}
target=${2:?Expected a release target}
case "$target" in macos-aarch64|linux-x86_64) ;; *) exit 1 ;; esac
catalog=native/release-inputs.json
entry=$(jq -ce --arg target "$target" '.[$target] | select(.distribution_approved == true)' "$catalog")
review=$(jq -er '.source_review | select(test("^docs/[a-zA-Z0-9./_-]+\\.md$") and (contains("..") | not))' <<< "$entry")
test -f "$review"

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT

download() {
  local name=$1 destination=$2 url expected actual
  url=$(jq -er --arg name "$name" '.[$name].url | select(startswith("https://"))' <<< "$entry")
  expected=$(jq -er --arg name "$name" '.[$name].sha256 | select(test("^[0-9a-f]{64}$"))' <<< "$entry")
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --max-time 300 --max-filesize 1073741824 --output "$destination" "$url"
  actual=$(openssl dgst -sha256 -r "$destination" | cut -d ' ' -f 1)
  [[ "$actual" == "$expected" ]]
}

download runtime "$stage/runtime.tar.gz"
download demo "$stage/demo.smolmachine"
mkdir -p "$stage/assets"
tar --no-same-owner -xzpf "$stage/runtime.tar.gz" --strip-components=1 -C "$stage/assets"
python3 native/bootstrap.py

if [[ "$target" == macos-* ]]; then
  mkdir "$stage/build-lib"
  cp -RL "$stage/assets/lib/." "$stage/build-lib/"
  export LIBKRUN_BUNDLE="$stage/build-lib"
fi

cargo build --manifest-path native/Cargo.toml -p smolbox-port --release --locked
python3 native/package.py --executable native/target/release/smolbox-port \
  --assets "$stage/assets" --output "$stage/package"

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
  --demo "$stage/demo.smolmachine" --output "release-output/smolbox-embedded-$target.tar.gz" \
  > "release-output/$target.json"
