//! Private record/callback models only, no SDK stop or VM lifecycle.
use super::*;
use crate::machine::tests::{install_record, test_engine};
use std::cell::Cell;
use std::time::{Duration, Instant};
fn budget() -> crate::ReadBudget {
    crate::ReadBudget::new(Duration::from_secs(5), Cancellation::default()).unwrap()
}
#[test]
fn cancelled_stop_preserves_the_exact_record_and_metadata_before_sdk_entry() {
    let temp = tempfile::tempdir().unwrap();
    let engine = test_engine(temp.path());
    let receipt = install_record(&engine);
    let before = crate::material::hash(&engine.record(&receipt).unwrap()).unwrap();
    let counts = engine.jobs.counts();
    let budget = budget();
    budget.cancel.cancel();
    let error = engine.stop_with_budget(&receipt, &budget).unwrap_err();
    assert!(error.code == ErrorCode::State && error.dispatch == crate::Dispatch::NotDispatched);
    assert_eq!(
        crate::material::hash(&engine.record(&receipt).unwrap()).unwrap(),
        before
    );
    assert_eq!(engine.jobs.counts(), counts);
}
#[test]
fn expired_stop_cannot_refresh_its_budget_into_a_stopped_observation() {
    let temp = tempfile::tempdir().unwrap();
    let engine = test_engine(temp.path());
    let receipt = install_record(&engine);
    let budget = crate::ReadBudget {
        deadline: Instant::now() - Duration::from_secs(1),
        cancel: Cancellation::default(),
    };
    let error = engine.stop_with_budget(&receipt, &budget).unwrap_err();
    assert!(error.code == ErrorCode::State && error.dispatch == crate::Dispatch::NotDispatched);
    assert!(engine.vm_directory(&receipt.name).exists());
}
#[test]
fn checkpoint_sized_budgets_cannot_widen_ordinary_stop() {
    let temp = tempfile::tempdir().unwrap();
    let engine = test_engine(temp.path());
    let receipt = install_record(&engine);
    let budget =
        crate::ReadBudget::for_checkpoint_work(Duration::from_secs(31), Cancellation::default())
            .unwrap();
    let error = engine.stop_with_budget(&receipt, &budget).unwrap_err();
    assert!(
        error.code == ErrorCode::Validation && error.dispatch == crate::Dispatch::NotDispatched
    );
    assert!(engine.inspect(&receipt).unwrap().state == ObservedState::Stopped);
}
#[test]
fn stop_inspection_uses_the_original_cancellation_instead_of_a_fresh_default() {
    let temp = tempfile::tempdir().unwrap();
    let engine = test_engine(temp.path());
    let receipt = install_record(&engine);
    let budget = budget();
    budget.cancel.cancel();
    let error = engine.inspect_under(&receipt, &budget).unwrap_err();
    assert!(error.code == ErrorCode::State && error.dispatch == crate::Dispatch::NotDispatched);
    assert!(engine.inspect(&receipt).unwrap().state == ObservedState::Stopped);
}
#[test]
fn cancellation_after_preflight_does_not_reach_the_sdk_callback() {
    let temp = tempfile::tempdir().unwrap();
    let engine = test_engine(temp.path());
    let receipt = install_record(&engine);
    let expected = engine.inspect(&receipt).unwrap();
    let budget = budget();
    budget.cancel.cancel();
    let calls = Cell::new(0);
    let error = engine
        .coordinated_lifecycle(&receipt, &expected, &budget, || {
            calls.set(1);
            Ok(())
        })
        .unwrap_err();
    assert_eq!(calls.get(), 0);
    assert!(error.dispatch == crate::Dispatch::NotDispatched);
}
#[test]
fn a_late_sdk_return_remains_uncertain_instead_of_acknowledging_stop() {
    let budget = budget();
    let calls = Cell::new(0);
    let error = lifecycle_sdk_call(&budget, || {
        calls.set(1);
        budget.cancel.cancel();
        Ok(())
    })
    .unwrap_err();
    assert_eq!(calls.get(), 1);
    assert!(error.code == ErrorCode::State && error.dispatch == crate::Dispatch::MayHaveDispatched);
}
#[test]
fn sdk_errors_stay_uncertain_even_with_remaining_caller_time() {
    let error = lifecycle_sdk_call(&budget(), || {
        Err(smolvm::Error::config("modeled SDK stop", "failure"))
    })
    .unwrap_err();
    assert!(
        error.code == ErrorCode::Native && error.dispatch == crate::Dispatch::MayHaveDispatched
    );
}
#[test]
fn absolute_budget_constructor_preserves_deadline_and_shared_cancellation() {
    let deadline = Instant::now() + Duration::from_secs(1);
    let cancel = Cancellation::default();
    let budget = crate::ReadBudget::until(deadline, cancel.clone()).unwrap();
    assert_eq!(budget.deadline(), deadline);
    cancel.cancel();
    assert!(budget.check().is_err());
    assert!(crate::ReadBudget::until(
        Instant::now() - Duration::from_secs(1),
        Cancellation::default()
    )
    .is_err());
    assert!(crate::ReadBudget::until(
        Instant::now() + Duration::from_secs(31),
        Cancellation::default()
    )
    .is_err());
}

