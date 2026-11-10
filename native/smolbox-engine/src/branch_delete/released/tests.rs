//! Private file/row/accounting models. No SDK stop/delete, VMM or owner-loss
//! campaign occurs. Original manager/ordinary platform qualification is separate.
use super::*;
use crate::branch_boot::tests::{identity_model, IdentityModel};
use crate::branch_delete::tests::{authority, budget, retained};
use std::cell::Cell;

pub(in crate::branch_delete) struct Model {
    pub(in crate::branch_delete) original: IdentityModel,
    pub(in crate::branch_delete) intent: Intent,
    pub(in crate::branch_delete) journal: Journal,
}
impl Model {
    pub(in crate::branch_delete) fn new(hold: bool) -> Self {
        let original = identity_model(hold);
        let request = crate::BranchReleaseRequest {
            operation_id: "released-delete-model".into(),
            request_sha256: "c".repeat(64),
            env: Vec::new(),
        };
        let release = crate::branch_release::Intent::issue(
            &original.plan.publication,
            &original.record,
            &original.enrollment,
            &original.identity_sha256,
            &request,
        )
        .unwrap();
        let lifecycle = crate::branch_boot::Lifecycle::at(&original.plan.child.path);
        let material = crate::material::MaterialJournal::at(&original.plan.child.path);
        lifecycle
            .enter_release(&original.plan, &release, &original.enrollment)
            .unwrap();
        material
            .begin_branch_release(&release, &original.record)
            .unwrap();
        let after = release.released_record(&original.record).unwrap();
        original
            .engine
            .db
            .update_vm(&after.name, |row| *row = after.clone())
            .unwrap();
        material
            .complete_branch_release(
                &release,
                &crate::branch_release::tests::confirmed(&release),
                &after,
            )
            .unwrap();
        lifecycle
            .released(&original.plan, &release, &original.enrollment)
            .unwrap();
        let intent = Intent {
            plan: original.plan.clone(),
            boot: original.enrollment.intent().clone(),
            child: original.enrollment.child(),
            identity_sha256: original.identity_sha256.clone(),
            nonce: "a".repeat(32),
            release: Some(release.transition),
        };
        intent.validate().unwrap();
        let journal = Journal::new(original.engine.domain.clone(), intent.receipt()).unwrap();
        Self {
            original,
            intent,
            journal,
        }
    }
    pub(in crate::branch_delete) fn collect(&self) {
        let proof = self
            .original
            .actors
            .collect_enrolled(&self.intent.receipt().name, &self.original.enrollment)
            .unwrap();
        self.journal.collected(&self.intent, &proof).unwrap();
        let before = self
            .original
            .engine
            .db
            .get_vm(&self.intent.receipt().name)
            .unwrap()
            .unwrap();
        let stopped = stopped_record(&self.intent, &before, &proof, &budget()).unwrap();
        self.original
            .engine
            .db
            .update_vm(&stopped.name, |row| *row = stopped.clone())
            .unwrap();
    }
    fn finish(&self, state: &mut Retained, delete: impl FnOnce() -> Result<()>) -> Result<()> {
        CollectedDeletion {
            journal: &self.journal,
            authority: authority(&self.original, &self.original.actors),
            budget: &budget(),
        }
        .finish(state, Phase::Collected, delete)
    }
}
#[test]
fn initial_and_explicit_releases_freeze_exact_current_head_and_distinct_schema_without_changing_held_bytes(
) {
    for hold in [false, true] {
        let model = Model::new(hold);
        model.journal.enter(&model.intent).unwrap();
        let (record, _) = model.journal.read().unwrap();
        assert!(record.schema == 4 && record.phase == Phase::Collecting);
        assert!(record.resolution.is_none() && record.continuation.is_none());
        assert!(model.intent.receipt() == &model.intent.release.as_ref().unwrap().receipt);
        assert!(model.intent.receipt() != model.original.plan.publication.child());
        let held = Journal::new(
            model.original.engine.domain.clone(),
            model.original.plan.publication.child(),
        )
        .unwrap();
        assert!(model.journal.path != held.path);
        let (_legacy_model, _, legacy, legacy_journal) = crate::branch_delete::tests::fixture();
        let encoded = serde_json::to_vec(&legacy).unwrap();
        assert!(!String::from_utf8(encoded.clone())
            .unwrap()
            .contains("\"release\""));
        let decoded: Intent = serde_json::from_slice(&encoded).unwrap();
        assert!(decoded == legacy && serde_json::to_vec(&decoded).unwrap() == encoded);
        legacy_journal.enter(&legacy).unwrap();
        assert_eq!(legacy_journal.read().unwrap().0.schema, 1);
    }
}
#[test]
fn release_proof_binding_and_stopped_record_require_original_boot_identity_material_and_held_flag()
{
    for hold in [false, true] {
        let model = Model::new(hold);
        for field in 0..5 {
            let mut wrong = model.intent.clone();
            match field {
                0 => wrong.release.as_mut().unwrap().change.identity_sha256 = "0".repeat(64),
                1 => wrong.release.as_mut().unwrap().change.boot_sha256 = "0".repeat(64),
                2 => wrong.release.as_mut().unwrap().receipt.owner_token = "0".repeat(64),
                3 => {
                    wrong
                        .plan
                        .publication
                        .change
                        .child_origin
                        .intent
                        .child
                        .owner_token = "0".repeat(64)
                }
                _ => wrong.release = None,
            }
            if field != 4 || !hold {
                assert!(wrong.validate().is_err());
            }
        }
        let proof = model
            .original
            .actors
            .collect_enrolled(&model.intent.receipt().name, &model.original.enrollment)
            .unwrap();
        let before = model
            .original
            .engine
            .db
            .get_vm(&model.intent.receipt().name)
            .unwrap()
            .unwrap();
        stopped_record(&model.intent, &before, &proof, &budget()).unwrap();
        for field in 0..4 {
            let mut wrong = before.clone();
            match field {
                0 => wrong.forkpoint_held = true,
                1 => wrong.pid_start_time = before.pid_start_time.map(|birth| birth + 1),
                2 => wrong.labels.clear(),
                _ => wrong.state = smolvm::config::RecordState::Created,
            }
            assert!(stopped_record(&model.intent, &wrong, &proof, &budget()).is_err());
        }
    }
}
#[test]
fn original_released_collection_enters_once_before_deletion_and_keeps_source_snapshot_and_all_backing(
) {
    for hold in [false, true] {
        let model = Model::new(hold);
        let pool = model.original.engine.jobs.clone();
        let mut preparation = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
        preparation.promote_branch_preparation().unwrap();
        preparation.promote_branch_backing(7 << 30).unwrap();
        let backing = preparation.handoff_branch().unwrap();
        drop(preparation);
        let mut state = retained(&model.original, &model.intent);
        model.journal.enter(&model.intent).unwrap();
        model.collect();
        let counts = pool.counts();
        let called = Cell::new(0);
        model
            .finish(&mut state, || {
                let record = model.journal.read()?.0;
                assert!(
                    record.schema == 4
                        && record.phase == Phase::Deleting
                        && record.intent == model.intent
                );
                called.set(called.get() + 1);
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
        assert_eq!(called.get(), 1);
        assert!(model.journal.read().unwrap().0.phase == Phase::Deleted);
        assert!(state.leases.is_some() && matches!(state.completion, Some(Completion::Deleted)));
        assert_eq!(pool.counts(), counts);
        state.retire_transient().unwrap();
        assert_eq!(pool.counts().checkpoint_material, 7 << 30);
        assert!(model.intent.plan.source.path.exists() && model.intent.plan.snapshot.path.exists());
        assert!(model
            .finish(&mut state, || panic!("completed delete replayed"))
            .is_err());
        drop(backing); // Synthetic accounting only; no native disk cleanup claim.
    }
}
#[test]
fn failed_or_partial_sdk_result_cannot_replay_and_original_work_and_charge_stay_retained() {
    let model = Model::new(true);
    let mut state = retained(&model.original, &model.intent);
    model.journal.enter(&model.intent).unwrap();
    model.collect();
    let counts = model.original.engine.jobs.counts();
    let calls = Cell::new(0);
    assert!(model
        .finish(&mut state, || {
            calls.set(calls.get() + 1);
            Err(Error::uncertain(ErrorCode::Native))
        })
        .is_err());
    assert!(model.journal.read().unwrap().0.phase == Phase::Deleting);
    assert!(model
        .finish(&mut state, || {
            calls.set(calls.get() + 1);
            Ok(())
        })
        .is_err());
    assert_eq!(calls.get(), 1);
    assert!(state.completion.is_none() && state.leases.is_some());
    assert_eq!(model.original.engine.jobs.counts(), counts);
    assert!(model.intent.plan.child.path.exists());
}
#[test]
fn released_records_cannot_be_relabeled_stripped_or_consumed_as_held_cleanup_authority() {
    for hold in [false, true] {
        let model = Model::new(hold);
        let mut state = retained(&model.original, &model.intent);
        model.journal.enter(&model.intent).unwrap();
        let (record, _) = model.journal.read().unwrap();
        let bytes = serde_json::to_vec(&record).unwrap();
        for schema in 1..=3 {
            let mut changed = record.clone();
            changed.schema = schema;
            assert!(changed.validate().is_err());
            changed.intent.release = None;
            assert!(changed
                .validate_for(
                    &model.journal,
                    serde_json::to_vec(&changed).unwrap().len() as u64
                )
                .is_err());
        }
        assert!(model.intent.require_held().is_err());
        assert!(model
            .journal
            .resolve_absent(
                &model.intent,
                "legacy-held-resolve",
                &"d".repeat(64),
                &Absence {
                    intent_sha256: crate::material::hash(&model.intent).unwrap()
                },
                &budget()
            )
            .is_err());
        assert_eq!(std::fs::read(&model.journal.path).unwrap(), bytes);
        assert!(state.retire_transient().is_err());
    }
}
#[test]
fn direct_released_delete_requires_original_manager_and_cancelled_lookup_cannot_adopt_inventory() {
    let model = Model::new(false);
    let counts = model.original.engine.jobs.counts();
    let cancelled = budget();
    cancelled.cancel.cancel();
    for selected in [budget(), cancelled] {
        assert_eq!(
            model
                .original
                .engine
                .delete_released_branch(model.intent.receipt(), &selected)
                .unwrap_err()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
    }
    assert_eq!(model.original.engine.jobs.counts(), counts);
    assert!(model.intent.plan.child.path.exists());
    assert!(model
        .original
        .engine
        .db
        .get_vm(&model.intent.receipt().name)
        .unwrap()
        .is_some());
}
