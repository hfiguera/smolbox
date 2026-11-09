use crate::domain::{valid_hex, valid_id};
use crate::{DomainBinding, Error, ErrorCode, Result};
use sha2::{Digest, Sha256};
use smolvm::config::{RecordState, VmRecord};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Resources {
    pub cpus: u8,
    pub memory_mib: u32,
    pub storage_gib: u64,
    pub overlay_gib: u64,
}

impl Resources {
    pub fn validate(&self) -> Result<()> {
        // In particular, libkrun silently clamps >16 vCPUs. Admission must not
        // report that a requested configuration was applied when it was not.
        if !(1..=16).contains(&self.cpus)
            || !(64..=65536).contains(&self.memory_mib)
            || !(1..=1024).contains(&self.storage_gib)
            || !(1..=1024).contains(&self.overlay_gib)
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        Ok(())
    }
}

/// Returned only by a successful create, then held by the durable caller.
/// Inventory inspection never mints this authority from copied labels.
#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreationReceipt {
    pub target_id: String,
    pub domain_generation: String,
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub material_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub material: Option<crate::MaterialProof>,
}

impl std::fmt::Debug for CreationReceipt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CreationReceipt")
            .field("target_id", &self.target_id)
            .field("name", &self.name)
            .finish_non_exhaustive()
    }
}

