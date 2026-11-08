//! Private original actor/cache/file/SQLite models only. No manager, SDK
//! lifecycle, VM, process loss or live persistence interruption.
use super::*;
use crate::branch::retention::resolution::partial_disposal::{tests::Model, RetainedCleanup};
use std::cell::Cell;

type Cache = Arc<Mutex<RetainedCleanup>>;
fn staged(mode: u8) -> (Model, PartialBranchDisposalCleanupRequest, Cache) {
    let model = Model::new(mode);
    model.enter();
    let mut request = PartialBranchDisposalCleanupRequest {
        disposal_request: model.intent.request.clone(),
        operation_id: "unused-absence-model".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    request.request_sha256 = request.digest().unwrap();
    let cache = Arc::new(Mutex::new(RetainedCleanup::new(&request).unwrap()));
    model
        .original
        .engine
        .db
        .remove_vm(&model.original.child.name)
        .unwrap();
    std::fs::remove_dir_all(&model.plan.child.path).unwrap();
    (model, request, cache)
}
fn observe(
    model: &Model,
    request: &PartialBranchDisposalCleanupRequest,
    cache: &Cache,
    authority: impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
) -> Result<Option<PartialBranchDisposal>> {
    model
        .original
        .resolution
        .unattempted_cleanup_absence_checked(
            &model.original.engine,
            request,
            &model.epoch,
            |work, intent| {
                assert!(work.boot.is_none());
                if *intent != model.intent {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                Ok((model.enrollment.clone(), RetainedCleanup::handoff(cache)?))
            },
            authority,
        )
}
fn assert_pending(model: &Model, counts: crate::jobs::Counts, main: &[u8]) {
    assert_eq!(model.original.counts(), counts);
    assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
    assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
    assert!(!model
        .original
        .engine
        .branch_retention
        .entries
        .lock()
        .unwrap()
        .is_empty());
    assert!(model
        .original
        .engine
        .branch_retention
        .partial_disposed
        .lock()
        .unwrap()
        .is_empty());
    assert!(model
        .original
        .engine
        .observation_gate(&model.original.source.name)
        .unwrap()
        .try_lock()
        .is_err());
    for suffix in ["cleanup.json", "cleanup-unneeded.json"] {
        assert!(!model.ledger().path().with_extension(suffix).exists());
    }
}

#[test]
fn all_original_partial_heads_complete_only_positive_absence_then_acknowledge_exact_unused_cleanup()
{
    for mode in 0..4 {
        let (mut model, request, cache) = staged(mode);
        let counts = model.original.counts();
        let source =
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap();
        let source_row = crate::material::hash(
            &model
                .original
                .engine
                .db
                .get_vm(&model.original.source.name)
                .unwrap(),
        )
        .unwrap();
        let observations = Cell::new(0);
        let proof = observe(&model, &request, &cache, |p, s, after| {
            assert!(after);
            let observer = model
                .original
                .engine
                .jobs
                .acquire(crate::jobs::Demand::observation())?;
            drop(observer);
            observations.set(observations.get() + 1);
            model.original.source_authority(p, s, after)
        })
        .unwrap()
        .unwrap();
        assert_eq!(observations.get(), 2);
        assert!(proof.completion == PartialBranchDisposalCompletion::ResolvedAbsent);
        assert!(proof.request == request.disposal_request && proof.release == model.intent.release);
        assert_eq!(model.original.counts(), counts);
        assert!(model
            .original
            .engine
            .observation_gate(&model.original.source.name)
            .unwrap()
            .try_lock()
            .is_err());
        assert_eq!(
            crate::material::hash(
                &model
                    .original
                    .engine
                    .db
                    .get_vm(&model.original.source.name)
                    .unwrap()
            )
            .unwrap(),
            source_row
        );
        assert!(model
            .original
            .engine
            .db
            .get_vm(&model.original.child.name)
            .unwrap()
            .is_none());
        assert_eq!(
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap(),
            source
        );
        let (record, _) = model.ledger().read().unwrap().unwrap();
        assert!(record.stage == Stage::ResolvedAbsent && record.proof == Some(proof.clone()));
        assert!(record.intent == model.intent);
        assert!(!model
            .ledger()
            .path()
            .with_extension("cleanup.json")
            .exists());
        assert!(observe(&model, &request, &cache, |_, _, _| panic!(
            "terminal proof cannot repeat absence completion"
        ))
        .unwrap()
        .is_none());
        drop(model.original.entry.take());
        model
            .archive_with_cleanup_handoff(&proof, RetainedCleanup::handoff(&cache).unwrap())
            .unwrap();
        drop(cache);
        let after = model.original.counts();
        let budget = ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        let ack = model
            .original
            .engine
            .resolve_unneeded_partial_cleanup(&request, &budget)
            .unwrap()
            .unwrap();
        assert!(ack.disposal == proof);
        ack.matches_request(&request).unwrap();
        assert_eq!(model.original.counts(), after);
        assert!(model.plan.source.path.exists() && model.plan.snapshot.path.exists());
    }
}

#[test]
fn bare_absence_without_exact_original_enrolled_unused_cache_cannot_publish_disposal() {
    for cache_fact in [CleanupHandoff::NeverEnrolled, CleanupHandoff::Unavailable] {
        let (model, request, _) = staged(1);
        let counts = model.original.counts();
        let main = std::fs::read(model.ledger().path()).unwrap();
        let result = model
            .original
            .resolution
            .unattempted_cleanup_absence_checked(
                &model.original.engine,
                &request,
                &model.epoch,
                |_, _| {
                    Ok((
                        model.enrollment.clone(),
                        match &cache_fact {
                            CleanupHandoff::NeverEnrolled => CleanupHandoff::NeverEnrolled,
                            _ => CleanupHandoff::Unavailable,
                        },
                    ))
                },
                |_, _, _| panic!("unproven origin must not inspect source"),
            );
        assert!(result.unwrap().is_none());
        assert_pending(&model, counts, &main);
    }
}

#[test]
fn crossed_cleanup_request_missing_owner_or_shared_cache_keeps_the_original_pending_action() {
    let (model, request, cache) = staged(1);
    let counts = model.original.counts();
    let main = std::fs::read(model.ledger().path()).unwrap();
    let mut crossed = request.clone();
    crossed.operation_id = "crossed-unused-absence".into();
    crossed.request_sha256 = crossed.digest().unwrap();
    assert!(observe(&model, &crossed, &cache, |_, _, _| panic!(
        "crossed cache cannot inspect"
    ))
    .is_err());
    let shared = cache.clone();
    assert!(observe(&model, &request, &cache, |_, _, _| panic!(
        "shared cache cannot inspect"
    ))
    .is_err());
    drop(shared);
    assert!(model
        .original
        .resolution
        .unattempted_cleanup_absence_checked(
            &model.original.engine,
            &request,
            &model.epoch,
            |_, _| Err(Error::before(ErrorCode::Ownership)),
            |_, _, _| panic!("missing owner cannot inspect")
        )
        .is_err());
    assert_pending(&model, counts, &main);
}

#[test]
fn child_rows_reservations_recreated_paths_handles_and_changed_source_prevent_absent_completion() {
    for case in 0..6 {
        let (model, request, cache) = staged(1);
        match case {
            0 => model
                .original
                .engine
                .db
                .insert_vm(&model.original.child.name, &model.original.child)
                .unwrap(),
            1 => {
                assert!(model
                    .original
                    .engine
                    .db
                    .reserve_vm_create(&model.original.child.name, "new-reservation")
                    .unwrap());
            }
            2 => std::fs::create_dir(&model.plan.child.path).unwrap(),
            3 => {
                std::os::unix::fs::symlink(&model.plan.source.path, &model.plan.child.path).unwrap()
            }
            4 => model
                .original
                .engine
                .track_handle(model.intent.head())
                .unwrap(),
            _ => {
                model
                    .original
                    .engine
                    .db
                    .update_vm(&model.original.source.name, |row| row.cpus += 1)
                    .unwrap();
            }
        }
        let counts = model.original.counts();
        let main = std::fs::read(model.ledger().path()).unwrap();
        assert!(observe(&model, &request, &cache, |p, s, a| model
            .original
            .source_authority(p, s, a))
        .is_err());
        assert_pending(&model, counts, &main);
    }
}

#[test]
fn both_source_observations_are_required_and_interference_never_publishes_terminal_proof() {
    for case in 0..3 {
        let (model, request, cache) = staged(1);
        let counts = model.original.counts();
        let main = std::fs::read(model.ledger().path()).unwrap();
        let observed = Cell::new(0);
        let result = observe(&model, &request, &cache, |p, s, a| {
            model.original.source_authority(p, s, a)?;
            observed.set(observed.get() + 1);
            if observed.get() == 1 {
                match case {
                    0 => model
                        .original
                        .engine
                        .db
                        .insert_vm(&model.original.child.name, &model.original.child)
                        .unwrap(),
                    1 => {
                        model
                            .original
                            .engine
                            .db
                            .update_vm(&model.original.source.name, |row| row.cpus += 1)
                            .unwrap();
                    }
                    _ => std::fs::create_dir(&model.plan.child.path).unwrap(),
                }
            }
            Ok(())
        });
        assert!(result.is_err());
        assert_eq!(observed.get(), 1);
        assert_pending(&model, counts, &main);
    }
}

#[test]
fn original_unused_provenance_is_rechecked_after_each_observation_before_publication() {
    for fail_after in [1, 2] {
        let (model, request, cache) = staged(1);
        let calls = Cell::new(0);
        let counts = model.original.counts();
        let main = std::fs::read(model.ledger().path()).unwrap();
        let result = model
            .original
            .resolution
            .unattempted_cleanup_absence_checked(
                &model.original.engine,
                &request,
                &model.epoch,
                |_, _| {
                    Ok((
                        model.enrollment.clone(),
                        if calls.get() >= fail_after {
                            CleanupHandoff::Unavailable
                        } else {
                            RetainedCleanup::handoff(&cache)?
                        },
                    ))
                },
                |p, s, a| {
                    model.original.source_authority(p, s, a)?;
                    calls.set(calls.get() + 1);
                    Ok(())
                },
            );
        assert!(result.is_err());
        assert_eq!(calls.get(), fail_after);
        assert_pending(&model, counts, &main);
    }
}

#[test]
fn active_work_or_conflicting_cleanup_history_cannot_become_unused_completion() {
    for case in 0..3 {
        let (model, request, cache) = staged(1);
        let active = Arc::new(());
        if case == 0 {
            model.original.entry().work.lock().unwrap().worker = Arc::downgrade(&active)
        } else {
            std::fs::write(
                model.ledger().path().with_extension(if case == 1 {
                    "cleanup.json"
                } else {
                    "cleanup-unneeded.json"
                }),
                b"foreign",
            )
            .unwrap()
        }
        let counts = model.original.counts();
        let main = std::fs::read(model.ledger().path()).unwrap();
        assert!(observe(&model, &request, &cache, |_, _, _| panic!(
            "conflicting history cannot inspect source"
        ))
        .is_err());
        assert_eq!(model.original.counts(), counts);
        assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
        assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
    }
}

#[test]
fn snapshot_substitution_foreign_epoch_and_cancelled_budget_preserve_work_and_backing() {
    let (model, request, cache) = staged(1);
    let counts = model.original.counts();
    let main = std::fs::read(model.ledger().path()).unwrap();
    let actors = tempfile::tempdir().unwrap();
    let (_, _, epoch) = crate::epoch::tests::fixture_for_binding_and_epoch(
        &actors.path().canonicalize().unwrap(),
        None,
        model.original.engine.binding().clone(),
        "f".repeat(32),
    );
    assert!(model
        .original
        .resolution
        .unattempted_cleanup_absence_checked(
            &model.original.engine,
            &request,
            &epoch,
            |_, _| Ok((model.enrollment.clone(), RetainedCleanup::handoff(&cache)?)),
            |_, _, _| panic!("foreign epoch cannot inspect source")
        )
        .is_err());
    assert_pending(&model, counts, &main);
    model.original.resolution.budget.cancel.cancel();
    assert!(observe(&model, &request, &cache, |_, _, _| panic!(
        "cancelled budget cannot inspect source"
    ))
    .is_err());
    assert_pending(&model, counts, &main);
    let (model, request, cache) = staged(1);
    std::fs::rename(
        &model.plan.snapshot.path,
        model.plan.snapshot.path.with_extension("saved-model"),
    )
    .unwrap();
    std::fs::create_dir(&model.plan.snapshot.path).unwrap();
    let counts = model.original.counts();
    let main = std::fs::read(model.ledger().path()).unwrap();
    assert!(observe(&model, &request, &cache, |_, _, _| panic!(
        "substituted snapshot cannot inspect source"
    ))
    .is_err());
    assert_pending(&model, counts, &main);
}

#[test]
fn exhausted_material_control_and_expired_deadline_do_not_enter_absence_observation() {
    let (mut model, request, cache) = staged(1);
    let control = model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    let counts = model.original.counts();
    let main = std::fs::read(model.ledger().path()).unwrap();
    assert!(observe(&model, &request, &cache, |_, _, _| panic!(
        "occupied material control cannot inspect"
    ))
    .is_err());
    assert_pending(&model, counts, &main);
    let observer = model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::observation())
        .unwrap();
    drop((observer, control));
    model.original.resolution.budget.deadline =
        std::time::Instant::now() - std::time::Duration::from_millis(1);
    let counts = model.original.counts();
    assert!(observe(&model, &request, &cache, |_, _, _| panic!(
        "expired deadline cannot inspect"
    ))
    .is_err());
    assert_pending(&model, counts, &main);
}

#[test]
fn crossed_primary_after_observation_is_preserved_and_publication_failure_stays_uncertain() {
    let (model, request, cache) = staged(1);
    let calls = Cell::new(0);
    let counts = model.original.counts();
    let foreign = std::cell::RefCell::new(None);
    let result = observe(&model, &request, &cache, |p, s, a| {
        model.original.source_authority(p, s, a)?;
        calls.set(calls.get() + 1);
        if calls.get() == 2 {
            let ledger = model.ledger();
            let (mut record, version) = ledger.read()?.unwrap();
            record.intent.request.operation_id = "foreign-primary-model".into();
            record.intent.request.request_sha256 = record.intent.request.digest()?;
            ledger.write(&record, Some(version))?;
            *foreign.borrow_mut() = Some(std::fs::read(ledger.path()).unwrap());
        }
        Ok(())
    });
    assert!(matches!(
        result,
        Err(Error {
            dispatch: crate::Dispatch::MayHaveDispatched,
            ..
        })
    ));
    assert_eq!(calls.get(), 2);
    assert_eq!(
        std::fs::read(model.ledger().path()).unwrap(),
        foreign.into_inner().unwrap()
    );
    assert_eq!(model.original.counts(), counts);
    assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
    assert!(!model
        .ledger()
        .path()
        .with_extension("cleanup-unneeded.json")
        .exists());
    assert!(model
        .original
        .engine
        .observation_gate(&model.original.source.name)
        .unwrap()
        .try_lock()
        .is_err());
}
