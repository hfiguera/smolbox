//! Inert private files, SQLite rows and opaque model actors. No SDK manager,
//! SDK delete, VMM, live persistence interruption or process-loss campaign.
use super::super::tests::Model;
use super::*;
use std::cell::Cell;
use std::os::unix::fs::PermissionsExt;

fn domain(model: &Model) -> Arc<crate::domain::DomainGuard> {
    model.original.engine.domain.clone()
}
fn budget() -> ReadBudget {
    ReadBudget::new(
        std::time::Duration::from_secs(30),
        crate::Cancellation::default(),
    )
    .unwrap()
}
fn entry_file(model: &Model) -> Ledger {
    file(domain(model), &model.intent).unwrap()
}
fn row(model: &Model) -> String {
    crate::material::hash(
        &model
            .original
            .engine
            .db
            .get_vm(&model.original.child.name)
            .unwrap()
            .unwrap(),
    )
    .unwrap()
}

#[test]
fn first_call_continuation_finishes_the_same_original_disposal_without_new_intent_or_charge_release(
) {
    for mode in 0..4 {
        let model = Model::new(mode);
        model.enter();
        let main = std::fs::read(model.ledger().path()).unwrap();
        let counts = model.original.counts();
        model.application().qualify_unentered().unwrap();
        let (record, _) = model.ledger().read().unwrap().unwrap();
        assert!(
            matches!(select_disposal(Some((&model.intent, true)), Some(&record), &model.intent.request, false).unwrap(), Selected::Published(intent) if intent == model.intent)
        );
        assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
        let calls = Cell::new(0);
        model
            .application()
            .run(|name, path| {
                assert_eq!(name, model.intent.head().name);
                assert_eq!(path, model.intent.child.path);
                calls.set(calls.get() + 1);
                model.delete()
            })
            .unwrap();
        let proof = model
            .finish(PartialBranchDisposalCompletion::Deleted)
            .unwrap();
        assert!(proof.request == model.intent.request && proof.release == model.intent.release);
        assert_eq!(calls.get(), 1);
        assert_eq!(model.original.counts(), counts);
        assert!(model.plan.source.path.exists() && model.plan.snapshot.path.exists());
        assert!(!model.plan.child.path.exists());
        assert!(model
            .application()
            .run(|_, _| panic!("completed first call cannot repeat"))
            .is_err());
    }
}

#[test]
fn published_original_heads_can_qualify_repeatedly_then_enter_sdk_exactly_once() {
    for mode in 0..4 {
        let model = Model::new(mode);
        model.enter();
        let counts = model.original.counts();
        let before = row(&model);
        let source =
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap();
        let main = std::fs::read(model.ledger().path()).unwrap();
        for _ in 0..2 {
            model.application().qualify_unentered().unwrap();
            let (record, version) = entry_file(&model)
                .read_record::<EntryRecord>()
                .unwrap()
                .unwrap();
            assert!(record.stage == EntryStage::Prepared);
            assert_eq!(
                record.disposal_sha256,
                crate::material::hash(&model.intent).unwrap()
            );
            entry_file(&model)
                .synchronize_record::<EntryRecord>(&version)
                .unwrap();
            assert_eq!(row(&model), before);
            assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
            assert_eq!(model.original.counts(), counts);
        }
        let calls = Cell::new(0);
        // Synthetic SDK callback intentionally leaves the row/directory intact.
        // Its error must still spend entry and forbid any second call.
        let error = model
            .application()
            .run(|_, _| {
                let (record, _) = entry_file(&model).read_record::<EntryRecord>()?.unwrap();
                assert!(record.stage == EntryStage::Entered);
                assert_eq!(row(&model), model.intent.stopped_sha256);
                calls.set(calls.get() + 1);
                Err(Error::uncertain(ErrorCode::Native))
            })
            .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        assert!(model.application().qualify_unentered().is_err());
        assert!(model
            .application()
            .run(|_, _| {
                calls.set(calls.get() + 1);
                Ok(())
            })
            .is_err());
        assert_eq!(calls.get(), 1);
        assert_eq!(model.original.counts(), counts);
        assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
        assert_eq!(
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap(),
            source
        );
    }
}

