//! Private stopped-row/actor/journal models; no SDK or VMM lifecycle.
use super::*;
use crate::branch_delete::released::tests::Model;
use crate::branch_delete::tests::{authority, budget, retained};
use std::cell::Cell;

fn stop(model: &Model) -> smolvm::config::VmRecord {
    model
        .original
        .engine
        .db
        .update_vm(&model.intent.receipt().name, |row| {
            row.state = smolvm::config::RecordState::Stopped;
            row.pid = None;
            row.pid_start_time = None;
        })
        .unwrap();
    model
        .original
        .engine
        .record(model.intent.receipt())
        .unwrap()
}
fn check(model: &Model, row: &smolvm::config::VmRecord) -> Result<()> {
    collected_before(
        &model.intent,
        row,
        authority(&model.original, &model.original.actors),
        &budget(),
    )
}
#[test]
fn both_original_release_heads_route_without_adopting_later_or_foreign_material() {
    for hold in [false, true] {
        let model = Model::new(hold);
        let child = model.intent.receipt();
        assert!(released_head(
            &model.original.plan,
            &model.original.enrollment,
            &model.original.identity_sha256,
            child,
            &budget()
        )
        .unwrap());
        assert!(!released_head(
            &model.original.plan,
            &model.original.enrollment,
            &model.original.identity_sha256,
            model.original.plan.publication.child(),
            &budget()
        )
        .unwrap());
        let mut advanced = child.clone();
        advanced.material.as_mut().unwrap().revision += 1;
        assert!(!released_head(
            &model.original.plan,
            &model.original.enrollment,
            &model.original.identity_sha256,
            &advanced,
            &budget()
        )
        .unwrap());
        // Selection alone never installs original ownership or deletion state.
        stop(&model);
        model
            .original
            .engine
            .require_no_active_branch_handles(child)
            .unwrap();
        assert!(!model.journal.path.exists());
    }
}
#[test]
fn stopped_released_original_uses_existing_intent_and_exactly_one_final_entry_with_backing_retained(
) {
    for hold in [false, true] {
        let model = Model::new(hold);
        let before = stop(&model);
        check(&model, &before).unwrap();
        let pool = model.original.engine.jobs.clone();
        let mut work = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
        work.promote_branch_preparation().unwrap();
        work.promote_branch_backing(7 << 30).unwrap();
        let backing = work.handoff_branch().unwrap();
        drop(work);
        let mut state = retained(&model.original, &model.intent);
        model.journal.enter(&model.intent).unwrap();
        model.collect();
        let counts = pool.counts();
        let calls = Cell::new(0);
        CollectedDeletion {
            journal: &model.journal,
            authority: authority(&model.original, &model.original.actors),
            budget: &budget(),
        }
        .finish(&mut state, Phase::Collected, || {
            assert!(model.journal.read()?.0.phase == Phase::Deleting);
            calls.set(calls.get() + 1);
            model
                .original
                .engine
                .db
                .remove_vm(&model.intent.receipt().name)
                .unwrap();
            std::fs::remove_dir_all(&model.intent.plan.child.path).unwrap();
            Ok(())
        })
        .unwrap();
        assert_eq!(calls.get(), 1);
        assert_eq!(pool.counts(), counts);
        state
            .completed(&model.journal, model.intent.receipt())
            .unwrap();
        state.retire_transient().unwrap();
        assert_eq!(pool.counts().checkpoint_material, 7 << 30);
        assert!(model.intent.plan.source.path.exists() && model.intent.plan.snapshot.path.exists());
        assert!(matches!(state.completion, Some(Completion::Deleted)));
        drop(backing);
    }
}
#[test]
fn ordinary_restart_pending_dispatch_blocks_collection_until_the_exact_entry_returns() {
    for hold in [false, true] {
        let model = Model::new(hold);
        let row = stop(&model);
        let restart = model.original.actors.begin_boot(&row.name).unwrap();
        assert!(check(&model, &row).is_err());
        assert!(!model.journal.path.exists());
        // Synthetic already-exited restart, no process launch or loss.
        let restarted = crate::epoch::tests::complete_model(restart);
        check(&model, &row).unwrap();
        assert!(model
            .original
            .actors
            .collect_enrolled(&row.name, &restarted)
            .is_ok());
        assert!(!model.journal.path.exists());
    }
}
#[test]
fn canonical_stopped_state_foreign_collection_and_changed_heads_reject_before_journal_entry() {
    for hold in [false, true] {
        let model = Model::new(hold);
        let row = stop(&model);
        for field in 0..7 {
            let mut row = row.clone();
            match field {
                0 => row.state = smolvm::config::RecordState::Running,
                1 => row.pid = Some(model.intent.child.pid),
                2 => row.pid_start_time = Some(model.intent.child.birth),
                3 => row.forkpoint_held = true,
                4 => row.labels.clear(),
                5 => row.cpus += 1,
                _ => row.state = smolvm::config::RecordState::Paused,
            }
            assert!(check(&model, &row).is_err());
        }
        let other = Model::new(hold);
        assert!(collected_before(
            &model.intent,
            &row,
            authority(&other.original, &other.original.actors),
            &budget()
        )
        .is_err());
        let mut changed = model.intent.clone();
        changed.identity_sha256 = "f".repeat(64);
        assert!(collected_before(
            &changed,
            &row,
            authority(&model.original, &model.original.actors),
            &budget()
        )
        .is_err());
        assert!(!model.journal.path.exists());
    }
}
#[test]
fn an_active_handle_cannot_be_borrowed_as_retired_original_authority() {
    let model = Model::new(true);
    stop(&model);
    let child = model.intent.receipt();
    model
        .original
        .engine
        .require_no_active_branch_handles(child)
        .unwrap();
    model.original.engine.track_handle(child).unwrap();
    assert!(model
        .original
        .engine
        .require_no_active_branch_handles(child)
        .is_err());
    assert!(!model.journal.path.exists());
}
#[test]
fn entered_stopped_deletion_remains_uncertain_without_another_final_sdk_step() {
    let model = Model::new(true);
    let row = stop(&model);
    check(&model, &row).unwrap();
    let mut state = retained(&model.original, &model.intent);
    model.journal.enter(&model.intent).unwrap();
    model.collect();
    let finish = CollectedDeletion {
        journal: &model.journal,
        authority: authority(&model.original, &model.original.actors),
        budget: &budget(),
    };
    assert!(finish
        .finish(&mut state, Phase::Collected, || Err(Error::uncertain(
            ErrorCode::Native
        )))
        .is_err());
    assert!(model.journal.read().unwrap().0.phase == Phase::Deleting);
    assert!(finish
        .finish(&mut state, Phase::Collected, || panic!(
            "entered delete replayed"
        ))
        .is_err());
    assert!(state.leases.is_some() && state.completion.is_none());
    assert!(model.intent.plan.source.path.exists() && model.intent.plan.snapshot.path.exists());
}

