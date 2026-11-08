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

fn running(child: crate::OwnerIdentity) -> Observation {
    Observation {
        state: crate::ObservedState::Running,
        pid_identity: Some((child.pid, child.birth)),
        configuration: None,
        resources: None,
    }
}

#[test]
fn source_gate_requires_original_enrollment_and_exact_receipt_and_birth() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = engine
        .runtime_boots
        .reserve(&receipt, &engine.jobs)
        .unwrap();
    assert_eq!(
        owned
            .source_quiescent(&receipt, (1, 1), &epoch)
            .unwrap_err()
            .code,
        ErrorCode::Ownership
    );
    owned
        .enroll(
            crate::epoch::tests::complete_model(epoch.begin_boot(&receipt.name).unwrap()),
            &epoch,
        )
        .unwrap();
    let child = owned.enrolled().unwrap().child();
    let counts = engine.jobs.counts();
    for pid in [(child.pid + 1, child.birth), (child.pid, child.birth + 1)] {
        assert_eq!(
            owned
                .source_quiescent(&receipt, pid, &epoch)
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
    }
    let mut foreign = receipt.clone();
    foreign.incarnation = "f".repeat(32);
    assert!(owned
        .source_quiescent(&foreign, (child.pid, child.birth), &epoch)
        .is_err());
    // The synthetic PID has no live original actor. Its row/enrollment cannot
    // grant a running source, retire the registry or release metadata.
    assert!(!owned
        .source_quiescent(&receipt, (child.pid, child.birth), &epoch)
        .unwrap());
    assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
    assert_eq!(engine.jobs.counts().branch_metadata, counts.branch_metadata);
}

#[test]
fn readiness_retries_only_probes_and_rechecks_the_original_enrollment_after_success() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let child = owned.enrolled().unwrap().child();
    let observation = running(child);
    let probes = Cell::new(0);
    let snapshots = Cell::new(0);
    let deadline = budget();
    let counts = engine.jobs.counts();
    let after = wait_until_ready(
        &deadline,
        || {
            snapshots.set(snapshots.get() + 1);
            owned.verify_running(&receipt, &observation, Some(child.pid))?;
            Ok(observation.clone())
        },
        |attempt| {
            assert!(attempt.deadline <= deadline.deadline);
            probes.set(probes.get() + 1);
            if probes.get() < 3 {
                Err(Error::uncertain(ErrorCode::Native))
            } else {
                Ok(())
            }
        },
    )
    .unwrap();
    assert_eq!(after, observation);
    assert_eq!(probes.get(), 3);
    assert_eq!(snapshots.get(), 4);
    assert_eq!(engine.jobs.counts().branch_metadata, counts.branch_metadata);
    assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
}

#[test]
fn readiness_rejects_replacement_stopped_missing_and_foreign_identity_without_probe() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let child = owned.enrolled().unwrap().child();
    let original = running(child);
    let mut cases = Vec::new();
    for state in [
        crate::ObservedState::Stopped,
        crate::ObservedState::Missing,
        crate::ObservedState::IdentityUnknown,
        crate::ObservedState::Unreachable,
    ] {
        let mut changed = original.clone();
        changed.state = state;
        cases.push(changed);
    }
    let mut replaced = original.clone();
    replaced.pid_identity = Some((child.pid, child.birth + 1));
    cases.push(replaced);
    for changed in cases {
        let error = wait_until_ready(
            &budget(),
            || {
                owned.verify_running(&receipt, &changed, Some(child.pid))?;
                Ok(changed.clone())
            },
            |_| panic!("invalid boot was probed"),
        )
        .unwrap_err();
        assert_eq!(error, Error::uncertain(ErrorCode::Ownership));
    }
    assert!(owned.verify_running(&receipt, &original, None).is_err());
    assert!(owned
        .verify_running(&receipt, &original, Some(child.pid + 1))
        .is_err());
    let mut foreign = receipt.clone();
    foreign.owner_token = "different-owner".into();
    assert!(owned
        .verify_running(&foreign, &original, Some(child.pid))
        .is_err());
}

#[test]
fn readiness_cancel_and_late_success_keep_original_authority_and_metadata() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let original = running(owned.enrolled().unwrap().child());
    let counts = engine.jobs.counts();
    for succeeds in [false, true] {
        let deadline = budget();
        let probes = Cell::new(0);
        let error = wait_until_ready(
            &deadline,
            || Ok(original.clone()),
            |_| {
                probes.set(probes.get() + 1);
                deadline.cancel.cancel();
                if succeeds {
                    Ok(())
                } else {
                    Err(Error::uncertain(ErrorCode::Native))
                }
            },
        )
        .unwrap_err();
        assert_eq!(error, Error::uncertain(ErrorCode::State));
        assert_eq!(probes.get(), 1);
        assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
        assert_eq!(engine.jobs.counts().branch_metadata, counts.branch_metadata);
    }
}

#[test]
fn readiness_does_not_retry_protocol_identity_or_admission_errors() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let original = running(owned.enrolled().unwrap().child());
    for code in [
        ErrorCode::Unsupported,
        ErrorCode::Admission,
        ErrorCode::Ownership,
        ErrorCode::Io,
    ] {
        let calls = Cell::new(0);
        let error = wait_until_ready(
            &budget(),
            || Ok(original.clone()),
            |_| {
                calls.set(calls.get() + 1);
                Err(Error::uncertain(code))
            },
        )
        .unwrap_err();
        assert_eq!(calls.get(), 1);
        assert_eq!(error, Error::uncertain(code));
        assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
    }
}

