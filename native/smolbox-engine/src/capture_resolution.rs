//! Explicit resolution of an entered capture is not capture completion.
//! It authorizes only the owned source's checkpoint-head material change after
//! capture-worker collection, whether the source is stopped or remains live.
use crate::capture_material::Intent;
use crate::domain::{valid_hex, valid_id};
use crate::material::{check_origin, hash, root_proof};
use crate::{CreationReceipt, Error, ErrorCode, MaterialProof, Result};
use serde::{Deserialize, Serialize};

/// Ephemeral source authority, constructed from engine/cache/process facts.
/// A stopped SDK row or a matching live PID alone cannot construct it.
pub(crate) struct SourceAuthority {
    pid: (i32, u64),
    running: bool,
}
pub(crate) struct SourceFacts {
    pub owner: Option<bool>,
    pub runtime_pid: Option<i32>,
    pub original_alive: bool,
    pub observed_birth: Option<u64>,
    pub excluded: bool,
}
impl SourceAuthority {
    pub(crate) fn verify(
        record: &smolvm::config::VmRecord,
        pid: (i32, u64),
        facts: SourceFacts,
    ) -> Result<Self> {
        use smolvm::config::RecordState;
        let running = record.state == RecordState::Running;
        let valid = if running {
            facts.owner == Some(true)
                && facts.runtime_pid == Some(pid.0)
                && facts.original_alive
                && facts.observed_birth == Some(pid.1)
                && record.pid.zip(record.pid_start_time) == Some(pid)
        } else {
            record.state == RecordState::Stopped
                && record.pid.is_none()
                && record.pid_start_time.is_none()
                && facts.owner.is_none()
                && facts.runtime_pid.is_none()
                && (!facts.original_alive
                    || facts.observed_birth.is_some_and(|birth| birth != pid.1))
        };
        if !valid || facts.excluded {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(Self { pid, running })
    }
    pub(crate) fn matches(&self, record: &smolvm::config::VmRecord, pid: (i32, u64)) -> bool {
        self.pid == pid
            && if self.running {
                record.state == smolvm::config::RecordState::Running
                    && record.pid.zip(record.pid_start_time) == Some(pid)
            } else {
                record.state == smolvm::config::RecordState::Stopped
                    && record.pid.is_none()
                    && record.pid_start_time.is_none()
            }
    }
    pub(crate) fn running(&self) -> bool {
        self.running
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureResolutionChange {
    pub(crate) intent: Intent,
    pub checkpoint_head: Option<String>,
    pub(crate) growth_immutable_sha256: String,
}
impl CaptureResolutionChange {
    pub fn operation_id(&self) -> &str {
        &self.intent.operation_id
    }
    pub fn request(&self) -> &crate::CaptureRequest {
        &self.intent.request
    }
    pub(crate) fn valid(&self) -> bool {
        self.intent.valid()
            && self.checkpoint_head.as_ref().is_none_or(|head| valid_hex(head, 32))
            // An entered capture may retain or advance a head, never erase it.
            && (self.intent.previous_head.is_none() || self.checkpoint_head.is_some())
            && valid_hex(&self.growth_immutable_sha256, 64)
    }
}

/// No artifact digest, size or successful capture result is present. The caller
/// must persist this distinct history before using the resulting receipt.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureResolutionTransition {
    pub schema: u8,
    pub previous: CreationReceipt,
    pub receipt: CreationReceipt,
    pub change: CaptureResolutionChange,
}
impl std::fmt::Debug for CaptureResolutionTransition {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CaptureResolutionTransition")
            .field("schema", &self.schema)
            .field(
                "revision",
                &self.receipt.material.as_ref().map(|proof| proof.revision),
            )
            .finish_non_exhaustive()
    }
}
impl CaptureResolutionTransition {
    pub fn validate(&self) -> Result<()> {
        let previous = self
            .previous
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let proof = self
            .receipt
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let mut origin = self.previous.clone();
        origin.material = None;
        check_origin(&origin, &self.receipt)?;
        if self.schema != 1
            || !valid_id(&origin.target_id)
            || !valid_hex(&origin.domain_generation, 32)
            || !valid_id(&origin.name)
            || !valid_hex(&origin.owner_token, 64)
            || !valid_hex(&origin.incarnation, 32)
            || !valid_hex(&origin.material_sha256, 64)
            || !self.change.valid()
            || *previous != self.change.intent.previous
            || (previous.revision == 0 && *previous != root_proof(&origin)?)
            || *proof != next_proof(&self.change, proof.record_sha256.clone())?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        proof.validate()
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Resolved {
    pub change: CaptureResolutionChange,
    pub proof: MaterialProof,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resulting_immutable_sha256: Option<String>,
}

pub(crate) fn next_proof(
    change: &CaptureResolutionChange,
    record_sha256: String,
) -> Result<MaterialProof> {
    if !change.valid() || change.intent.previous.revision >= 1024 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(MaterialProof {
        schema: 2,
        revision: change.intent.previous.revision + 1,
        chain_sha256: hash(&(
            "smolbox-quiesced-capture-resolution-v1",
            change,
            &record_sha256,
        ))?,
        record_sha256,
        operation_id: Some(change.intent.operation_id.clone()),
        request_sha256: Some(hash(&change.intent.request)?),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn running_authority_requires_original_cache_owner_process_and_exact_record_without_inventory_adoption(
    ) {
        let mut record =
            smolvm::config::VmRecord::new("source".into(), 1, 512, vec![], vec![], false);
        record.state = smolvm::config::RecordState::Running;
        record.pid = Some(123);
        record.pid_start_time = Some(456);
        let facts = || SourceFacts {
            owner: Some(true),
            runtime_pid: Some(123),
            original_alive: true,
            observed_birth: Some(456),
            excluded: false,
        };
        let authority = SourceAuthority::verify(&record, (123, 456), facts()).unwrap();
        assert!(authority.running() && authority.matches(&record, (123, 456)));
        for case in 0..7 {
            let mut invalid = facts();
            match case {
                0 => invalid.owner = None,
                1 => invalid.owner = Some(false),
                2 => invalid.runtime_pid = None,
                3 => invalid.runtime_pid = Some(789),
                4 => invalid.original_alive = false,
                5 => invalid.observed_birth = None,
                _ => invalid.excluded = true,
            }
            assert!(SourceAuthority::verify(&record, (123, 456), invalid).is_err());
        }
        let mut invalid = facts();
        invalid.observed_birth = Some(457);
        assert!(SourceAuthority::verify(&record, (123, 456), invalid).is_err());
        record.pid_start_time = Some(457);
        assert!(!authority.matches(&record, (123, 456)));
        assert!(SourceAuthority::verify(&record, (123, 456), facts()).is_err());
    }

    #[test]
    fn shared_resolution_wire_fixtures_match_the_engine_proof_domain_and_never_capture_success() {
        let proofs: Vec<CaptureResolutionTransition> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/capture-resolutions-v1.json"
        ))
        .unwrap();
        for proof in proofs {
            proof.validate().unwrap();
            let value = serde_json::to_value(&proof).unwrap();
            assert!(serde_json::from_value::<crate::CaptureTransition>(value).is_err());
            let mut changed = proof.clone();
            changed.change.intent.source_pid.1 += 1;
            assert!(changed.validate().is_err());
            let mut changed = proof;
            changed.receipt.material.as_mut().unwrap().chain_sha256 = "f".repeat(64);
            assert!(changed.validate().is_err());
        }
    }
}