#[test]
fn late_final_observation_preserves_the_returned_boot_slot_and_handle_for_retry() {
    for expired in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let mut engine = test_engine(root.path());
        let receipt = install_record(&engine);
        engine
            .db
            .update_vm(&receipt.name, |row| {
                row.state = smolvm::config::RecordState::Stopped
            })
            .unwrap();
        let actors_root = tempfile::tempdir().unwrap();
        let (_, launcher, epoch) = crate::epoch::tests::fixture_for_binding(
            &actors_root.path().canonicalize().unwrap(),
            None,
            engine.binding().clone(),
        );
        engine.boot = Some((launcher, epoch.clone()));
        engine.track_handle(&receipt).unwrap();
        let owned = engine
            .runtime_boots
            .reserve(&receipt, &engine.jobs)
            .unwrap();
        owned
            .enroll(
                crate::epoch::tests::complete_model(epoch.begin_boot(&receipt.name).unwrap()),
                &epoch,
            )
            .unwrap();
        owned
            .call(&receipt, &epoch, None, &budget(), || Ok(()))
            .unwrap();
        let caller = budget();
        let observed = engine.inspect_under(&receipt, &caller).unwrap();
        let counts = engine.jobs.counts();
        let result = if expired {
            caller.cancel.cancel();
            Ok(observed)
        } else {
            Err(Error::before(ErrorCode::State))
        };
        let error = engine
            .finish_stop_result(&receipt, &caller, result)
            .unwrap_err();
        assert!(error.dispatch == crate::Dispatch::MayHaveDispatched);
        assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
        assert!(engine
            .owned_handles
            .lock()
            .unwrap()
            .contains_key(&receipt.name));
        assert_eq!(engine.jobs.counts(), counts);
        assert!(engine.vm_directory(&receipt.name).exists());
    }
}
#[test]
fn final_stopped_acknowledgement_retires_only_the_original_boot_slot_and_active_handle() {
    let root = tempfile::tempdir().unwrap();
    let mut engine = test_engine(root.path());
    let receipt = install_record(&engine);
    engine
        .db
        .update_vm(&receipt.name, |row| {
            row.state = smolvm::config::RecordState::Stopped
        })
        .unwrap();
    let actors_root = tempfile::tempdir().unwrap();
    let (_, launcher, epoch) = crate::epoch::tests::fixture_for_binding(
        &actors_root.path().canonicalize().unwrap(),
        None,
        engine.binding().clone(),
    );
    engine.boot = Some((launcher, epoch.clone()));
    engine.track_handle(&receipt).unwrap();
    let baseline = engine.jobs.counts();
    let owned = engine
        .runtime_boots
        .reserve(&receipt, &engine.jobs)
        .unwrap();
    owned
        .enroll(
            crate::epoch::tests::complete_model(epoch.begin_boot(&receipt.name).unwrap()),
            &epoch,
        )
        .unwrap();
    owned
        .call(&receipt, &epoch, None, &budget(), || Ok(()))
        .unwrap();
    let caller = budget();
    let observed = engine.inspect_under(&receipt, &caller);
    assert!(
        engine
            .finish_stop_result(&receipt, &caller, observed)
            .unwrap()
            .state
            == ObservedState::Stopped
    );
    assert!(!engine.runtime_boots.contains(&receipt.name).unwrap());
    assert!(!engine
        .owned_handles
        .lock()
        .unwrap()
        .contains_key(&receipt.name));
    drop(owned);
    assert_eq!(engine.jobs.counts(), baseline);
    engine.require_no_active_branch_handles(&receipt).unwrap();
    assert!(engine.vm_directory(&receipt.name).exists());
}