#[test]
fn missing_or_rolled_back_published_entry_and_new_cache_cannot_reconstruct_sdk_authority() {
    for case in 0..4 {
        let model = Model::new(1);
        model.enter();
        model.application().qualify_unentered().unwrap();
        let prepared = std::fs::read(&entry_file(&model).path).unwrap();
        if case >= 2 {
            model
                .application()
                .run(|_, _| Err(Error::uncertain(ErrorCode::Native)))
                .unwrap_err();
        }
        match case {
            0 => std::fs::remove_file(&entry_file(&model).path).unwrap(),
            1 => {
                // A sidecar cannot initialize a second missing original cache.
                let mut other = RetainedSdkEntry::new(&model.intent).unwrap();
                assert!(other
                    .prepare(domain(&model), &model.intent, &budget())
                    .is_err());
                continue;
            }
            2 => std::fs::write(&entry_file(&model).path, &prepared).unwrap(),
            _ => std::fs::remove_file(&entry_file(&model).path).unwrap(),
        }
        let before = row(&model);
        assert!(model.application().qualify_unentered().is_err());
        assert!(model
            .application()
            .run(|_, _| panic!("missing/rolled-back entry cannot delete"))
            .is_err());
        assert_eq!(row(&model), before);
        assert!(model.plan.child.path.exists());
    }
}

#[test]
fn crossed_original_intent_cannot_obtain_entry_from_a_legacy_primary_record() {
    let model = Model::new(1);
    model.enter();
    assert!(!entry_file(&model).path.exists());
    let main = std::fs::read(model.ledger().path()).unwrap();
    let mut foreign = model.intent.clone();
    foreign.request.operation_id = "crossed-original-disposal".into();
    foreign.request.request_sha256 = foreign.request.digest().unwrap();
    let mut cached = RetainedSdkEntry::new(&foreign).unwrap();
    assert!(cached
        .prepare(domain(&model), &model.intent, &budget())
        .is_err());
    assert!(!entry_file(&model).path.exists());
    assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
}

#[test]
fn uncertain_entry_publication_spends_cache_before_io_and_never_retries_sdk() {
    for stale in [false, true] {
        let model = Model::new(1);
        model.enter();
        model.application().qualify_unentered().unwrap();
        let mut retained = model.sdk_entry.lock().unwrap();
        let error = retained
            .enter_with(
                domain(&model),
                &model.intent,
                &budget(),
                |ledger, record, version| {
                    assert!(record.stage == EntryStage::Entered);
                    if stale {
                        let (prepared, _) = ledger.read_record::<EntryRecord>()?.unwrap();
                        // Deterministic private file replacement before the real writer's
                        // stale-version check; no VM or live persistence interruption.
                        std::fs::remove_file(&ledger.path).unwrap();
                        ledger.write_record(&prepared, None)?;
                        ledger.write_record(record, Some(version))
                    } else {
                        Err(Error::before(ErrorCode::Io))
                    }
                },
            )
            .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        assert!(retained.record.stage == EntryStage::Entered);
        drop(retained);
        assert!(model.application().qualify_unentered().is_err());
        assert!(model
            .application()
            .run(|_, _| panic!("uncertain entry cannot retry SDK"))
            .is_err());
        assert!(
            entry_file(&model)
                .read_record::<EntryRecord>()
                .unwrap()
                .unwrap()
                .0
                .stage
                == EntryStage::Prepared
        );
    }
}

#[test]
fn prepared_publication_can_resynchronize_only_the_original_cached_attempt() {
    let model = Model::new(1);
    model.enter();
    let ledger = entry_file(&model);
    let record = EntryRecord::new(&model.intent).unwrap();
    ledger.write_record(&record, None).unwrap();
    let mut retained = model.sdk_entry.lock().unwrap();
    assert!(retained
        .prepare(domain(&model), &model.intent, &budget())
        .is_err());
    retained.attempted = true; // Explicit inert projection of a visible failed sync.
    retained
        .prepare(domain(&model), &model.intent, &budget())
        .unwrap();
    assert!(retained.published && retained.record.stage == EntryStage::Prepared);
    let bytes = std::fs::read(&ledger.path).unwrap();
    retained
        .prepare(domain(&model), &model.intent, &budget())
        .unwrap();
    assert_eq!(std::fs::read(&ledger.path).unwrap(), bytes);
}

