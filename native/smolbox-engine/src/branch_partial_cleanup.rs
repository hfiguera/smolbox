//! Explicit original partial-disposal residual cleanup, never SDK delete retry,
//! initialization completion or dependency/backing retirement.
use crate::{Error, ErrorCode, PartialBranchDisposal, PartialBranchDisposalRequest, Result};
use serde::{Deserialize, Serialize};
pub const PARTIAL_BRANCH_CLEANUP_REQUEST_BYTES: usize = 28 * 1024;
pub const PARTIAL_BRANCH_CLEANUP_PROOF_BYTES: usize = 80 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposalCleanupRequest {
    pub disposal_request: PartialBranchDisposalRequest,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for PartialBranchDisposalCleanupRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposalCleanupRequest")
            .finish_non_exhaustive()
    }
}
impl PartialBranchDisposalCleanupRequest {
    pub fn validate(&self) -> Result<()> {
        self.disposal_request.validate()?;
        let creation = &self.disposal_request.collection_request.creation;
        if !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id == self.disposal_request.operation_id
            || self.operation_id == self.disposal_request.collection_request.operation_id
            || self.operation_id == creation.child.operation_id
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|r| r.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PARTIAL_BRANCH_CLEANUP_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-disposal-cleanup-request-v1",
            &self.disposal_request,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn matches(&self, proof: &PartialBranchDisposalCleanup) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if proof.request != *self {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposalCleanup {
    pub schema: u8,
    pub request: PartialBranchDisposalCleanupRequest,
    pub disposal: PartialBranchDisposal,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchDisposalCleanup {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposalCleanup")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchDisposalCleanup {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        self.disposal.validate()?;
        if self.schema != 1
            || self.disposal.request != self.request.disposal_request
            || self.disposal.completion != crate::PartialBranchDisposalCompletion::ResolvedAbsent
            || self
                .disposal
                .release
                .as_ref()
                .is_some_and(|r| r.change.request.operation_id == self.request.operation_id)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PARTIAL_BRANCH_CLEANUP_PROOF_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-disposal-cleanup-v1",
            self.schema,
            &self.request,
            &self.disposal,
        ))
    }
    pub(crate) fn issue(
        request: &PartialBranchDisposalCleanupRequest,
        disposal: PartialBranchDisposal,
    ) -> Result<Self> {
        let mut proof = Self {
            schema: 1,
            request: request.clone(),
            disposal,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        proof.validate()?;
        Ok(proof)
    }
}
