//! Typed volume requests/authority, separate from engine DTOs. Only operator
//! policy IDs arrive in requests; paths are owned result evidence.
use crate::{DomainIdentity, InvalidMessage};
use serde::{Deserialize, Serialize};
type Result<T> = std::result::Result<T, InvalidMessage>;

/// Additional volume bounds. Job metadata remains the work allowance; reserved
/// control metadata is an explicitly separate finite allowance for observations.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeLimits {
    pub work_ms: u64,
    pub observation_ms: u64,
    pub record_bytes: u64,
    pub delete_entries: u64,
    pub ancestor_bytes: u64,
    pub control_metadata_bytes: u64,
    pub observation_metadata_bytes: u64,
}
impl Default for VolumeLimits {
    fn default() -> Self {
        Self {
            work_ms: 86_400_000,
            observation_ms: 30_000,
            record_bytes: 16_384,
            delete_entries: 1_000_000,
            ancestor_bytes: 4096,
            control_metadata_bytes: 262_144,
            observation_metadata_bytes: 131_072,
        }
    }
}
fn check(value: bool) -> Result<()> {
    if value {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}
fn id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !matches!(value, "." | "..")
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
fn hex(value: &str, count: usize) -> bool {
    value.len() == count
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeIntent {
    pub worker_volume_id: String,
    pub size_gb: u64,
}
impl VolumeIntent {
    pub fn validate(&self) -> Result<()> {
        check(
            self.worker_volume_id
                .strip_prefix("sbv-")
                .is_some_and(|value| hex(value, 32))
                && (1..=1024).contains(&self.size_gb),
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum VolumeAction {
    Provision,
    Delete,
    ResolveDeletion { quiesced: bool },
    AbortStaging { quiesced: bool },
    InspectProvision,
    InspectDeletion,
    InspectAbort,
    QualifyDeletion,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeRequest {
    pub policy_id: String,
    pub intent: VolumeIntent,
    pub action: VolumeAction,
}
impl VolumeRequest {
    pub fn validate(&self, budget_ms: u64) -> Result<()> {
        check(id(&self.policy_id))?;
        self.intent.validate()?;
        check(budget_ms > 0 && budget_ms <= 86_400_000)?;
        match self.action {
            VolumeAction::ResolveDeletion { quiesced }
            | VolumeAction::AbortStaging { quiesced } => check(quiesced),
            _ if self.is_observation() => check(budget_ms <= 30_000),
            _ => Ok(()),
        }
    }
    pub fn is_observation(&self) -> bool {
        matches!(
            self.action,
            VolumeAction::InspectProvision
                | VolumeAction::InspectDeletion
                | VolumeAction::InspectAbort
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumePolicy {
    pub id: String,
    pub root: String,
}
impl VolumePolicy {
    pub fn validate(&self) -> Result<()> {
        check(
            id(&self.id)
                && self.root.starts_with('/')
                && self.root.len() <= 4059
                && !self.root.ends_with('/')
                && !self.root.contains('\0')
                && !self.root.contains('\\')
                && !self.root.contains("//")
                && !self.root.split('/').any(|part| matches!(part, "." | "..")),
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeBacking {
    pub schema: u8,
    pub target_id: String,
    pub domain_generation: String,
    pub policy: VolumePolicy,
    pub intent: VolumeIntent,
    pub owner_token: String,
    pub root_device: u64,
    pub root_inode: u64,
    pub device: u64,
    pub inode: u64,
    pub mode: u32,
}
impl VolumeBacking {
    pub fn validate(&self) -> Result<()> {
        self.policy.validate()?;
        self.intent.validate()?;
        check(
            self.schema == 1
                && id(&self.target_id)
                && hex(&self.domain_generation, 32)
                && hex(&self.owner_token, 64)
                && self.root_inode > 0
                && self.inode > 0
                && self.root_device == self.device
                && self.mode == 0o700,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeAccount {
    pub uid: u32,
    pub gid: u32,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeProvision {
    pub schema: u8,
    pub backing: VolumeBacking,
    pub account: VolumeAccount,
}
impl VolumeProvision {
    pub fn validate(&self) -> Result<()> {
        self.backing.validate()?;
        check(self.schema == 1 && self.account.uid > 0)
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeMount {
    pub proof: VolumeProvision,
    pub target: String,
    pub readonly: bool,
}
impl VolumeMount {
    pub fn validate_set(mounts: &[Self]) -> Result<()> {
        check(!mounts.is_empty() && mounts.len() <= 8)?;
        for (index, mount) in mounts.iter().enumerate() {
            mount.proof.validate()?;
            check(
                mount.target.starts_with("/mnt/volumes/")
                    && mount.target.len() <= 4096
                    && !mount.target.ends_with('/')
                    && !mount.target.contains('\0')
                    && !mount.target.contains('\\')
                    && !mount.target.contains("//")
                    && !mount
                        .target
                        .split('/')
                        .any(|part| matches!(part, "." | "..")),
            )?;
            check(
                mount.proof.backing.policy == mounts[0].proof.backing.policy
                    && mount.proof.account == mounts[0].proof.account,
            )?;
            for previous in &mounts[..index] {
                check(
                    previous.target < mount.target
                        && !mount.target.starts_with(&format!("{}/", previous.target))
                        && previous.proof.backing.intent.worker_volume_id
                            != mount.proof.backing.intent.worker_volume_id,
                )?;
            }
        }
        Ok(())
    }
    pub fn bound(mounts: &[Self], domain: &DomainIdentity) -> Result<()> {
        Self::validate_set(mounts)?;
        check(mounts.iter().all(|mount| {
            mount.proof.backing.target_id == domain.target_id
                && mount.proof.backing.domain_generation == domain.generation
        }))
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeDeletion {
    pub schema: u8,
    pub operation_id: String,
    pub provision: VolumeProvision,
}
impl VolumeDeletion {
    pub fn validate(&self) -> Result<()> {
        self.provision.validate()?;
        check(self.schema == 1 && hex(&self.operation_id, 32))
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeAbort {
    pub schema: u8,
    pub operation_id: String,
    pub backing: VolumeBacking,
    pub account: VolumeAccount,
}
impl VolumeAbort {
    pub fn validate(&self) -> Result<()> {
        self.backing.validate()?;
        check(self.schema == 1 && self.account.uid > 0 && hex(&self.operation_id, 32))
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum VolumeResult {
    Provisioned { proof: Box<VolumeProvision> },
    Deleted { proof: Box<VolumeDeletion> },
    Aborted { proof: Box<VolumeAbort> },
    Qualified { proof: Box<VolumeProvision> },
    Absent,
    Unverified,
}
impl VolumeResult {
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::Provisioned { proof } | Self::Qualified { proof } => proof.validate(),
            Self::Deleted { proof } => proof.validate(),
            Self::Aborted { proof } => proof.validate(),
            Self::Absent | Self::Unverified => Ok(()),
        }
    }
    pub fn backing(&self) -> Option<&VolumeBacking> {
        match self {
            Self::Provisioned { proof } | Self::Qualified { proof } => Some(&proof.backing),
            Self::Deleted { proof } => Some(&proof.provision.backing),
            Self::Aborted { proof } => Some(&proof.backing),
            Self::Absent | Self::Unverified => None,
        }
    }
    pub fn matches(&self, request: &VolumeRequest, domain: &DomainIdentity) -> Result<()> {
        self.validate()?;
        check(match (&request.action, self) {
            (
                VolumeAction::Provision | VolumeAction::InspectProvision,
                Self::Provisioned { .. },
            )
            | (
                VolumeAction::Delete
                | VolumeAction::ResolveDeletion { .. }
                | VolumeAction::InspectDeletion,
                Self::Deleted { .. },
            )
            | (
                VolumeAction::AbortStaging { .. } | VolumeAction::InspectAbort,
                Self::Aborted { .. },
            )
            | (VolumeAction::QualifyDeletion, Self::Qualified { .. })
            | (VolumeAction::InspectProvision, Self::Absent) => true,
            (_, Self::Unverified) => request.is_observation(),
            _ => false,
        })?;
        if let Some(backing) = self.backing() {
            check(
                backing.target_id == domain.target_id
                    && backing.domain_generation == domain.generation
                    && backing.policy.id == request.policy_id
                    && backing.intent == request.intent,
            )?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> VolumeRequest {
        VolumeRequest {
            policy_id: "local".into(),
            intent: VolumeIntent {
                worker_volume_id: format!("sbv-{}", "a".repeat(32)),
                size_gb: 4,
            },
            action: VolumeAction::Provision,
        }
    }
    fn proof() -> VolumeProvision {
        VolumeProvision {
            schema: 1,
            backing: VolumeBacking {
                schema: 1,
                target_id: "worker".into(),
                domain_generation: "b".repeat(32),
                policy: VolumePolicy {
                    id: "local".into(),
                    root: "/srv/smolvm/volumes".into(),
                },
                intent: request().intent,
                owner_token: "c".repeat(64),
                root_device: 1,
                root_inode: u64::MAX,
                device: 1,
                inode: u64::MAX - 1,
                mode: 0o700,
            },
            account: VolumeAccount {
                uid: 1000,
                gid: 1000,
            },
        }
    }
    #[test]
    fn requests_require_generated_ids_exact_policy_and_positive_fencing_without_host_paths() {
        request().validate(86_400_000).unwrap();
        for action in [
            VolumeAction::ResolveDeletion { quiesced: false },
            VolumeAction::AbortStaging { quiesced: false },
        ] {
            assert!(VolumeRequest {
                action,
                ..request()
            }
            .validate(1000)
            .is_err());
        }
        assert!(VolumeRequest {
            action: VolumeAction::InspectProvision,
            ..request()
        }
        .validate(30_001)
        .is_err());
        let mut value = serde_json::to_value(request()).unwrap();
        value["root"] = serde_json::json!("/caller/path");
        assert!(serde_json::from_value::<VolumeRequest>(value).is_err());
        for id in ["foreign", "../volume", "sbv-ABC"] {
            let mut r = request();
            r.intent.worker_volume_id = id.into();
            assert!(r.validate(1000).is_err());
        }
    }
    #[test]
    fn correlated_volume_results_preserve_full_unsigned_identity_and_reject_crossed_authority() {
        let domain = DomainIdentity {
            target_id: "worker".into(),
            generation: "b".repeat(32),
        };
        let result = VolumeResult::Provisioned {
            proof: Box::new(proof()),
        };
        result.matches(&request(), &domain).unwrap();
        let bytes = serde_json::to_vec(&result).unwrap();
        let decoded: VolumeResult = serde_json::from_slice(&bytes).unwrap();
        assert!(decoded == result);
        for field in ["worker_volume_id", "size_gb"] {
            let mut changed = request();
            if field == "worker_volume_id" {
                changed.intent.worker_volume_id = format!("sbv-{}", "f".repeat(32));
            } else {
                changed.intent.size_gb = 5;
            }
            assert!(result.matches(&changed, &domain).is_err());
        }
        assert!(result
            .matches(
                &VolumeRequest {
                    policy_id: "other".into(),
                    ..request()
                },
                &domain
            )
            .is_err());
        assert!(result
            .matches(
                &request(),
                &DomainIdentity {
                    generation: "d".repeat(32),
                    ..domain
                }
            )
            .is_err());
        assert!(VolumeResult::Absent
            .matches(
                &request(),
                &DomainIdentity {
                    target_id: "worker".into(),
                    generation: "b".repeat(32)
                }
            )
            .is_err());
    }
    #[test]
    fn proof_shapes_reject_root_accounts_unsafe_modes_unknown_fields_and_wrong_action_results() {
        let mut p = proof();
        p.account.uid = 0;
        assert!(p.validate().is_err());
        p = proof();
        p.backing.mode = 0o777;
        assert!(p.validate().is_err());
        let mut value = serde_json::to_value(proof()).unwrap();
        value["adopt_existing"] = serde_json::Value::Bool(true);
        assert!(serde_json::from_value::<VolumeProvision>(value).is_err());
        assert!(VolumeResult::Qualified {
            proof: Box::new(proof())
        }
        .matches(
            &request(),
            &DomainIdentity {
                target_id: "worker".into(),
                generation: "b".repeat(32)
            }
        )
        .is_err());
    }
}
