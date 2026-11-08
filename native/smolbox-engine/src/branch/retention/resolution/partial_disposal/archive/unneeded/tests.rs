//! Inert original owner/actor/file/SQLite projections. No SDK manager or delete,
//! VMM, process loss, live persistence interruption or independent CLI race.
use super::super::super::tests::Model;
use super::*;
use std::os::unix::fs::PermissionsExt;

fn budget() -> ReadBudget {
    ReadBudget::new(
        std::time::Duration::from_secs(30),
        crate::Cancellation::default(),
    )
    .unwrap()
}
fn cleanup_request(model: &Model) -> PartialBranchDisposalCleanupRequest {
    let mut request = PartialBranchDisposalCleanupRequest {
        disposal_request: model.intent.request.clone(),
        operation_id: "unneeded-original-cleanup".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request
}
fn staged(mode: u8, resolved: bool, unused: bool) -> (Model, PartialBranchDisposalCleanupRequest) {
    let mut model = Model::new(mode);
    let proof = model.disposed(resolved);
    drop(model.original.entry.take());
    model.archive_with_cleanup_unused(&proof, unused).unwrap();
    let request = cleanup_request(&model);
    (model, request)
}
fn resolve(
    model: &Model,
    request: &PartialBranchDisposalCleanupRequest,
) -> Result<Option<PartialBranchDisposalCleanupUnneeded>> {
    model
        .original
        .engine
        .resolve_unneeded_partial_cleanup(request, &budget())
}
fn receipt_file(model: &Model, request: &PartialBranchDisposalCleanupRequest) -> Ledger {
    file(model.original.engine.domain.clone(), request).unwrap()
}

#[test]
fn all_original_heads_and_both_terminal_provenances_acknowledge_unneeded_cleanup_without_removal() {
    for mode in 0..4 {
        for resolved in [false, true] {
            let (model, request) = staged(mode, resolved, true);
            let counts = model.original.counts();
            let main = std::fs::read(model.ledger().path()).unwrap();
            let source =
                std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap();
            let proof = resolve(&model, &request).unwrap().unwrap();
            proof.matches_request(&request).unwrap();
            assert_eq!(
                proof.disposal.completion,
                if resolved {
                    PartialBranchDisposalCompletion::ResolvedAbsent
                } else {
                    PartialBranchDisposalCompletion::Deleted
                }
            );
            assert!(proof.disposal.release == model.intent.release);
            assert_eq!(model.original.counts(), counts);
            assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
            assert_eq!(
                std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap(),
                source
            );
            assert!(model.plan.snapshot.path.exists() && !model.plan.child.path.exists());
            let bytes = std::fs::read(&receipt_file(&model, &request).path).unwrap();
            assert!(resolve(&model, &request).unwrap() == Some(proof));
            assert_eq!(
                std::fs::read(&receipt_file(&model, &request).path).unwrap(),
                bytes
            );
        }
    }
}

#[test]
fn historical_unneeded_ack_does_not_inspect_recreated_names_or_require_live_source() {
    for initial in [false, true] {
        let (model, request) = staged(1, false, true);
        let proof = if initial {
            None
        } else {
            resolve(&model, &request).unwrap()
        };
        std::fs::remove_dir_all(&model.plan.source.path).unwrap();
        model
            .original
            .engine
            .db
            .remove_vm(&model.original.source.name)
            .unwrap();
        std::fs::create_dir(&model.plan.child.path).unwrap();
        std::fs::set_permissions(
            &model.plan.child.path,
            std::fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        let preserved = model.plan.child.path.join("new-occupant");
        std::fs::write(&preserved, b"keep").unwrap();
        model
            .original
            .engine
            .db
            .insert_vm(&model.original.child.name, &model.original.child)
            .unwrap();
        model
            .original
            .engine
            .track_handle(model.intent.head())
            .unwrap();
        let counts = model.original.counts();
        let actual = resolve(&model, &request).unwrap().unwrap();
        assert!(actual.disposal.request == request.disposal_request);
        if let Some(proof) = proof {
            assert!(actual == proof);
        }
        assert_eq!(std::fs::read(preserved).unwrap(), b"keep");
        assert!(model
            .original
            .engine
            .db
            .get_vm(&model.original.child.name)
            .unwrap()
            .is_some());
        assert_eq!(model.original.counts(), counts);
    }
}

#[test]
fn unproven_archive_or_contended_original_owner_cannot_mint_acknowledgement() {
    let (model, request) = staged(1, false, false);
    assert!(resolve(&model, &request).unwrap().is_none());
    assert!(!receipt_file(&model, &request).path.exists());
    let model = Model::new(1);
    model.enter();
    let request = cleanup_request(&model);
    // This inert fixture still holds its exclusive original resolution token;
    // the public recovery selector must not borrow that owner a second time.
    assert!(matches!(
        resolve(&model, &request),
        Err(Error {
            code: ErrorCode::Conflict,
            dispatch: crate::Dispatch::NotDispatched
        })
    ));
    assert!(!receipt_file(&model, &request).path.exists());
}

#[test]
fn existing_cleanup_or_missing_crossed_original_history_keeps_unused_ack_unavailable() {
    for case in 0..4 {
        let (model, request) = staged(1, true, true);
        let path = model.ledger().path().to_owned();
        match case {
            0 => std::fs::write(path.with_extension("cleanup.json"), b"present").unwrap(),
            1 => std::fs::remove_file(&path).unwrap(),
            2 => std::fs::write(&path, b"corrupt").unwrap(),
            _ => {
                let (mut original, version) = model.ledger().read().unwrap().unwrap();
                original.intent.request.operation_id = "crossed-disposal".into();
                original.intent.request.request_sha256 = original.intent.request.digest().unwrap();
                original.proof = Some(
                    original
                        .intent
                        .proof(PartialBranchDisposalCompletion::ResolvedAbsent)
                        .unwrap(),
                );
                model.ledger().write(&original, Some(version)).unwrap();
            }
        }
        let counts = model.original.counts();
        assert!(resolve(&model, &request).is_err());
        assert!(!receipt_file(&model, &request).path.exists());
        assert_eq!(model.original.counts(), counts);
    }
}

#[test]
fn crossed_action_freezes_first_request_and_published_receipt_cannot_be_recreated_or_adopted() {
    let (model, request) = staged(1, false, true);
    let proof = resolve(&model, &request).unwrap().unwrap();
    let path = receipt_file(&model, &request).path;
    let mut crossed = request.clone();
    crossed.operation_id = "other-cleanup".into();
    crossed.request_sha256 = crossed.digest().unwrap();
    assert!(resolve(&model, &crossed).is_err());
    std::fs::remove_file(&path).unwrap();
    assert!(resolve(&model, &request).is_err());
    assert!(!path.exists());
    let mut foreign = RetainedUnneeded::new(&proof).unwrap();
    let ledger = receipt_file(&model, &request);
    ledger
        .write_record(
            &Receipt {
                schema: 1,
                proof: proof.clone(),
            },
            None,
        )
        .unwrap();
    assert!(foreign.acknowledge(&ledger, &proof, &budget()).is_err());
}

#[test]
fn visible_failed_publication_resynchronizes_only_the_original_cached_acknowledgement() {
    let (model, request) = staged(1, false, true);
    let disposal = model
        .original
        .engine
        .inspect_partial_branch_disposal(&request.disposal_request, &budget())
        .unwrap()
        .unwrap();
    let proof = PartialBranchDisposalCleanupUnneeded::issue(&request, disposal).unwrap();
    let ledger = receipt_file(&model, &request);
    let mut state = RetainedUnneeded::new(&proof).unwrap();
    let error = state
        .acknowledge_with(&ledger, &proof, &budget(), |ledger, record| {
            ledger.write_record(record, None)?;
            Err(Error::before(ErrorCode::Io))
        })
        .unwrap_err();
    assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
    assert!(state.attempted && !state.published);
    let bytes = std::fs::read(&ledger.path).unwrap();
    state.acknowledge(&ledger, &proof, &budget()).unwrap();
    assert!(state.published);
    assert_eq!(std::fs::read(&ledger.path).unwrap(), bytes);
}

#[test]
fn invalid_receipt_modes_links_bounds_or_bytes_cannot_supply_saved_acknowledgement() {
    for case in 0..5 {
        let (model, request) = staged(1, true, true);
        resolve(&model, &request).unwrap().unwrap();
        let path = receipt_file(&model, &request).path;
        match case {
            0 => std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap(),
            1 | 2 => {
                let saved = path.with_extension("preserved-model");
                std::fs::rename(&path, &saved).unwrap();
                if case == 1 {
                    std::os::unix::fs::symlink(saved, &path).unwrap();
                } else {
                    std::fs::hard_link(saved, &path).unwrap();
                }
            }
            3 => std::fs::write(&path, vec![b' '; Receipt::MAX_BYTES as usize + 1]).unwrap(),
            _ => std::fs::write(&path, b"invalid").unwrap(),
        }
        assert!(resolve(&model, &request).is_err());
    }
}

#[test]
fn exhausted_budgets_control_or_archive_ownership_are_nonblocking_and_publish_no_ack() {
    for case in 0..4 {
        let (model, request) = staged(1, false, true);
        let engine = &model.original.engine;
        let mut budget = budget();
        if case == 0 {
            budget.cancel.cancel();
        }
        if case == 1 {
            budget.deadline = std::time::Instant::now() - std::time::Duration::from_millis(1);
        }
        let control = if case == 2 {
            Some(
                engine
                    .jobs
                    .acquire(crate::jobs::Demand::material_resolution())
                    .unwrap(),
            )
        } else {
            None
        };
        let held = if case == 3 {
            Some(engine.branch_retention.partial_disposed.lock().unwrap())
        } else {
            None
        };
        assert!(engine
            .resolve_unneeded_partial_cleanup(&request, &budget)
            .is_err());
        assert!(!receipt_file(&model, &request).path.exists());
        drop(held);
        drop(control);
    }
}

#[test]
fn cancellation_after_receipt_publication_preserves_history_for_exact_retry() {
    let (model, request) = staged(1, false, true);
    let disposal = model
        .original
        .engine
        .inspect_partial_branch_disposal(&request.disposal_request, &budget())
        .unwrap()
        .unwrap();
    let proof = PartialBranchDisposalCleanupUnneeded::issue(&request, disposal).unwrap();
    let ledger = receipt_file(&model, &request);
    let mut state = RetainedUnneeded::new(&proof).unwrap();
    let cancelled = budget();
    let error = state
        .acknowledge_with(&ledger, &proof, &cancelled, |ledger, record| {
            ledger.write_record(record, None)?;
            cancelled.cancel.cancel();
            Ok(())
        })
        .unwrap_err();
    assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
    assert!(state.attempted && state.published);
    let bytes = std::fs::read(&ledger.path).unwrap();
    state.acknowledge(&ledger, &proof, &budget()).unwrap();
    assert_eq!(std::fs::read(&ledger.path).unwrap(), bytes);
}

#[test]
fn acknowledged_unneeded_cleanup_cannot_be_bypassed_by_fresh_qualification_even_if_receipt_disappears(
) {
    let (model, request) = staged(1, false, true);
    resolve(&model, &request).unwrap().unwrap();
    let engine = &model.original.engine;
    assert!(engine
        .qualify_partial_branch_cleanup(&request.disposal_request, &budget())
        .is_err());
    std::fs::remove_file(&receipt_file(&model, &request).path).unwrap();
    assert!(engine
        .qualify_partial_branch_cleanup(&request.disposal_request, &budget())
        .is_err());
    assert!(!receipt_file(&model, &request).path.exists());
}

#[test]
fn unexpected_unneeded_receipt_cannot_supply_eligibility_or_sdk_first_entry_to_a_pending_job() {
    let model = Model::new(1);
    model.enter();
    let request = cleanup_request(&model);
    let path = receipt_file(&model, &request).path;
    std::fs::write(&path, b"untrusted-present-history").unwrap();
    assert!(require_no_unneeded_history(
        &model.original.engine,
        &request.disposal_request.collection_request.creation
    )
    .is_err());
    assert!(model.application().qualify_unentered().is_err());
    assert!(model
        .application()
        .run(|_, _| panic!("unneeded history cannot become SDK first entry"))
        .is_err());
    assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
}
