//! Fresh namespace absence under original unbooted disposal, without a boot or
//! guest-completion surrogate. Proof correlation never grants SDK ownership.
use crate::{Error, ErrorCode, Result, UnbootedBranchDisposal};
use serde::{Deserialize, Serialize};
pub const UNBOOTED_BRANCH_ABSENCE_BYTES: usize = 68 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchChildAbsenceRequest {
    pub disposal: UnbootedBranchDisposal,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for UnbootedBranchChildAbsenceRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnbootedBranchChildAbsenceRequest")
            .finish_non_exhaustive()
    }
}
impl UnbootedBranchChildAbsenceRequest {
    pub fn validate(&self) -> Result<()> {
        self.disposal.validate()?;
        let creation = &self.disposal.creation;
        if !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id == creation.child.operation_id
            || self.operation_id == self.disposal.request.operation_id
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|release| release.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > UNBOOTED_BRANCH_ABSENCE_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-unbooted-branch-child-absence-request-v1",
            &self.disposal,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn matches(&self, proof: &UnbootedBranchChildAbsence) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if self != &proof.request {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

/// Historical positive observation, never child readiness, SDK disposal,
/// source dependency retirement or backing accounting release by itself.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchChildAbsence {
    pub schema: u8,
    pub request: UnbootedBranchChildAbsenceRequest,
    pub proof_sha256: String,
}
impl std::fmt::Debug for UnbootedBranchChildAbsence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnbootedBranchChildAbsence")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl UnbootedBranchChildAbsence {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        if self.schema != 1
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > UNBOOTED_BRANCH_ABSENCE_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-unbooted-branch-child-absence-v1",
            self.schema,
            &self.request,
        ))
    }
    pub(crate) fn issue(request: UnbootedBranchChildAbsenceRequest) -> Result<Self> {
        let mut result = Self {
            schema: 1,
            request,
            proof_sha256: String::new(),
        };
        result.proof_sha256 = result.digest()?;
        result.validate()?;
        Ok(result)
    }
}
