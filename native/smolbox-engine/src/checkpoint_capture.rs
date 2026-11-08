//! Shared bare/offline capture eligibility. This is neither guest-idleness
//! evidence nor permission to adopt a record or change its material fields.
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
    smolvm::portable_checkpoint::validate_capture_profile(record)
        .map_err(|_| Error::before(ErrorCode::Unsupported))?;
    if record.image.is_some()
        || record.network
        || !record.ports.is_empty()
        || !record.disks.is_empty()
        || record.nested_virt.unwrap_or(false)
        || record.network_backend.is_some()
        || record
            .allowed_cidrs
            .as_ref()
            .is_some_and(|values| !values.is_empty())
        || record
            .dns_filter_hosts
            .as_ref()
            .is_some_and(|values| !values.is_empty())
        || record.credential_policy.is_some()
        || !record.credential_placeholders.is_empty()
        || record.credentials_supplied_by_api
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
    resources.validate()?;
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
                allowed_cidrs: Some(vec![]),
                ..Default::default()
            },
            ..Default::default()
        }
        .to_record();
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
        for case in 0..12 {
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
                _ => changed.storage_gb = None,
            }
            assert!(validate_record(&changed).is_err(), "{case}");
        }
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
