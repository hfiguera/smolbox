//! Positive original residual eligibility, never a removal or disposal grant.
use crate::{Error, ErrorCode, PartialBranchDisposal, PartialBranchDisposalRequest, Result};
use serde::{Deserialize, Serialize};
pub const PARTIAL_BRANCH_CLEANUP_CANDIDATE_BYTES: usize = 48 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchCleanupCandidate {
    pub schema: u8,
    pub request: PartialBranchDisposalRequest,
    pub publication: crate::BranchPublication,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release: Option<crate::BranchReleaseTransition>,
    pub disposal_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchCleanupCandidate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchCleanupCandidate")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchCleanupCandidate {
    pub fn validate(&self) -> Result<()> {
        crate::branch_partial_disposal::validate_context(
            &self.request,
            &self.publication,
            self.release.as_ref(),
        )?;
        if self.schema != 1
            || !crate::domain::valid_hex(&self.disposal_sha256, 64)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PARTIAL_BRANCH_CLEANUP_CANDIDATE_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub fn matches_request(&self, request: &PartialBranchDisposalRequest) -> Result<()> {
        self.validate()?;
        request.validate()?;
        if self.request != *request {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-cleanup-candidate-v1",
            self.schema,
            &self.request,
            &self.publication,
            &self.release,
            &self.disposal_sha256,
        ))
    }
    pub(crate) fn issue(
        request: &PartialBranchDisposalRequest,
        publication: &crate::BranchPublication,
        release: Option<&crate::BranchReleaseTransition>,
        disposal_sha256: String,
    ) -> Result<Self> {
        let mut result = Self {
            schema: 1,
            request: request.clone(),
            publication: publication.clone(),
            release: release.cloned(),
            disposal_sha256,
            proof_sha256: String::new(),
        };
        result.proof_sha256 = result.digest()?;
        result.validate()?;
        Ok(result)
    }
}

/// Qualification selects a positive residual candidate or the original terminal
/// disposal with its original provenance. Neither variant creates cleanup work.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", deny_unknown_fields)]
pub enum PartialBranchCleanupState {
    Residual {
        candidate: Box<PartialBranchCleanupCandidate>,
    },
    Disposed {
        proof: Box<PartialBranchDisposal>,
    },
}

#[cfg(test)]
mod reader_tests {
    use super::*;
    #[test]
    fn independent_synthetic_fixture_roundtrips_without_sdk_or_original_authority() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-cleanup-candidate-v1.json"
        ))
        .unwrap();
        for row in rows {
            let request: PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let candidate: PartialBranchCleanupCandidate =
                serde_json::from_value(row["candidate"].clone()).unwrap();
            candidate.matches_request(&request).unwrap();
            assert_eq!(serde_json::to_value(candidate).unwrap(), row["candidate"]);
        }
    }
}