#[test]
fn strict_private_entry_records_reject_wrong_context_modes_links_and_excess_bytes() {
    for case in 0..8 {
        let model = Model::new(1);
        model.enter();
        model.application().qualify_unentered().unwrap();
        let ledger = entry_file(&model);
        let original = std::fs::read(&ledger.path).unwrap();
        match case {
            0 => std::fs::set_permissions(&ledger.path, std::fs::Permissions::from_mode(0o640))
                .unwrap(),
            1 | 2 => {
                let saved = ledger.path.with_extension("preserved-model");
                std::fs::rename(&ledger.path, &saved).unwrap();
                if case == 1 {
                    std::os::unix::fs::symlink(saved, &ledger.path).unwrap();
                } else {
                    std::fs::hard_link(saved, &ledger.path).unwrap();
                }
            }
            3 => std::fs::write(&ledger.path, vec![b' '; 4097]).unwrap(),
            _ => {
                let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
                match case {
                    4 => value["schema"] = 2.into(),
                    5 => value["creation_key"] = "0".repeat(64).into(),
                    6 => value["disposal_sha256"] = "0".repeat(64).into(),
                    _ => value["extra"] = true.into(),
                }
                std::fs::write(&ledger.path, serde_json::to_vec(&value).unwrap()).unwrap();
            }
        }
        let before = row(&model);
        assert!(model.application().qualify_unentered().is_err());
        assert!(model
            .application()
            .run(|_, _| panic!("invalid protected entry cannot delete"))
            .is_err());
        assert_eq!(row(&model), before);
    }
}

#[test]
fn expired_cancelled_and_cached_cleanup_controls_do_not_publish_or_enter_sdk() {
    for case in 0..3 {
        let model = Model::new(1);
        model.enter();
        let mut app = model.application();
        if case == 0 {
            app.budget.deadline = std::time::Instant::now() - std::time::Duration::from_millis(1);
        } else if case == 1 {
            app.budget.cancel.cancel();
        } else {
            std::fs::write(
                model.ledger().path.with_extension("cleanup.json"),
                b"malformed-but-present",
            )
            .unwrap();
        }
        assert!(app.qualify_unentered().is_err());
        assert!(app
            .run(|_, _| panic!("spent/cleanup controls cannot enter SDK"))
            .is_err());
        assert!(!entry_file(&model).path.exists());
    }
}

#[test]
fn cancellation_after_entry_publication_keeps_spent_grant_and_cannot_become_sdk_retry() {
    let model = Model::new(1);
    model.enter();
    model.application().qualify_unentered().unwrap();
    let budget = budget();
    let mut retained = model.sdk_entry.lock().unwrap();
    let error = retained
        .enter_with(
            domain(&model),
            &model.intent,
            &budget,
            |ledger, record, version| {
                ledger.write_record(record, Some(version))?;
                budget.cancel.cancel();
                Ok(())
            },
        )
        .unwrap_err();
    assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
    assert!(retained.record.stage == EntryStage::Entered);
    assert!(
        entry_file(&model)
            .read_record::<EntryRecord>()
            .unwrap()
            .unwrap()
            .0
            .stage
            == EntryStage::Entered
    );
    drop(retained);
    assert!(model.application().qualify_unentered().is_err());
    assert!(model
        .application()
        .run(|_, _| panic!("cancelled entered grant cannot retry SDK"))
        .is_err());
    assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
}

#[test]
fn original_unused_sdk_cache_can_resynchronize_only_its_matching_visible_primary_without_entry() {
    for mode in 0..4 {
        let model = Model::new(mode);
        model.enter();
        let main = std::fs::read(model.ledger().path()).unwrap();
        let before = row(&model);
        let counts = model.original.counts();
        for _ in 0..2 {
            let sdk = model.sdk_entry.lock().unwrap();
            sdk.unpublished_primary(domain(&model), &model.intent, &budget())
                .unwrap();
            assert!(!sdk.attempted && !sdk.published && sdk.record.stage == EntryStage::Prepared);
            assert!(!entry_file(&model).path.exists());
            assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
            assert_eq!(row(&model), before);
            assert_eq!(model.original.counts(), counts);
        }
        // Successful resynchronization does not spend the original first entry.
        model.application().qualify_unentered().unwrap();
        model.application().run(|_, _| model.delete()).unwrap();
        let proof = model
            .finish(PartialBranchDisposalCompletion::Deleted)
            .unwrap();
        assert!(proof.request == model.intent.request);
    }
}

