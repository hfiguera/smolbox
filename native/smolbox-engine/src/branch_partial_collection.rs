//! Explicit original-child collection before branch readiness/handoff. This
//! proof grants no SDK deletion, source cleanup or reservation release.
use crate::{BranchCreateRequest, Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchCollectionRequest {
    pub creation: BranchCreateRequest,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}

#[cfg(test)]
mod reader_tests {
    use super::*;
    #[test]
    fn shared_synthetic_partial_collection_bytes_match_both_readers_without_sdk_authority() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-collection-v1.json"
        ))
        .unwrap();
        for row in rows {
            let request: PartialBranchCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchCollection =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            assert!(serde_json::to_value(&request).unwrap() == row["request"]);
            assert!(serde_json::to_value(&proof).unwrap() == row["proof"]);
        }
    }
}
impl std::fmt::Debug for PartialBranchCollectionRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchCollectionRequest")
            .finish_non_exhaustive()
    }
}
impl PartialBranchCollectionRequest {
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-collection-request-v1",
            &self.creation,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn validate(&self) -> Result<()> {
        self.creation.validate_declaration()?;
        if serde_json::to_vec(&self.creation)
            .map_err(|_| Error::before(ErrorCode::Io))?
            .len()
            > 16 * 1024
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        if !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id == self.creation.child.operation_id
            || self
                .creation
                .initial_release
                .as_ref()
                .is_some_and(|r| r.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > 20 * 1024
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn matches(&self, proof: &PartialBranchCollection) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if proof.creation_sha256 != crate::material::hash(&self.creation)?
            || proof.operation_id != self.operation_id
            || proof.request_sha256 != self.request_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchCollection {
    pub schema: u8,
    pub creation_sha256: String,
    pub publication_sha256: String,
    pub operation_id: String,
    pub request_sha256: String,
    pub boot_sha256: String,
    pub collection_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchCollection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchCollection")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchCollection {
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-collection-proof-v1",
            self.schema,
            &self.creation_sha256,
            &self.publication_sha256,
            &self.operation_id,
            &self.request_sha256,
            &self.boot_sha256,
            &self.collection_sha256,
        ))
    }
    pub fn validate(&self) -> Result<()> {
        if self.schema != 1
            || !crate::domain::valid_id(&self.operation_id)
            || [
                &self.creation_sha256,
                &self.publication_sha256,
                &self.request_sha256,
                &self.boot_sha256,
                &self.collection_sha256,
            ]
            .into_iter()
            .any(|s| !crate::domain::valid_hex(s, 64))
            || self.proof_sha256 != self.digest()?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn issue(
        request: &PartialBranchCollectionRequest,
        publication: &crate::BranchPublication,
        collected: &crate::epoch::BootCollection,
    ) -> Result<Self> {
        request.validate()?;
        publication
            .change
            .child_origin
            .intent
            .matches_creation(&request.creation)?;
        let mut proof = Self {
            schema: 1,
            creation_sha256: crate::material::hash(&request.creation)?,
            publication_sha256: crate::material::hash(publication)?,
            operation_id: request.operation_id.clone(),
            request_sha256: request.request_sha256.clone(),
            boot_sha256: crate::material::hash(collected.intent())?,
            collection_sha256: crate::material::hash(&(collected.intent(), collected.child()))?,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        proof.validate()?;
        Ok(proof)
    }
}
