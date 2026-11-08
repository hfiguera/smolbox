//! Compile-only HTTP-parity witnesses against verified, unmodified SDK bytes.
//! No function in this module is invoked by the test runner. API existence is
//! not evidence of ownership, boundedness, dispatch safety or live qualification.

use smolvm::agent::{AgentClient, InteractiveInput, InteractiveOutput, RunConfig};
use smolvm::config::VmRecord;
use smolvm::embedded::{EmbeddedRuntime, MachineSpec};
use std::path::Path;
use std::sync::mpsc::Receiver;
use std::time::Duration;

pub fn network_and_workload(
    runtime: &EmbeddedRuntime,
    spec: MachineSpec,
    policy: &smolvm::data::network::EgressPolicy,
) -> smolvm::Result<()> {
    let name = spec.name.clone();
    runtime.create_machine_with_workload(spec, Vec::new(), Some("/workspace".into()), None)?;
    runtime.set_egress_policy(&name, policy)
}

pub fn mapped_ports(spec: &mut MachineSpec, host: u16, guest: u16) {
    spec.ports
        .push(smolvm::agent::PortMapping::new(host, guest));
}

/// Correct overlay lineage, mount and optional volume selection are supplied
/// from the controller's receipt-checked record, never inferred by a worker.
pub fn existing_image_command(record: &VmRecord, image: String) -> RunConfig {
    RunConfig::new(image, vec!["/bin/true".into()])
        .in_machine(record, &record.name, &[])
        .with_mounts(smolvm::workload::record_mounts_to_bindings(record))
        .with_env(Vec::new())
        .with_workdir(Some("/workspace".into()))
        .with_user(None)
        .with_timeout(Some(Duration::from_secs(1)))
        .with_stdin(Some("finite UTF-8 input".into()))
}

pub fn buffered_and_background(
    client: &mut AgentClient,
    image_config: RunConfig,
) -> smolvm::Result<()> {
    let _ = client.vm_exec(
        vec!["/bin/true".into()],
        Vec::new(),
        None,
        Some(Duration::from_secs(1)),
        Some("finite input".into()),
    )?;
    let _ = client.run_non_interactive(image_config.clone())?;
    let _ = client.run_background(image_config.with_stdin(None).with_timeout(None))?;
    Ok(())
}

pub fn image_terminal(
    client: &mut AgentClient,
    config: RunConfig,
    input: Receiver<InteractiveInput>,
    output: impl FnMut(InteractiveOutput),
) -> smolvm::Result<i32> {
    client.run_interactive_io(config.with_stdin(None).with_tty(true), input, output)
}

pub fn terminal_resize(cols: u16, rows: u16) -> InteractiveInput {
    InteractiveInput::Resize { cols, rows }
}

pub fn images(runtime: &EmbeddedRuntime, name: &str, approved_image: &str) -> smolvm::Result<()> {
    let _ = runtime.list_images(name)?;
    let _ = runtime.pull_image(name, approved_image)?;
    Ok(())
}

pub fn checkpoint(
    runtime: &EmbeddedRuntime,
    source: &str,
    restore: &str,
    output: &Path,
    options: &smolvm::portable_checkpoint::CaptureOptions,
) -> smolvm::Result<()> {
    runtime.start_forkable_machine(source)?;
    let _ = runtime.checkpoint_machine(source, output, options)?;
    runtime.restore_checkpoint_machine(restore, output)
}

/// The public running-resize method is unsuitable for managed stopped growth.
/// These SDK-owned disk expansion APIs remain callable without reproducing the
/// filesystem algorithm. The engine must own the source and publish a verified
/// material transition before this can be product behavior.
pub fn stopped_disks(storage: &Path, overlay: &Path, gib: u64) -> smolvm::Result<()> {
    smolvm::storage::expand_disk::<smolvm::storage::Storage>(storage, gib)?;
    smolvm::storage::expand_disk::<smolvm::storage::Overlay>(overlay, gib)
}

pub fn export_assets(
    collector: &mut smolvm_pack::assets::AssetCollector,
    record: &VmRecord,
    directory: &Path,
    options: &smolvm::pack_export::FromVmExportOptions,
) -> smolvm::Result<smolvm::pack_export::FromVmAssets> {
    // This can launch an auxiliary VM. Never execute this witness or substitute
    // it for the required enrollment/accounting/host-conversion feasibility gate.
    smolvm::pack_export::collect_from_vm_assets(collector, &record.name, record, directory, options)
}