#[test]
fn attempted_or_entered_sdk_state_and_any_existing_entry_or_cleanup_file_refuse_primary_recovery() {
    for case in 0..5 {
        let model = Model::new(1);
        model.enter();
        match case {
            0 => model.application().qualify_unentered().unwrap(),
            1 => {
                model
                    .application()
                    .run(|_, _| Err(Error::uncertain(ErrorCode::Native)))
                    .unwrap_err();
            }
            2 => {
                entry_file(&model)
                    .write_record(&EntryRecord::new(&model.intent).unwrap(), None)
                    .unwrap();
            }
            3 => std::fs::write(&entry_file(&model).path, b"malformed").unwrap(),
            _ => std::fs::write(
                model.ledger().path.with_extension("cleanup.json"),
                b"present",
            )
            .unwrap(),
        }
        let before = row(&model);
        let main = std::fs::read(model.ledger().path()).unwrap();
        let counts = model.original.counts();
        let sdk = model.sdk_entry.lock().unwrap();
        assert!(sdk
            .unpublished_primary(domain(&model), &model.intent, &budget())
            .is_err());
        assert_eq!(row(&model), before);
        assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
        assert_eq!(model.original.counts(), counts);
    }
}

#[test]
fn missing_crossed_terminal_or_corrupt_primary_does_not_reconstruct_or_enter_sdk() {
    for case in 0..5 {
        let model = Model::new(1);
        model.enter();
        match case {
            0 => std::fs::remove_file(model.ledger().path()).unwrap(),
            1 => std::fs::write(model.ledger().path(), b"invalid").unwrap(),
            2 => {
                let (mut record, version) = model.ledger().read().unwrap().unwrap();
                record.intent.request.operation_id = "crossed-primary".into();
                record.intent.request.request_sha256 = record.intent.request.digest().unwrap();
                model.ledger().write(&record, Some(version)).unwrap();
            }
            3 | 4 => {
                // A valid terminal primary can never be reinterpreted as intent
                // publication whose SDK entry has not started.
                let (mut record, version) = model.ledger().read().unwrap().unwrap();
                let completion = if case == 3 {
                    PartialBranchDisposalCompletion::Deleted
                } else {
                    PartialBranchDisposalCompletion::ResolvedAbsent
                };
                record.stage = if case == 3 {
                    Stage::Deleted
                } else {
                    Stage::ResolvedAbsent
                };
                record.proof = Some(model.intent.proof(completion).unwrap());
                model.ledger().write(&record, Some(version)).unwrap();
            }
            _ => unreachable!(),
        }
        let before = std::fs::read(model.ledger().path()).ok();
        let sdk = model.sdk_entry.lock().unwrap();
        assert!(sdk
            .unpublished_primary(domain(&model), &model.intent, &budget())
            .is_err());
        assert!(!sdk.attempted && !sdk.published && sdk.record.stage == EntryStage::Prepared);
        assert!(!entry_file(&model).path.exists());
        assert_eq!(std::fs::read(model.ledger().path()).ok(), before);
    }
}

#[test]
fn cancelled_or_expired_primary_recovery_does_not_write_entry_or_spend_cached_grant() {
    for cancel in [false, true] {
        let model = Model::new(1);
        model.enter();
        let mut budget = budget();
        if cancel {
            budget.cancel.cancel();
        } else {
            budget.deadline = std::time::Instant::now() - std::time::Duration::from_millis(1);
        }
        let main = std::fs::read(model.ledger().path()).unwrap();
        let sdk = model.sdk_entry.lock().unwrap();
        assert!(sdk
            .unpublished_primary(domain(&model), &model.intent, &budget)
            .is_err());
        assert!(!sdk.attempted && !sdk.published && sdk.record.stage == EntryStage::Prepared);
        assert!(!entry_file(&model).path.exists());
        assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
    }
}
