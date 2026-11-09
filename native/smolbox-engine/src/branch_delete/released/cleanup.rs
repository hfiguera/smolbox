//! Explicit original released-child residual cleanup. No SDK lifecycle retry.
//! Positive collection and SDK row/reservation absence precede bounded removal.
use super::*;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleasedBranchDeletionCleanupRequest {
    pub completion: crate::BranchCompletion,
    pub release: crate::BranchReleaseTransition,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for ReleasedBranchDeletionCleanupRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReleasedBranchDeletionCleanupRequest")
            .finish_non_exhaustive()
    }
}
impl ReleasedBranchDeletionCleanupRequest {
    pub fn validate(&self) -> Result<()> {
        self.completion.validate()?;
        self.release.validate()?;
        if self.release.previous != *self.completion.publication.child()
            || self.release.change.binding != self.completion.publication.change.child_origin
            || self.release.change.identity_sha256 != self.completion.identity_sha256
            || (!self.completion.held && self.completion.release.as_ref() != Some(&self.release))
            || self.child != self.release.receipt
            || !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id == self.release.change.request.operation_id
            || self.operation_id
                == self
                    .completion
                    .publication
                    .change
                    .child_origin
                    .intent
                    .child
                    .operation_id
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > RELEASED_BRANCH_DELETION_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-released-child-delete-cleanup-request-v1",
            &self.completion,
            &self.release,
            &self.child,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub(in crate::branch_delete) fn matches_intent(&self, intent: &Intent) -> Result<()> {
        self.validate()?;
        intent.validate()?;
        if intent.release.as_ref() != Some(&self.release)
            || intent.receipt() != &self.child
            || intent.plan.publication != self.completion.publication
            || intent.identity_sha256 != self.completion.identity_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub fn matches(&self, proof: &ReleasedBranchDeletionResolution) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if proof.child != self.child
            || proof.operation_id != self.operation_id
            || proof.request_sha256 != self.request_sha256
            || proof.release_sha256 != crate::material::hash(&self.release)?
            || proof.completion_sha256 != crate::material::hash(&self.completion)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

impl ReleasedBranchDeletionResolution {
    pub(in crate::branch_delete) fn issue_cleanup(
        request: &ReleasedBranchDeletionCleanupRequest,
        intent: &Intent,
        continuation: Option<&ContinuationRequest>,
    ) -> Result<Self> {
        request.matches_intent(intent)?;
        let mut proof = Self {
            schema: 1,
            child: request.child.clone(),
            operation_id: request.operation_id.clone(),
            request_sha256: request.request_sha256.clone(),
            completion_sha256: crate::material::hash(&request.completion)?,
            release_sha256: crate::material::hash(&request.release)?,
            deletion_sha256: deletion_digest(intent, continuation)?,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        proof.validate_for_intent(intent, continuation)?;
        request.matches(&proof)?;
        Ok(proof)
    }
}
impl Engine {
    /// Remove only the original collected released child's residuals. Caller
    /// fencing, exact completed authority and namespace absence are mandatory.
    /// Neither SDK deletion nor source/backing retirement is performed.
    pub fn cleanup_released_branch_deletion_checked(
        &self,
        request: &ReleasedBranchDeletionCleanupRequest,
        budget: &ReadBudget,
    ) -> Result<ReleasedBranchDeletionResolution> {
        budget.check()?;
        request.validate()?;
        request.child.validate(self.binding())?;
        let proof = self
            .cleanup_original_branch_deletion(
                &request.child,
                (&request.operation_id, &request.request_sha256),
                request.quiesced,
                Some((&request.completion, Some(request))),
                budget,
            )?
            .released()?;
        request
            .matches(&proof)
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
}
#[cfg(test)]
mod tests;
