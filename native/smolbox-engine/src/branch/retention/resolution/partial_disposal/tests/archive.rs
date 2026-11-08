//! Inert original-entry/actor/file/accounting projections. No SDK manager,
//! deletion, VMM, process loss or live persistence interruption is exercised.
use super::*;
use crate::PartialBranchCollection;
use std::time::{Duration, Instant};

impl Model {
    pub(in crate::branch::retention::resolution::partial_disposal) fn disposed(
        &self,
        resolved: bool,
    ) -> PartialBranchDisposal {
        self.enter();
        self.application().run(|_, _| self.delete()).unwrap();
        self.finish(if resolved {
            PartialBranchDisposalCompletion::ResolvedAbsent
        } else {
            PartialBranchDisposalCompletion::Deleted
        })
        .unwrap()
    }
    pub(super) fn archive(&self, proof: &PartialBranchDisposal) -> Result<PartialBranchDisposal> {
        self.archive_with_cleanup_unused(proof, false)
    }
    pub(in crate::branch::retention::resolution::partial_disposal) fn archive_with_cleanup_unused(
        &self,
        proof: &PartialBranchDisposal,
        cleanup_unused: bool,
    ) -> Result<PartialBranchDisposal> {
        self.archive_with_cleanup_handoff(
            proof,
            if cleanup_unused {
                super::super::archive::CleanupHandoff::NeverEnrolled
            } else {
                super::super::archive::CleanupHandoff::Unavailable
            },
        )
    }
    pub(in crate::branch::retention::resolution::partial_disposal) fn archive_with_cleanup_handoff(
        &self,
        proof: &PartialBranchDisposal,
        cleanup: super::super::archive::CleanupHandoff,
    ) -> Result<PartialBranchDisposal> {
        self.original.resolution.archive_partial_checked(
            &self.original.engine,
            proof,
            |work, intent| {
                // Explicit inert projection of the production wrapper's opaque
                // original-manager facts, never public authority or enrollment.
                assert!(work.boot.is_none());
                if *intent != self.intent {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let collected = self
                    .epoch
                    .collect_enrolled(&self.original.child.name, &self.enrollment)?;
                if PartialBranchCollection::issue(
                    &intent.request.collection_request,
                    &self.plan.publication,
                    &collected,
                )? != intent.request.collection
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                Ok((self.enrollment.clone(), cleanup))
            },
        )
    }
    fn historical(&self) -> Result<Option<PartialBranchDisposal>> {
        self.original.engine.inspect_partial_branch_disposal(
            &self.intent.request,
            &ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap(),
        )
    }
    fn assert_retained(&self, counts: crate::jobs::Counts) {
        assert_eq!(self.original.counts(), counts);
        assert_eq!(
            self.original
                .engine
                .branch_retention
                .entries
                .lock()
                .unwrap()
                .len(),
            1
        );
        assert!(self
            .original
            .engine
            .branch_retention
            .partial_disposed
            .lock()
            .unwrap()
            .is_empty());
        assert!(self
            .original
            .engine
            .observation_gate(&self.original.source.name)
            .unwrap()
            .try_lock()
            .is_err());
    }
}

#[test]
fn original_partial_disposal_handoff_keeps_backing_snapshot_and_both_completion_provenances() {
    for mode in 0..4 {
        for resolved in [false, true] {
            let mut model = Model::new(mode);
            let proof = model.disposed(resolved);
            let counts = model.original.counts();
            let source_path = model.plan.source.path.join("smolbox.material-v2.json");
            let source = std::fs::read(&source_path).unwrap();
            drop(model.original.entry.take());
            let enrollment_owners = Arc::strong_count(&model.enrollment);
            assert!(model.archive(&proof).unwrap() == proof);
            assert_eq!(Arc::strong_count(&model.enrollment), enrollment_owners + 1);
            let after = model.original.counts();
            assert_eq!(after.checkpoint_material, counts.checkpoint_material);
            assert!(after.checkpoint_material > 0);
            assert_eq!(after.branch_metadata, crate::jobs::BRANCH_BACKING_METADATA);
            assert_eq!(
                (after.work, after.children, after.descriptors, after.control),
                (0, 0, 0, 0)
            );
            assert_eq!(
                (after.staging, after.metadata, after.checkpoint_metadata),
                (0, 0, 0)
            );
            for name in [&model.original.source.name, &model.original.child.name] {
                assert!(model
                    .original
                    .engine
                    .observation_gate(name)
                    .unwrap()
                    .try_lock()
                    .is_ok());
            }
            assert!(model
                .original
                .engine
                .branch_retention
                .entries
                .lock()
                .unwrap()
                .is_empty());
            assert!(model
                .original
                .engine
                .branch_retention
                .completed
                .lock()
                .unwrap()
                .is_empty());
            assert!(model
                .original
                .engine
                .branch_retention
                .disposed
                .lock()
                .unwrap()
                .is_empty());
            assert!(model
                .original
                .engine
                .owned_managers
                .lock()
                .unwrap()
                .is_empty());
            assert!(model.plan.snapshot.path.exists());
            assert_eq!(std::fs::read(source_path).unwrap(), source);
            assert!(model.historical().unwrap() == Some(proof.clone()));
            assert!(
                model
                    .original
                    .resolution
                    .archive_partial_checked(&model.original.engine, &proof, |_, _| panic!(
                        "historical lookup never requalifies a live owner"
                    ))
                    .unwrap()
                    == proof
            );
            assert_eq!(model.original.counts(), after);
            assert!(model
                .original
                .resolution
                .state_checked(&model.original.engine)
                .is_err());
        }
    }
}

#[test]
fn extra_strong_or_weak_original_entry_owners_preserve_or_restore_the_entire_job() {
    for weak in [false, true] {
        let mut model = Model::new(2);
        let proof = model.disposed(false);
        let strong = model.original.entry.take().unwrap();
        let extra = Arc::downgrade(&strong);
        let counts = model.original.counts();
        if weak {
            drop(strong);
        }
        // Weak-only fails the unique conversion after registry removal; the
        // exact entry must be restored, including its original borrow and gates.
        assert_eq!(model.archive(&proof).unwrap_err().code, ErrorCode::Conflict);
        model.assert_retained(counts);
        drop(extra);
    }
    let mut model = Model::new(1);
    let proof = model.disposed(false);
    let extra = model.original.entry.take().unwrap();
    assert!(model.archive(&proof).is_err());
    drop(extra);
    assert!(model.archive(&proof).unwrap() == proof);
}

#[test]
fn partial_handoff_requires_exact_completed_ledger_not_a_rehashed_or_missing_acknowledgement() {
    for case in 0..3 {
        let mut model = Model::new(3);
        let mut proof = model.disposed(false);
        let counts = model.original.counts();
        drop(model.original.entry.take());
        match case {
            0 => std::fs::remove_file(model.ledger().path()).unwrap(),
            1 => {
                proof = model
                    .intent
                    .proof(PartialBranchDisposalCompletion::ResolvedAbsent)
                    .unwrap();
                proof.validate().unwrap();
            }
            _ => {
                let (mut record, version) = model.ledger().read().unwrap().unwrap();
                record.stage = Stage::Entered;
                record.proof = None;
                model.ledger().write(&record, Some(version)).unwrap();
            }
        }
        assert!(model.archive(&proof).is_err());
        model.assert_retained(counts);
        assert!(model.historical().unwrap().is_none());
    }
}

#[test]
fn opaque_collection_rejection_or_active_worker_prevents_handoff_without_freeing_work() {
    let mut model = Model::new(0);
    let proof = model.disposed(false);
    let counts = model.original.counts();
    drop(model.original.entry.take());
    assert!(model
        .original
        .resolution
        .archive_partial_checked(&model.original.engine, &proof, |_, _| Err(Error::before(
            ErrorCode::Ownership
        )))
        .is_err());
    model.assert_retained(counts);
    let active = Arc::new(());
    {
        let entries = model
            .original
            .engine
            .branch_retention
            .entries
            .lock()
            .unwrap();
        entries.values().next().unwrap().work.lock().unwrap().worker = Arc::downgrade(&active);
    }
    assert!(model.archive(&proof).is_err());
    model.assert_retained(counts);
    drop(active);
    assert!(model.archive(&proof).unwrap() == proof);
}

#[test]
fn partial_handoff_rejects_crossed_metadata_material_and_phase_without_changing_reservations() {
    for case in 0..4 {
        let mut model = Model::new(1);
        let proof = model.disposed(false);
        let counts = model.original.counts();
        {
            let mut work = model.original.entry().work.lock().unwrap();
            match case {
                0 => work.phase = Phase::Published,
                1 => work.snapshot.as_mut().unwrap().source.created_at += 7,
                2 => work.snapshot.as_mut().unwrap().child.created_at += 7,
                _ => {
                    let path = model.plan.snapshot.path.clone();
                    std::fs::rename(&path, path.with_extension("kept")).unwrap();
                    std::fs::create_dir(&path).unwrap();
                }
            }
        }
        drop(model.original.entry.take());
        assert!(model.archive(&proof).is_err());
        model.assert_retained(counts);
    }
}

#[test]
fn partial_handoff_control_admission_cancellation_expiry_and_missing_epoch_keep_original_job() {
    for case in 0..4 {
        let mut model = Model::new(1);
        let proof = model.disposed(false);
        let counts = model.original.counts();
        drop(model.original.entry.take());
        let control = if case == 0 {
            Some(
                model
                    .original
                    .engine
                    .jobs
                    .acquire(crate::jobs::Demand::branch_retirement())
                    .unwrap(),
            )
        } else {
            None
        };
        if case == 1 {
            model.original.resolution.budget.cancel.cancel();
        }
        if case == 2 {
            model.original.resolution.budget.deadline = Instant::now();
        }
        let result = if case == 3 {
            model
                .original
                .resolution
                .finish_partial_branch_disposal(&model.original.engine, &proof)
        } else {
            model.archive(&proof)
        };
        assert!(result.is_err());
        drop(control);
        model.assert_retained(counts);
    }
}

#[test]
fn partial_handoff_works_in_quarantine_without_reopening_admission_or_releasing_backing() {
    let mut model = Model::new(3);
    let proof = model.disposed(true);
    let bytes = model.original.counts().checkpoint_material;
    drop(model.original.entry.take());
    model.original.engine.jobs.quarantine();
    assert!(model.archive(&proof).unwrap() == proof);
    assert_eq!(model.original.counts().work, 0);
    assert_eq!(model.original.counts().checkpoint_material, bytes);
    assert!(!model.original.engine.jobs.available());
    assert!(model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::branch_source())
        .is_err());
    assert!(model.historical().unwrap() == Some(proof));
}