#[test]
fn readiness_never_refreshes_deadline_or_accepts_identity_change_during_ping() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let original = running(owned.enrolled().unwrap().child());
    let deadline = ReadBudget::new(
        std::time::Duration::from_millis(60),
        crate::Cancellation::default(),
    )
    .unwrap();
    let expires = deadline.deadline;
    let error = wait_until_ready(
        &deadline,
        || Ok(original.clone()),
        |attempt| {
            assert!(attempt.deadline <= expires);
            Err(Error::uncertain(ErrorCode::Native))
        },
    )
    .unwrap_err();
    assert_eq!(error, Error::uncertain(ErrorCode::State));
    assert_eq!(deadline.deadline, expires);
    let snapshots = Cell::new(0);
    let error = wait_until_ready(
        &budget(),
        || {
            snapshots.set(snapshots.get() + 1);
            let mut observation = original.clone();
            if snapshots.get() > 1 {
                observation.pid_identity = None;
            }
            Ok(observation)
        },
        |_| Ok(()),
    )
    .unwrap_err();
    assert_eq!(error, Error::uncertain(ErrorCode::Ownership));
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
fn failed_created_boot_with_original_exited_enrollment_can_enter_normal_fenced_cleanup() {
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = enrolled(&engine, &receipt, &epoch);
    let counts = engine.jobs.counts();
    let mut row = engine.record(&receipt).unwrap();
    row.state = smolvm::config::RecordState::Created;
    owned.verify_before(&receipt, &row).unwrap();
    for partial in [
        (Some(owned.enrolled().unwrap().child().pid), None),
        (None, Some(1)),
    ] {
        let mut crossed = row.clone();
        crossed.pid = partial.0;
        crossed.pid_start_time = partial.1;
        assert!(owned.verify_before(&receipt, &crossed).is_err());
    }
    let before = row.clone();
    owned
        .call(&receipt, &epoch, None, &budget(), || {
            assert!(!epoch.quiescent_for(&receipt.name).unwrap());
            assert!(epoch
                .collect_enrolled(&receipt.name, owned.enrolled().unwrap())
                .is_err());
            row.state = smolvm::config::RecordState::Stopped;
            Ok(())
        })
        .unwrap();
    let mut stopped = before;
    stopped.state = smolvm::config::RecordState::Stopped;
    verify_stopped(&receipt, &stopped, &row, None).unwrap();
    assert_eq!(engine.jobs.counts(), counts);
    assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
    owned.collected(&receipt, &epoch, &budget()).unwrap();
}

#[test]
fn created_row_without_original_enrollment_or_with_a_live_original_actor_has_no_cleanup_authority()
{
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let owned = engine
        .runtime_boots
        .reserve(&receipt, &engine.jobs)
        .unwrap();
    let mut row = engine.record(&receipt).unwrap();
    row.state = smolvm::config::RecordState::Created;
    assert!(owned.verify_before(&receipt, &row).is_err());
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
    assert!(owned.verify_before(&receipt, &row).is_err());
    row.pid = Some(actor.pid);
    row.pid_start_time = Some(actor.birth);
    assert!(owned.verify_before(&receipt, &row).is_err());
    assert!(engine.runtime_boots.contains(&receipt.name).unwrap());
    // This live identity is observed only. No SDK closure or signal runs.
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

#[cfg(target_os = "linux")]
#[test]
fn failed_created_child_normal_exit_keeps_wait_status_for_sdk_collection() {
    use std::{
        io::Write,
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    let (_root, engine, receipt, _actors, epoch) = fixture();
    let mut child = Command::new("/bin/sh")
        .args(["-c", "read release; exit 23"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let actor = crate::OwnerIdentity {
        pid: child.id() as i32,
        birth: smolvm::process::process_start_time(child.id() as i32).unwrap(),
        uid: unsafe { libc::geteuid() },
    };
    let owned = engine
        .runtime_boots
        .reserve(&receipt, &engine.jobs)
        .unwrap();
    owned
        .enroll(
            crate::epoch::tests::complete_model_with_child(
                epoch.begin_boot(&receipt.name).unwrap(),
                actor,
            ),
            &epoch,
        )
        .unwrap();
    let mut row = engine.record(&receipt).unwrap();
    row.state = smolvm::config::RecordState::Created;
    assert!(owned.verify_before(&receipt, &row).is_err());
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"normal release\n")
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while smolvm::process::is_alive(actor.pid) {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    owned.verify_before(&receipt, &row).unwrap();
    assert_eq!(
        smolvm::process::process_start_time(actor.pid),
        Some(actor.birth)
    );
    owned
        .call(&receipt, &epoch, Some(actor.pid), &budget(), || {
            assert!(!epoch.quiescent_for(&receipt.name).unwrap());
            assert_eq!(child.wait().unwrap().code(), Some(23));
            Ok(())
        })
        .unwrap();
    owned.collected(&receipt, &epoch, &budget()).unwrap();
}

#[test]
fn bounded_boot_membership_refuses_a_busy_registry_without_waiting_or_minting_ownership() {
    let registry = Registry::default();
    let held = registry.0.lock().unwrap();
    assert_eq!(
        registry.try_contains("inert-model-child").unwrap_err().code,
        ErrorCode::Conflict
    );
    drop(held);
    assert!(!registry.try_contains("inert-model-child").unwrap());
}
