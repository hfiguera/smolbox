//! Private file/row/callback models only; no SDK lifecycle, VM or live faults.
use super::*;
use crate::branch_delete::released::tests::Model;
use crate::branch_delete::tests::{authority, budget, retained};
use std::cell::Cell;

fn request(model: &Model) -> ReleasedBranchDeletionContinuationRequest {
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
    let mut request = ReleasedBranchDeletionContinuationRequest {
        completion,
        child: release.receipt.clone(),
        release,
        operation_id: "continue-released-delete".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    request
}
fn grant(request: &ReleasedBranchDeletionContinuationRequest) -> ContinuationRequest {
    ContinuationRequest {
        operation_id: request.operation_id.clone(),
        request_sha256: request.request_sha256.clone(),
    }
}
fn begin(model: &Model, state: &mut Retained, request: &ReleasedBranchDeletionContinuationRequest) {
    let collection = model
        .original
        .actors
        .collect_enrolled(&request.child.name, &model.original.enrollment)
        .unwrap();
    let before = model
        .original
        .engine
        .db
        .get_vm(&request.child.name)
        .unwrap()
        .unwrap();
    let stopped = stopped_record(&model.intent, &before, &collection, &budget()).unwrap();
    state.continuation = Some(grant(request));
    model
        .journal
        .begin_released_finishing(&model.intent, &grant(request), &collection, &budget())
        .unwrap();
    model
        .original
        .engine
        .db
        .update_vm(&stopped.name, |row| *row = stopped.clone())
        .unwrap();
}
fn finish(
    model: &Model,
    state: &mut Retained,
    selected: &ReadBudget,
    callback: impl FnOnce() -> Result<()>,
) -> Result<()> {
    CollectedDeletion {
        journal: &model.journal,
        authority: authority(&model.original, &model.original.actors),
        budget: selected,
    }
    .finish(state, Phase::Finishing, callback)
}
fn remove(model: &Model) {
    model
        .original
        .engine
        .db
        .remove_vm(&model.intent.receipt().name)
        .unwrap();
    std::fs::remove_dir_all(&model.intent.plan.child.path).unwrap();
}
fn resolution(
    request: &ReleasedBranchDeletionContinuationRequest,
) -> ReleasedBranchDeletionRequest {
    let mut value = serde_json::to_value(request).unwrap();
    value["operation_id"] = "resolve-after-continuation".into();
    value["request_sha256"] = crate::material::hash(&(
        "smolbox-released-child-delete-request-v1",
        &request.completion,
        &request.release,
        &request.child,
        "resolve-after-continuation",
        true,
    ))
    .unwrap()
    .into();
    let request: ReleasedBranchDeletionRequest = serde_json::from_value(value).unwrap();
    request.validate().unwrap();
    request
}

#[test]
fn both_release_origins_continue_each_unentered_phase_once_and_preserve_source_snapshot_and_backing(
) {
    for hold in [false, true] {
        for collected in [false, true] {
            let model = Model::new(hold);
            let request = request(&model);
            let pool = &model.original.engine.jobs;
            let mut creation = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
            creation.promote_branch_preparation().unwrap();
            creation.promote_branch_backing(7 << 30).unwrap();
            let backing = creation.handoff_branch().unwrap();
            drop(creation);
            let mut state = retained(&model.original, &model.intent);
            model.journal.enter(&model.intent).unwrap();
            if collected {
                model.collect();
            }
            begin(&model, &mut state, &request);
            let (entered, _) = model.journal.read().unwrap();
            assert!(entered.schema == 6 && entered.phase == Phase::Finishing);
            assert!(!state
                .continuation_status(&model.journal, &grant(&request))
                .unwrap());
            let calls = Cell::new(0);
            let counts = pool.counts();
            finish(&model, &mut state, &budget(), || {
                assert!(model.journal.read().unwrap().0.phase == Phase::Deleting);
                assert_eq!(pool.counts(), counts);
                calls.set(calls.get() + 1);
                remove(&model);
                Ok(())
            })
            .unwrap();
            assert!(finish(&model, &mut state, &budget(), || {
                calls.set(calls.get() + 1);
                Ok(())
            })
            .is_err());
            assert_eq!(calls.get(), 1);
            let (record, version) = model.journal.read().unwrap();
            crate::branch_delete::continuation::check_continuation_result(
                &state,
                &record,
                &grant(&request),
            )
            .unwrap();
            model
                .journal
                .sync_released_resolution(&version, &budget())
                .unwrap();
            let proof = ReleasedBranchDeletionContinuation::issue(
                &request,
                &model.intent,
                Some(&grant(&request)),
            )
            .unwrap();
            request.matches(&proof).unwrap();
            assert_eq!(
                proof.deletion_sha256,
                deletion_digest(&model.intent, Some(&grant(&request))).unwrap()
            );
            assert!(
                ReleasedBranchDeletionContinuation::issue(&request, &model.intent, None).is_err()
            );
            let old: ReleasedBranchDeletionResolution =
                serde_json::from_value(serde_json::to_value(&proof).unwrap()).unwrap();
            assert!(old.validate().is_err());
            assert!(state
                .continuation_status(&model.journal, &grant(&request))
                .unwrap());
            state.retire_transient().unwrap();
            assert_eq!(pool.counts().checkpoint_material, 7 << 30);
            assert!(
                state._release_metadata.is_some()
                    && model.original.plan.source.path.exists()
                    && model.original.plan.snapshot.path.exists()
            );
            drop(backing); // Accounting teardown, not backing disposal.
        }
    }
}

#[test]
fn an_unknown_entered_sdk_result_never_replays_and_distinct_absence_keeps_the_continuation_binding()
{
    for hold in [false, true] {
        let model = Model::new(hold);
        let request = request(&model);
        let mut state = retained(&model.original, &model.intent);
        model.journal.enter(&model.intent).unwrap();
        begin(&model, &mut state, &request);
        let calls = Cell::new(0);
        let counts = model.original.engine.jobs.counts();
        assert!(finish(&model, &mut state, &budget(), || {
            calls.set(1);
            Err(Error::uncertain(ErrorCode::Native))
        })
        .is_err());
        assert!(finish(&model, &mut state, &budget(), || {
            calls.set(2);
            Ok(())
        })
        .is_err());
        assert_eq!(calls.get(), 1);
        assert!(state
            .continuation_status(&model.journal, &grant(&request))
            .is_err());
        let resolve = resolution(&request);
        assert!(state
            .resolve_released(
                &model.journal,
                &resolve,
                authority(&model.original, &model.original.actors),
                &budget()
            )
            .is_err());
        assert_eq!(model.original.engine.jobs.counts(), counts);
        remove(&model); // Explicit private row/file result, not SDK replay or persistence interruption.
        let proof = state
            .resolve_released(
                &model.journal,
                &resolve,
                authority(&model.original, &model.original.actors),
                &budget(),
            )
            .unwrap();
        resolve.matches(&proof).unwrap();
        let (record, _) = model.journal.read().unwrap();
        assert!(record.schema == 6 && record.phase == Phase::ResolvedAbsent);
        assert_eq!(
            proof.deletion_sha256,
            deletion_digest(&model.intent, Some(&grant(&request))).unwrap()
        );
        assert!(
            crate::branch_delete::continuation::check_continuation_result(
                &state,
                &record,
                &grant(&request)
            )
            .is_err()
        );
        let mut crossed = record.clone();
        crossed.continuation.as_mut().unwrap().request_sha256 = "f".repeat(64);
        assert!(crossed.validate().is_err());
        assert!(state.leases.is_some() && model.original.plan.source.path.exists());
    }
}

#[test]
fn cancelled_unentered_continuation_reuses_only_its_original_grant_and_active_worker_blocks_results(
) {
    let model = Model::new(false);
    let request = request(&model);
    let mut state = retained(&model.original, &model.intent);
    model.journal.enter(&model.intent).unwrap();
    begin(&model, &mut state, &request);
    let cancelled = budget();
    cancelled.cancel.cancel();
    let calls = Cell::new(0);
    let bytes = std::fs::read(&model.journal.path).unwrap();
    assert!(finish(&model, &mut state, &cancelled, || {
        calls.set(1);
        Ok(())
    })
    .is_err());
    assert_eq!(calls.get(), 0);
    assert_eq!(std::fs::read(&model.journal.path).unwrap(), bytes);
    let mut other = grant(&request);
    other.operation_id = "different-continuation".into();
    assert!(state.continuation_status(&model.journal, &other).is_err());
    let active = Arc::new(());
    state.worker = Arc::downgrade(&active);
    assert!(state
        .continuation_status(&model.journal, &grant(&request))
        .is_err());
    drop(active);
    finish(&model, &mut state, &budget(), || {
        calls.set(1);
        remove(&model);
        Ok(())
    })
    .unwrap();
    assert_eq!(calls.get(), 1);
}

#[test]
fn released_continuation_records_cannot_strip_or_relabel_the_origin_and_checked_requests_cannot_adopt_rows(
) {
    let model = Model::new(true);
    let request = request(&model);
    let mut state = retained(&model.original, &model.intent);
    model.journal.enter(&model.intent).unwrap();
    begin(&model, &mut state, &request);
    let (record, _) = model.journal.read().unwrap();
    for mode in 0..4 {
        let mut wrong = record.clone();
        match mode {
            0 => wrong.schema = 3,
            1 => wrong.schema = 4,
            2 => wrong.continuation = None,
            _ => wrong.intent.release = None,
        };
        assert!(wrong.validate().is_err());
    }
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
                .continue_released_branch_deletion_checked(&request, &selected)
                .unwrap_err()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
    }
    assert_eq!(model.original.engine.jobs.counts(), counts);
    assert!(model.intent.plan.child.path.exists());
}

