//! Fresh namespace absence under original collected pre-handoff disposal, without a boot or
//! guest-completion surrogate. Proof correlation never grants SDK ownership.
use crate::{Error, ErrorCode, PartialBranchDisposal, Result};
use serde::{Deserialize, Serialize};
pub const PARTIAL_BRANCH_ABSENCE_BYTES: usize = 56 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchChildAbsenceRequest {
    pub disposal: PartialBranchDisposal,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for PartialBranchChildAbsenceRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchChildAbsenceRequest")
            .finish_non_exhaustive()
    }
}
impl PartialBranchChildAbsenceRequest {
    pub fn validate(&self) -> Result<()> {
        self.disposal.validate()?;
        let creation = &self.disposal.request.collection_request.creation;
        if !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id == creation.child.operation_id
            || self.operation_id == self.disposal.request.operation_id
            || self.operation_id == self.disposal.request.collection_request.operation_id
            || self
                .disposal
                .release
                .as_ref()
                .is_some_and(|r| r.change.request.operation_id == self.operation_id)
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|release| release.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PARTIAL_BRANCH_ABSENCE_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-child-absence-request-v1",
            &self.disposal,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn matches(&self, proof: &PartialBranchChildAbsence) -> Result<()> {
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
pub struct PartialBranchChildAbsence {
    pub schema: u8,
    pub request: PartialBranchChildAbsenceRequest,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchChildAbsence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchChildAbsence")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchChildAbsence {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        if self.schema != 1
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PARTIAL_BRANCH_ABSENCE_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-child-absence-v1",
            self.schema,
            &self.request,
        ))
    }
    pub(crate) fn issue(request: PartialBranchChildAbsenceRequest) -> Result<Self> {
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn synthetic_partial_absence_readers_match_wire_bytes_without_native_authority() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/partial-branch-child-absence-v1.json"
        ))
        .unwrap();
        assert_eq!(rows.len(), 10);
        for row in rows {
            let proof: PartialBranchChildAbsence =
                serde_json::from_value(row["proof"].clone()).unwrap();
            proof.request.matches(&proof).unwrap();
            assert!(PartialBranchChildAbsence::issue(proof.request.clone()).unwrap() == proof);
            assert!(serde_json::to_value(&proof).unwrap() == row["proof"]);
            let creation = &proof.request.disposal.request.collection_request.creation;
            let mut ids = vec![
                creation.child.operation_id.clone(),
                proof.request.disposal.request.operation_id.clone(),
                proof
                    .request
                    .disposal
                    .request
                    .collection_request
                    .operation_id
                    .clone(),
            ];
            if let Some(release) = &proof.request.disposal.release {
                ids.push(release.change.request.operation_id.clone());
            }
            if let Some(release) = &creation.initial_release {
                ids.push(release.operation_id.clone());
            }
            for id in ids {
                let mut request = proof.request.clone();
                request.operation_id = id;
                request.request_sha256 = request.digest().unwrap();
                assert!(request.validate().is_err());
            }
            let mut request = proof.request.clone();
            request.quiesced = false;
            request.request_sha256 = request.digest().unwrap();
            assert!(request.validate().is_err());
        }
    }
}