pub fn release_held_child(child: &VmRecord) -> smolvm::Result<()> {
    let _ = smolvm::agent::fork::activate_held_fork(&child.name, child, &[])?;
    Ok(())
}

/// Runtime convenience forks release immediately and offer no held-slot option.
/// The public launch-agnostic preparation path preserves hold for a controller
/// that owns source/child intent, gates, accounting and boot epoch enrollment.
pub fn prepare_held_child(
    database: &smolvm::db::SmolvmDb,
    source: &str,
    child: &str,
) -> smolvm::Result<smolvm::agent::fork::PreparedFork> {
    smolvm::agent::fork::prepare_held_fork(
        database,
        source,
        child,
        &[],
        &[],
        &std::collections::BTreeMap::new(),
        smolvm::agent::fork::ForkSourcePolicy::PlatformDefault,
    )
}

pub fn start_prepared_child(
    manager: &smolvm::agent::AgentManager,
    prepared: &smolvm::agent::fork::PreparedFork,
) -> smolvm::Result<()> {
    let record = &prepared.clone_record;
    manager.start_with_full_config(
        record.host_mounts(),
        record
            .ports
            .iter()
            .map(|&(host, guest)| smolvm::agent::PortMapping::new(host, guest))
            .collect(),
        record.vm_resources(),
        smolvm::agent::LaunchFeatures {
            snapshot_dir: Some(prepared.snapshot_dir.clone()),
            watch_parent: Some(true),
            ..smolvm::agent::LaunchFeatures::default()
        },
    )
}

pub fn registry_source(registry: &str, config: &smolvm::registry::RegistryConfig) {
    let _client =
        smolvm::registry::registry_client(registry, config, &smolvm::registry::PullAuth::Anonymous);
    let _reference = smolvm::registry::Reference::parse(&format!(
        "registry.example/team/image@sha256:{}",
        "a".repeat(64)
    ));
}

pub async fn registry_artifact(
    client: &smolvm_registry::RegistryClient,
    cache: &smolvm_registry::BlobCache,
    output: &Path,
    reference: &str,
) -> Result<(), smolvm_registry::RegistryError> {
    let _pull =
        smolvm_registry::pull(client, "team/image", reference, Some(output), cache, &[]).await?;
    let _push = smolvm_registry::push(client, "team/image", reference, output).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn existing_image_configuration_preserves_overlay_lineage_and_guest_mount_tags() {
        let mut record = MachineSpec {
            name: "child".into(),
            image: Some("registry.example/team/image".into()),
            persistent: true,
            ..MachineSpec::default()
        }
        .to_record();
        record.golden = Some("parent".into());
        record.fork_overlay_owner = Some("original-root".into());
        record.mounts = vec![("/approved/volume".into(), "/mnt/volumes/data".into(), true)];
        let config = existing_image_command(&record, record.image.clone().unwrap());
        assert_eq!(
            config.persistent_overlay_id.as_deref(),
            Some("original-root")
        );
        assert_eq!(config.mounts.len(), 1);
        assert_ne!(config.mounts[0].0, "/approved/volume");
        assert_eq!(config.mounts[0].1, "/mnt/volumes/data");
        assert!(config.mounts[0].2);
        assert_eq!(config.stdin.as_deref(), Some("finite UTF-8 input"));
        assert_eq!(config.workdir.as_deref(), Some("/workspace"));
        assert_eq!(config.timeout, Some(Duration::from_secs(1)));
    }

    #[test]
    fn ordinary_image_configuration_uses_its_own_persistent_overlay() {
        let record = MachineSpec {
            name: "owned-machine".into(),
            persistent: true,
            ..MachineSpec::default()
        }
        .to_record();
        let config = existing_image_command(&record, "registry.example/team/image".into());
        assert_eq!(
            config.persistent_overlay_id.as_deref(),
            Some("owned-machine")
        );
        assert!(config.mounts.is_empty());
    }

    #[test]
    fn mapped_ports_do_not_silently_enable_outbound_networking() {
        let mut spec = MachineSpec::default();
        spec.resources.network = false;
        spec.resources.allowed_cidrs = Some(Vec::new());
        mapped_ports(&mut spec, 18080, 8080);
        let record = spec.to_record();
        assert_eq!(record.ports, vec![(18080, 8080)]);
        assert!(!record.network);
        assert_eq!(record.allowed_cidrs, Some(Vec::new()));
    }
}
