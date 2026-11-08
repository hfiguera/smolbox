//! Explicit cleanup continuation with the original leases and collected child.
//! An entered SDK deletion is never retried, even with the same request.
use super::*;

impl Journal {
    fn begin_finishing(
        &self,
        intent: &Intent,
        request: &ContinuationRequest,
        collection: &crate::epoch::BootCollection,
        budget: &ReadBudget,
    ) -> Result<()> {
        request.validate()?;
        intent.collected(collection)?;
        let (mut record, version) = self.read()?;
        if record.intent != *intent {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if record
            .continuation
            .as_ref()
            .is_some_and(|prior| prior != request)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if record.phase == Phase::Finishing && record.continuation.as_ref() == Some(request) {
            return budget.check();
        }
        if !matches!(record.phase, Phase::Collecting | Phase::Collected) {
            return Err(Error::before(ErrorCode::State));
        }
        record.schema = 3;
        record.phase = Phase::Finishing;
        record.continuation = Some(request.clone());
        budget.check()?;
        self.write(&record, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
}
impl Retained {
    fn continuation_status(
        &mut self,
        journal: &Journal,
        request: &ContinuationRequest,
    ) -> Result<bool> {
        self.check_returned(self.intent.receipt())?;
        request.validate()?;
        if self
            .continuation
            .as_ref()
            .is_some_and(|prior| prior != request)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if let Some(completion) = &self.completion {
            return match completion {
                Completion::Deleted if self.continuation.as_ref() == Some(request) => Ok(true),
                _ => Err(Error::before(ErrorCode::State)),
            };
        }
        let (record, _) = journal.read()?;
        if record.intent != self.intent {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if record
            .continuation
            .as_ref()
            .is_some_and(|prior| prior != request)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        match record.phase {
            Phase::Deleted => {
                self.import_completion(record)?;
                if self.continuation.as_ref() == Some(request) {
                    Ok(true)
                } else {
                    Err(Error::before(ErrorCode::State))
                }
            }
            Phase::ResolvedAbsent => {
                self.import_completion(record)?;
                Err(Error::before(ErrorCode::State))
            }
            Phase::Deleting => Err(Error::uncertain(ErrorCode::State)),
            Phase::Finishing | Phase::Collecting | Phase::Collected => Ok(false),
        }
    }
}
pub(super) fn manager_is_original(context: &Context) -> Result<()> {
    let manager = context
        .manager
        .try_lock()
        .map_err(|_| Error::before(ErrorCode::Conflict))?;
    let name = &context.plan.publication.child().name;
    if manager.name() != Some(name.as_str())
        || manager
            .child_pid()
            .is_some_and(|pid| pid != context.enrollment.child().pid)
        || manager.storage_path()
            != context
                .plan
                .child
                .path
                .join(smolvm::storage::STORAGE_DISK_FILENAME)
        || manager.overlay_path()
            != context
                .plan
                .child
                .path
                .join(smolvm::storage::OVERLAY_DISK_FILENAME)
        || context._runtime.pid(name).is_some()
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
impl Engine {
    /// Continue only the as-yet-unentered delete step after positive original
    /// collection. Requires explicit fencing; never repeats SDK shutdown/delete.
    pub fn continue_held_branch_deletion(
        &self,
        child: &CreationReceipt,
        operation_id: &str,
        request_sha256: &str,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<Observation> {
        let request = ContinuationRequest {
            operation_id: operation_id.into(),
            request_sha256: request_sha256.into(),
        };
        request.validate()?;
        if !quiesced {
            return Err(Error::before(ErrorCode::Validation));
        }
        budget.check()?;
        child.validate(self.binding())?;
        let control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self.retained_branch_context(child)?;
        let journal = Journal::new(self.domain.clone(), child)?;
        let mut retained = context
            .deletion
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let state = retained.as_mut().ok_or(Error::before(ErrorCode::State))?;
        state.check_returned(child)?;
        if state.continuation_status(&journal, &request)? {
            budget.check()?;
            drop(retained);
            if !self.known_branch_deletion(&context, &journal, child)? {
                return Err(Error::uncertain(ErrorCode::State));
            }
            return Ok(missing());
        }
        self.binding().validate()?;
        self.verify_database_identity()?;
        let epoch = self.collection_epoch()?.clone();
        if state.leases.is_none()
            || state.intent.plan != context.plan
            || state.intent.boot != *context.enrollment.intent()
            || state.intent.child != context.enrollment.child()
            || state.intent.identity_sha256 != context.identity_sha256
            || !epoch.bound_to(self.binding())
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let collection = epoch.collect_enrolled(&child.name, &context.enrollment)?;
        manager_is_original(&context)?;
        let before = self
            .observation_record(&child.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        stopped_record(&state.intent, &before, &collection, budget)?;
        let active = Arc::new(());
        // Freeze the request and retain the worker before even publishing entry.
        state.continuation = Some(request.clone());
        state.worker = Arc::downgrade(&active);
        journal.begin_finishing(&state.intent, &request, &collection, budget)?;
        drop(retained);
        let application = ContinuedDeletion {
            context: context.clone(),
            epoch,
            journal,
            request,
            before,
            database: self.binding().database.clone(),
            identity: self.database_identity,
            db: self.db.clone(),
            budget: budget.clone(),
            _control: control,
        };
        crate::oci_start::observe_owned(
            self.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _active = active;
                application.run()
            },
        )
        .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        let journal = Journal::new(self.domain.clone(), child)?;
        if !self.known_branch_deletion(&context, &journal, child)? {
            return Err(Error::uncertain(ErrorCode::State));
        }
        Ok(missing())
    }
}
struct ContinuedDeletion {
    context: Arc<Context>,
    epoch: crate::epoch::ActorEpoch,
    journal: Journal,
    request: ContinuationRequest,
    before: smolvm::config::VmRecord,
    database: std::path::PathBuf,
    identity: (u64, u64),
    db: smolvm::db::SmolvmDb,
    budget: ReadBudget,
    // This control request belongs to the actual owner-thread job after timeout.
    _control: crate::jobs::JobLease,
}
impl ContinuedDeletion {
    fn run(self) -> Result<()> {
        let mut retained = self
            .context
            .deletion
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        let state = retained
            .as_mut()
            .ok_or(Error::uncertain(ErrorCode::State))?;
        let (record, _) = self.journal.read()?;
        if record.intent != state.intent
            || record.phase != Phase::Finishing
            || record.continuation.as_ref() != Some(&self.request)
            || state.continuation.as_ref() != Some(&self.request)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let name = &self.before.name;
        let collection = self
            .epoch
            .collect_enrolled(name, &self.context.enrollment)?;
        manager_is_original(&self.context)?;
        self.context
            .manager
            .try_lock()
            .map_err(|_| Error::uncertain(ErrorCode::Conflict))?
            .mark_stopped();
        let current =
            crate::sdk_compat::observe_record(&self.database, self.identity, name, &self.budget)?
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        let before_sha256 = crate::material::hash(&self.before)?;
        if crate::material::hash(&current)? != before_sha256 {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let stopped = stopped_record(&state.intent, &current, &collection, &self.budget)?;
        let mut changed = false;
        self.budget.check()?;
        self.db
            .update_vm(name, |row| {
                if crate::material::hash(row).ok().as_ref() == Some(&before_sha256) {
                    *row = stopped.clone();
                    changed = true;
                }
            })
            .map_err(|_| Error::uncertain(ErrorCode::Database))?;
        let after =
            crate::sdk_compat::observe_record(&self.database, self.identity, name, &self.budget)?
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if !changed || crate::material::hash(&after)? != crate::material::hash(&stopped)? {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        CollectedDeletion {
            journal: &self.journal,
            authority: ResolutionAuthority {
                epoch: &self.epoch,
                enrollment: &self.context.enrollment,
                database: &self.database,
                identity: self.identity,
            },
            budget: &self.budget,
        }
        .finish(state, Phase::Finishing, || {
            if smolvm::agent::vm_data_dir(name) != self.context.plan.child.path {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            self.context
                ._runtime
                .delete_machine(name)
                .map_err(|_| Error::uncertain(ErrorCode::Native))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch_delete::tests::{authority, budget, fixture, retained};
    use std::cell::Cell;

    fn request() -> ContinuationRequest {
        ContinuationRequest {
            operation_id: "continue-owned-delete".into(),
            request_sha256: "c".repeat(64),
        }
    }
    // Private row/file/accounting results only; callbacks never call the SDK.
    fn canonical(
        model: &crate::branch_boot::tests::IdentityModel,
        epoch: &crate::epoch::ActorEpoch,
        intent: &Intent,
    ) {
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        let row = stopped_record(intent, &model.record, &collection, &budget()).unwrap();
        model
            .engine
            .db
            .update_vm(&row.name, |actual| *actual = row.clone())
            .unwrap();
    }
    #[test]
    fn continuation_requires_quiescence_request_and_original_context_without_sdk_adoption() {
        let (model, _, intent, journal) = fixture();
        let before = model.engine.jobs.counts();
        for (quiesced, id, hash) in [
            (false, "continue-delete", "c".repeat(64)),
            (true, "../invalid", "c".repeat(64)),
            (true, "continue-delete", "invalid".into()),
            (true, "continue-delete", "c".repeat(64)),
        ] {
            let error = model
                .engine
                .continue_held_branch_deletion(intent.receipt(), id, &hash, quiesced, &budget())
                .unwrap_err();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(model.engine.jobs.counts(), before);
        }
        assert!(!journal.path.exists());
        assert_eq!(
            crate::material::hash(&model.engine.record(intent.receipt()).unwrap()).unwrap(),
            crate::material::hash(&model.record).unwrap()
        );
    }
    #[test]
    fn collection_only_normalizes_the_original_held_row_and_rejects_foreign_or_changed_material() {
        let (model, epoch, intent, _) = fixture();
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        let stopped = stopped_record(&intent, &model.record, &collection, &budget()).unwrap();
        assert!(
            stopped.state == smolvm::config::RecordState::Stopped
                && stopped.pid.is_none()
                && stopped.pid_start_time.is_none()
        );
        assert!(stopped.forkpoint_held);
        assert_eq!(
            crate::identity::material_hash(&stopped).unwrap(),
            crate::identity::material_hash(&model.record).unwrap()
        );
        for case in 0..6 {
            let mut row = model.record.clone();
            match case {
                0 => row.pid = Some(1),
                1 => row.pid_start_time = Some(9),
                2 => row.state = smolvm::config::RecordState::Paused,
                3 => row.forkpoint_held = false,
                4 => {
                    row.labels.insert("smolbox.owner".into(), "f".repeat(64));
                }
                _ => row.cpus += 1,
            }
            assert!(stopped_record(&intent, &row, &collection, &budget()).is_err());
        }
        let foreign = crate::branch_boot::tests::identity_model(true);
        let foreign_collection = foreign
            .actors
            .collect_enrolled(&foreign.record.name, &foreign.enrollment)
            .unwrap();
        assert!(stopped_record(&intent, &model.record, &foreign_collection, &budget()).is_err());
        assert!(
            model.engine.record(intent.receipt()).unwrap().state
                == smolvm::config::RecordState::Running
        );
    }
    #[test]
    fn finishing_freezes_request_and_preserves_legacy_versions_without_sdk_reentry() {
        for collected in [false, true] {
            let (model, epoch, intent, journal) = fixture();
            let mut state = retained(&model, &intent);
            journal.enter(&intent).unwrap();
            let original = std::fs::read(&journal.path).unwrap();
            assert!(!std::str::from_utf8(&original)
                .unwrap()
                .contains("\"continuation\""));
            let collection = epoch
                .collect_enrolled(&intent.receipt().name, &model.enrollment)
                .unwrap();
            if collected {
                journal.collected(&intent, &collection).unwrap();
            }
            let request = request();
            assert!(!state.continuation_status(&journal, &request).unwrap());
            state.continuation = Some(request.clone());
            journal
                .begin_finishing(&intent, &request, &collection, &budget())
                .unwrap();
            let (record, _) = journal.read().unwrap();
            assert!(
                record.schema == 3
                    && record.phase == Phase::Finishing
                    && record.resolution.is_none()
            );
            let bytes = std::fs::read(&journal.path).unwrap();
            journal
                .begin_finishing(&intent, &request, &collection, &budget())
                .unwrap();
            assert_eq!(std::fs::read(&journal.path).unwrap(), bytes);
            let mut crossed = request.clone();
            crossed.request_sha256 = "f".repeat(64);
            assert!(journal
                .begin_finishing(&intent, &crossed, &collection, &budget())
                .is_err());
            assert!(state.continuation_status(&journal, &crossed).is_err());
            let active = Arc::new(());
            state.worker = Arc::downgrade(&active);
            assert_eq!(
                state
                    .continuation_status(&journal, &request)
                    .unwrap_err()
                    .code,
                ErrorCode::Conflict
            );
            drop(active);
            let mut invalid = record.clone();
            invalid.schema = 1;
            assert!(invalid.validate().is_err());
            invalid.schema = 2;
            assert!(invalid.validate().is_err());
            invalid = record;
            invalid.continuation = None;
            assert!(invalid.validate().is_err());
            journal
                .advance(&intent, Phase::Finishing, Phase::Deleting)
                .unwrap();
            assert!(journal
                .advance(&intent, Phase::Deleting, Phase::Finishing)
                .is_err());
            assert!(journal
                .begin_finishing(&intent, &request, &collection, &budget())
                .is_err());
            assert!(state.continuation_status(&journal, &request).is_err());
        }
    }
    #[test]
    fn final_delete_is_one_shot_closes_only_sdk_lock_and_preserves_backing_admission() {
        let (model, epoch, intent, journal) = fixture();
        let pool = &model.engine.jobs;
        let mut creation = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
        creation.promote_branch_preparation().unwrap();
        creation.promote_branch_backing(7 << 30).unwrap();
        let backing = creation.handoff_branch().unwrap();
        drop(creation);
        let mut state = retained(&model, &intent);
        journal.enter(&intent).unwrap();
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        canonical(&model, &epoch, &intent);
        let request = request();
        state.continuation = Some(request.clone());
        journal
            .begin_finishing(&intent, &request, &collection, &budget())
            .unwrap();
        pool.quarantine(); // Admission-only model, no live SDK interruption.
        let control = pool
            .acquire(crate::jobs::Demand::material_resolution())
            .unwrap();
        let observer = pool
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        let source_gate = model
            .engine
            .observation_gate(&intent.plan.publication.previous.name)
            .unwrap();
        let called = Cell::new(0);
        let budget = budget();
        let finish = CollectedDeletion {
            journal: &journal,
            authority: authority(&model, &epoch),
            budget: &budget,
        };
        finish
            .finish(&mut state, Phase::Finishing, || {
                called.set(called.get() + 1);
                assert!(journal.read().unwrap().0.phase == Phase::Deleting);
                assert!(source_gate.try_lock().is_err());
                let sdk_lock = crate::sdk_compat::source_lease(
                    &model.engine.binding().vm_root,
                    &intent.receipt().name,
                )
                .unwrap();
                drop(sdk_lock); // The outer source lease really closed before callback entry.
                model.engine.db.remove_vm(&intent.receipt().name).unwrap();
                std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
                Ok(())
            })
            .unwrap();
        assert!(finish
            .finish(&mut state, Phase::Finishing, || {
                called.set(called.get() + 1);
                Ok(())
            })
            .is_err());
        assert_eq!(called.get(), 1);
        assert!(state.continuation_status(&journal, &request).unwrap());
        let bytes = std::fs::read(&journal.path).unwrap();
        state.completion = None;
        assert!(state.continuation_status(&journal, &request).unwrap());
        assert_eq!(std::fs::read(&journal.path).unwrap(), bytes);
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().checkpoint_material, 7 << 30);
        state.retire_transient().unwrap(); // Caller acknowledgement model, no real manager cache.
        assert_eq!(pool.counts().work, 0);
        assert_eq!(pool.counts().checkpoint_material, 7 << 30);
        assert_eq!(
            pool.counts().branch_metadata,
            2 * crate::jobs::BRANCH_BACKING_METADATA
        );
        assert!(
            !pool.available()
                && model.plan.source.path.exists()
                && model.plan.snapshot.path.exists()
        );
        drop((control, observer, backing)); // Accounting teardown only, no backing disposal.
    }
    #[test]
    fn unknown_final_delete_never_replays_and_can_only_resolve_by_positive_absence() {
        let (model, epoch, intent, journal) = fixture();
        let mut state = retained(&model, &intent);
        journal.enter(&intent).unwrap();
        canonical(&model, &epoch, &intent);
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        let request = request();
        state.continuation = Some(request.clone());
        journal
            .begin_finishing(&intent, &request, &collection, &budget())
            .unwrap();
        let called = Cell::new(0);
        let counts = model.engine.jobs.counts();
        let budget = budget();
        let finish = CollectedDeletion {
            journal: &journal,
            authority: authority(&model, &epoch),
            budget: &budget,
        };
        assert!(finish
            .finish(&mut state, Phase::Finishing, || {
                called.set(1);
                Err(Error::uncertain(ErrorCode::Native))
            })
            .is_err());
        assert!(finish
            .finish(&mut state, Phase::Finishing, || {
                called.set(2);
                Ok(())
            })
            .is_err());
        assert_eq!(called.get(), 1);
        assert!(state.continuation_status(&journal, &request).is_err());
        assert!(journal
            .begin_finishing(&intent, &request, &collection, &budget)
            .is_err());
        assert_eq!(model.engine.jobs.counts(), counts);
        assert!(state.leases.is_some() && state.completion.is_none());
        assert!(state
            .resolve(
                &journal,
                intent.receipt(),
                "resolve-continued-delete",
                &"e".repeat(64),
                authority(&model, &epoch),
                &budget
            )
            .is_err());
        // Model later confirmed absence, not another SDK invocation or a live fault.
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
        let proof = state
            .resolve(
                &journal,
                intent.receipt(),
                "resolve-continued-delete",
                &"e".repeat(64),
                authority(&model, &epoch),
                &budget,
            )
            .unwrap();
        let (record, _) = journal.read().unwrap();
        assert!(record.schema == 3 && record.phase == Phase::ResolvedAbsent);
        assert_eq!(
            proof.deletion_sha256,
            deletion_digest(&intent, Some(&request)).unwrap()
        );
        let mut crossed = record.clone();
        crossed.continuation.as_mut().unwrap().request_sha256 = "f".repeat(64);
        assert!(crossed.validate().is_err());
        assert!(record.continuation.as_ref() == Some(&request) && record.resolution == Some(proof));
        assert!(state.continuation_status(&journal, &request).is_err()); // Resolution is not SDK success.
        assert!(model.plan.source.path.exists() && state.leases.is_some());
    }
    #[test]
    fn cancelled_finishing_can_continue_only_the_same_unentered_step_with_a_fresh_budget() {
        let (model, epoch, intent, journal) = fixture();
        let mut state = retained(&model, &intent);
        journal.enter(&intent).unwrap();
        canonical(&model, &epoch, &intent);
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        let request = request();
        state.continuation = Some(request.clone());
        journal
            .begin_finishing(&intent, &request, &collection, &budget())
            .unwrap();
        let old = budget();
        old.cancel.cancel();
        let called = Cell::new(0);
        assert!(CollectedDeletion {
            journal: &journal,
            authority: authority(&model, &epoch),
            budget: &old
        }
        .finish(&mut state, Phase::Finishing, || {
            called.set(1);
            Ok(())
        })
        .is_err());
        assert_eq!(called.get(), 0);
        assert!(journal.read().unwrap().0.phase == Phase::Finishing);
        assert!(!state.continuation_status(&journal, &request).unwrap());
        let fresh = budget();
        journal
            .begin_finishing(&intent, &request, &collection, &fresh)
            .unwrap();
        CollectedDeletion {
            journal: &journal,
            authority: authority(&model, &epoch),
            budget: &fresh,
        }
        .finish(&mut state, Phase::Finishing, || {
            called.set(1);
            model.engine.db.remove_vm(&intent.receipt().name).unwrap();
            std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
            Ok(())
        })
        .unwrap();
        assert_eq!(called.get(), 1);
        assert!(state.continuation_status(&journal, &request).unwrap());
    }
    #[test]
    fn final_delete_checks_fresh_bounded_leaf_inventory_before_sdk_entry() {
        let (model, epoch, intent, journal) = fixture();
        let mut state = retained(&model, &intent);
        journal.enter(&intent).unwrap();
        canonical(&model, &epoch, &intent);
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        let request = request();
        state.continuation = Some(request.clone());
        journal
            .begin_finishing(&intent, &request, &collection, &budget())
            .unwrap();
        let before = std::fs::read(&journal.path).unwrap();
        let mut nested = model.record.clone();
        nested.name = "unexpected-descendant".into();
        nested.golden = Some(intent.receipt().name.clone());
        model.engine.db.insert_vm(&nested.name, &nested).unwrap();
        let budget = budget();
        let finish = CollectedDeletion {
            journal: &journal,
            authority: authority(&model, &epoch),
            budget: &budget,
        };
        assert!(finish
            .finish(&mut state, Phase::Finishing, || panic!(
                "nested child reached SDK deletion"
            ))
            .is_err());
        model.engine.db.remove_vm(&nested.name).unwrap();
        let writer = rusqlite::Connection::open(&model.engine.binding().database).unwrap();
        writer
            .execute(
                "INSERT INTO vms(name,data) VALUES ('oversized',zeroblob(?1))",
                [crate::observations::MAX_RECORD_BYTES + 1],
            )
            .unwrap();
        assert!(finish
            .finish(&mut state, Phase::Finishing, || panic!(
                "unbounded inventory reached SDK deletion"
            ))
            .is_err());
        assert_eq!(std::fs::read(&journal.path).unwrap(), before);
        assert!(state.leases.is_some() && state.completion.is_none());
    }
    #[test]
    fn final_delete_excludes_private_pack_mounts_and_never_follows_a_source_cache_link() {
        let (model, epoch, intent, journal) = fixture();
        let mut state = retained(&model, &intent);
        journal.enter(&intent).unwrap();
        canonical(&model, &epoch, &intent);
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        let request = request();
        state.continuation = Some(request.clone());
        journal
            .begin_finishing(&intent, &request, &collection, &budget())
            .unwrap();
        let pack = intent.plan.child.path.join("pack");
        std::fs::create_dir(&pack).unwrap();
        let budget = budget();
        let finish = CollectedDeletion {
            journal: &journal,
            authority: authority(&model, &epoch),
            budget: &budget,
        };
        assert!(finish
            .finish(&mut state, Phase::Finishing, || panic!(
                "private volume reached SDK deletion"
            ))
            .is_err());
        assert!(journal.read().unwrap().0.phase == Phase::Finishing);
        std::fs::remove_dir(&pack).unwrap();
        let source_cache = tempfile::tempdir().unwrap();
        let marker = source_cache.path().join("retained-source-marker");
        std::fs::write(&marker, b"source remains owned elsewhere").unwrap();
        std::os::unix::fs::symlink(source_cache.path(), &pack).unwrap();
        finish
            .finish(&mut state, Phase::Finishing, || {
                model.engine.db.remove_vm(&intent.receipt().name).unwrap();
                std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
                Ok(())
            })
            .unwrap();
        assert_eq!(
            std::fs::read(&marker).unwrap(),
            b"source remains owned elsewhere"
        );
        assert!(model.plan.source.path.exists());
    }
}
