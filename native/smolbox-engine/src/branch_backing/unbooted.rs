//! Original never-booted disposal is independent of guest/boot completion.
//! Expected tombstone heads correlate with the durable caller; absence alone
//! cannot prove a claimed historical source head. No paths or PID authority.
use super::*;
use crate::UnbootedBranchDisposal;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchBackingReleaseRequest {
    pub disposal: UnbootedBranchDisposal,
    pub source: CreationReceipt,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
    pub backing_removed: bool,
}
impl std::fmt::Debug for UnbootedBranchBackingReleaseRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnbootedBranchBackingReleaseRequest")
            .finish_non_exhaustive()
    }
}
impl UnbootedBranchBackingReleaseRequest {
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
        if self.child != *publication.child()
            || material.revision < before.revision
            || (material.revision == before.revision && material != before)
            || (material.revision == 0 && material != &crate::material::root_proof(&origin)?)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let creation = &self.disposal.creation;
        if !self.quiesced
            || !self.backing_removed
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
                > BRANCH_BACKING_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-unbooted-branch-backing-request-v1",
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
    fn shared_synthetic_native_disposal_and_backing_fixtures_keep_provenance_and_exact_creation() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/unbooted-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let proof: crate::UnbootedBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            proof.validate().unwrap();
            let request: UnbootedBranchBackingReleaseRequest =
                serde_json::from_value(row["backing_request"].clone()).unwrap();
            let result: BranchBackingRelease =
                serde_json::from_value(row["backing_proof"].clone()).unwrap();
            request.matches(&result).unwrap();
            assert!(request.disposal == proof);
            assert!(!format!("{proof:?}").contains(&proof.creation.child.owner_token));
        }
    }
}
