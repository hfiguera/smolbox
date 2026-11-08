//! Private file/row/accounting models. No SDK dispatch, VMM enrollment or live
//! owner-loss/fault campaign is performed.
use super::*;
use crate::branch::retention::boot::{handoff_ready, qualify_ready_result};

fn budget() -> ReadBudget {
    ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
}
fn request(model: &crate::branch_boot::tests::IdentityModel) -> BranchCreateRequest {
    let intent = &model.plan.publication.change.child_origin.intent;
    BranchCreateRequest {
        source: intent.source.clone(),
        child: intent.child.clone(),
        approval: intent.approval.clone(),
        initial_release: if intent.child.hold {
            None
        } else {
            Some(crate::BranchReleaseRequest {
                operation_id: "initial-ready-release".into(),
                request_sha256: "d".repeat(64),
            })
        },
    }
}
#[test]
fn exact_held_ready_result_is_qualified_from_protected_lifecycle_without_sdk_replay() {
    let model = crate::branch_boot::tests::identity_model(true);
    let creation = request(&model);
    let before = model.engine.jobs.counts();
    let completion = qualify_ready_result(
        &model.plan,
        &model.enrollment,
        &model.identity_sha256,
        Some(&creation),
    )
    .unwrap();
    assert!(completion.held && completion.release.is_none());
    assert_eq!(completion.child, *model.plan.publication.child());
    let path = model.plan.child.path.join("smolbox.branch-start-v1.json");
    let bytes = std::fs::read(&path).unwrap();
    assert!(
        qualify_ready_result(
            &model.plan,
            &model.enrollment,
            &model.identity_sha256,
            Some(&creation)
        )
        .unwrap()
            == completion
    );
    assert_eq!(std::fs::read(path).unwrap(), bytes);
    assert!(model.engine.owned_managers.lock().unwrap().is_empty());
    assert_eq!(model.engine.jobs.counts(), before);
}
#[test]
fn initial_ready_result_requires_the_exact_completed_release_in_both_protected_journals() {
    let model = crate::branch_boot::tests::identity_model(false);
    let creation = request(&model);
    assert!(qualify_ready_result(
        &model.plan,
        &model.enrollment,
        &model.identity_sha256,
        Some(&creation)
    )
    .is_err());
    let release = crate::branch_release::Intent::issue(
        &model.plan.publication,
        &model.record,
        &model.enrollment,
        &model.identity_sha256,
        creation.initial_release.as_ref().unwrap(),
    )
    .unwrap();
    let lifecycle = crate::branch_boot::Lifecycle::at(&model.plan.child.path);
    lifecycle
        .enter_release(&model.plan, &release, &model.enrollment)
        .unwrap();
    let journal = crate::material::MaterialJournal::at(&model.plan.child.path);
    journal
        .begin_branch_release(&release, &model.record)
        .unwrap();
    assert!(qualify_ready_result(
        &model.plan,
        &model.enrollment,
        &model.identity_sha256,
        Some(&creation)
    )
    .is_err());
    let after = release.released_record(&model.record).unwrap();
    model
        .engine
        .db
        .update_vm(&after.name, |row| *row = after.clone())
        .unwrap();
    journal
        .complete_branch_release(
            &release,
            &crate::branch_release::tests::confirmed(&release),
            &after,
        )
        .unwrap();
    assert!(qualify_ready_result(
        &model.plan,
        &model.enrollment,
        &model.identity_sha256,
        Some(&creation)
    )
    .is_err());
    lifecycle
        .released(&model.plan, &release, &model.enrollment)
        .unwrap();
    let completion = qualify_ready_result(
        &model.plan,
        &model.enrollment,
        &model.identity_sha256,
        Some(&creation),
    )
    .unwrap();
    assert!(!completion.held && completion.child == release.transition.receipt);
    assert!(completion.release.as_ref() == Some(&release.transition));
    assert!(model
        .engine
        .promote_branch_handle(&release.transition.previous, &completion.child)
        .is_err());
    // Private authority model, no SDK inventory is adopted by the product path.
    model
        .engine
        .track_handle(&release.transition.previous)
        .unwrap();
    model
        .engine
        .promote_branch_handle(&release.transition.previous, &completion.child)
        .unwrap();
    model
        .engine
        .promote_branch_handle(&release.transition.previous, &completion.child)
        .unwrap();
    assert!(model.engine.owned_managers.lock().unwrap().is_empty());
    let mut changed = creation;
    changed.initial_release.as_mut().unwrap().operation_id = "different-release".into();
    assert!(qualify_ready_result(
        &model.plan,
        &model.enrollment,
        &model.identity_sha256,
        Some(&changed)
    )
    .is_err());
}
#[test]
fn changed_frozen_creation_or_identity_cannot_qualify_an_original_ready_result() {
    let model = crate::branch_boot::tests::identity_model(true);
    let original = request(&model);
    for field in 0..5 {
        let mut changed = original.clone();
        match field {
            0 => changed.source.owner_token = "e".repeat(64),
            1 => changed.child.owner_token = "e".repeat(64),
            2 => changed.child.operation_id = "another-creation".into(),
            3 => changed.approval.resources.disk_gb += 1,
            _ => {
                changed.child.hold = false;
                changed.initial_release = Some(crate::BranchReleaseRequest {
                    operation_id: "different-release".into(),
                    request_sha256: "d".repeat(64),
                });
            }
        }
        assert!(qualify_ready_result(
            &model.plan,
            &model.enrollment,
            &model.identity_sha256,
            Some(&changed)
        )
        .is_err());
    }
    assert!(qualify_ready_result(
        &model.plan,
        &model.enrollment,
        &"0".repeat(64),
        Some(&original)
    )
    .is_err());
}
#[test]
fn phase_or_worker_facts_never_grant_ready_completion_and_original_gates_and_backing_remain() {
    let (_root, engine, _, original) = crate::branch::retention::tests::fixture_bound(true);
    let entry = original.entry(&engine).unwrap();
    let before = engine.jobs.counts();
    let active = Arc::new(());
    {
        let mut work = entry.work.lock().unwrap();
        assert!(!handoff_ready(&work, true));
        work.prepared.take();
        for phase in [
            Phase::Entered,
            Phase::Verified,
            Phase::Published,
            Phase::DisposalEntered,
            Phase::Disposed,
            Phase::BootEntered,
            Phase::Booted,
        ] {
            work.phase = phase;
            assert!(!handoff_ready(&work, true));
        }
        for phase in [
            Phase::IdentityEntered,
            Phase::IdentityReady,
            Phase::ReleaseEntered,
            Phase::Released,
        ] {
            work.phase = phase;
            assert!(handoff_ready(&work, true));
            assert_eq!(
                handoff_ready(&work, false),
                matches!(phase, Phase::IdentityReady | Phase::Released)
            );
            work.worker = Arc::downgrade(&active);
            assert!(!handoff_ready(&work, true));
            work.worker = Weak::new();
        }
    }
    assert_eq!(engine.jobs.counts(), before);
    assert!(engine.owned_managers.lock().unwrap().is_empty());
    assert!(engine
        .observation_gate(&entry.ownership.intent.intent.source.name)
        .unwrap()
        .try_lock()
        .is_err());
    assert!(engine
        .observation_gate(&entry.ownership.intent.intent.child.name)
        .unwrap()
        .try_lock()
        .is_err());
    engine.branch_retention.entries.lock().unwrap().clear();
}
#[test]
fn explicit_resolution_requires_quiescence_finite_budget_and_original_epoch_before_handoff() {
    let (_root, engine, _, original) = crate::branch::retention::tests::fixture_bound(true);
    let entry = original.entry(&engine).unwrap();
    let creation = entry.ownership.creation.clone().unwrap();
    let before = engine.jobs.counts();
    assert_eq!(
        engine
            .resolve_ready_branch_completion(&creation, false, &budget())
            .unwrap_err()
            .code,
        ErrorCode::Validation
    );
    let long =
        ReadBudget::for_checkpoint_work(Duration::from_secs(60), crate::Cancellation::default())
            .unwrap();
    assert!(engine
        .resolve_ready_branch_completion(&creation, true, &long)
        .is_err());
    let cancel = crate::Cancellation::default();
    let cancelled = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
    cancel.cancel();
    assert!(engine
        .resolve_ready_branch_completion(&creation, true, &cancelled)
        .is_err());
    let mut expired = budget();
    expired.deadline = Instant::now();
    assert!(engine
        .resolve_ready_branch_completion(&creation, true, &expired)
        .is_err());
    entry.work.lock().unwrap().phase = Phase::IdentityReady;
    drop(original);
    let resolution = engine
        .branch_retention
        .claim_resolution(&engine, &creation, &budget())
        .unwrap()
        .unwrap();
    assert_eq!(
        resolution.finish_ready_child(&engine).unwrap_err().code,
        ErrorCode::Ownership
    );
    assert_eq!(engine.jobs.counts(), before);
    assert!(engine.owned_managers.lock().unwrap().is_empty());
    engine.branch_retention.entries.lock().unwrap().clear();
}
#[test]
fn fresh_deadline_cannot_invent_missing_original_boot_manager_or_initialization() {
    let (_root, engine, _, original) = crate::branch::retention::tests::fixture_bound(true);
    let entry = original.entry(&engine).unwrap();
    let creation = entry.ownership.creation.clone().unwrap();
    let before = engine.jobs.counts();
    drop(original);
    // Inert producer facts only. No SDK/VM exists or is interrupted.
    entry.ownership.intent.guard.budget.cancel.cancel();
    {
        let mut work = entry.work.lock().unwrap();
        work.prepared.take();
        work.phase = Phase::IdentityEntered;
    }
    drop(entry);
    let resolution = engine
        .branch_retention
        .claim_resolution(&engine, &creation, &budget())
        .unwrap()
        .unwrap();
    assert!(resolution.finish_ready_checked(&engine).is_err());
    assert_eq!(engine.jobs.counts(), before);
    assert!(engine.owned_managers.lock().unwrap().is_empty());
    assert_eq!(engine.branch_retention.entries.lock().unwrap().len(), 1);
    engine.branch_retention.entries.lock().unwrap().clear();
}

#[test]
fn missing_original_ready_context_never_adopts_a_matching_sdk_row_or_publishes_readiness() {
    let (_root, engine, _, original) = crate::branch::retention::tests::fixture_bound(true);
    let entry = original.entry(&engine).unwrap();
    let creation = entry.ownership.creation.clone().unwrap();
    let mut row = engine.db.get_vm(&creation.source.name).unwrap().unwrap();
    row.name = creation.child.name.clone();
    row.state = smolvm::config::RecordState::Running;
    engine.db.insert_vm(&row.name, &row).unwrap();
    engine.branch_retention.entries.lock().unwrap().clear();
    drop((entry, original)); // Inert model only; no worker or VM ever existed.
    let before = engine.jobs.counts();
    assert!(engine
        .resolve_ready_branch_completion(&creation, true, &budget())
        .unwrap()
        .is_none());
    assert!(engine.owned_managers.lock().unwrap().is_empty());
    assert_eq!(engine.jobs.counts(), before);
    assert!(engine.db.get_vm(&row.name).unwrap().is_some());
}
