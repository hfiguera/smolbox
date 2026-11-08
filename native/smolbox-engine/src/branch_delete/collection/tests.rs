//! Private files, accounting and opaque epoch models only; no SDK stop/delete or VMM.
use super::*;
use crate::branch_boot::tests::IdentityModel;
use crate::branch_delete::tests::{authority, budget, retained};
use std::cell::Cell;

struct Model {
    original: IdentityModel,
    intent: Intent,
    journal: Journal,
}
impl Model {
    fn new(mode: u8) -> Self {
        let model = if mode == 0 {
            let (original, _, intent, journal) = crate::branch_delete::tests::fixture();
            Self {
                original,
                intent,
                journal,
            }
        } else {
            let model = crate::branch_delete::released::tests::Model::new(mode == 2);
            Self {
                original: model.original,
                intent: model.intent,
                journal: model.journal,
            }
        };
        model.journal.enter(&model.intent).unwrap();
        model
    }
    fn request(&self) -> BranchDeletionCollectionRequest {
        let held = self
            .intent
            .plan
            .publication
            .change
            .child_origin
            .intent
            .child
            .hold;
        let completion = crate::BranchCompletion {
            schema: 1,
            publication: self.intent.plan.publication.clone(),
            child: if held {
                self.intent.plan.publication.child().clone()
            } else {
                self.intent.receipt().clone()
            },
            identity_sha256: self.intent.identity_sha256.clone(),
            held,
            release: if held {
                None
            } else {
                self.intent.release.clone()
            },
        };
        let mut request = BranchDeletionCollectionRequest {
            completion,
            release: self.intent.release.clone(),
            child: self.intent.receipt().clone(),
            operation_id: "collect-original-delete".into(),
            request_sha256: String::new(),
            quiesced: true,
        };
        request.request_sha256 = request.digest().unwrap();
        request.validate().unwrap();
        request
    }
    fn proof(&self) -> crate::epoch::BootCollection {
        self.original
            .actors
            .collect_enrolled(&self.intent.receipt().name, &self.original.enrollment)
            .unwrap()
    }
    fn ledger(&self) -> Journal {
        collection_journal(self.journal.domain.clone(), self.intent.receipt()).unwrap()
    }
    fn finish(&self, state: &mut Retained) -> BranchDeletionCollection {
        state
            .finish_collection(&self.journal, &self.proof(), &budget())
            .unwrap()
    }
}

