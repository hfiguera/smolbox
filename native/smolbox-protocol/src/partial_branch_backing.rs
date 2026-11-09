//! Correlation for original collected partial disposal; hashes grant no SDK ownership.
use crate::{BranchBackingRelease, InvalidMessage, PartialBranchDisposal, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
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
fn origin(receipt: &Receipt) -> Receipt {
    let mut value = receipt.clone();
    value.material = None;
    value
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchBackingReleaseRequest {
    pub disposal: PartialBranchDisposal,
    pub source: Receipt,
    pub child: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
    pub backing_removed: bool,
}
impl PartialBranchBackingReleaseRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.disposal.validate()?;
        self.source.validate_for(2)?;
        let before = self
            .disposal
            .publication
            .receipt
            .material
            .as_ref()
            .ok_or(InvalidMessage)?;
        let head = self.source.material.as_ref().ok_or(InvalidMessage)?;
        crate::wire::id(&self.operation_id)?;
        let creation = &self.disposal.request.collection_request.creation;
        check(
            origin(&self.source) == origin(&self.disposal.publication.receipt)
                && self.child
                    == self
                        .disposal
                        .release
                        .as_ref()
                        .map_or(&self.disposal.publication.change.child, |r| &r.receipt)
                        .clone()
                && head.revision >= before.revision
                && (head.revision != before.revision || head == before)
                && (head.revision != 0
                    || head.chain_sha256
                        == hash(&("smolbox-material-origin-v2", origin(&self.source)))?)
                && self.quiesced
                && self.backing_removed
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
                    .is_none_or(|r| r.operation_id != self.operation_id)
                && self.request_sha256
                    == hash(&(
                        "smolbox-partial-branch-backing-request-v1",
                        &self.disposal,
                        &self.source,
                        &self.child,
                        &self.operation_id,
                        self.quiesced,
                        self.backing_removed,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= crate::BRANCH_BACKING_REQUEST_BYTES,
        )
    }
    pub fn approval(&self) -> &crate::BranchApproval {
        &self.disposal.request.collection_request.creation.approval
    }
    pub fn matches(&self, proof: &BranchBackingRelease) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        check(
            proof.publication == self.disposal.publication
                && proof.operation_id == self.operation_id
                && proof.request_sha256 == self.request_sha256,
        )
    }
}

#[cfg(test)]
mod tests;
