//! Deterministic file/row/actor models only. No VMM, SDK stop or forced loss.
use super::*;
use crate::branch_boot::tests::identity_model;
use std::cell::Cell;

#[test]
fn original_gone_child_collects_without_sdk_entry_and_rejects_another_manager() {
    let model = identity_model(true);
    let name = &model.record.name;
    for manager in [None, Some(model.enrollment.child().pid)] {
        let proof = collect_with(
            &budget(),
            &model.actors,
            &model.enrollment,
            name,
            manager,
            || panic!("no SDK stop needed"),
        )
        .unwrap();
        assert!(proof.child() == model.enrollment.child());
        assert!(proof.intent() == model.enrollment.intent());
    }
    assert!(collect_with(
        &budget(),
        &model.actors,
        &model.enrollment,
        name,
        Some(1),
        || panic!("foreign manager")
    )
    .is_err());
    assert!(collect_with(
        &budget(),
        &model.actors,
        &model.enrollment,
        "foreign",
        None,
        || panic!("foreign name")
    )
    .is_err());
    let other = identity_model(true);
    assert!(collect_with(
        &budget(),
        &other.actors,
        &model.enrollment,
        name,
        None,
        || panic!("foreign epoch")
    )
    .is_err());
}

#[test]
fn pending_collection_excludes_actor_sweeps_until_sdk_return_even_on_error() {
    let temp = tempfile::tempdir().unwrap();
    let (_, _, actors) = crate::epoch::tests::fixture_for_binding(
        &temp.path().canonicalize().unwrap(),
        None,
        identity_model(true).engine.binding().clone(),
    );
    let owner = crate::OwnerIdentity::capture().unwrap();
    let enrollment =
        crate::epoch::tests::complete_model_with_child(actors.begin_boot("owned").unwrap(), owner);
    let calls = Cell::new(0);
    let result = collect_with(
        &budget(),
        &actors,
        &enrollment,
        "owned",
        Some(owner.pid),
        || {
            calls.set(calls.get() + 1);
            assert!(!actors.quiescent_for("owned").unwrap());
            assert!(actors.quiescent_for("sibling").unwrap());
            assert!(actors.collect_enrolled("owned", &enrollment).is_err());
            Err(Error::before(ErrorCode::Native))
        },
    );
    let error = result.err().unwrap();
    assert!(
        error.code == ErrorCode::Native && error.dispatch == crate::Dispatch::MayHaveDispatched
    );
    assert_eq!(calls.get(), 1);
    // A returned stop error has no pending SDK entry, but the live model actor
    // still prevents collection. No process is stopped by this test.
    assert!(actors.available());
    assert!(actors
        .begin_collection("owned", &enrollment)
        .unwrap()
        .sdk_returned()
        .is_ok());
    assert!(actors.collect_enrolled("owned", &enrollment).is_err());
}

#[test]
fn sdk_success_without_positive_original_collection_is_uncertain() {
    let model = identity_model(true);
    let temp = tempfile::tempdir().unwrap();
    let (_, _, actors) = crate::epoch::tests::fixture_for_binding(
        &temp.path().canonicalize().unwrap(),
        None,
        model.engine.binding().clone(),
    );
    let owner = crate::OwnerIdentity::capture().unwrap();
    let enrollment =
        crate::epoch::tests::complete_model_with_child(actors.begin_boot("owned").unwrap(), owner);
    let error = collect_with(
        &budget(),
        &actors,
        &enrollment,
        "owned",
        Some(owner.pid),
        || Ok(()),
    )
    .err()
    .unwrap();
    assert!(error.dispatch == crate::Dispatch::MayHaveDispatched);
    assert!(actors.available() && !actors.quiescent_for("owned").unwrap());
    let calls = Cell::new(0);
    assert!(
        collect_with(&budget(), &actors, &enrollment, "owned", None, || {
            calls.set(1);
            Ok(())
        })
        .is_err()
    );
    assert_eq!(calls.get(), 0);
}

#[test]
fn released_stopped_projection_accepts_only_original_pid_or_exact_stopped_row() {
    for hold in [false, true] {
        let model = identity_model(hold);
        let release = crate::branch_release::Intent::issue(
            &model.plan.publication,
            &model.record,
            &model.enrollment,
            &model.identity_sha256,
            &crate::BranchReleaseRequest {
                operation_id: "stop-released-model".into(),
                request_sha256: "c".repeat(64),
            },
        )
        .unwrap();
        let receipt = &release.transition.receipt;
        let mut row = release.released_record(&model.record).unwrap();
        verify_row(&row, receipt, &model.enrollment).unwrap();
        row.state = smolvm::config::RecordState::Stopped;
        row.pid = None;
        row.pid_start_time = None;
        verify_row(&row, receipt, &model.enrollment).unwrap();
        let before = row.clone();
        for change in 0..6 {
            let mut row = before.clone();
            match change {
                0 => row.pid = Some(model.enrollment.child().pid + 1),
                1 => row.pid_start_time = Some(1),
                2 => row.forkpoint_held = true,
                3 => row.state = smolvm::config::RecordState::Paused,
                4 => row.cpus += 1,
                _ => row.state = smolvm::config::RecordState::Running,
            }
            assert!(verify_row(&row, receipt, &model.enrollment).is_err());
        }
        assert!(model.engine.record(model.plan.publication.child()).is_ok());
    }
}

