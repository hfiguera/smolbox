//! Private namespace/file/row models; no SDK lifecycle or live fault campaign.
use super::*;
use crate::branch_delete::released::tests::Model;
use crate::branch_delete::tests::{authority, budget, retained};

fn request(model: &Model) -> crate::ReleasedBranchDeletionCleanupRequest {
    let release = model.intent.release.as_ref().unwrap().clone();
    let held = model
        .original
        .plan
        .publication
        .change
        .child_origin
        .intent
        .child
        .hold;
    let completion = crate::BranchCompletion {
        schema: 1,
        publication: model.original.plan.publication.clone(),
        child: if held {
            release.previous.clone()
        } else {
            release.receipt.clone()
        },
        identity_sha256: model.original.identity_sha256.clone(),
        held,
        release: if held { None } else { Some(release.clone()) },
    };
    let mut request = crate::ReleasedBranchDeletionCleanupRequest {
        completion,
        child: release.receipt.clone(),
        release,
        operation_id: "cleanup-released-child".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    digest(&mut request);
    request.validate().unwrap();
    request
}
fn digest(request: &mut crate::ReleasedBranchDeletionCleanupRequest) {
    request.request_sha256 = crate::material::hash(&(
        "smolbox-released-child-delete-cleanup-request-v1",
        &request.completion,
        &request.release,
        &request.child,
        &request.operation_id,
        request.quiesced,
    ))
    .unwrap();
}
fn grant(request: &crate::ReleasedBranchDeletionCleanupRequest) -> ContinuationRequest {
    ContinuationRequest {
        operation_id: request.operation_id.clone(),
        request_sha256: request.request_sha256.clone(),
    }
}
fn setup(model: &Model, continuation: bool) -> Retained {
    let mut state = retained(&model.original, &model.intent);
    model.journal.enter(&model.intent).unwrap();
    model.collect();
    if continuation {
        // Original frozen-before-publication grant, projected without an IO fault.
        state.continuation = Some(ContinuationRequest {
            operation_id: "original-continuation".into(),
            request_sha256: "c".repeat(64),
        });
    }
    model
        .original
        .engine
        .db
        .remove_vm(&model.intent.receipt().name)
        .unwrap();
    state
}
fn run(
    model: &Model,
    state: &mut Retained,
    request: &crate::ReleasedBranchDeletionCleanupRequest,
    selected: &ReadBudget,
    entries: usize,
) -> Result<ReleasedBranchDeletionResolution> {
    Removal {
        main: &model.journal,
        file: ledger(&model.journal),
        authority: authority(&model.original, &model.original.actors),
        budget: selected,
        max_entries: entries,
    }
    .run_original(state, &grant(request), Some(request))?
    .released()
}

#[test]
fn both_release_origins_remove_only_original_residuals_keep_backing_and_return_historical_proof_without_touching_new_material(
) {
    for held in [false, true] {
        for continued in [false, true] {
            let model = Model::new(held);
            let request = request(&model);
            let pool = &model.original.engine.jobs;
            let mut creation = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
            creation.promote_branch_preparation().unwrap();
            creation.promote_branch_backing(7 << 30).unwrap();
            let backing = creation.handoff_branch().unwrap();
            drop(creation);
            let mut state = setup(&model, continued);
            let external = tempfile::tempdir().unwrap();
            std::fs::write(external.path().join("must-stay"), b"source").unwrap();
            std::os::unix::fs::symlink(external.path(), model.intent.plan.child.path.join("pack"))
                .unwrap();
            pool.quarantine(); // Accounting state only; no live failure campaign.
            let control = pool
                .acquire(crate::jobs::Demand::material_resolution())
                .unwrap();
            let observer = pool
                .acquire(crate::jobs::Demand::volume_observation())
                .unwrap();
            let counts = pool.counts();
            let proof = run(
                &model,
                &mut state,
                &request,
                &budget(),
                crate::VOLUME_DELETE_ENTRIES,
            )
            .unwrap();
            request.matches(&proof).unwrap();
            assert!(!model.intent.plan.child.path.exists());
            assert_eq!(
                std::fs::read(external.path().join("must-stay")).unwrap(),
                b"source"
            );
            assert_eq!(pool.counts(), counts);
            assert!(
                model.original.plan.source.path.exists()
                    && model.original.plan.snapshot.path.exists()
            );
            let file = ledger(&model.journal);
            let (saved, _): (Cleanup, _) = file.read_record().unwrap();
            assert!(
                saved.schema == 2 && saved.stage == Stage::Cleaned && saved.resolution.is_none()
            );
            assert_eq!(saved.released_resolution.as_ref(), Some(&proof));
            assert_eq!(
                proof.deletion_sha256,
                deletion_digest(&model.intent, state.continuation.as_ref()).unwrap()
            );
            state.completed(&model.journal, &request.child).unwrap();
            state.retire_transient().unwrap();
            assert!(state._cleanup_metadata.is_some());
            assert_eq!(pool.counts().checkpoint_material, 7 << 30);
            std::fs::create_dir(&model.intent.plan.child.path).unwrap();
            std::fs::write(model.intent.plan.child.path.join("foreign"), b"new").unwrap();
            assert_eq!(
                run(
                    &model,
                    &mut state,
                    &request,
                    &budget(),
                    crate::VOLUME_DELETE_ENTRIES
                )
                .unwrap(),
                proof
            );
            assert_eq!(
                std::fs::read(model.intent.plan.child.path.join("foreign")).unwrap(),
                b"new"
            );
            drop((control, observer, backing)); // Accounting teardown, not backing disposal.
        }
    }
}

#[test]
fn row_and_reservation_presence_never_create_removal_authority_or_unlink_material() {
    let model = Model::new(false);
    let request = request(&model);
    let mut state = retained(&model.original, &model.intent);
    model.journal.enter(&model.intent).unwrap();
    model.collect();
    let counts = model.original.engine.jobs.counts();
    assert!(run(
        &model,
        &mut state,
        &request,
        &budget(),
        crate::VOLUME_DELETE_ENTRIES
    )
    .is_err());
    model
        .original
        .engine
        .db
        .remove_vm(&request.child.name)
        .unwrap();
    let writer = rusqlite::Connection::open(&model.original.engine.binding().database).unwrap();
    writer
        .execute(
            "INSERT INTO vm_create_reservations VALUES (?1,'pending',-1,0)",
            [&request.child.name],
        )
        .unwrap();
    assert!(run(
        &model,
        &mut state,
        &request,
        &budget(),
        crate::VOLUME_DELETE_ENTRIES
    )
    .is_err());
    assert!(!ledger(&model.journal).path.exists() && state.cleanup.is_none());
    assert!(model
        .intent
        .plan
        .child
        .path
        .join("smolbox.material-v2.json")
        .exists());
    assert_eq!(model.original.engine.jobs.counts(), counts);
}

#[test]
fn bounded_partial_removal_retains_its_exact_grant_and_resumes_forward_under_a_fresh_budget() {
    for held in [false, true] {
        let model = Model::new(held);
        let request = request(&model);
        let mut state = setup(&model, false);
        std::fs::write(model.intent.plan.child.path.join("extra"), b"owned").unwrap();
        let counts = model.original.engine.jobs.counts();
        assert!(run(&model, &mut state, &request, &budget(), 1).is_err());
        let file = ledger(&model.journal);
        let (saved, _): (Cleanup, _) = file.read_record().unwrap();
        assert!(saved.stage == Stage::Cleaning && saved.schema == 2 && state.leases.is_some());
        let bytes = std::fs::read(&file.path).unwrap();
        let mut wrong = request.clone();
        wrong.operation_id = "another-cleanup".into();
        digest(&mut wrong);
        assert!(run(
            &model,
            &mut state,
            &wrong,
            &budget(),
            crate::VOLUME_DELETE_ENTRIES
        )
        .is_err());
        assert_eq!(std::fs::read(&file.path).unwrap(), bytes);
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(run(
            &model,
            &mut state,
            &request,
            &cancelled,
            crate::VOLUME_DELETE_ENTRIES
        )
        .is_err());
        assert_eq!(model.original.engine.jobs.counts(), counts);
        request
            .matches(
                &run(
                    &model,
                    &mut state,
                    &request,
                    &budget(),
                    crate::VOLUME_DELETE_ENTRIES,
                )
                .unwrap(),
            )
            .unwrap();
    }
}

#[test]
fn only_original_recorded_cleanup_can_finish_an_already_removed_path_and_replaced_roots_never_grant_removal(
) {
    for recorded in [false, true] {
        let model = Model::new(true);
        let request = request(&model);
        let mut state = setup(&model, false);
        if recorded {
            assert!(run(&model, &mut state, &request, &budget(), 1).is_err());
        }
        std::fs::remove_dir_all(&model.intent.plan.child.path).unwrap();
        let result = run(
            &model,
            &mut state,
            &request,
            &budget(),
            crate::VOLUME_DELETE_ENTRIES,
        );
        assert_eq!(result.is_ok(), recorded);
    }
    for link in [false, true] {
        let model = Model::new(false);
        let request = request(&model);
        let mut state = setup(&model, false);
        let kept = model.intent.plan.child.path.with_extension("kept");
        std::fs::rename(&model.intent.plan.child.path, &kept).unwrap();
        if link {
            std::os::unix::fs::symlink(&kept, &model.intent.plan.child.path).unwrap();
        } else {
            std::fs::create_dir(&model.intent.plan.child.path).unwrap();
        }
        assert!(run(
            &model,
            &mut state,
            &request,
            &budget(),
            crate::VOLUME_DELETE_ENTRIES
        )
        .is_err());
        assert!(!ledger(&model.journal).path.exists() && kept.exists());
    }
}

#[test]
fn primary_completion_recovers_only_its_matching_audit_without_traversing_recreated_namespace() {
    let model = Model::new(false);
    let request = request(&model);
    let mut state = setup(&model, true);
    let proof = run(
        &model,
        &mut state,
        &request,
        &budget(),
        crate::VOLUME_DELETE_ENTRIES,
    )
    .unwrap();
    let file = ledger(&model.journal);
    let (mut entry, version): (Cleanup, _) = file.read_record().unwrap();
    // Deterministic final-audit state projection, not a live persistence fault.
    entry.stage = Stage::Cleaning;
    entry.released_resolution = None;
    file.write_record(&entry, Some(version)).unwrap();
    std::fs::create_dir(&model.intent.plan.child.path).unwrap();
    std::fs::write(model.intent.plan.child.path.join("foreign"), b"preserved").unwrap();
    state.completion = None;
    assert_eq!(
        run(&model, &mut state, &request, &budget(), 1).unwrap(),
        proof
    );
    assert_eq!(
        std::fs::read(model.intent.plan.child.path.join("foreign")).unwrap(),
        b"preserved"
    );
    let mut crossed = request.clone();
    crossed.operation_id = "foreign-request".into();
    digest(&mut crossed);
    assert!(run(
        &model,
        &mut state,
        &crossed,
        &budget(),
        crate::VOLUME_DELETE_ENTRIES
    )
    .is_err());
}

#[test]
fn released_cleanup_cannot_be_relabelled_as_held_or_consume_a_different_proof_or_parent_identity() {
    let model = Model::new(true);
    let request = request(&model);
    let mut state = setup(&model, false);
    assert!(run(&model, &mut state, &request, &budget(), 1).is_err());
    let file = ledger(&model.journal);
    let (entry, _): (Cleanup, _) = file.read_record().unwrap();
    for mode in 0..4 {
        let mut wrong = entry.clone();
        match mode {
            0 => wrong.schema = 1,
            1 => wrong.parent.0 = 0,
            2 => wrong.intent.release = None,
            _ => wrong.request.request_sha256 = "0".repeat(64),
        };
        if mode == 3 {
            // Valid new grant cannot replace the one retained in the original state.
            let bytes = std::fs::read(&file.path).unwrap();
            let mut crossed = request.clone();
            crossed.request_sha256 = "0".repeat(64);
            assert!(run(
                &model,
                &mut state,
                &crossed,
                &budget(),
                crate::VOLUME_DELETE_ENTRIES
            )
            .is_err());
            assert_eq!(std::fs::read(&file.path).unwrap(), bytes);
        } else {
            assert!(wrong
                .validate_for(&file, serde_json::to_vec(&wrong).unwrap().len() as u64)
                .is_err());
        }
    }
    let old: crate::ReleasedBranchDeletionRequest =
        serde_json::from_value(serde_json::to_value(&request).unwrap()).unwrap();
    assert!(old.validate().is_err());
}

#[test]
fn checked_cleanup_requires_original_context_and_cancelled_lookup_never_adopts_matching_inventory()
{
    let model = Model::new(false);
    let request = request(&model);
    let counts = model.original.engine.jobs.counts();
    for cancelled in [false, true] {
        let selected = budget();
        if cancelled {
            selected.cancel.cancel();
        }
        assert_eq!(
            model
                .original
                .engine
                .cleanup_released_branch_deletion_checked(&request, &selected)
                .unwrap_err()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
    }
    assert_eq!(model.original.engine.jobs.counts(), counts);
    assert!(model.intent.plan.child.path.exists());
}

#[test]
fn an_entered_cleanup_grant_cannot_be_replaced_by_a_distinct_observation_after_namespace_absence() {
    let model = Model::new(false);
    let request = request(&model);
    let mut state = setup(&model, true);
    assert!(run(&model, &mut state, &request, &budget(), 1).is_err());
    std::fs::remove_dir_all(&model.intent.plan.child.path).unwrap();
    let mut value = serde_json::to_value(&request).unwrap();
    value["operation_id"] = "observe-after-cleanup".into();
    value["request_sha256"] = crate::material::hash(&(
        "smolbox-released-child-delete-request-v1",
        &request.completion,
        &request.release,
        &request.child,
        "observe-after-cleanup",
        true,
    ))
    .unwrap()
    .into();
    let observation: crate::ReleasedBranchDeletionRequest = serde_json::from_value(value).unwrap();
    observation.validate().unwrap();
    let before = std::fs::read(&model.journal.path).unwrap();
    assert!(state
        .resolve_released(
            &model.journal,
            &observation,
            authority(&model.original, &model.original.actors),
            &budget()
        )
        .is_err());
    assert_eq!(std::fs::read(&model.journal.path).unwrap(), before);
    request
        .matches(
            &run(
                &model,
                &mut state,
                &request,
                &budget(),
                crate::VOLUME_DELETE_ENTRIES,
            )
            .unwrap(),
        )
        .unwrap();
}

#[test]
fn cached_primary_proof_must_match_the_full_completion_before_finishing_its_audit() {
    let model = Model::new(false);
    let request = request(&model);
    let mut state = setup(&model, false);
    run(
        &model,
        &mut state,
        &request,
        &budget(),
        crate::VOLUME_DELETE_ENTRIES,
    )
    .unwrap();
    let file = ledger(&model.journal);
    let (mut entry, version): (Cleanup, _) = file.read_record().unwrap();
    // Private metadata projection only; no live owner or persistence fault.
    entry.stage = Stage::Cleaning;
    entry.released_resolution = None;
    file.write_record(&entry, Some(version)).unwrap();
    let (mut primary, version) = model.journal.read().unwrap();
    let proof = primary.released_resolution.as_mut().unwrap();
    proof.completion_sha256 = "0".repeat(64);
    proof.proof_sha256 = crate::material::hash(&(
        "smolbox-released-child-delete-resolution-v1",
        proof.schema,
        &proof.child,
        &proof.operation_id,
        &proof.request_sha256,
        &proof.completion_sha256,
        &proof.release_sha256,
        &proof.deletion_sha256,
    ))
    .unwrap();
    proof.validate().unwrap();
    model.journal.write(&primary, Some(version)).unwrap();
    state.completion = None;
    std::fs::create_dir(&model.intent.plan.child.path).unwrap();
    std::fs::write(model.intent.plan.child.path.join("foreign"), b"preserved").unwrap();
    let before = std::fs::read(&file.path).unwrap();
    let counts = model.original.engine.jobs.counts();
    assert!(run(
        &model,
        &mut state,
        &request,
        &budget(),
        crate::VOLUME_DELETE_ENTRIES
    )
    .is_err());
    assert_eq!(std::fs::read(&file.path).unwrap(), before);
    assert_eq!(model.original.engine.jobs.counts(), counts);
    assert!(state.completion.is_none() && state.leases.is_some());
    assert_eq!(
        std::fs::read(model.intent.plan.child.path.join("foreign")).unwrap(),
        b"preserved"
    );
}
