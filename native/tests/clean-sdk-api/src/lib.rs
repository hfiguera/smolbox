//! Compile-only public API feasibility check. Never launches a VM or owns a domain.
use smolvm::agent::{AgentClient, FileWriteMeta};
use smolvm::embedded::EmbeddedRuntime;
use std::io::Read;
use std::path::Path;

pub mod parity;

pub fn transfer(
    socket: &Path,
    guest_path: &str,
    staging: &Path,
    reader: impl Read,
    total: u64,
) -> smolvm::Result<u64> {
    let mut client = AgentClient::connect(socket)?;
    client.write_file_from_reader_with_progress(
        guest_path,
        reader,
        total,
        FileWriteMeta::mode_only(Some(0o600)),
        |_| {},
    )?;
    client.read_file_to_path_capped(guest_path, staging, 16 * 1024 * 1024, |_| {})
}

pub fn lifecycle(runtime: &EmbeddedRuntime, name: &str) -> smolvm::Result<()> {
    runtime.start_machine(name)?;
    runtime.stop_machine(name)?;
    runtime.delete_machine(name)
}

pub fn boot_entry(config: std::path::PathBuf) -> smolvm::Result<()> {
    smolvm::internal_boot::run(config)
}

pub fn seed_and_lock(name: &str) -> smolvm::Result<()> {
    let _lease = smolvm::agent::fork::lock_fork_source(name)?;
    let _seed = smolvm::storage::seed_vm_mode_disks;
    let _prepare = smolvm::portable_checkpoint::materialize_pack_layers;
    let _resolve = smolvm_pack::assets::find_existing_template;
    Ok(())
}

/// Compile-only witness for SDK-owned formatting of existing backing disks.
/// This function is never invoked by the feasibility fixture.
pub fn prepare_existing_disks(directory: &Path) -> smolvm::Result<()> {
    let (storage, storage_format) =
        smolvm::agent::resolve_disk_image(directory, smolvm::storage::STORAGE_DISK_FILENAME);
    let (overlay, overlay_format) =
        smolvm::agent::resolve_disk_image(directory, smolvm::storage::OVERLAY_DISK_FILENAME);
    smolvm::storage::StorageDisk::open_existing_with_format(&storage, storage_format)?
        .ensure_formatted()?;
    smolvm::storage::OverlayDisk::open_existing_with_format(&overlay, overlay_format)?
        .ensure_formatted()
}