#[test]
fn held_initial_and_explicit_release_collection_is_distinct_and_retains_every_reservation() {
    for mode in 0..3 {
        let model = Model::new(mode);
        let mut state = retained(&model.original, &model.intent);
        let request = model.request();
        let main = std::fs::read(&model.journal.path).unwrap();
        let row = model
            .original
            .engine
            .db
            .get_vm(&request.child.name)
            .unwrap()
            .unwrap();
        let counts = model.original.engine.jobs.counts();
        let active = Arc::new(());
        assert!(state
            .prepare_collection(&model.journal, &request, &active, &budget())
            .unwrap()
            .is_none());
        assert_eq!(
            state
                .prepare_collection(&model.journal, &request, &Arc::new(()), &budget())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        let proof = model.finish(&mut state);
        request.matches(&proof).unwrap();
        assert!(proof.release_sha256.is_some() == (mode != 0));
        assert!(
            state.completion.is_none() && state.continuation.is_none() && state.leases.is_some()
        );
        assert!(state.leases.as_ref().unwrap().source.is_some());
        assert_eq!(model.original.engine.jobs.counts(), counts);
        assert_eq!(
            crate::material::hash(
                &model
                    .original
                    .engine
                    .db
                    .get_vm(&request.child.name)
                    .unwrap()
                    .unwrap()
            )
            .unwrap(),
            crate::material::hash(&row).unwrap()
        );
        assert_eq!(std::fs::read(&model.journal.path).unwrap(), main);
        drop(active);
        assert!(state.retire_transient().is_err());
        assert_eq!(
            state
                .prepare_collection(&model.journal, &request, &Arc::new(()), &budget())
                .unwrap(),
            Some(proof)
        );
        assert_eq!(model.original.engine.jobs.counts(), counts);
    }
}

#[test]
fn checked_requests_reject_changed_quiescence_completion_release_child_and_request_hash() {
    for mode in 0..3 {
        let model = Model::new(mode);
        let request = model.request();
        for field in 0..7 {
            let mut wrong = request.clone();
            match field {
                0 => wrong.quiesced = false,
                1 => wrong.child.owner_token = "0".repeat(64),
                2 => wrong.completion.identity_sha256 = "0".repeat(64),
                3 => {
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
                4 => wrong.request_sha256 = "0".repeat(64),
                5 => {
                    wrong.release = if mode == 0 {
                        Model::new(1).intent.release
                    } else {
                        None
                    }
                }
                _ => wrong.child.material.as_mut().unwrap().revision += 1,
            }
            if field != 4 {
                wrong.request_sha256 = wrong.digest().unwrap();
            }
            assert!(
                wrong.matches_intent(&model.intent).is_err(),
                "mode {mode}, field {field}"
            );
        }
        let counts = model.original.engine.jobs.counts();
        assert!(model
            .original
            .engine
            .collect_branch_deletion_checked(&request, &budget())
            .is_err());
        assert_eq!(model.original.engine.jobs.counts(), counts);
        assert!(!model.ledger().path.exists()); // Receipts do not reconstruct original ownership.
    }
}

#[test]
fn prepared_grant_can_publish_once_but_a_published_missing_ledger_never_reenrolls() {
    let model = Model::new(0);
    let mut state = retained(&model.original, &model.intent);
    let request = model.request();
    let grant = Grant::new(&request, &crate::material::hash(&model.intent).unwrap()).unwrap();
    // Deterministic model of a returned publication failure, not live interruption.
    state.collection = Some(RetainedCollection {
        grant,
        published: false,
    });
    let mut other = request.clone();
    other.operation_id = "another-collection".into();
    other.request_sha256 = other.digest().unwrap();
    assert!(state
        .prepare_collection(&model.journal, &other, &Arc::new(()), &budget())
        .is_err());
    let active = Arc::new(());
    state
        .prepare_collection(&model.journal, &request, &active, &budget())
        .unwrap();
    drop(active);
    let bytes = std::fs::read(&model.ledger().path).unwrap();
    std::fs::remove_file(&model.ledger().path).unwrap();
    assert!(state
        .prepare_collection(&model.journal, &request, &Arc::new(()), &budget())
        .is_err());
    assert!(!model.ledger().path.exists());
    std::fs::write(&model.ledger().path, bytes).unwrap();
    std::fs::set_permissions(&model.ledger().path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let active = Arc::new(());
    state
        .prepare_collection(&model.journal, &request, &active, &budget())
        .unwrap();
    drop(active);
    let mut fresh_state = retained_without_gates(&model);
    assert!(fresh_state
        .prepare_collection(&model.journal, &request, &Arc::new(()), &budget())
        .is_err());
}
fn retained_without_gates(model: &Model) -> Retained {
    // No source/root ownership is reconstructed for this negative fixture.
    Retained {
        intent: model.intent.clone(),
        worker: Weak::new(),
        leases: None,
        completion: None,
        continuation: None,
        cleanup: None,
        collection: None,
        _metadata: model.original.engine.jobs.branch_result_metadata().unwrap(),
        _release_metadata: None,
        _cleanup_metadata: None,
        _collection_metadata: model.original.engine.jobs.branch_result_metadata().unwrap(),
    }
}

#[test]
fn quarantine_uses_preallocated_metadata_and_reserved_control_without_retiring_work_or_backing() {
    let model = Model::new(2);
    let pool = model.original.engine.jobs.clone();
    let mut creation = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
    creation.promote_branch_preparation().unwrap();
    creation.promote_branch_backing(7 << 30).unwrap();
    let backing = creation.handoff_branch().unwrap();
    drop(creation);
    let mut state = retained(&model.original, &model.intent);
    pool.quarantine(); // Admission model only; no process or persistence interruption.
    assert!(pool.branch_result_metadata().is_err());
    let control = pool
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    let observer = pool
        .acquire(crate::jobs::Demand::volume_observation())
        .unwrap();
    let counts = pool.counts();
    let active = Arc::new(());
    state
        .prepare_collection(&model.journal, &model.request(), &active, &budget())
        .unwrap();
    model.finish(&mut state);
    assert_eq!(pool.counts(), counts);
    assert_eq!(pool.counts().checkpoint_material, 7 << 30);
    assert!(state.leases.is_some() && state.completion.is_none() && !pool.available());
    drop((active, control, observer, backing));
}

#[test]
fn cancelled_or_late_publication_retains_the_exact_pending_grant_without_issuing_proof() {
    let model = Model::new(0);
    let mut state = retained(&model.original, &model.intent);
    let request = model.request();
    let cancelled = budget();
    cancelled.cancel.cancel();
    assert!(state
        .prepare_collection(&model.journal, &request, &Arc::new(()), &cancelled)
        .is_err());
    assert!(state.collection.is_none() && !model.ledger().path.exists());
    let active = Arc::new(());
    state
        .prepare_collection(&model.journal, &request, &active, &budget())
        .unwrap();
    let before = std::fs::read(&model.ledger().path).unwrap();
    assert!(state
        .finish_collection(&model.journal, &model.proof(), &cancelled)
        .is_err());
    let mut expired = budget();
    expired.deadline = std::time::Instant::now();
    assert!(state
        .finish_collection(&model.journal, &model.proof(), &expired)
        .is_err());
    assert_eq!(std::fs::read(&model.ledger().path).unwrap(), before);
    assert!(model
        .ledger()
        .read_record::<CollectionRecord>()
        .unwrap()
        .0
        .proof
        .is_none());
    drop(active);
    let active = Arc::new(());
    state
        .prepare_collection(&model.journal, &request, &active, &budget())
        .unwrap();
    model.finish(&mut state);
    assert!(state.leases.is_some() && state.completion.is_none());
}

#[test]
fn foreign_opaque_collection_or_changed_ledger_cannot_become_original_collection() {
    let model = Model::new(1);
    let foreign = Model::new(1);
    let mut state = retained(&model.original, &model.intent);
    let active = Arc::new(());
    state
        .prepare_collection(&model.journal, &model.request(), &active, &budget())
        .unwrap();
    let before = std::fs::read(&model.ledger().path).unwrap();
    assert!(state
        .finish_collection(&model.journal, &foreign.proof(), &budget())
        .is_err());
    assert_eq!(std::fs::read(&model.ledger().path).unwrap(), before);
    let (mut record, version) = model.ledger().read_record::<CollectionRecord>().unwrap();
    record.grant.deletion_sha256 = "0".repeat(64);
    model.ledger().write_record(&record, Some(version)).unwrap();
    assert!(state
        .finish_collection(&model.journal, &model.proof(), &budget())
        .is_err());
    drop(active);
    assert!(state
        .prepare_collection(&model.journal, &model.request(), &Arc::new(()), &budget())
        .is_err());
    assert!(state.completion.is_none() && state.leases.is_some());
}

#[test]
fn completed_collection_acknowledgement_does_not_traverse_recreated_or_missing_namespace() {
    for mode in 0..3 {
        let model = Model::new(mode);
        let mut state = retained(&model.original, &model.intent);
        let request = model.request();
        let active = Arc::new(());
        state
            .prepare_collection(&model.journal, &request, &active, &budget())
            .unwrap();
        let proof = model.finish(&mut state);
        drop(active);
        let original = std::fs::read(&model.ledger().path).unwrap();
        model
            .original
            .engine
            .db
            .remove_vm(&request.child.name)
            .unwrap();
        std::fs::remove_dir_all(&model.intent.plan.child.path).unwrap();
        for recreated in [false, true] {
            if recreated {
                std::fs::create_dir(&model.intent.plan.child.path).unwrap();
                std::fs::write(model.intent.plan.child.path.join("foreign"), b"untouched").unwrap();
            }
            assert_eq!(
                state
                    .prepare_collection(&model.journal, &request, &Arc::new(()), &budget())
                    .unwrap(),
                Some(proof.clone())
            );
            assert_eq!(std::fs::read(&model.ledger().path).unwrap(), original);
            assert!(state.completion.is_none() && state.leases.is_some());
        }
        assert_eq!(
            std::fs::read(model.intent.plan.child.path.join("foreign")).unwrap(),
            b"untouched"
        );
    }
}

#[test]
fn collecting_control_never_enters_an_uncertain_final_delete() {
    for phase in [Phase::Deleting, Phase::Finishing] {
        let model = Model::new(0);
        let mut state = retained(&model.original, &model.intent);
        // Phase guards are also checked on validated records. Finishing has its
        // original continuation, Deleting is a real valid entered record.
        let collection = model.proof();
        model.journal.collected(&model.intent, &collection).unwrap();
        if phase == Phase::Finishing {
            let request = ContinuationRequest {
                operation_id: "finish-model".into(),
                request_sha256: "d".repeat(64),
            };
            state.continuation = Some(request.clone());
            model
                .journal
                .begin_original_finishing(&model.intent, &request, &collection, &budget())
                .unwrap();
        } else {
            model
                .journal
                .advance(&model.intent, Phase::Collected, Phase::Deleting)
                .unwrap();
        }
        let before = std::fs::read(&model.journal.path).unwrap();
        assert!(state
            .prepare_collection(&model.journal, &model.request(), &Arc::new(()), &budget())
            .is_err());
        assert!(!model.ledger().path.exists());
        assert_eq!(std::fs::read(&model.journal.path).unwrap(), before);
    }
}

#[test]
fn explicit_collection_then_existing_continuation_enters_final_sdk_delete_only_once() {
    for mode in 0..3 {
        let model = Model::new(mode);
        let mut state = retained(&model.original, &model.intent);
        let active = Arc::new(());
        let request = model.request();
        state
            .prepare_collection(&model.journal, &request, &active, &budget())
            .unwrap();
        let proof = model.finish(&mut state);
        drop(active);
        let continuation = ContinuationRequest {
            operation_id: "finish-collected-model".into(),
            request_sha256: "d".repeat(64),
        };
        let collection = model.proof();
        let before = model
            .original
            .engine
            .db
            .get_vm(&request.child.name)
            .unwrap()
            .unwrap();
        let stopped = stopped_record(&model.intent, &before, &collection, &budget()).unwrap();
        state.continuation = Some(continuation.clone());
        model
            .journal
            .begin_original_finishing(&model.intent, &continuation, &collection, &budget())
            .unwrap();
        model
            .original
            .engine
            .db
            .update_vm(&request.child.name, |row| *row = stopped)
            .unwrap();
        let calls = Cell::new(0);
        let budget = budget();
        let finish = CollectedDeletion {
            journal: &model.journal,
            authority: authority(&model.original, &model.original.actors),
            budget: &budget,
        };
        finish
            .finish(&mut state, Phase::Finishing, || {
                calls.set(calls.get() + 1);
                model
                    .original
                    .engine
                    .db
                    .remove_vm(&request.child.name)
                    .unwrap();
                std::fs::remove_dir_all(&model.intent.plan.child.path).unwrap();
                Ok(())
            })
            .unwrap();
        assert!(finish
            .finish(&mut state, Phase::Finishing, || {
                calls.set(calls.get() + 1);
                Ok(())
            })
            .is_err());
        assert_eq!(calls.get(), 1);
        assert!(state
            .continuation_status(&model.journal, &continuation)
            .unwrap());
        state.retire_transient().unwrap();
        let counts = model.original.engine.jobs.counts();
        assert_eq!(
            state
                .prepare_collection(&model.journal, &request, &Arc::new(()), &budget)
                .unwrap(),
            Some(proof)
        );
        assert_eq!(model.original.engine.jobs.counts(), counts);
    }
}

#[test]
fn collection_proof_cannot_substitute_for_absence_or_sdk_success_and_debug_hides_identity() {
    for mode in 0..3 {
        let model = Model::new(mode);
        let request = model.request();
        let mut state = retained(&model.original, &model.intent);
        let active = Arc::new(());
        state
            .prepare_collection(&model.journal, &request, &active, &budget())
            .unwrap();
        let proof = model.finish(&mut state);
        let encoded = serde_json::to_value(&proof).unwrap();
        assert!(serde_json::from_value::<BranchDeletionResolution>(encoded.clone()).is_err());
        assert!(serde_json::from_value::<BranchDeletionContinuation>(encoded.clone()).is_err());
        assert!(
            serde_json::from_value::<ReleasedBranchDeletionResolution>(encoded.clone()).is_err()
        );
        assert!(serde_json::from_value::<ReleasedBranchDeletionContinuation>(encoded).is_err());
        for value in [format!("{request:?}"), format!("{proof:?}")] {
            assert!(!value.contains(&request.child.owner_token));
            assert!(!value.contains(&request.request_sha256));
        }
        let mut wrong = proof.clone();
        wrong.collection_sha256 = "0".repeat(64);
        assert!(request.matches(&wrong).is_err());
        let mut wrong = request;
        wrong.operation_id = "different-grant".into();
        wrong.request_sha256 = wrong.digest().unwrap();
        assert!(wrong.matches(&proof).is_err());
    }
}

#[test]
fn protected_collection_ledger_enforces_small_bound_permissions_links_and_unknown_fields() {
    let model = Model::new(0);
    let mut state = retained(&model.original, &model.intent);
    let active = Arc::new(());
    state
        .prepare_collection(&model.journal, &model.request(), &active, &budget())
        .unwrap();
    let ledger = model.ledger();
    let original = std::fs::read(&ledger.path).unwrap();
    let alias = ledger.path.with_extension("alias");
    std::fs::hard_link(&ledger.path, &alias).unwrap();
    assert!(ledger.read_record::<CollectionRecord>().is_err());
    std::fs::remove_file(&alias).unwrap();
    std::fs::set_permissions(&ledger.path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(ledger.read_record::<CollectionRecord>().is_err());
    std::fs::set_permissions(&ledger.path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
    value["unknown"] = true.into();
    std::fs::write(&ledger.path, serde_json::to_vec(&value).unwrap()).unwrap();
    assert!(ledger.read_record::<CollectionRecord>().is_err());
    std::fs::write(&ledger.path, vec![b' '; LEDGER_BYTES as usize + 1]).unwrap();
    assert!(ledger.read_record::<CollectionRecord>().is_err());
    std::fs::write(&ledger.path, &original).unwrap();
    std::fs::rename(&ledger.path, &alias).unwrap();
    std::os::unix::fs::symlink(&alias, &ledger.path).unwrap();
    assert!(ledger.read_record::<CollectionRecord>().is_err());
    std::fs::remove_file(&ledger.path).unwrap();
    std::fs::rename(&alias, &ledger.path).unwrap();
    ledger.read_record::<CollectionRecord>().unwrap();
}

#[test]
fn shared_wire_collection_fixtures_match_engine_algebra_without_sdk_or_native_authority() {
    let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
        "../../../../smolbox-protocol/fixtures/branch-deletion-collection-v1.json"
    ))
    .unwrap();
    for row in rows {
        let request: BranchDeletionCollectionRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: BranchDeletionCollection = serde_json::from_value(row["proof"].clone()).unwrap();
        request.matches(&proof).unwrap();
        assert!(!format!("{request:?}").contains(&request.child.owner_token));
        assert!(!format!("{proof:?}").contains(&request.request_sha256));
    }
}
