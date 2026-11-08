//! Positive released-child absence under the original returned deletion worker.
//! This never calls SDK stop/delete, reconstructs ownership or frees backing.
use super::*;

pub const RELEASED_BRANCH_DELETION_REQUEST_BYTES: usize = 132 * 1024;
pub const RELEASED_BRANCH_DELETION_PROOF_BYTES: usize = 4096;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleasedBranchDeletionRequest {
    pub completion: crate::BranchCompletion,
    pub release: crate::BranchReleaseTransition,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for ReleasedBranchDeletionRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReleasedBranchDeletionRequest")
            .finish_non_exhaustive()
    }
}
impl ReleasedBranchDeletionRequest {
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
            "smolbox-released-child-delete-request-v1",
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

/// Historical confirmed absence; separate from SDK success and backing release.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleasedBranchDeletionResolution {
    pub schema: u8,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub completion_sha256: String,
    pub release_sha256: String,
    pub deletion_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for ReleasedBranchDeletionResolution {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReleasedBranchDeletionResolution")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl ReleasedBranchDeletionResolution {
    pub(in crate::branch_delete) fn matches_request(
        &self,
        operation_id: &str,
        request_sha256: &str,
    ) -> bool {
        self.operation_id == operation_id && self.request_sha256 == request_sha256
    }
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
    pub(super) fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-released-child-delete-resolution-v1",
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
        request: &ReleasedBranchDeletionRequest,
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

impl Retained {
    pub(in crate::branch_delete) fn qualify_released_record(
        &self,
        record: &mut Record,
    ) -> Result<()> {
        if record.intent != self.intent {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if record.continuation != self.continuation {
            if record.continuation.is_some()
                || self.continuation.is_none()
                || !matches!(record.phase, Phase::Collecting | Phase::Collected)
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            self.continuation.as_ref().unwrap().validate()?;
            record.continuation = self.continuation.clone();
        }
        Ok(())
    }
    pub(in crate::branch_delete) fn resolve_released(
        &mut self,
        journal: &Journal,
        request: &ReleasedBranchDeletionRequest,
        authority: ResolutionAuthority<'_>,
        budget: &ReadBudget,
    ) -> Result<ReleasedBranchDeletionResolution> {
        budget.check()?;
        request.matches_intent(&self.intent)?;
        self.check_returned(&request.child)?;
        if self.cleanup.as_ref().is_some_and(|cleanup| {
            !cleanup.operation_id.eq(&request.operation_id)
                || cleanup.request_sha256 != request.request_sha256
        }) {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let (mut record, version) = journal.read()?;
        self.qualify_released_record(&mut record)?;
        if let Some(Completion::ReleasedResolved(proof)) = &self.completion {
            request.matches(proof)?;
            if record.released_resolution.as_ref() != Some(proof.as_ref()) {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        if let Some(proof) = &record.released_resolution {
            request.matches(proof)?;
            let proof = proof.clone();
            // A prior publication may have returned an uncertain fsync result.
            // Re-establish durability before acknowledging its recorded proof.
            journal.sync_released_resolution(&version, budget)?;
            self.import_completion(record)?;
            return Ok(proof);
        }
        // Only a previously completed ordinary deletion may have retired leases.
        // The engine acquires fresh gates for that case before this observation.
        if !matches!(
            record.phase,
            Phase::Collecting
                | Phase::Collected
                | Phase::Finishing
                | Phase::Deleting
                | Phase::Deleted
        ) || (self.leases.is_none() && !matches!(self.completion, Some(Completion::Deleted)))
        {
            return Err(Error::before(ErrorCode::State));
        }
        let collection = authority
            .epoch
            .collect_enrolled(&request.child.name, authority.enrollment)?;
        let absent = absence(
            &self.intent,
            &collection,
            authority.database,
            authority.identity,
            budget,
        )?;
        let proof = ReleasedBranchDeletionResolution::issue(
            request,
            &self.intent,
            record.continuation.as_ref(),
        )?;
        journal.publish_released_absence(record, version, &proof, &absent, budget)?;
        self.completion = Some(Completion::ReleasedResolved(Box::new(proof.clone())));
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
}
impl Journal {
    pub(in crate::branch_delete) fn publish_released_absence(
        &self,
        mut record: Record,
        version: Version,
        proof: &ReleasedBranchDeletionResolution,
        absence: &Absence,
        budget: &ReadBudget,
    ) -> Result<()> {
        record.intent.validate()?;
        proof.validate_for_intent(&record.intent, record.continuation.as_ref())?;
        if absence.intent_sha256 != crate::material::hash(&record.intent)?
            || !matches!(
                record.phase,
                Phase::Collecting
                    | Phase::Collected
                    | Phase::Finishing
                    | Phase::Deleting
                    | Phase::Deleted
            )
            || record.resolution.is_some()
            || record.released_resolution.is_some()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        record.schema = if record.continuation.is_some() { 6 } else { 5 };
        record.phase = Phase::ResolvedAbsent;
        record.released_resolution = Some(proof.clone());
        budget.check()?;
        self.write(&record, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(in crate::branch_delete) fn sync_released_resolution(
        &self,
        version: &Version,
        budget: &ReadBudget,
    ) -> Result<()> {
        self.sync_record::<Record>(version, budget)
    }
    pub(in crate::branch_delete) fn sync_record<T: ProtectedRecord>(
        &self,
        version: &Version,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.domain.verify()?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&self.path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if Version::of(&file.metadata().map_err(|_| Error::before(ErrorCode::Io))?) != *version {
            return Err(Error::before(ErrorCode::Ownership));
        }
        file.sync_all()
            .and_then(|()| File::open(&self.domain.directory)?.sync_all())
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        if self.read_record::<T>()?.1 != *version {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()
    }
}
impl Engine {
    /// Resolve a returned original released delete using positive bounded absence.
    /// The caller must fence durable/controller work before requesting resolution.
    pub fn resolve_released_branch_deletion_checked(
        &self,
        request: &ReleasedBranchDeletionRequest,
        budget: &ReadBudget,
    ) -> Result<ReleasedBranchDeletionResolution> {
        budget.check()?;
        request.validate()?;
        request.child.validate(self.binding())?;
        self.domain.verify()?;
        self.verify_database_identity()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self
            .branch_retention
            .completed_context_exact(&request.completion)?;
        if !Arc::ptr_eq(&context, &self.retained_branch_context(&request.child)?) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let journal = Journal::new(self.domain.clone(), &request.child)?;
        let mut retained = context
            .deletion
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let state = retained.as_mut().ok_or(Error::before(ErrorCode::State))?;
        request.matches_intent(&state.intent)?;
        state.check_returned(&request.child)?;
        let source_name = &context.plan.publication.previous.name;
        let _fresh_gates = if state.leases.is_none() {
            let source = self.observation_gate(source_name)?;
            let child = self.observation_gate(&request.child.name)?;
            Some(
                crate::gate::lock_pair((source_name, &source), (&request.child.name, &child))
                    .map_err(|()| Error::before(ErrorCode::Conflict))?,
            )
        } else {
            None
        };
        let epoch = self.collection_epoch()?;
        if state.intent.plan != context.plan
            || state.intent.boot != *context.enrollment.intent()
            || state.intent.child != context.enrollment.child()
            || state.intent.identity_sha256 != context.identity_sha256
            || !epoch.bound_to(self.binding())
            || !context
                .enrollment
                .intent()
                .matches_epoch(&request.child.name, epoch)
            || context._runtime.pid(&request.child.name).is_some()
            || context
                .manager
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?
                .child_pid()
                .is_some()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let proof = state.resolve_released(
            &journal,
            request,
            ResolutionAuthority {
                epoch,
                enrollment: &context.enrollment,
                database: &self.binding().database,
                identity: self.database_identity,
            },
            budget,
        )?;
        request
            .matches(&proof)
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        drop(retained);
        if !self.known_branch_deletion(&context, &journal, &request.child)? {
            return Err(Error::uncertain(ErrorCode::State));
        }
        Ok(proof)
    }
}

#[cfg(test)]
mod tests;
