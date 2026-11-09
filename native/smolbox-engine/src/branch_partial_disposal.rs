//! Explicit disposal after original pre-handoff child collection. This is not
//! never-booted disposal, branch readiness or dependency/backing retirement.
use crate::{Error, ErrorCode, PartialBranchCollection, PartialBranchCollectionRequest, Result};
use serde::{Deserialize, Serialize};

pub const PARTIAL_BRANCH_DISPOSAL_REQUEST_BYTES: usize = 24 * 1024;
pub const PARTIAL_BRANCH_DISPOSAL_PROOF_BYTES: usize = 48 * 1024;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposalRequest {
    pub collection_request: PartialBranchCollectionRequest,
    pub collection: PartialBranchCollection,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for PartialBranchDisposalRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposalRequest")
            .finish_non_exhaustive()
    }
}
impl PartialBranchDisposalRequest {
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-disposal-request-v1",
            &self.collection_request,
            &self.collection,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn validate(&self) -> Result<()> {
        self.collection_request.matches(&self.collection)?;
        let creation = &self.collection_request.creation;
        if !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id == self.collection.operation_id
            || self.operation_id == creation.child.operation_id
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|r| r.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PARTIAL_BRANCH_DISPOSAL_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PartialBranchDisposalCompletion {
    Deleted,
    ResolvedAbsent,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposal {
    pub schema: u8,
    pub completion: PartialBranchDisposalCompletion,
    pub request: PartialBranchDisposalRequest,
    pub publication: crate::BranchPublication,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release: Option<crate::BranchReleaseTransition>,
    pub disposal_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchDisposal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposal")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
pub(crate) fn validate_context(
    request: &PartialBranchDisposalRequest,
    publication: &crate::BranchPublication,
    release: Option<&crate::BranchReleaseTransition>,
) -> Result<()> {
    request.validate()?;
    publication.validate()?;
    let creation = &request.collection_request.creation;
    publication
        .change
        .child_origin
        .intent
        .matches_creation(creation)?;
    if let Some(release) = release {
        release.validate()?;
        if release.change.request.operation_id == request.operation_id
            || release.previous != *publication.child()
            || release.change.binding != publication.change.child_origin
            || release.change.boot_sha256 != request.collection.boot_sha256
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|r| *r != release.change.request)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    if request.collection.publication_sha256 != crate::material::hash(publication)? {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

impl PartialBranchDisposal {
    pub fn validate(&self) -> Result<()> {
        validate_context(&self.request, &self.publication, self.release.as_ref())?;
        if self.schema != 1
            || !crate::domain::valid_hex(&self.disposal_sha256, 64)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PARTIAL_BRANCH_DISPOSAL_PROOF_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-disposal-proof-v1",
            self.schema,
            self.completion,
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
        completion: PartialBranchDisposalCompletion,
    ) -> Result<Self> {
        let mut result = Self {
            schema: 1,
            completion,
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

#[cfg(test)]
mod reader_tests {
    use super::*;
    #[test]
    fn synthetic_partial_disposal_wire_bytes_match_native_reader_without_sdk_authority() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let request: PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.validate().unwrap();
            proof.validate().unwrap();
            assert!(proof.request == request);
            assert!(serde_json::to_value(request).unwrap() == row["request"]);
            assert!(serde_json::to_value(proof).unwrap() == row["proof"]);
        }
    }
}
