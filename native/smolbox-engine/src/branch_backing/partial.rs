//! Original collected pre-handoff disposal has neither ordinary child ownership
//! nor a never-booted substitute. Expected source heads correlate with the
//! durable caller; namespace absence cannot prove that history itself.
use super::*;
use crate::PartialBranchDisposal;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchBackingReleaseRequest {
    pub disposal: PartialBranchDisposal,
    pub source: CreationReceipt,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
    pub backing_removed: bool,
}
impl std::fmt::Debug for PartialBranchBackingReleaseRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchBackingReleaseRequest")
            .finish_non_exhaustive()
    }
}
impl PartialBranchBackingReleaseRequest {
    pub fn validate(&self) -> Result<()> {
        self.disposal.validate()?;
        let publication = &self.disposal.publication;
        let mut origin = publication.receipt.clone();
        origin.material = None;
        crate::material::check_origin(&origin, &self.source)?;
        let material = self
            .source
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        material.validate()?;
        let before = publication
            .receipt
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let child = self
            .disposal
            .release
            .as_ref()
            .map_or(publication.child(), |release| &release.receipt);
        if self.child != *child
            || material.revision < before.revision
            || (material.revision == before.revision && material != before)
            || (material.revision == 0 && material != &crate::material::root_proof(&origin)?)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let creation = &self.disposal.request.collection_request.creation;
        if !self.quiesced
            || !self.backing_removed
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
                .is_some_and(|r| r.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > BRANCH_BACKING_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-partial-branch-backing-request-v1",
            &self.disposal,
            &self.source,
            &self.child,
            &self.operation_id,
            self.quiesced,
            self.backing_removed,
        ))
    }
    pub fn matches(&self, proof: &BranchBackingRelease) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if proof.publication != self.disposal.publication
            || proof.operation_id != self.operation_id
            || proof.request_sha256 != self.request_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_synthetic_partial_backing_requests_preserve_both_disposal_provenances_and_exact_heads(
    ) {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/partial-branch-backing-release-v1.json"
        ))
        .unwrap();
        assert_eq!(rows.len(), 10);
        for row in rows {
            let request: PartialBranchBackingReleaseRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchBackingRelease = serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            assert!(serde_json::to_value(&request).unwrap() == row["request"]);
            assert!(serde_json::to_value(&proof).unwrap() == row["proof"]);
            assert!(!format!("{request:?}").contains(&request.child.owner_token));
            assert!(!format!("{proof:?}").contains(&request.source.name));
        }
    }
}
