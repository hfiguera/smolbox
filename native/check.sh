#!/usr/bin/env bash
set -euo pipefail
# Executables and approved fixture inputs must never be group-writable, even
# when the invoking account uses a shared-group default such as 0002.
umask 077
native_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "$native_root/bootstrap.py"
python3 -m unittest discover -s "$native_root/tests" -v
python3 "$native_root/bootstrap.py" --check
python3 "$native_root/bootstrap.py" --clean
python3 "$native_root/bootstrap.py" --clean --check

# The upstream macOS build rewrites/signs LIBKRUN_BUNDLE. Compile against a
# private copy even when the caller supplied an installed or research bundle.
if [[ -n ${LIBKRUN_BUNDLE:-} ]]; then
  native_input_libs=$LIBKRUN_BUNDLE
  native_copy_libs=$(mktemp -d "$native_root/target/check-libs.XXXXXX")
  trap 'rm -rf -- "$native_copy_libs"' EXIT
  # Dereference input symlinks so rewriting a copied library can never follow
  # an absolute or escaping link back into the installed/research bundle.
  python3 - "$native_input_libs" "$native_copy_libs" <<'PY'
import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=False, dirs_exist_ok=True)
PY
  export LIBKRUN_BUNDLE=$native_copy_libs
fi
native_manifest="$native_root/Cargo.toml"
cargo fmt --manifest-path "$native_manifest" -p smolbox-engine -p smolbox-protocol -p smolbox-port --check
# Ordinary migration checks exclude the historical parent-loss integration
# campaign. Child reaping here uses only normal pipe release and process exit.
cargo test --manifest-path "$native_manifest" --workspace --lib --bins --locked
cargo test --manifest-path "$native_manifest" -p smolbox-engine --test child_reaping --locked
cargo build --manifest-path "$native_manifest" -p smolbox-port --locked
SMOLBOX_UMASK_HELPER="${CARGO_TARGET_DIR:-$native_root/target}/debug/smolbox-port" \
  python3 "$native_root/tests/test_port_umask.py" -v
# Only these two ignored fixtures are ordinary checks: private worker entry and
# binary transfers to a local SDK-protocol peer. Neither launches a VM or forces
# child termination. Never select all ignored tests.
SMOLBOX_TEST_FILE_WORKER="${CARGO_TARGET_DIR:-$native_root/target}/debug/smolbox-port" \
  cargo test --manifest-path "$native_manifest" -p smolbox-engine --lib ordinary_worker --locked -- --ignored
# The guard fixture enters the SDK only with invalid JSON configuration and
# observes its normal exit. It cannot boot a VM or exercise owner-loss behavior.
SMOLBOX_TEST_FILE_WORKER="${CARGO_TARGET_DIR:-$native_root/target}/debug/smolbox-port" \
  cargo test --manifest-path "$native_manifest" -p smolbox-engine --lib ordinary_boot_guard --locked -- --ignored
native_clean_fixture="$native_root/tests/clean-sdk-api"
if [[ ! -f "$native_clean_fixture/Cargo.lock" ]]; then
  cp "$native_root/Cargo.lock" "$native_clean_fixture/Cargo.lock"
fi
# Reconcile only the independent fixture's package entry using seeded locked
# versions; source inputs remain verified. Its generated lock stays untracked.
cargo build --manifest-path "$native_clean_fixture/Cargo.toml" --bin template-resolver --offline
# Pure public configuration/lineage witnesses only. These tests never invoke
# the compile-only lifecycle/network/PTY/checkpoint/export functions or a VM.
cargo test --manifest-path "$native_clean_fixture/Cargo.toml" --lib parity::tests --offline
SMOLBOX_CLEAN_TEMPLATE_RESOLVER="${CARGO_TARGET_DIR:-$native_clean_fixture/target}/debug/template-resolver" \
  python3 "$native_root/tests/test_clean_template_resolver.py" -v
cargo clippy --manifest-path "$native_manifest" --all-targets --locked -- -D warnings
RUSTDOCFLAGS='-D warnings' cargo doc --manifest-path "$native_manifest" --workspace --no-deps --locked
python3 "$native_root/bootstrap.py" --check
python3 "$native_root/bootstrap.py" --clean --check