#[test]
fn request_and_proof_domains_are_distinct_from_observation_and_hold_only_authority() {
    let model = Model::new(false);
    let request = request(&model);
    let old: ReleasedBranchDeletionRequest =
        serde_json::from_value(serde_json::to_value(&request).unwrap()).unwrap();
    assert!(old.validate().is_err());
    assert!(!format!("{request:?}").contains(&request.child.owner_token));
    let proof =
        ReleasedBranchDeletionContinuation::issue(&request, &model.intent, Some(&grant(&request)))
            .unwrap();
    assert!(!format!("{proof:?}").contains(&request.child.owner_token));
    for mode in 0..4 {
        let mut wrong = request.clone();
        match mode {
            0 => wrong.quiesced = false,
            1 => wrong.child = wrong.release.previous.clone(),
            2 => wrong.operation_id = wrong.release.change.request.operation_id.clone(),
            _ => wrong.completion.identity_sha256 = "0".repeat(64),
        };
        wrong.request_sha256 = wrong.digest().unwrap();
        assert!(wrong.matches(&proof).is_err());
    }
}

#[test]
fn shared_continuation_fixtures_match_the_engine_without_borrowing_observation_authority() {
    let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
        "../../../../../smolbox-protocol/fixtures/released-branch-deletion-continuation-v1.json"
    ))
    .unwrap();
    for row in rows {
        let request: ReleasedBranchDeletionContinuationRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: ReleasedBranchDeletionContinuation =
            serde_json::from_value(row["proof"].clone()).unwrap();
        request.matches(&proof).unwrap();
        let old: ReleasedBranchDeletionRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        assert!(old.validate().is_err());
    }
}

