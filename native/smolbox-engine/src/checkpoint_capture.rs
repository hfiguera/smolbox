//! Bare guest eligibility for checkpoint capture and managed branching.
//! Eligibility leaves guest idleness and material authority to the caller.
use crate::{Error, ErrorCode, Resources, Result};
use smolvm::config::{RestartPolicy, VmRecord};
use smolvm_pack::format::{PackManifest, PackMode};

pub(crate) fn validate_pack(manifest: &PackManifest) -> Result<()> {
    if manifest.mode != PackMode::Vm
        || !manifest.assets.layers.is_empty()
        || manifest.assets.workspace_seed.is_some()
        || !manifest.secret_refs.is_empty()
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(())
}

pub(crate) fn validate_record(record: &VmRecord) -> Result<Resources> {
    validate_bare_record(record, false)
}

pub(crate) fn validate_branch_record(record: &VmRecord) -> Result<Resources> {
    let networked = record.network;
    if networked {
        if !cfg!(target_os = "linux")
            || record.network_backend != Some(smolvm::network::NetworkBackend::VirtioNet)
            || record.dns_filter_hosts.is_none()
            || record.allowed_cidrs.is_none()
            || record.guest_subnet.is_some()
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let observed = crate::MachineConfiguration::observe_explicit(record);
        crate::CreationFeatures {
            branch_https: false,
            network: observed.network,
            ports: vec![],
            workload: None,
        }
        .validate()?;
    }
    validate_bare_record(record, networked)
}

fn validate_bare_record(record: &VmRecord, static_egress: bool) -> Result<Resources> {
    smolvm::portable_checkpoint::validate_capture_profile(record, false)
        .map_err(|_| Error::before(ErrorCode::Unsupported))?;
    if record.image.is_some()
        || record.launch_network_plan().has_network() != static_egress
        || !record.ports.is_empty()
        || !record.udp_ports.is_empty()
        || !record.disks.is_empty()
        || record.cache_disk.is_some()
        || !record.disk_volumes.is_empty()
        || record.disk_durability != smolvm::data::resources::DiskDurability::Full
        || record.nested_virt.unwrap_or(false)
        || (!static_egress && record.network_backend.is_some())
        || !record.egress_rules.is_empty()
        || !record.dns_options.is_empty()
        || record.block_private.is_some()
        || record.mediated_egress_required
        || record.external_interceptor_required
        || (!static_egress
            && record
                .dns_filter_hosts
                .as_ref()
                .is_some_and(|values| !values.is_empty()))
        || (!static_egress
            && (record.credential_policy.is_some()
                || !record.credential_placeholders.is_empty()
                || record.credentials_supplied_by_api))
        || record.entrypoint != ["/bin/true"]
        || !record.cmd.is_empty()
        || !record.env.is_empty()
        || record.user.is_some()
        || record.workdir.as_deref() != Some("/")
        || record.restart.policy != RestartPolicy::Never
        || record.paused_checkpoint.is_some()
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    let resources = Resources {
        cpus: record.cpus,
        memory_mib: record.mem,
        storage_gib: record
            .storage_gb
            .ok_or(Error::before(ErrorCode::Validation))?,
        overlay_gib: record
            .overlay_gb
            .ok_or(Error::before(ErrorCode::Validation))?,
    };
    if static_egress {
        crate::branch_credentials::validate_record(record)?;
    }
    resources.validate()?;
    Ok(resources)
}

/// SDK 1.22 records a pack dependency for every source_smolmachine, including
/// bare packs without OCI layers. That output violates the self-contained
/// checkpoint contract. Branching still accepts its separate bare-pack profile.
pub(crate) fn validate_portable_record(record: &VmRecord) -> Result<Resources> {
    let resources = validate_record(record)?;
    if record.source_smolmachine.is_some() || record.source_registry_ref.is_some() {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(resources)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn record() -> VmRecord {
        let mut record = smolvm::embedded::MachineSpec {
            name: "capture-source".into(),
            persistent: true,
            resources: smolvm::agent::VmResources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: Some(1),
                overlay_gib: Some(1),
                network: false,
                ..Default::default()
            },
            ..Default::default()
        }
        .to_record()
        .unwrap();
        record.entrypoint = vec!["/bin/true".into()];
        record.cmd.clear();
        record.env.clear();
        record.workdir = Some("/".into());
        record.user = None;
        record
    }

    #[test]
    fn capture_profile_is_bare_offline_neutral_and_has_exact_allocations() {
        let source = record();
        assert_eq!(
            validate_record(&source).unwrap(),
            Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 1,
                overlay_gib: 1
            }
        );
        for case in 0..13 {
            let mut changed = source.clone();
            match case {
                0 => changed.image = Some("container".into()),
                1 => changed.network = true,
                2 => changed.ports = vec![(8080, 80)],
                3 => changed.env = vec![("TOKEN".into(), "private".into())],
                4 => changed.entrypoint = vec!["/application".into()],
                5 => changed.user = Some("0".into()),
                6 => changed.nested_virt = Some(true),
                7 => changed.mounts = vec![("/host".into(), "/guest".into(), false)],
                8 => {
                    changed.secret_refs.insert(
                        "secret".into(),
                        serde_json::from_value(serde_json::json!({"from_env":"SECRET"})).unwrap(),
                    );
                }
                9 => changed.credentials_supplied_by_api = true,
                10 => changed.restart.policy = RestartPolicy::Always,
                11 => changed.allowed_cidrs = Some(vec![]),
                _ => changed.storage_gb = None,
            }
            assert!(validate_record(&changed).is_err(), "{case}");
        }
    }

    #[test]
    fn portable_capture_excludes_sdk_pack_dependencies_before_entry_but_branches_remain_eligible() {
        let mut source = record();
        assert!(validate_portable_record(&source).is_ok());
        source.source_smolmachine = Some("/approved/bare.smolmachine".into());
        assert!(validate_record(&source).is_ok());
        let error = validate_portable_record(&source).unwrap_err();
        assert_eq!(error.code, ErrorCode::Unsupported);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        source.source_smolmachine = None;
        source.source_registry_ref = Some("registry.example/pack".into());
        assert!(validate_portable_record(&source).is_err());
    }

    #[test]
    fn eligibility_does_not_attest_guest_idle_or_remove_material_fields() {
        let mut source = record();
        let before = crate::identity::material_hash(&source).unwrap();
        validate_record(&source).unwrap();
        assert_eq!(crate::identity::material_hash(&source).unwrap(), before);
        source.forkable = true;
        let opted_in = crate::identity::material_hash(&source).unwrap();
        assert_ne!(opted_in, before);
        source.checkpoint_head = Some("a".repeat(32));
        assert_ne!(crate::identity::material_hash(&source).unwrap(), opted_in);
    }
}