#[test]
fn historical_partial_disposal_never_adopts_or_removes_recreated_names_or_changed_actions() {
    let mut model = Model::new(2);
    let proof = model.disposed(true);
    drop(model.original.entry.take());
    model.archive(&proof).unwrap();
    let counts = model.original.counts();
    let mut foreign = model.original.child.clone();
    foreign.created_at += 7;
    model
        .original
        .engine
        .db
        .insert_vm(&foreign.name, &foreign)
        .unwrap();
    std::fs::create_dir(&model.plan.child.path).unwrap();
    let sentinel = model.plan.child.path.join("foreign");
    std::fs::write(&sentinel, b"preserved").unwrap();
    model
        .original
        .engine
        .db
        .update_vm(&model.original.source.name, |row| row.created_at += 9)
        .unwrap();
    assert!(model.historical().unwrap() == Some(proof.clone()));
    assert!(model.archive(&proof).unwrap() == proof);
    assert_eq!(std::fs::read(sentinel).unwrap(), b"preserved");
    let mut request = model.intent.request.clone();
    request.operation_id = "different-partial-disposal".into();
    request.request_sha256 = request.digest().unwrap();
    let budget = ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap();
    assert!(model
        .original
        .engine
        .inspect_partial_branch_disposal(&request, &budget)
        .is_err());
    assert_eq!(model.original.counts(), counts);
}

#[test]
fn archived_partial_acknowledgement_requires_its_protected_ledger_and_original_runtime() {
    for replace in [false, true] {
        let mut model = Model::new(1);
        let proof = model.disposed(false);
        drop(model.original.entry.take());
        model.archive(&proof).unwrap();
        let counts = model.original.counts();
        if replace {
            let other_root = tempfile::tempdir().unwrap();
            model.original.engine.runtime = crate::machine::tests::test_engine(other_root.path())
                .runtime
                .clone();
        } else {
            std::fs::remove_file(model.ledger().path()).unwrap();
        }
        assert!(model.historical().is_err());
        assert!(model.archive(&proof).is_err());
        assert_eq!(model.original.counts(), counts);
    }
}
