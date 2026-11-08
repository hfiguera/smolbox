//! Private row/actor/metadata models; SDK closures never launch or stop a VM.
use super::*;
use crate::machine::tests::{install_record, test_engine};
use std::cell::Cell;
fn budget() -> ReadBudget {
    ReadBudget::new(
        std::time::Duration::from_secs(5),
        crate::Cancellation::default(),
    )
    .unwrap()
}
fn fixture() -> (
    tempfile::TempDir,
    Engine,
    CreationReceipt,
    tempfile::TempDir,
    ActorEpoch,
) {
    let root = tempfile::tempdir().unwrap();
    let engine = test_engine(root.path());
    let receipt = install_record(&engine);
    engine
        .db
        .update_vm(&receipt.name, |row| {
            row.state = smolvm::config::RecordState::Stopped
        })
        .unwrap();
    let epoch_root = tempfile::tempdir().unwrap();
    let (_, _, epoch) = crate::epoch::tests::fixture_for_binding(
        &epoch_root.path().canonicalize().unwrap(),
        None,
        engine.binding().clone(),
    );
    (root, engine, receipt, epoch_root, epoch)
}
fn enrolled(engine: &Engine, receipt: &CreationReceipt, epoch: &ActorEpoch) -> Arc<Owned> {
    let owned = engine.runtime_boots.reserve(receipt, &engine.jobs).unwrap();
    owned
        .enroll(
            crate::epoch::tests::complete_model(epoch.begin_boot(&receipt.name).unwrap()),
            epoch,
        )
        .unwrap();
    owned
}
#[test]
fn pending_entry_is_charged_but_has_no_sdk_stop_authority_or_stopped_acknowledgement() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let before = engine.jobs.counts();
    let owned = engine
        .runtime_boots
        .reserve(&receipt, &engine.jobs)
        .unwrap();
    assert!(engine.jobs.counts().branch_metadata > before.branch_metadata);
    assert!(engine
        .runtime_boots
        .reserve(&receipt, &engine.jobs)
        .is_err());
    assert!(owned
        .call(&receipt, &epoch, None, &budget(), || panic!(
            "pending authority dispatched"
        ))
        .is_err());
    assert!(engine.stop(&receipt).is_err());
    assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
    assert!(engine.record(&receipt).unwrap().state == smolvm::config::RecordState::Stopped);
}
#[test]
fn exited_child_sdk_cleanup_is_fenced_before_any_sweep_and_retires_only_exact_metadata() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let counts = engine.jobs.counts();
    let owned = enrolled(&engine, &receipt, &epoch);
    let calls = Cell::new(0);
    owned
        .call(
            &receipt,
            &epoch,
            Some(owned.enrolled().unwrap().child().pid),
            &budget(),
            || {
                calls.set(calls.get() + 1);
                assert!(!epoch.quiescent_for(&receipt.name).unwrap());
                assert!(epoch.quiescent_for("sibling").unwrap());
                assert!(epoch
                    .collect_enrolled(&receipt.name, owned.enrolled().unwrap())
                    .is_err());
                Ok(())
            },
        )
        .unwrap();
    assert_eq!(calls.get(), 1);
    owned.collected(&receipt, &epoch, &budget()).unwrap();
    engine.runtime_boots.retire(&owned).unwrap();
    drop(owned);
    assert_eq!(engine.jobs.counts(), counts);
    assert!(engine.vm_directory(&receipt.name).exists());
}
#[test]
fn returned_sdk_error_keeps_original_enrollment_and_budget_for_explicit_retry() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let counts = engine.jobs.counts();
    let error = owned
        .call(&receipt, &epoch, None, &budget(), || {
            Err(Error::before(ErrorCode::Native))
        })
        .unwrap_err();
    assert!(error.dispatch == crate::Dispatch::MayHaveDispatched);
    assert!(Arc::ptr_eq(
        &engine.runtime_boots.get(&receipt).unwrap().unwrap(),
        &owned
    ));
    assert_eq!(engine.jobs.counts(), counts);
    assert!(epoch.available());
    owned
        .call(&receipt, &epoch, None, &budget(), || Ok(()))
        .unwrap();
    assert!(owned.enrollment.get().is_some());
}
#[test]
fn runtime_success_without_positive_collection_cannot_retire_current_boot_authority() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = engine
        .runtime_boots
        .reserve(&receipt, &engine.jobs)
        .unwrap();
    let actor = crate::OwnerIdentity::capture().unwrap();
    owned
        .enroll(
            crate::epoch::tests::complete_model_with_child(
                epoch.begin_boot(&receipt.name).unwrap(),
                actor,
            ),
            &epoch,
        )
        .unwrap();
    let error = owned
        .call(&receipt, &epoch, Some(actor.pid), &budget(), || Ok(()))
        .unwrap_err();
    assert!(error.dispatch == crate::Dispatch::MayHaveDispatched);
    assert!(owned.collected(&receipt, &epoch, &budget()).is_err());
    assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
    // The current-process actor is observed only, never stopped or signalled.
}
#[test]
fn crossed_runtime_pid_epoch_origin_pending_budget_and_reenrollment_reject_before_sdk_entry() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let (_other_root, _, _, _other_actors, other) = fixture();
    let calls = Cell::new(0);
    for (receipt, epoch, pid) in [
        (
            receipt.clone(),
            &epoch,
            Some(owned.enrolled().unwrap().child().pid + 1),
        ),
        (receipt.clone(), &other, None),
        (
            {
                let mut bad = receipt.clone();
                bad.incarnation = "f".repeat(32);
                bad
            },
            &epoch,
            None,
        ),
    ] {
        assert!(owned
            .call(&receipt, epoch, pid, &budget(), || {
                calls.set(1);
                Ok(())
            })
            .is_err());
    }
    let cancelled = budget();
    cancelled.cancel.cancel();
    assert!(owned
        .call(&receipt, &epoch, None, &cancelled, || {
            calls.set(1);
            Ok(())
        })
        .is_err());
    assert_eq!(calls.get(), 0);
    assert!(owned
        .enroll(
            crate::epoch::tests::complete_model(epoch.begin_boot(&receipt.name).unwrap()),
            &epoch
        )
        .is_err());
    assert!(engine
        .runtime_boots
        .get(&{
            let mut wrong = receipt.clone();
            wrong.owner_token = "e".repeat(64);
            wrong
        })
        .is_err());
}
#[test]
fn stopped_row_and_current_head_checks_preserve_every_non_runtime_field() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let row = engine.record(&receipt).unwrap();
    owned.verify_before(&receipt, &row).unwrap();
    verify_stopped(&receipt, &row, &row, None).unwrap();
    for field in 0..6 {
        let mut changed = row.clone();
        match field {
            0 => changed.pid = Some(1),
            1 => changed.pid_start_time = Some(1),
            2 => changed.state = smolvm::config::RecordState::Running,
            3 => changed.forkpoint_held = true,
            4 => changed.cpus += 1,
            _ => changed.labels.clear(),
        }
        assert!(verify_stopped(&receipt, &row, &changed, None).is_err());
        assert!(owned.verify_before(&receipt, &changed).is_err());
    }
    assert!(verify_stopped(&receipt, &row, &row, Some(1)).is_err());
}
#[test]
fn completed_old_owner_cannot_remove_a_new_boot_slot_and_retired_branch_checks_see_pending_boots() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let old = enrolled(&engine, &receipt, &epoch);
    old.collected(&receipt, &epoch, &budget()).unwrap();
    engine.runtime_boots.retire(&old).unwrap();
    let next = engine
        .runtime_boots
        .reserve(&receipt, &engine.jobs)
        .unwrap();
    assert!(engine.runtime_boots.retire(&old).is_err());
    assert!(Arc::ptr_eq(
        &engine.runtime_boots.get(&receipt).unwrap().unwrap(),
        &next
    ));
    assert!(engine.require_no_active_branch_handles(&receipt).is_err());
}
#[test]
fn finite_boot_metadata_admission_keeps_reserved_observation_capacity_available() {
    let (_root, engine, receipt, _actors, _) = fixture();
    let mut accepted = Vec::new();
    for index in 0..4096 {
        let mut receipt = receipt.clone();
        receipt.name = format!("metadata-model-{index}");
        match engine.runtime_boots.reserve(&receipt, &engine.jobs) {
            Ok(entry) => accepted.push(entry),
            Err(error) => {
                assert_eq!(error.code, ErrorCode::Admission);
                break;
            }
        }
    }
    assert!(!accepted.is_empty() && accepted.len() < 4096);
    let _control = engine
        .jobs
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    let _observer = engine
        .jobs
        .acquire(crate::jobs::Demand::observation())
        .unwrap();
}