impl CreationReceipt {
    pub(crate) fn validate(&self, domain: &DomainBinding) -> Result<()> {
        if !valid_id(&self.name)
            || !valid_hex(&self.owner_token, 64)
            || !valid_hex(&self.incarnation, 32)
            || !valid_hex(&self.material_sha256, 64)
            || self.target_id != domain.target_id
            || self.domain_generation != domain.generation
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(proof) = &self.material {
            proof.validate()?;
            if proof.revision == 0 && proof.record_sha256 != self.material_sha256 {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }

    pub(crate) fn matches(&self, record: &VmRecord) -> Result<bool> {
        Ok(self.name == record.name
            && self
                .material
                .as_ref()
                .map_or(&self.material_sha256, |proof| &proof.record_sha256)
                == &material_hash(record)?
            && record.labels.get("smolbox.owner") == Some(&self.owner_token))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ObservedState {
    Missing,
    Stopped,
    Running,
    Paused,
    Pausing,
    Frozen,
    Failed,
    Unreachable,
    /// A live PID cannot be proven to be the expected VMM.
    IdentityUnknown,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Observation {
    pub state: ObservedState,
    /// Stored configuration, not an attestation of resources applied in guest.
    pub resources: Option<Resources>,
    // Observational PID identity is not assignment identity or store authority.
    pub pid_identity: Option<(i32, u64)>,
    pub configuration: Option<Box<crate::MachineConfiguration>>,
}

impl std::fmt::Debug for Observation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Observation")
            .field("state", &self.state)
            .field("resources", &self.resources)
            .finish_non_exhaustive()
    }
}

pub(crate) fn material_hash(record: &VmRecord) -> Result<String> {
    let value = material_value(record)?;
    let bytes = serde_json::to_vec(&value).map_err(|_| Error::before(ErrorCode::Native))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

pub(crate) fn material_value(record: &VmRecord) -> Result<serde_json::Value> {
    let mut value = serde_json::to_value(record).map_err(|_| Error::before(ErrorCode::Native))?;
    let fields = value
        .as_object_mut()
        .ok_or(Error::before(ErrorCode::Native))?;
    // Hash all material fields in the exact pinned schema. Unknown future fields
    // are included, rather than silently authorizing a smaller projection.
    for field in [
        "state",
        "pid",
        "pid_start_time",
        "last_exit_code",
        "init_completed",
        "pause_reason",
        "engine_build",
        "agent_rootfs_digest",
        "agent_rootfs_path",
    ] {
        fields.remove(field);
    }
    // These 1.34.0 fields serialize their defaults. Keep existing receipt
    // hashes for unchanged records while binding any non-default setting.
    if fields
        .get("disk_durability")
        .and_then(|value| value.as_str())
        == Some("full")
    {
        fields.remove("disk_durability");
    }
    if fields
        .get("staged_mounts_detached_from")
        .is_some_and(serde_json::Value::is_null)
    {
        fields.remove("staged_mounts_detached_from");
    }
    Ok(value)
}

pub(crate) fn verify_boot_rootfs(record: &VmRecord, rootfs: &std::path::Path) -> Result<()> {
    // A branch must use the same rootfs as its source. Match the digest the
    // SDK will see for this approved directory before it can resolve any
    // alternate path from the source record.
    if let Some(expected) = &record.agent_rootfs_digest {
        let observed = smolvm_pack::assets::cached_agent_rootfs_digest(rootfs)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if *expected != observed {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    Ok(())
}

pub(crate) fn record_state(record: &VmRecord, has_dependents: bool) -> ObservedState {
    if record.paused_checkpoint.is_some() || record.state == RecordState::Paused {
        return ObservedState::Paused;
    }
    match record.state {
        RecordState::Pausing => return ObservedState::Pausing,
        RecordState::Frozen => return ObservedState::Frozen,
        RecordState::Failed => return ObservedState::Failed,
        _ => {}
    }
    if has_dependents {
        return ObservedState::Frozen;
    }
    if let Some(pid) = record.pid {
        if smolvm::process::is_alive(pid) {
            if !smolvm::process::is_our_process_strict(pid, record.pid_start_time) {
                return ObservedState::IdentityUnknown;
            }
            return ObservedState::Running; // Must still qualify with an agent ping.
        }
    }
    ObservedState::Stopped
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record() -> VmRecord {
        VmRecord::new("owned".into(), 1, 512, vec![], vec![], false)
    }

    #[test]
    fn every_material_field_matters_but_runtime_transitions_do_not_change_receipt() {
        let mut r = record();
        let hash = material_hash(&r).unwrap();
        r.state = RecordState::Running;
        r.pid = Some(1);
        r.pid_start_time = Some(2);
        r.last_exit_code = Some(0);
        r.init_completed = true;
        r.engine_build = Some("runtime-build".into());
        r.agent_rootfs_digest = Some(format!("sha256:{}", "a".repeat(64)));
        r.agent_rootfs_path = Some("/verified/agent-rootfs".into());
        assert_eq!(hash, material_hash(&r).unwrap());
        r.disk_durability = smolvm::data::resources::DiskDurability::Deferred;
        assert_ne!(hash, material_hash(&r).unwrap());
        r.disk_durability = smolvm::data::resources::DiskDurability::Full;
        r.created_at += 1;
        assert_ne!(hash, material_hash(&r).unwrap());
        r.created_at -= 1;
        r.network = true;
        assert_ne!(hash, material_hash(&r).unwrap());
        r.network = false;
        r.source_smolmachine = Some("foreign".into());
        assert_ne!(hash, material_hash(&r).unwrap());
        let packed_hash = material_hash(&r).unwrap();
        r.source_registry_ref = Some(format!(
            "registry.example/team/app@sha256:{}",
            "a".repeat(64)
        ));
        assert_ne!(packed_hash, material_hash(&r).unwrap());
        let registry_hash = material_hash(&r).unwrap();
        r.source_registry_ref = Some(format!(
            "registry.example/team/app@sha256:{}",
            "b".repeat(64)
        ));
        assert_ne!(registry_hash, material_hash(&r).unwrap());
    }

    #[test]
    fn live_pid_without_verified_start_time_is_never_stopped_or_owned() {
        let mut r = record();
        r.pid = Some(std::process::id() as i32);
        assert_eq!(record_state(&r, false), ObservedState::IdentityUnknown);
        r.pid_start_time = smolvm::process::process_start_time(r.pid.unwrap());
        assert_eq!(record_state(&r, false), ObservedState::Running);
        r.pid_start_time = Some(0);
        assert_eq!(record_state(&r, false), ObservedState::IdentityUnknown);
    }

    #[test]
    fn paused_failed_and_frozen_are_not_collapsed_to_stopped() {
        let mut r = record();
        assert_eq!(record_state(&r, true), ObservedState::Frozen);
        for (state, expected) in [
            (RecordState::Paused, ObservedState::Paused),
            (RecordState::Pausing, ObservedState::Pausing),
            (RecordState::Failed, ObservedState::Failed),
            (RecordState::Frozen, ObservedState::Frozen),
        ] {
            r.state = state;
            assert_eq!(record_state(&r, false), expected);
        }
    }
}
