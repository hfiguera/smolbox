//! Fresh admitted release after completed held creation. Original manager and
//! enrollment remain mandatory; an uncertain attempt never authorizes replay.
use crate::branch_boot::Lifecycle;
use crate::branch_owned::Context;
use crate::{
    BranchReleaseRequest, BranchReleaseTransition, CreationReceipt, Engine, Error, ErrorCode,
    ReadBudget, Result,
};
use std::sync::{Arc, Weak};

struct Leases {
    _gates: [crate::gate::MachineLease; 2],
    _source: crate::sdk_compat::SourceLease,
    _work: crate::jobs::JobLease,
}
pub(crate) struct Retained {
    request: BranchReleaseRequest,
    intent: crate::branch_release::Intent,
    worker: Weak<()>,
    leases: Option<Leases>,
    result: Option<BranchReleaseTransition>,
    _metadata: crate::jobs::BranchBackingLease,
}
impl Context {
    fn verify_release_live(&self, epoch: &crate::epoch::ActorEpoch) -> Result<()> {
        self.plan.verify()?;
        let child = self.enrollment.child();
        if !self
            .enrollment
            .intent()
            .matches_epoch(&self.plan.publication.child().name, epoch)
            || self
                .manager
                .try_lock()
                .map_err(|_| Error::uncertain(ErrorCode::Conflict))?
                .child_pid()
                != Some(child.pid)
            || smolvm::process::process_start_time(child.pid) != Some(child.birth)
            || !smolvm::process::is_alive(child.pid)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Retained {
    fn completed(
        &mut self,
        plan: &crate::branch_boot::Plan,
        enrollment: &crate::epoch::BootEnrollment,
        receipt: &CreationReceipt,
        request: &BranchReleaseRequest,
    ) -> Result<Option<BranchReleaseTransition>> {
        if self.request != *request {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if self.worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let result = match &self.result {
            Some(result) => Some(result.clone()),
            None => Lifecycle::at(&plan.child.path).completed_release(plan, request, enrollment)?,
        };
        let Some(result) = result else {
            return Err(Error::uncertain(ErrorCode::State));
        };
        if result != self.intent.transition
            || (receipt != &result.previous && receipt != &result.receipt)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.result = Some(result.clone());
        Ok(Some(result))
    }
    pub(crate) fn deletion_ready(&self, release: &BranchReleaseTransition) -> Result<()> {
        if self.worker.upgrade().is_some()
            || self.leases.is_some()
            || self.result.as_ref() != Some(release)
            || self.intent.transition != *release
            || self.request != release.change.request
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        Ok(())
    }
    fn retire_after_promotion(&mut self, result: &BranchReleaseTransition) -> Result<()> {
        if self.worker.upgrade().is_some() || self.result.as_ref() != Some(result) {
            return Err(Error::uncertain(ErrorCode::State));
        }
        self.leases.take();
        Ok(())
    }
}
impl Engine {
    /// Bridge entry: the exact original held completion is checked before work.
    pub fn release_held_branch_checked(
        &self,
        completion: &crate::BranchCompletion,
        source: &CreationReceipt,
        request: &BranchReleaseRequest,
        budget: &ReadBudget,
    ) -> Result<BranchReleaseTransition> {
        budget.check()?;
        completion.validate()?;
        source.validate(self.binding())?;
        request.validate()?;
        let context = self.retained_branch_context(&completion.child)?;
        verify_completion(&context.plan, &context.identity_sha256, completion, source)?;
        self.release_held_branch(source, &completion.child, request, budget)
    }

    /// Qualify only an original completed attempt. No SDK call or ownership
    /// reconstruction occurs. None grants neither absence nor retry authority.
    /// Both recorded completions and collected original work may promote an
    /// existing handle and retire transient work, never backing or a new handle.
    pub fn qualify_held_branch_release(
        &self,
        completion: &crate::BranchCompletion,
        source: &CreationReceipt,
        request: &BranchReleaseRequest,
        budget: &ReadBudget,
    ) -> Result<Option<BranchReleaseTransition>> {
        budget.check()?;
        completion.validate()?;
        source.validate(self.binding())?;
        request.validate()?;
        self.domain.verify()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self.retained_branch_context(&completion.child)?;
        verify_completion(&context.plan, &context.identity_sha256, completion, source)?;
        let result = self.known_held_release(&context, &completion.child, request)?;
        budget.check()?;
        if let Some(result) = &result {
            self.acknowledge_held_release(&context, result)?;
        }
        self.domain.verify()?;
        budget.check()?;
        Ok(result)
    }

    /// The caller's request digest binds its durable release/version intent.
    /// This API uses a new absolute budget, never the creation request's budget.
    pub fn release_held_branch(
        &self,
        source: &CreationReceipt,
        child: &CreationReceipt,
        request: &BranchReleaseRequest,
        budget: &ReadBudget,
    ) -> Result<BranchReleaseTransition> {
        request.validate()?;
        source.validate(self.binding())?;
        let context = self.retained_branch_context(child)?;
        let mut origin = context.plan.publication.receipt.clone();
        origin.material = None;
        crate::material::check_origin(&origin, source)?;
        if !context
            .plan
            .publication
            .change
            .child_origin
            .intent
            .child
            .hold
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        if let Some(result) = self.known_held_release(&context, child, request)? {
            self.acknowledge_held_release(&context, &result)?;
            return Ok(result);
        }
        budget.check()?;
        self.binding().validate()?;
        self.verify_database_identity()?;
        self.original_branch_manager(child, &context)?;
        let job = self.jobs.acquire(crate::jobs::Demand::branch_release())?;
        let metadata = self.jobs.branch_result_metadata()?;
        let parent_gate = self.gate(&source.name)?;
        let child_gate = self.gate(&child.name)?;
        let gates =
            crate::gate::lock_pair((&source.name, &parent_gate), (&child.name, &child_gate))
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source_lease = self.source_lease(child)?;
        let epoch = self.boot_epoch()?.clone();
        context.verify_release_live(&epoch)?;
        let record = self
            .observation_record(&child.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_record(child, &record)?;
        if child != context.plan.publication.child() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let source_record = self
            .observation_record(&source.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_record(source, &source_record)?;
        let expected_source_pid = context
            .plan
            .publication
            .change
            .child_origin
            .intent
            .source_pid;
        let dependents = crate::sdk_compat::source_dependents(
            &self.binding().database,
            self.database_identity,
            &source.name,
            budget,
        )?;
        if source_record.pid.zip(source_record.pid_start_time) != Some(expected_source_pid)
            || !self.original_continuing_source(source, &source_record)?
            || !dependents.contains(&child.name)
            || !crate::material::MaterialJournal::at(&self.vm_directory(&source.name))
                .continuing_branch_children(
                    source,
                    &dependents,
                    &self.binding().database,
                    self.database_identity,
                    budget,
                )?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let intent = crate::branch_release::Intent::issue(
            &context.plan.publication,
            &record,
            &context.enrollment,
            &context.identity_sha256,
            request,
        )?;
        let staging = self.transfer_directory()?;
        let active = Arc::new(());
        {
            let mut state = context
                .release
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if state.is_some() {
                return Err(Error::before(ErrorCode::Conflict));
            }
            budget.check()?;
            *state = Some(Box::new(Retained {
                request: request.clone(),
                intent: intent.clone(),
                worker: Arc::downgrade(&active),
                leases: Some(Leases {
                    _gates: gates,
                    _source: source_lease,
                    _work: job,
                }),
                result: None,
                _metadata: metadata,
            }));
        }
        Lifecycle::at(&context.plan.child.path).enter_release(
            &context.plan,
            &intent,
            &context.enrollment,
        )?;
        crate::material::MaterialJournal::at(&context.plan.child.path)
            .begin_branch_release(&intent, &record)?;
        let application = crate::branch_release::Application {
            plan: context.plan.clone(),
            intent: intent.clone(),
            before: record,
            source: source_record,
            enrollment: context.enrollment.clone(),
            database: self.binding().database.clone(),
            database_identity: self.database_identity,
            db: self.db.clone(),
            staging,
            budget: budget.clone(),
        };
        let retained = context.clone();
        let result = crate::oci_start::observe_owned(
            self.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _active = active;
                let result = application.run(|| {
                    let state = retained
                        .release
                        .lock()
                        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                    if !state.as_ref().is_some_and(|state| state.intent == intent) {
                        return Err(Error::uncertain(ErrorCode::Ownership));
                    }
                    retained.verify_release_live(&epoch)
                })?;
                let mut state = retained
                    .release
                    .lock()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                let state = state.as_mut().ok_or(Error::uncertain(ErrorCode::State))?;
                if state.intent != intent {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                state.result = Some(result.clone());
                Ok(result)
            },
        )
        .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        let known = self
            .known_held_release(&context, child, request)?
            .ok_or(Error::uncertain(ErrorCode::State))?;
        if result != known {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        self.acknowledge_held_release(&context, &known)?;
        Ok(known)
    }
    fn acknowledge_held_release(
        &self,
        context: &Context,
        result: &BranchReleaseTransition,
    ) -> Result<()> {
        self.recover_branch_release_handle(result)?;
        let mut state = context
            .release
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        if let Some(state) = state.as_mut() {
            state.retire_after_promotion(result)?;
        }
        Ok(())
    }
    fn known_held_release(
        &self,
        context: &Context,
        child: &CreationReceipt,
        request: &BranchReleaseRequest,
    ) -> Result<Option<BranchReleaseTransition>> {
        let mut state = context
            .release
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if let Some(state) = state.as_mut() {
            return state.completed(&context.plan, &context.enrollment, child, request);
        }
        let recorded = Lifecycle::at(&context.plan.child.path).completed_release(
            &context.plan,
            request,
            &context.enrollment,
        )?;
        if recorded
            .as_ref()
            .is_some_and(|result| child != &result.previous && child != &result.receipt)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(recorded)
    }
}

fn verify_completion(
    plan: &crate::branch_boot::Plan,
    identity: &str,
    completion: &crate::BranchCompletion,
    source: &CreationReceipt,
) -> Result<()> {
    completion.validate()?;
    if !completion.held
        || completion.publication != plan.publication
        || completion.identity_sha256 != identity
        || completion.child != *plan.publication.child()
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut origin = plan.publication.receipt.clone();
    origin.material = None;
    crate::material::check_origin(&origin, source)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch_boot::tests::{identity_model, IdentityModel};
    use crate::material::MaterialJournal;

    #[test]
    fn deletion_requires_collected_completed_release_and_retired_transient_work() {
        let (model, mut state) = entered();
        let release = material_complete(&model, &state);
        assert!(state.deletion_ready(&release).is_err());
        Lifecycle::at(&model.plan.child.path)
            .released(&model.plan, &state.intent, &model.enrollment)
            .unwrap();
        let result = state
            .completed(
                &model.plan,
                &model.enrollment,
                &release.previous,
                &request(),
            )
            .unwrap()
            .unwrap();
        assert!(state.deletion_ready(&release).is_err());
        state.retire_after_promotion(&result).unwrap();
        state.deletion_ready(&release).unwrap();
        let mut crossed = release.clone();
        crossed.change.request.operation_id = "other-release".into();
        assert!(state.deletion_ready(&crossed).is_err());
        let active = Arc::new(());
        state.worker = Arc::downgrade(&active);
        assert!(state.deletion_ready(&release).is_err());
    }
    #[test]
    fn checked_completion_binds_original_plan_identity_and_source_before_dispatch() {
        let model = identity_model(true);
        let completion = crate::BranchCompletion {
            schema: 1,
            publication: model.plan.publication.clone(),
            child: model.plan.publication.child().clone(),
            identity_sha256: model.identity_sha256.clone(),
            held: true,
            release: None,
        };
        verify_completion(
            &model.plan,
            &model.identity_sha256,
            &completion,
            &model.plan.publication.receipt,
        )
        .unwrap();
        let mut crossed = completion.clone();
        crossed.identity_sha256 = "0".repeat(64);
        assert!(verify_completion(
            &model.plan,
            &model.identity_sha256,
            &crossed,
            &model.plan.publication.receipt
        )
        .is_err());
        let mut source = model.plan.publication.receipt.clone();
        source.owner_token = "0".repeat(64);
        assert!(
            verify_completion(&model.plan, &model.identity_sha256, &completion, &source).is_err()
        );
        let budget = ReadBudget::new(
            std::time::Duration::from_secs(1),
            crate::Cancellation::default(),
        )
        .unwrap();
        let before = model.engine.jobs.counts();
        assert!(model
            .engine
            .qualify_held_branch_release(
                &completion,
                &model.plan.publication.receipt,
                &request(),
                &budget
            )
            .is_err());
        assert!(model
            .engine
            .release_held_branch_checked(
                &completion,
                &model.plan.publication.receipt,
                &request(),
                &budget
            )
            .is_err());
        assert_eq!(model.engine.jobs.counts(), before);
        assert!(
            model
                .engine
                .record(model.plan.publication.child())
                .unwrap()
                .forkpoint_held
        );
    }

    #[test]
    fn shared_explicit_release_fixture_validates_engine_hashes_without_manager_ownership() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-held-release-v1.json"
        ))
        .unwrap();
        for row in rows {
            let completion: crate::BranchCompletion =
                serde_json::from_value(row["request"]["completion"].clone()).unwrap();
            let proof: crate::BranchReleaseTransition =
                serde_json::from_value(row["transition"].clone()).unwrap();
            completion.validate().unwrap();
            proof.validate().unwrap();
            assert_eq!(proof.previous, completion.child);
            assert!(proof.change.mode == crate::branch_release::Mode::Explicit);
            assert!(proof.change.binding == completion.publication.change.child_origin);
        }
    }

    fn request() -> BranchReleaseRequest {
        BranchReleaseRequest {
            operation_id: "later-held-release".into(),
            request_sha256: "e".repeat(64),
            env: Vec::new(),
        }
    }
    // Private file/row/accounting model only; no SDK manager or VMM is created.
    fn entered() -> (IdentityModel, Retained) {
        let model = identity_model(true);
        Lifecycle::at(&model.plan.child.path)
            .finish_record(&model.plan, &model.enrollment, &model.identity_sha256)
            .unwrap();
        let intent = crate::branch_release::Intent::issue(
            &model.plan.publication,
            &model.record,
            &model.enrollment,
            &model.identity_sha256,
            &request(),
        )
        .unwrap();
        let source_gate = model
            .engine
            .observation_gate(&model.plan.publication.receipt.name)
            .unwrap();
        let child_gate = model.engine.observation_gate(&model.record.name).unwrap();
        let gates = crate::gate::lock_pair(
            (&model.plan.publication.receipt.name, &source_gate),
            (&model.record.name, &child_gate),
        )
        .unwrap();
        let leases = Leases {
            _gates: gates,
            _source: crate::sdk_compat::source_lease(
                &model.engine.binding().vm_root,
                &model.record.name,
            )
            .unwrap(),
            _work: model
                .engine
                .jobs
                .acquire(crate::jobs::Demand::branch_release())
                .unwrap(),
        };
        let state = Retained {
            request: request(),
            intent: intent.clone(),
            worker: Weak::new(),
            leases: Some(leases),
            result: None,
            _metadata: model.engine.jobs.branch_result_metadata().unwrap(),
        };
        Lifecycle::at(&model.plan.child.path)
            .enter_release(&model.plan, &intent, &model.enrollment)
            .unwrap();
        MaterialJournal::at(&model.plan.child.path)
            .begin_branch_release(&intent, &model.record)
            .unwrap();
        (model, state)
    }
    fn material_complete(model: &IdentityModel, state: &Retained) -> BranchReleaseTransition {
        let after = state.intent.released_record(&model.record).unwrap();
        model
            .engine
            .db
            .update_vm(&after.name, |record| *record = after.clone())
            .unwrap();
        MaterialJournal::at(&model.plan.child.path)
            .complete_branch_release(
                &state.intent,
                &crate::branch_release::tests::confirmed(&state.intent),
                &after,
            )
            .unwrap()
    }
    #[test]
    fn row_and_receipt_cannot_reconstruct_original_later_release_context() {
        let model = identity_model(true);
        let budget = crate::ReadBudget::new(
            std::time::Duration::from_secs(1),
            crate::Cancellation::default(),
        )
        .unwrap();
        let before = model.engine.jobs.counts();
        let error = model
            .engine
            .release_held_branch(
                &model.plan.publication.receipt,
                model.plan.publication.child(),
                &request(),
                &budget,
            )
            .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(model.engine.jobs.counts(), before);
        assert!(
            model
                .engine
                .record(model.plan.publication.child())
                .unwrap()
                .forkpoint_held
        );
    }
    #[test]
    fn entered_unknown_release_keeps_work_gates_and_never_replays_from_the_held_flag() {
        let (model, mut state) = entered();
        let before = model.engine.jobs.counts();
        let bytes =
            std::fs::read(model.plan.child.path.join("smolbox.branch-start-v1.json")).unwrap();
        for _ in 0..2 {
            assert!(state
                .completed(
                    &model.plan,
                    &model.enrollment,
                    model.plan.publication.child(),
                    &request()
                )
                .is_err());
            assert_eq!(model.engine.jobs.counts(), before);
        }
        assert_eq!(
            std::fs::read(model.plan.child.path.join("smolbox.branch-start-v1.json")).unwrap(),
            bytes
        );
        model
            .engine
            .db
            .update_vm(&model.record.name, |record| record.forkpoint_held = false)
            .unwrap();
        assert!(state
            .completed(
                &model.plan,
                &model.enrollment,
                model.plan.publication.child(),
                &request()
            )
            .is_err());
        assert!(state.leases.is_some());
        assert!(model
            .engine
            .observation_gate(&model.record.name)
            .unwrap()
            .try_lock()
            .is_err());
        let mut other = request();
        other.operation_id = "another-release".into();
        assert_eq!(
            state
                .completed(
                    &model.plan,
                    &model.enrollment,
                    model.plan.publication.child(),
                    &other
                )
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
    }
    #[test]
    fn both_completions_and_cache_promotion_precede_retiring_only_transient_work() {
        let (model, mut state) = entered();
        let result = material_complete(&model, &state);
        assert!(state
            .completed(&model.plan, &model.enrollment, &result.previous, &request())
            .is_err());
        assert!(state.retire_after_promotion(&result).is_err());
        Lifecycle::at(&model.plan.child.path)
            .released(&model.plan, &state.intent, &model.enrollment)
            .unwrap();
        assert_eq!(
            state
                .completed(&model.plan, &model.enrollment, &result.previous, &request())
                .unwrap(),
            Some(result.clone())
        );
        assert_eq!(model.engine.jobs.counts().work, 1);
        assert!(model
            .engine
            .observation_gate(&model.record.name)
            .unwrap()
            .try_lock()
            .is_err());
        model.engine.recover_branch_release_handle(&result).unwrap();
        state.retire_after_promotion(&result).unwrap();
        assert_eq!(
            model.engine.jobs.counts(),
            crate::jobs::Counts {
                branch_metadata: crate::jobs::BRANCH_BACKING_METADATA,
                ..crate::jobs::Counts::default()
            }
        );
        assert!(model
            .engine
            .observation_gate(&model.record.name)
            .unwrap()
            .try_lock()
            .is_ok());
        assert!(model
            .engine
            .observation_gate(&model.plan.publication.receipt.name)
            .unwrap()
            .try_lock()
            .is_ok());
    }
    #[test]
    fn completed_original_result_survives_journal_removal_without_another_sdk_call() {
        let (model, mut state) = entered();
        let result = material_complete(&model, &state);
        Lifecycle::at(&model.plan.child.path)
            .released(&model.plan, &state.intent, &model.enrollment)
            .unwrap();
        state
            .completed(&model.plan, &model.enrollment, &result.previous, &request())
            .unwrap();
        for name in ["smolbox.material-v2.json", "smolbox.branch-start-v1.json"] {
            std::fs::rename(
                model.plan.child.path.join(name),
                model.plan.child.path.join(format!("{name}.saved-model")),
            )
            .unwrap();
        }
        assert_eq!(
            state
                .completed(&model.plan, &model.enrollment, &result.receipt, &request())
                .unwrap(),
            Some(result.clone())
        );
        let active = Arc::new(());
        state.worker = Arc::downgrade(&active);
        assert_eq!(
            state
                .completed(&model.plan, &model.enrollment, &result.receipt, &request())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
    }
}
