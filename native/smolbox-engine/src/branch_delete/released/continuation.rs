//! One explicit continuation of the unentered final released-child delete.
//! Only original returned collection and a protected request grant SDK entry.
use super::*;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleasedBranchDeletionContinuationRequest {
    pub completion: crate::BranchCompletion,
    pub release: crate::BranchReleaseTransition,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for ReleasedBranchDeletionContinuationRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReleasedBranchDeletionContinuationRequest")
            .finish_non_exhaustive()
    }
}
impl ReleasedBranchDeletionContinuationRequest {
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
            "smolbox-released-child-delete-continuation-request-v1",
            &self.completion,
            &self.release,
            &self.child,
            &self.operation_id,
            self.quiesced,
        ))
    }
    fn matches_intent(&self, intent: &Intent) -> Result<()> {
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
    pub fn matches(&self, proof: &ReleasedBranchDeletionContinuation) -> Result<()> {
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

/// Acknowledgement of original collected-child SDK deletion, never absence resolution.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleasedBranchDeletionContinuation {
    pub schema: u8,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub completion_sha256: String,
    pub release_sha256: String,
    pub deletion_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for ReleasedBranchDeletionContinuation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReleasedBranchDeletionContinuation")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl ReleasedBranchDeletionContinuation {
    pub fn validate(&self) -> Result<()> {
        let material = self
            .child
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        material.validate()?;
        if self.schema != 1
            || material.revision != 1
            || !crate::domain::valid_id(&self.child.target_id)
            || !crate::domain::valid_id(&self.child.name)
            || !crate::domain::valid_hex(&self.child.domain_generation, 32)
            || !crate::domain::valid_hex(&self.child.owner_token, 64)
            || !crate::domain::valid_hex(&self.child.incarnation, 32)
            || !crate::domain::valid_hex(&self.child.material_sha256, 64)
            || !crate::domain::valid_id(&self.operation_id)
            || [
                &self.request_sha256,
                &self.completion_sha256,
                &self.release_sha256,
                &self.deletion_sha256,
            ]
            .iter()
            .any(|value| !crate::domain::valid_hex(value, 64))
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > RELEASED_BRANCH_DELETION_PROOF_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-released-child-delete-continuation-proof-v1",
            self.schema,
            &self.child,
            &self.operation_id,
            &self.request_sha256,
            &self.completion_sha256,
            &self.release_sha256,
            &self.deletion_sha256,
        ))
    }
    pub(in crate::branch_delete) fn validate_for_intent(
        &self,
        intent: &Intent,
        continuation: Option<&ContinuationRequest>,
    ) -> Result<()> {
        self.validate()?;
        let release = intent
            .release
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if self.child != *intent.receipt()
            || self.release_sha256 != crate::material::hash(release)?
            || self.deletion_sha256 != deletion_digest(intent, continuation)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn issue(
        request: &ReleasedBranchDeletionContinuationRequest,
        intent: &Intent,
        continuation: Option<&ContinuationRequest>,
    ) -> Result<Self> {
        let expected = ContinuationRequest {
            operation_id: request.operation_id.clone(),
            request_sha256: request.request_sha256.clone(),
        };
        if continuation != Some(&expected) {
            return Err(Error::before(ErrorCode::Ownership));
        }
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
    /// Continue only the unentered final delete after original released-child
    /// collection. Entered SDK deletion cannot replay and backing stays retained.
    pub fn continue_released_branch_deletion_checked(
        &self,
        request: &ReleasedBranchDeletionContinuationRequest,
        budget: &ReadBudget,
    ) -> Result<ReleasedBranchDeletionContinuation> {
        budget.check()?;
        request.validate()?;
        request.child.validate(self.binding())?;
        let observation = self.continue_original_branch_deletion(
            &request.child,
            (&request.operation_id, &request.request_sha256),
            request.quiesced,
            Some((&request.completion, Some(&request.release))),
            budget,
        )?;
        if observation.state != crate::ObservedState::Missing {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self
            .branch_retention
            .completed_context_exact(&request.completion)?;
        let retained = context
            .deletion
            .try_lock()
            .map_err(|_| Error::uncertain(ErrorCode::Conflict))?;
        let state = retained
            .as_ref()
            .ok_or(Error::uncertain(ErrorCode::State))?;
        request.matches_intent(&state.intent)?;
        let grant = ContinuationRequest {
            operation_id: request.operation_id.clone(),
            request_sha256: request.request_sha256.clone(),
        };
        let journal = Journal::new(self.domain.clone(), &request.child)?;
        let (record, version) = journal.read()?;
        crate::branch_delete::continuation::check_continuation_result(state, &record, &grant)?;
        journal.sync_released_resolution(&version, budget)?;
        let proof =
            ReleasedBranchDeletionContinuation::issue(request, &state.intent, Some(&grant))?;
        request
            .matches(&proof)
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
}
#[cfg(test)]
mod tests;
