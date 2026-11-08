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
cargo test --manifest-path "$native_manifest" --workspace --lib --bins --test contract --locked
# This example's Rust test harness runs only its in-memory/socket owner-retention
# model; it never invokes the explicit first/second live guest entry points.
cargo test --manifest-path "$native_manifest" -p smolbox-engine --example volume-guest-proof --locked
# Only pure source approval models run here. The explicit source/control CLI is
# never invoked by the default check; live OCI/registry qualification is opt-in.
cargo test --manifest-path "$native_manifest" -p smolbox-engine --example oci-guest-proof --locked
# The branch example's harness checks only approval/state/request models. The
# explicit Linux `ordinary` entry point is never selected by default checks.
cargo test --manifest-path "$native_manifest" -p smolbox-engine --example branch-guest-proof --locked
cargo test --manifest-path "$native_manifest" -p smolbox-engine --test child_reaping --locked
cargo build --manifest-path "$native_manifest" -p smolbox-port --locked
SMOLBOX_UMASK_HELPER="${CARGO_TARGET_DIR:-$native_root/target}/debug/smolbox-port" \
  python3 "$native_root/tests/test_port_umask.py" -v
# Unoptimized Linux SDK executables can exceed the unchanged 256-MiB host
# executable bound. Ordinary worker fixtures use the production build profile.
cargo build --manifest-path "$native_manifest" --release -p smolbox-port --locked
# Every ignored fixture is individually reviewed and exactly named. This list
# uses ordinary protocol/filesystem peers and normal child exit only; it cannot
# select a newly added similarly named test, a VM fixture or a fault campaign.
native_ordinary_fixtures=(
  "transfer_supervisor::tests::ordinary_worker_process_connects_without_initializing_runtime_ownership"
  "transfer_supervisor::tests::ordinary_worker_binary_transfers_use_public_agent_api"
  "terminal_supervisor::tests::ordinary_terminal_supervisor_holds_leases_until_exact_normal_collection"
  "terminal_supervisor::tests::ordinary_terminal_natural_exit_preserves_final_output_and_collected_exit"
  "terminal_supervisor::tests::ordinary_terminal_eof_and_ambiguous_exit_do_not_confirm_completion"
  "checkpoint_source::tests::ordinary_worker_checkpoint_installation_commits_only_fresh_owned_material"
  "checkpoint_source::tests::ordinary_worker_checkpoint_materializes_sdk_files_and_collects_without_vm_dispatch"
  "transfer_supervisor::tests::ordinary_conversion_worker_collects_and_rehashes_both_spools_with_original_leases"
  "transfer_supervisor::tests::ordinary_imported_conversion_worker_preserves_source_gate_and_spools"
  "transfer_supervisor::tests::ordinary_growth_worker_collects_raw_and_qcow_sdk_geometry_with_owned_leases"
  "transfer_supervisor::tests::ordinary_branch_worker_rejects_unentered_fixture_and_collects_original_leases"
  "epoch::tests::ordinary_boot_guard_enrolls_before_sdk_and_collects_normal_exit"
)
for native_ordinary_fixture in "${native_ordinary_fixtures[@]}"; do
  SMOLBOX_TEST_FILE_WORKER="${CARGO_TARGET_DIR:-$native_root/target}/release/smolbox-port" \
    cargo test --manifest-path "$native_manifest" -p smolbox-engine --lib "$native_ordinary_fixture" --locked -- --exact --ignored
done
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