#[test]
fn uncertain_missing_result_keeps_metadata_until_positive_collection_without_sdk_replay() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let mut preparation = engine
        .jobs
        .acquire(crate::jobs::Demand::branch_source())
        .unwrap();
    preparation.promote_branch_preparation().unwrap();
    preparation.promote_branch_backing(7 << 30).unwrap();
    let backing = preparation.handoff_branch().unwrap();
    drop(preparation);
    let before = engine.jobs.counts();
    let owned = enrolled(&engine, &receipt, &epoch);
    assert!(owned
        .call(&receipt, &epoch, None, &budget(), || {
            engine.db.remove_vm(&receipt.name).unwrap();
            std::fs::remove_dir_all(engine.vm_directory(&receipt.name)).unwrap();
            Err(Error::uncertain(ErrorCode::Native))
        })
        .is_err());
    assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
    assert!(engine.jobs.counts().branch_metadata > before.branch_metadata);
    // The retained original enrollment can confirm collection without another
    // SDK entry. Namespace checks remain the caller's separate obligation.
    owned.collected(&receipt, &epoch, &budget()).unwrap();
    engine.runtime_boots.retire(&owned).unwrap();
    drop(owned);
    assert_eq!(engine.jobs.counts(), before);
    assert_eq!(engine.jobs.counts().checkpoint_material, 7 << 30);
    drop(backing);
}

#[test]
fn cancellation_after_pending_publication_cannot_enter_sdk_or_claim_sdk_return() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let pending = epoch
        .begin_collection(&receipt.name, owned.enrolled().unwrap())
        .unwrap();
    let cancelled = budget();
    cancelled.cancel.cancel();
    let error = pending
        .run(&cancelled, || panic!("cancelled collection entered SDK"))
        .unwrap_err();
    assert!(error.dispatch == crate::Dispatch::NotDispatched);
    assert!(epoch.available());
    owned.collected(&receipt, &epoch, &budget()).unwrap();
    assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
}
