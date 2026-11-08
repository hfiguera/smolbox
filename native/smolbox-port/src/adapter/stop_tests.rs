//! Deterministic bridge budgets only; no native engine, SDK or VM is started.
use super::*;
fn stopped() -> engine::Observation {
    engine::Observation {
        state: engine::ObservedState::Stopped,
        resources: None,
        pid_identity: None,
        configuration: None,
    }
}
#[test]
fn stop_keeps_the_exact_captured_deadline_instead_of_refreshing_remaining_time() {
    let entered = Instant::now() - Duration::from_secs(10);
    let deadline = capped_stop_deadline(entered, Duration::from_secs(40)).unwrap();
    assert_eq!(deadline, entered + Duration::from_secs(30));
    let result = stop_operation(Some(deadline), engine::Cancellation::default(), |budget| {
        assert_eq!(budget.deadline(), deadline);
        Ok(stopped())
    })
    .unwrap();
    assert!(matches!(result, wire::Outcome::Observed { .. }));
}
#[test]
fn exhausted_or_overflowed_stop_budgets_do_not_enter_the_engine() {
    let failure = stop_operation(None, engine::Cancellation::default(), |_| {
        panic!("overflow engine entry")
    })
    .err()
    .unwrap();
    assert!(failure.dispatch == engine::Dispatch::NotDispatched);
    let expired = stop_operation(
        Some(Instant::now() - Duration::from_secs(1)),
        engine::Cancellation::default(),
        |_| panic!("late engine entry"),
    )
    .unwrap();
    assert!(matches!(
        expired,
        wire::Outcome::Error {
            code: wire::SafeCode::Deadline,
            dispatch: wire::Dispatch::NotDispatched
        }
    ));
    assert!(capped_stop_deadline(Instant::now(), Duration::MAX).is_none());
}
#[test]
fn cancelled_stop_before_entry_never_calls_the_engine() {
    let cancel = engine::Cancellation::default();
    cancel.cancel();
    let failure = stop_operation(
        Some(Instant::now() + Duration::from_secs(1)),
        cancel,
        |_| panic!("cancelled engine entry"),
    )
    .unwrap();
    assert!(matches!(
        failure,
        wire::Outcome::Error {
            code: wire::SafeCode::Cancelled,
            dispatch: wire::Dispatch::NotDispatched
        }
    ));
}
#[test]
fn cancellation_during_engine_return_cannot_publish_a_late_stopped_result() {
    let cancel = engine::Cancellation::default();
    let failure = stop_operation(
        Some(Instant::now() + Duration::from_secs(1)),
        cancel.clone(),
        |_| {
            cancel.cancel();
            Ok(stopped())
        },
    )
    .unwrap();
    assert!(matches!(
        failure,
        wire::Outcome::Error {
            code: wire::SafeCode::Cancelled,
            dispatch: wire::Dispatch::MayHaveDispatched
        }
    ));
}
#[test]
fn engine_uncertainty_remains_uncertain_through_the_stop_adapter() {
    let failure = stop_operation(
        Some(Instant::now() + Duration::from_secs(1)),
        engine::Cancellation::default(),
        |_| {
            Err(engine::Error {
                code: engine::ErrorCode::Native,
                dispatch: engine::Dispatch::MayHaveDispatched,
            })
        },
    )
    .err()
    .unwrap();
    assert!(
        failure.code == engine::ErrorCode::Native
            && failure.dispatch == engine::Dispatch::MayHaveDispatched
    );
}

#[test]
fn cancellation_after_a_definitive_engine_rejection_preserves_not_dispatched_evidence() {
    let cancel = engine::Cancellation::default();
    let outcome = stop_operation(
        Some(Instant::now() + Duration::from_secs(1)),
        cancel.clone(),
        |_| {
            cancel.cancel();
            Err(engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            })
        },
    )
    .unwrap();
    assert!(matches!(
        outcome,
        wire::Outcome::Error {
            code: wire::SafeCode::Cancelled,
            dispatch: wire::Dispatch::NotDispatched
        }
    ));
}
