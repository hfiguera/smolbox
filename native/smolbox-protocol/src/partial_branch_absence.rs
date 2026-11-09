//! Correlation for original collected pre-handoff child absence, never boot completion or
//! authority to dispose, retire a dependency or release accounting by itself.
use crate::{BranchApproval, InvalidMessage, PartialBranchDisposal};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
pub const PARTIAL_BRANCH_ABSENCE_BYTES: usize = 56 * 1024;
fn check(value: bool) -> Result<(), InvalidMessage> {
    if value {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}
fn hash(value: &impl Serialize) -> Result<String, InvalidMessage> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchChildAbsenceRequest {
    pub disposal: PartialBranchDisposal,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl PartialBranchChildAbsenceRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.disposal.validate()?;
        crate::wire::id(&self.operation_id)?;
        let creation = &self.disposal.request.collection_request.creation;
        check(
            self.quiesced
                && self.operation_id != creation.child.operation_id
                && self.operation_id != self.disposal.request.operation_id
                && self.operation_id != self.disposal.request.collection_request.operation_id
                && self
                    .disposal
                    .release
                    .as_ref()
                    .is_none_or(|r| r.change.request.operation_id != self.operation_id)
                && creation
                    .initial_release
                    .as_ref()
                    .is_none_or(|release| release.operation_id != self.operation_id)
                && self.request_sha256 == self.digest()?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= PARTIAL_BRANCH_ABSENCE_BYTES,
        )
    }
    pub fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-partial-branch-child-absence-request-v1",
            &self.disposal,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn approval(&self) -> &BranchApproval {
        &self.disposal.request.collection_request.creation.approval
    }
    pub fn matches(&self, proof: &PartialBranchChildAbsence) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        check(proof.request == *self)
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchChildAbsence {
    pub schema: u8,
    pub request: PartialBranchChildAbsenceRequest,
    pub proof_sha256: String,
}
impl PartialBranchChildAbsence {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.request.validate()?;
        check(
            self.schema == 1
                && self.proof_sha256
                    == hash(&(
                        "smolbox-partial-branch-child-absence-v1",
                        self.schema,
                        &self.request,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= PARTIAL_BRANCH_ABSENCE_BYTES,
        )
    }
}

#[cfg(test)]
mod tests;
