//! Acknowledgement that an accepted cleanup is unnecessary after original
//! disposal. This is not residual removal, SDK-entry or dependency-release proof.
use crate::{Error, ErrorCode, PartialBranchDisposal, PartialBranchDisposalCleanupRequest, Result};
use serde::{Deserialize, Serialize};

pub const PARTIAL_BRANCH_UNNEEDED_CLEANUP_PROOF_BYTES: usize = 80 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposalCleanupUnneeded {
    pub schema: u8,
    pub request: PartialBranchDisposalCleanupRequest,
    pub disposal: PartialBranchDisposal,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchDisposalCleanupUnneeded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposalCleanupUnneeded")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchDisposalCleanupUnneeded {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        self.disposal.validate()?;
        if self.schema != 1
            || self.disposal.request != self.request.disposal_request
            || self.disposal.release.as_ref().is_some_and(|release| {
                release.change.request.operation_id == self.request.operation_id
            })
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PARTIAL_BRANCH_UNNEEDED_CLEANUP_PROOF_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-disposal-cleanup-unneeded-v1",
            self.schema,
            &self.request,
            &self.disposal,
        ))
    }
    pub fn matches_request(&self, request: &PartialBranchDisposalCleanupRequest) -> Result<()> {
        self.validate()?;
        request.validate()?;
        if self.request != *request {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn synthetic_terminal_provenances_have_distinct_unneeded_not_removal_proof() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let disposal: PartialBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let mut request = PartialBranchDisposalCleanupRequest {
                disposal_request: disposal.request.clone(),
                operation_id: "unneeded-cleanup-model".into(),
                request_sha256: String::new(),
                quiesced: true,
            };
            request.request_sha256 = request.digest().unwrap();
            let proof =
                PartialBranchDisposalCleanupUnneeded::issue(&request, disposal.clone()).unwrap();
            proof.matches_request(&request).unwrap();
            assert!(proof.disposal == disposal);
            assert!(!format!("{proof:?}").contains(&request.operation_id));
            let bytes = serde_json::to_vec(&proof).unwrap();
            assert!(bytes.len() <= PARTIAL_BRANCH_UNNEEDED_CLEANUP_PROOF_BYTES);
            let removal: crate::PartialBranchDisposalCleanup =
                serde_json::from_slice(&bytes).unwrap();
            assert!(removal.validate().is_err());
            let mut changed = proof.clone();
            changed.request.operation_id = "crossed-cleanup".into();
            changed.request.request_sha256 = changed.request.digest().unwrap();
            assert!(changed.validate().is_err());
            let mut wire = serde_json::to_value(&proof).unwrap();
            wire["removed"] = true.into();
            assert!(serde_json::from_value::<PartialBranchDisposalCleanupUnneeded>(wire).is_err());
        }
    }
}
