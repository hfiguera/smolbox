//! Capture evidence stays distinct from disk growth and generic observation.
use crate::domain::{valid_hex, valid_id};
use crate::material::{check_origin, hash, root_proof};
use crate::{CreationReceipt, Error, ErrorCode, MaterialProof, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureRequest {
    pub max_bytes: u64,
    pub idle: bool,
}
impl CaptureRequest {
    pub fn validate(&self) -> Result<()> {
        if !self.idle || self.max_bytes == 0 || self.max_bytes > crate::CHECKPOINT_ARTIFACT_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureArtifact {
    pub sha256: String,
    pub size_bytes: u64,
    pub head: String,
    pub parent: Option<String>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Intent {
    pub operation_id: String,
    pub request: CaptureRequest,
    pub previous: MaterialProof,
    pub immutable_sha256: String,
    pub previous_head: Option<String>,
    pub source_pid: (i32, u64),
    pub growth_immutable_sha256: String,
}
impl Intent {
    pub(crate) fn valid(&self) -> bool {
        valid_id(&self.operation_id)
            && self.request.validate().is_ok()
            && self.previous.validate().is_ok()
            && valid_hex(&self.immutable_sha256, 64)
            && valid_hex(&self.growth_immutable_sha256, 64)
            && self
                .previous_head
                .as_ref()
                .is_none_or(|value| valid_hex(value, 32))
            && self.source_pid.0 > 0
            && self.source_pid.1 > 0
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureChange {
    pub(crate) intent: Intent,
    pub artifact: CaptureArtifact,
    pub(crate) growth_immutable_sha256: String,
}
impl CaptureChange {
    pub fn operation_id(&self) -> &str {
        &self.intent.operation_id
    }
    pub fn request(&self) -> &CaptureRequest {
        &self.intent.request
    }
    pub(crate) fn valid(&self) -> bool {
        self.intent.valid()
            && valid_hex(&self.artifact.sha256, 64)
            && self.artifact.size_bytes > 0
            && self.artifact.size_bytes <= self.intent.request.max_bytes
            && valid_hex(&self.artifact.head, 32)
            && self.artifact.parent == self.intent.previous_head
            && self.artifact.parent.as_ref() != Some(&self.artifact.head)
            && valid_hex(&self.growth_immutable_sha256, 64)
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureTransition {
    pub schema: u8,
    pub previous: CreationReceipt,
    pub receipt: CreationReceipt,
    pub change: CaptureChange,
}
impl std::fmt::Debug for CaptureTransition {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CaptureTransition")
            .field("schema", &self.schema)
            .field(
                "revision",
                &self.receipt.material.as_ref().map(|proof| proof.revision),
            )
            .finish_non_exhaustive()
    }
}
impl CaptureTransition {
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
pub(crate) struct Completed {
    pub change: CaptureChange,
    pub proof: MaterialProof,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resulting_immutable_sha256: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Pending {
    pub intent: Intent,
    pub entered: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_lineage: Option<u64>,
}
pub(crate) struct Permit {
    pub intent: Intent,
    pub directory: (u64, u64),
}
pub(crate) fn next_proof(change: &CaptureChange, record_sha256: String) -> Result<MaterialProof> {
    if !change.valid() || change.intent.previous.revision >= 1024 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(MaterialProof {
        schema: 2,
        revision: change.intent.previous.revision + 1,
        chain_sha256: hash(&(
            "smolbox-checkpoint-capture-transition-v1",
            change,
            &record_sha256,
        ))?,
        record_sha256,
        operation_id: Some(change.intent.operation_id.clone()),
        request_sha256: Some(hash(&change.intent.request)?),
    })
}