#[test]
fn positive_absence_preserves_an_original_frozen_grant_before_finishing_publication() {
    for hold in [false, true] {
        for collected in [false, true] {
            let model = Model::new(hold);
            let request = request(&model);
            let mut state = retained(&model.original, &model.intent);
            model.journal.enter(&model.intent).unwrap();
            if collected {
                model.collect();
            }
            // Deterministic state projection only; no interruption or IO fault.
            state.continuation = Some(grant(&request));
            let bytes = std::fs::read(&model.journal.path).unwrap();
            let resolve = resolution(&request);
            assert!(state
                .resolve_released(
                    &model.journal,
                    &resolve,
                    authority(&model.original, &model.original.actors),
                    &budget()
                )
                .is_err());
            assert_eq!(std::fs::read(&model.journal.path).unwrap(), bytes);
            remove(&model);
            let proof = state
                .resolve_released(
                    &model.journal,
                    &resolve,
                    authority(&model.original, &model.original.actors),
                    &budget(),
                )
                .unwrap();
            let (record, _) = model.journal.read().unwrap();
            assert!(record.schema == 6 && record.phase == Phase::ResolvedAbsent);
            assert!(record.continuation.as_ref() == Some(&grant(&request)));
            assert_eq!(
                proof.deletion_sha256,
                deletion_digest(&model.intent, Some(&grant(&request))).unwrap()
            );
            assert!(
                crate::branch_delete::continuation::check_continuation_result(
                    &state,
                    &record,
                    &grant(&request)
                )
                .is_err()
            );
            state.retire_transient().unwrap();
            assert!(
                model.original.plan.source.path.exists()
                    && model.original.plan.snapshot.path.exists()
            );
        }
    }
}
