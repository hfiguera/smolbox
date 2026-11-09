//! Inert private original-entry/actor/SQLite/path models. No AgentManager,
//! SDK deletion, VMM, process loss or live persistence interruption occurs.
use super::*;
use crate::{PartialBranchChildAbsence, PartialBranchChildAbsenceRequest};
use std::time::{Duration, Instant};

fn staged(mode: u8, resolved: bool) -> (Model, PartialBranchChildAbsenceRequest) {
    let mut model = Model::new(mode);
    let disposal = model.disposed(resolved);
    drop(model.original.entry.take());
    model.archive(&disposal).unwrap();
    let mut request = PartialBranchChildAbsenceRequest {
        disposal,
        operation_id: "retire-original-partial-child".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    (model, request)
}
fn budget() -> ReadBudget {
    ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
}
fn observe(
    model: &Model,
    request: &PartialBranchChildAbsenceRequest,
) -> Result<PartialBranchChildAbsence> {
    let budget = budget();
    model
        .original
        .engine
        .qualify_partial_child_absence(request, &budget, |record, enrollment| {
            super::super::archive::absence::collected(&model.epoch, record, enrollment, &budget)
        })
}

#[test]
fn original_collected_partial_absence_keeps_both_provenances_source_snapshot_and_all_backing() {
    for mode in 0..4 {
        for resolved in [false, true] {
            let (model, request) = staged(mode, resolved);
            let before = model.original.counts();
            let source =
                std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap();
            let source_gate = model
                .original
                .engine
                .observation_gate(&model.original.source.name)
                .unwrap();
            let child_gate = model
                .original
                .engine
                .observation_gate(&model.original.child.name)
                .unwrap();
            let checks = Cell::new(0);
            let budget = budget();
            let proof = model
                .original
                .engine
                .qualify_partial_child_absence(&request, &budget, |record, enrollment| {
                    assert!(source_gate.try_lock().is_err() && child_gate.try_lock().is_err());
                    assert!(Arc::ptr_eq(enrollment, &model.enrollment));
                    assert_eq!(model.original.counts().control, 1);
                    checks.set(checks.get() + 1);
                    super::super::archive::absence::collected(
                        &model.epoch,
                        record,
                        enrollment,
                        &budget,
                    )
                })
                .unwrap();
            request.matches(&proof).unwrap();
            assert_eq!(checks.get(), 2);
            assert_eq!(model.original.counts(), before);
            assert!(before.checkpoint_material > 0 && model.plan.snapshot.path.exists());
            assert_eq!(
                std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap(),
                source
            );
            assert_eq!(
                model
                    .original
                    .engine
                    .db
                    .get_vm(&model.original.source.name)
                    .unwrap()
                    .unwrap()
                    .state,
                smolvm::config::RecordState::Running
            );
            assert!(observe(&model, &request).unwrap() == proof);
            assert!(!format!("{proof:?}").contains(&model.original.child.name));
        }
    }
}

#[test]
fn prior_disposal_and_absence_proofs_cannot_authorize_a_recreated_namespace_or_ownership_handle() {
    for case in 0..5 {
        let (model, request) = staged(1, false);
        let saved = observe(&model, &request).unwrap();
        let before = model.original.counts();
        let path = &model.plan.child.path;
        match case {
            0 => model
                .original
                .engine
                .db
                .insert_vm(&model.original.child.name, &model.original.child)
                .unwrap(),
            1 => assert!(model
                .original
                .engine
                .db
                .reserve_vm_create(&model.original.child.name, "inert-reservation")
                .unwrap()),
            2 => std::fs::create_dir(path).unwrap(),
            3 => std::os::unix::fs::symlink(model.plan.source.path.join("absent-target"), path)
                .unwrap(),
            _ => model
                .original
                .engine
                .track_handle(request.disposal.publication.child())
                .unwrap(),
        }
        assert!(observe(&model, &request).is_err());
        request.matches(&saved).unwrap(); // Historical correlation only.
        assert_eq!(model.original.counts(), before);
        if matches!(case, 2 | 3) {
            assert!(std::fs::symlink_metadata(path).is_ok());
        }
    }
}

#[test]
fn second_pass_rejects_an_inert_namespace_change_without_publishing_absence() {
    let (model, request) = staged(2, false);
    let before = model.original.counts();
    let checks = Cell::new(0);
    let budget = budget();
    assert!(model
        .original
        .engine
        .qualify_partial_child_absence(&request, &budget, |record, enrollment| {
            checks.set(checks.get() + 1);
            if checks.get() == 2 {
                std::fs::create_dir(&model.plan.child.path).unwrap();
            }
            super::super::archive::absence::collected(&model.epoch, record, enrollment, &budget)
        })
        .is_err());
    assert_eq!(checks.get(), 2);
    assert!(model.plan.child.path.exists());
    assert_eq!(model.original.counts(), before);
}

#[test]
fn missing_original_archive_ledger_or_crossed_valid_disposal_never_reconstructs_authority() {
    for case in 0..3 {
        let (model, mut request) = staged(3, false);
        let before = model.original.counts();
        if case == 0 {
            let archived = std::mem::take(
                &mut *model
                    .original
                    .engine
                    .branch_retention
                    .partial_disposed
                    .lock()
                    .unwrap(),
            );
            assert!(observe(&model, &request).is_err());
            *model
                .original
                .engine
                .branch_retention
                .partial_disposed
                .lock()
                .unwrap() = archived;
        } else if case == 1 {
            std::fs::remove_file(model.ledger().path()).unwrap();
            assert!(observe(&model, &request).is_err());
        } else {
            request.disposal = model
                .intent
                .proof(PartialBranchDisposalCompletion::ResolvedAbsent)
                .unwrap();
            request.request_sha256 = request.digest().unwrap();
            request.validate().unwrap();
            assert!(observe(&model, &request).is_err());
        }
        assert_eq!(model.original.counts(), before);
    }
}

#[test]
fn final_archive_check_refuses_a_changed_inert_file_projection_and_keeps_backing() {
    let (model, request) = staged(0, true);
    let before = model.original.counts();
    let checks = Cell::new(0);
    let budget = budget();
    assert!(model
        .original
        .engine
        .qualify_partial_child_absence(&request, &budget, |record, enrollment| {
            checks.set(checks.get() + 1);
            if checks.get() == 2 {
                std::fs::rename(
                    model.ledger().path(),
                    model.ledger().path().with_extension("kept"),
                )
                .unwrap();
            }
            super::super::archive::absence::collected(&model.epoch, record, enrollment, &budget)
        })
        .is_err());
    assert_eq!(checks.get(), 2);
    assert_eq!(model.original.counts(), before);
}

#[test]
fn current_original_epoch_and_opaque_collection_are_required_independently_of_source_boots() {
    let (model, request) = staged(1, false);
    // A pending source actor is an inert record; it neither grants nor blocks
    // fresh absence for the already collected original child.
    let pending = model.epoch.begin_boot(&model.original.source.name).unwrap();
    assert!(observe(&model, &request).is_ok());
    drop(pending);
    let other = tempfile::tempdir().unwrap();
    let (_, _, epoch) = crate::epoch::tests::fixture_for_binding_and_epoch(
        &other.path().canonicalize().unwrap(),
        None,
        model.original.engine.binding().clone(),
        "f".repeat(32),
    );
    let budget = budget();
    assert!(model
        .original
        .engine
        .qualify_partial_child_absence(&request, &budget, |record, enrollment| {
            super::super::archive::absence::collected(&epoch, record, enrollment, &budget)
        })
        .is_err());
}

#[test]
fn finite_controls_cancellation_expiry_gates_and_missing_live_epoch_never_release_charge() {
    let (model, request) = staged(1, false);
    let before = model.original.counts();
    assert!(model
        .original
        .engine
        .qualify_partial_branch_child_absence(&request, &budget())
        .is_err());
    for case in 0..3 {
        let mut b = budget();
        match case {
            0 => b.cancel.cancel(),
            1 => b.deadline = Instant::now(),
            _ => b.deadline = Instant::now() + Duration::from_secs(31),
        }
        assert!(model
            .original
            .engine
            .qualify_partial_child_absence(&request, &b, |_, _| panic!(
                "rejected budget reached collection"
            ))
            .is_err());
    }
    let control = model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    assert!(observe(&model, &request).is_err());
    drop(control);
    for name in [&model.original.source.name, &model.original.child.name] {
        let gate = model.original.engine.observation_gate(name).unwrap();
        let held = gate.try_lock().unwrap();
        assert!(observe(&model, &request).is_err());
        drop(held);
    }
    assert_eq!(model.original.counts(), before);
}

#[test]
fn quarantined_original_absence_uses_reserved_control_without_reopening_work_or_releasing_backing()
{
    let (model, request) = staged(3, true);
    let before = model.original.counts();
    model.original.engine.jobs.quarantine();
    let proof = observe(&model, &request).unwrap();
    request.matches(&proof).unwrap();
    assert!(!model.original.engine.jobs.available());
    assert_eq!(model.original.counts(), before);
    assert!(model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::branch_source())
        .is_err());
}

#[test]
fn busy_owned_manager_map_rejects_the_observation_without_waiting_or_releasing_any_charge() {
    let (model, request) = staged(1, false);
    let before = model.original.counts();
    let held = model.original.engine.owned_managers.lock().unwrap();
    assert!(observe(&model, &request).is_err());
    drop(held);
    assert_eq!(model.original.counts(), before);
    assert!(observe(&model, &request).is_ok());
}