fn released_model(
    hold: bool,
) -> (
    crate::branch_boot::tests::IdentityModel,
    crate::BranchReleaseTransition,
) {
    let model = identity_model(hold);
    let intent = crate::branch_release::Intent::issue(
        &model.plan.publication,
        &model.record,
        &model.enrollment,
        &model.identity_sha256,
        &crate::BranchReleaseRequest {
            operation_id: "stop-ack-model".into(),
            request_sha256: "e".repeat(64),
        },
    )
    .unwrap();
    let lifecycle = crate::branch_boot::Lifecycle::at(&model.plan.child.path);
    let material = crate::material::MaterialJournal::at(&model.plan.child.path);
    lifecycle
        .enter_release(&model.plan, &intent, &model.enrollment)
        .unwrap();
    material
        .begin_branch_release(&intent, &model.record)
        .unwrap();
    let after = intent.released_record(&model.record).unwrap();
    model
        .engine
        .db
        .update_vm(&after.name, |row| *row = after.clone())
        .unwrap();
    material
        .complete_branch_release(
            &intent,
            &crate::branch_release::tests::confirmed(&intent),
            &after,
        )
        .unwrap();
    lifecycle
        .released(&model.plan, &intent, &model.enrollment)
        .unwrap();
    (model, intent.transition)
}
fn budget() -> ReadBudget {
    ReadBudget::new(
        std::time::Duration::from_secs(5),
        crate::Cancellation::default(),
    )
    .unwrap()
}
#[test]
fn positive_collection_normalizes_only_exact_row_and_preserves_restart_material_and_backing() {
    for hold in [false, true] {
        let (model, release) = released_model(hold);
        let receipt = &release.receipt;
        let before = model.engine.record(receipt).unwrap();
        let proof = model
            .actors
            .collect_enrolled(&receipt.name, &model.enrollment)
            .unwrap();
        let usage = model.engine.jobs.counts();
        acknowledge_stopped(
            &model.engine,
            receipt,
            &model.enrollment,
            &before,
            &proof,
            &budget(),
        )
        .unwrap();
        let after = model.engine.record(receipt).unwrap();
        assert!(
            after.state == smolvm::config::RecordState::Stopped
                && after.pid.is_none()
                && after.pid_start_time.is_none()
        );
        let mut expected = before.clone();
        expected.state = smolvm::config::RecordState::Stopped;
        expected.pid = None;
        expected.pid_start_time = None;
        assert_eq!(
            crate::material::hash(&after).unwrap(),
            crate::material::hash(&expected).unwrap()
        );
        crate::branch_boot::Lifecycle::at(&model.plan.child.path)
            .require_regular_restart(receipt)
            .unwrap();
        assert!(model.plan.source.path.exists() && model.plan.snapshot.path.exists());
        assert_eq!(model.engine.jobs.counts(), usage);
        // An explicit retry can acknowledge the now-stopped exact row without SDK work.
        acknowledge_stopped(
            &model.engine,
            receipt,
            &model.enrollment,
            &after,
            &proof,
            &budget(),
        )
        .unwrap();
    }
}
#[test]
fn changed_row_crossed_collection_or_expired_budget_cannot_acknowledge_stop() {
    for hold in [false, true] {
        let (model, release) = released_model(hold);
        let receipt = &release.receipt;
        let before = model.engine.record(receipt).unwrap();
        let other = identity_model(true);
        let crossed = other
            .actors
            .collect_enrolled(&other.record.name, &other.enrollment)
            .unwrap();
        assert!(acknowledge_stopped(
            &model.engine,
            receipt,
            &model.enrollment,
            &before,
            &crossed,
            &budget()
        )
        .is_err());
        let proof = model
            .actors
            .collect_enrolled(&receipt.name, &model.enrollment)
            .unwrap();
        let cancelled = crate::Cancellation::default();
        cancelled.cancel();
        let expired = ReadBudget::new(std::time::Duration::from_secs(5), cancelled).unwrap();
        assert!(acknowledge_stopped(
            &model.engine,
            receipt,
            &model.enrollment,
            &before,
            &proof,
            &expired
        )
        .is_err());
        assert_eq!(
            crate::material::hash(&model.engine.record(receipt).unwrap()).unwrap(),
            crate::material::hash(&before).unwrap()
        );
        model
            .engine
            .db
            .update_vm(&receipt.name, |row| {
                row.state = smolvm::config::RecordState::Paused
            })
            .unwrap();
        assert!(acknowledge_stopped(
            &model.engine,
            receipt,
            &model.enrollment,
            &before,
            &proof,
            &budget()
        )
        .is_err());
        assert!(model.engine.record(receipt).unwrap().state == smolvm::config::RecordState::Paused);
    }
}