#[test]
fn missing_final_acknowledgement_resolves_through_existing_released_absence_without_replay() {
    for held in [false, true] {
        let model = Model::new(held);
        let row = stop(&model);
        check(&model, &row).unwrap();
        let mut state = retained(&model.original, &model.intent);
        model.journal.enter(&model.intent).unwrap();
        model.collect();
        let finish = CollectedDeletion {
            journal: &model.journal,
            authority: authority(&model.original, &model.original.actors),
            budget: &budget(),
        };
        assert!(finish
            .finish(&mut state, Phase::Collected, || {
                model.original.engine.db.remove_vm(&row.name).unwrap();
                std::fs::remove_dir_all(&model.intent.plan.child.path).unwrap();
                Err(Error::uncertain(ErrorCode::Native))
            })
            .is_err());
        assert!(finish
            .finish(&mut state, Phase::Collected, || panic!(
                "entered SDK step replayed"
            ))
            .is_err());
        let release = model.intent.release.clone().unwrap();
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
            operation_id: "resolve-collected-model".into(),
            request_sha256: String::new(),
            quiesced: true,
        };
        request.request_sha256 = crate::material::hash(&(
            "smolbox-released-child-delete-request-v1",
            &request.completion,
            &request.release,
            &request.child,
            &request.operation_id,
            request.quiesced,
        ))
        .unwrap();
        let counts = model.original.engine.jobs.counts();
        let proof = state
            .resolve_released(
                &model.journal,
                &request,
                authority(&model.original, &model.original.actors),
                &budget(),
            )
            .unwrap();
        request.matches(&proof).unwrap();
        assert!(model.journal.read().unwrap().0.phase == Phase::ResolvedAbsent);
        assert_eq!(model.original.engine.jobs.counts(), counts);
        assert!(model.intent.plan.source.path.exists() && model.intent.plan.snapshot.path.exists());
        let bytes = std::fs::read(&model.journal.path).unwrap();
        assert_eq!(
            state
                .resolve_released(
                    &model.journal,
                    &request,
                    authority(&model.original, &model.original.actors),
                    &budget()
                )
                .unwrap(),
            proof
        );
        assert_eq!(std::fs::read(&model.journal.path).unwrap(), bytes);
    }
}
