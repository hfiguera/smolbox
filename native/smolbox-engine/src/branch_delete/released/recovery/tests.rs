//! Deterministic private database/file models only. No SDK lifecycle or VM.
use super::*;
use crate::branch_delete::released::tests::Model;
use crate::branch_delete::tests::{authority, budget, retained};

fn request(model: &Model) -> ReleasedBranchDeletionRequest {
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
    let mut request = ReleasedBranchDeletionRequest {
        completion,
        child: release.receipt.clone(),
        release,
        operation_id: "resolve-released-delete".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    request
}
fn remove_private_child(model: &Model) {
    model
        .original
        .engine
        .db
        .remove_vm(&model.intent.receipt().name)
        .unwrap();
    std::fs::remove_dir_all(&model.intent.plan.child.path).unwrap();
}
fn resolve(
    model: &Model,
    state: &mut Retained,
    request: &ReleasedBranchDeletionRequest,
) -> Result<ReleasedBranchDeletionResolution> {
    state.resolve_released(
        &model.journal,
        request,
        authority(&model.original, &model.original.actors),
        &budget(),
    )
}

#[test]
fn both_release_modes_resolve_each_entered_phase_and_keep_backing_until_explicit_retirement() {
    for hold in [false, true] {
        for phase in [
            Phase::Collecting,
            Phase::Collected,
            Phase::Deleting,
            Phase::Deleted,
        ] {
            let model = Model::new(hold);
            let request = request(&model);
            let mut state = retained(&model.original, &model.intent);
            model.journal.enter(&model.intent).unwrap();
            if phase != Phase::Collecting {
                model.collect();
            }
            if matches!(phase, Phase::Deleting | Phase::Deleted) {
                model
                    .journal
                    .advance(&model.intent, Phase::Collected, Phase::Deleting)
                    .unwrap();
            }
            remove_private_child(&model);
            if phase == Phase::Deleted {
                let proof = absence(
                    &model.intent,
                    &model
                        .original
                        .actors
                        .collect_enrolled(&request.child.name, &model.original.enrollment)
                        .unwrap(),
                    &model.original.engine.binding().database,
                    model.original.engine.database_identity,
                    &budget(),
                )
                .unwrap();
                model.journal.deleted(&model.intent, &proof).unwrap();
                state.completion = Some(Completion::Deleted);
                state.retire_transient().unwrap();
            }
            let before = model.original.engine.jobs.counts();
            let proof = resolve(&model, &mut state, &request).unwrap();
            request.matches(&proof).unwrap();
            assert_eq!(model.original.engine.jobs.counts(), before);
            assert!(model.original.plan.source.path.exists());
            let (record, _) = model.journal.read().unwrap();
            assert!(record.schema == 5 && record.phase == Phase::ResolvedAbsent);
            assert_eq!(record.released_resolution.as_ref(), Some(&proof));
            assert!(record.resolution.is_none() && record.continuation.is_none());
            let bytes = std::fs::read(&model.journal.path).unwrap();
            assert_eq!(resolve(&model, &mut state, &request).unwrap(), proof);
            assert_eq!(std::fs::read(&model.journal.path).unwrap(), bytes);
            let mut other = request.clone();
            other.operation_id = "another-resolution".into();
            other.request_sha256 = other.digest().unwrap();
            assert!(resolve(&model, &mut state, &other).is_err());
            assert_eq!(std::fs::read(&model.journal.path).unwrap(), bytes);
            state.retire_transient().unwrap();
            assert!(state.leases.is_none() && state._release_metadata.is_some());
        }
    }
}

#[test]
fn released_request_and_proof_cannot_be_crossed_relabelled_or_used_as_held_authority() {
    for hold in [false, true] {
        let model = Model::new(hold);
        let request = request(&model);
        let proof = ReleasedBranchDeletionResolution::issue(&request, &model.intent, None).unwrap();
        assert!(!format!("{request:?}").contains(&request.child.owner_token));
        assert!(!format!("{proof:?}").contains(&request.child.owner_token));
        assert!(serde_json::from_value::<BranchDeletionResolution>(
            serde_json::to_value(&proof).unwrap()
        )
        .is_err());
        for mode in 0..7 {
            let mut wrong = request.clone();
            match mode {
                0 => wrong.quiesced = false,
                1 => wrong.child = wrong.release.previous.clone(),
                2 => wrong.release.change.identity_sha256 = "0".repeat(64),
                3 => wrong.operation_id = wrong.release.change.request.operation_id.clone(),
                4 => {
                    wrong.operation_id = wrong
                        .completion
                        .publication
                        .change
                        .child_origin
                        .intent
                        .child
                        .operation_id
                        .clone()
                }
                5 => wrong.completion.identity_sha256 = "0".repeat(64),
                _ => wrong.request_sha256 = "0".repeat(64),
            }
            assert!(wrong.validate().is_err());
            wrong.request_sha256 = wrong.digest().unwrap();
            if mode == 6 {
                wrong.matches(&proof).unwrap();
            } else {
                assert!(wrong.matches(&proof).is_err());
            }
        }
        for mode in 0..4 {
            let mut wrong = proof.clone();
            match mode {
                0 => wrong.release_sha256 = "0".repeat(64),
                1 => wrong.completion_sha256 = "0".repeat(64),
                2 => wrong.child = request.release.previous.clone(),
                _ => wrong.deletion_sha256 = "0".repeat(64),
            }
            wrong.proof_sha256 = wrong.digest().unwrap();
            assert!(
                wrong.validate_for_intent(&model.intent, None).is_err()
                    || request.matches(&wrong).is_err()
            );
        }
    }
}

#[test]
fn present_rows_directory_active_worker_missing_grant_and_cancellation_preserve_journal_and_leases()
{
    for mode in 0..6 {
        let model = Model::new(false);
        let request = request(&model);
        let mut state = retained(&model.original, &model.intent);
        model.journal.enter(&model.intent).unwrap();
        let active = Arc::new(());
        match mode {
            0 => {} // row and directory present
            1 => {
                model
                    .original
                    .engine
                    .db
                    .remove_vm(&request.child.name)
                    .unwrap();
            }
            2 => {
                remove_private_child(&model);
                state.worker = Arc::downgrade(&active);
            }
            3 => {
                remove_private_child(&model);
                state.leases.take();
            }
            _ => remove_private_child(&model),
        }
        let selected = budget();
        if mode == 4 {
            selected.cancel.cancel();
        }
        let bytes = std::fs::read(&model.journal.path).unwrap();
        let counts = model.original.engine.jobs.counts();
        if mode == 5 {
            let collection = model
                .original
                .actors
                .collect_enrolled(&request.child.name, &model.original.enrollment)
                .unwrap();
            let mut wrong = state.intent.clone();
            wrong.child.birth += 1;
            assert!(absence(
                &wrong,
                &collection,
                &model.original.engine.binding().database,
                model.original.engine.database_identity,
                &selected
            )
            .is_err());
        } else {
            assert!(state
                .resolve_released(
                    &model.journal,
                    &request,
                    authority(&model.original, &model.original.actors),
                    &selected
                )
                .is_err());
        }
        assert_eq!(std::fs::read(&model.journal.path).unwrap(), bytes);
        assert_eq!(model.original.engine.jobs.counts(), counts);
        assert!(state.completion.is_none());
    }
}

#[test]
fn released_resolution_schema_cannot_strip_proof_or_change_origin_and_legacy_bytes_stay_exact() {
    let model = Model::new(true);
    let request = request(&model);
    let mut state = retained(&model.original, &model.intent);
    model.journal.enter(&model.intent).unwrap();
    remove_private_child(&model);
    resolve(&model, &mut state, &request).unwrap();
    let (record, _) = model.journal.read().unwrap();
    for mode in 0..4 {
        let mut changed = record.clone();
        match mode {
            0 => changed.schema = 4,
            1 => changed.released_resolution = None,
            2 => changed.intent.release = None,
            _ => changed.schema = 2,
        }
        assert!(changed.validate().is_err());
    }
    let (_legacy, _, intent, journal) = crate::branch_delete::tests::fixture();
    journal.enter(&intent).unwrap();
    let bytes = std::fs::read(&journal.path).unwrap();
    assert!(!String::from_utf8(bytes.clone())
        .unwrap()
        .contains("released_resolution"));
    let (legacy, _) = journal.read().unwrap();
    assert_eq!(serde_json::to_vec(&legacy).unwrap(), bytes);
}

#[test]
fn checked_resolution_cannot_reconstruct_original_completion_from_matching_inventory() {
    let model = Model::new(false);
    let request = request(&model);
    let before = model.original.engine.jobs.counts();
    for cancelled in [false, true] {
        let selected = budget();
        if cancelled {
            selected.cancel.cancel();
        }
        assert_eq!(
            model
                .original
                .engine
                .resolve_released_branch_deletion_checked(&request, &selected)
                .unwrap_err()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
    }
    assert_eq!(model.original.engine.jobs.counts(), before);
    assert!(model.intent.plan.child.path.exists());
}

#[test]
fn shared_wire_fixtures_match_engine_algebra_for_both_platforms_and_release_origins() {
    let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
        "../../../../../smolbox-protocol/fixtures/released-branch-deletion-v1.json"
    ))
    .unwrap();
    for row in rows {
        let request: ReleasedBranchDeletionRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: ReleasedBranchDeletionResolution =
            serde_json::from_value(row["proof"].clone()).unwrap();
        request.matches(&proof).unwrap();
    }
}
