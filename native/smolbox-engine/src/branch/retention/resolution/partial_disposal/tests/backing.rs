//! Inert original actor/SQLite/file/accounting models only. No manager, SDK
//! deletion, VM, owner loss, live persistence interruption or external CLI.
use super::*;
use crate::{BranchBackingRelease, PartialBranchBackingReleaseRequest};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

fn budget() -> ReadBudget {
    ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
}
fn staged(mode: u8, resolved: bool) -> (Model, PartialBranchBackingReleaseRequest) {
    let mut model = Model::new(mode);
    let disposal = model.disposed(resolved);
    drop(model.original.entry.take());
    model.archive(&disposal).unwrap();
    let mut request = PartialBranchBackingReleaseRequest {
        source: disposal.publication.receipt.clone(),
        child: disposal
            .release
            .as_ref()
            .map_or(disposal.publication.child(), |r| &r.receipt)
            .clone(),
        disposal,
        operation_id: "release-original-partial-backing".into(),
        request_sha256: String::new(),
        quiesced: true,
        backing_removed: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    (model, request)
}
fn remove_source(model: &Model) {
    model
        .original
        .engine
        .db
        .remove_vm(&model.original.source.name)
        .unwrap();
    std::fs::remove_dir_all(&model.plan.source.path).unwrap();
}
fn release(
    model: &Model,
    request: &PartialBranchBackingReleaseRequest,
) -> Result<BranchBackingRelease> {
    let epoch = model.epoch.clone();
    model.original.engine.release_partial_backing(
        request,
        &budget(),
        move |record, enrollment, b| {
            super::super::archive::backing::collected(&epoch, record, enrollment, b)
        },
    )
}
fn releases(model: &Model) -> Vec<std::path::PathBuf> {
    std::fs::read_dir(&model.original.engine.domain.directory)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("branch-backing-")
        })
        .collect()
}

#[test]
fn exact_original_partial_disposal_releases_only_its_backing_after_two_fenced_collected_absence_passes(
) {
    for mode in 0..4 {
        for resolved in [false, true] {
            let (model, request) = staged(mode, resolved);
            let before = model.original.counts();
            let mut sibling = model
                .original
                .engine
                .jobs
                .acquire(crate::jobs::Demand::branch_source())
                .unwrap();
            sibling.promote_branch_preparation().unwrap();
            sibling.promote_branch_backing(7 << 30).unwrap();
            let sibling = sibling.handoff_disposed_branch().unwrap();
            remove_source(&model);
            let unrelated = model
                .original
                .engine
                .domain
                .directory
                .join("unrelated-backing-model");
            std::fs::write(&unrelated, b"preserved").unwrap();
            let source = model
                .original
                .engine
                .observation_gate(&request.source.name)
                .unwrap();
            let child = model
                .original
                .engine
                .observation_gate(&request.child.name)
                .unwrap();
            let epoch = model.epoch.clone();
            let enrollment = model.enrollment.clone();
            let calls = Arc::new(AtomicUsize::new(0));
            let checks = calls.clone();
            let jobs = model.original.engine.jobs.clone();
            let proof = model
                .original
                .engine
                .release_partial_backing(&request, &budget(), move |record, original, b| {
                    assert!(source.try_lock().is_err() && child.try_lock().is_err());
                    assert!(std::ptr::eq(original, enrollment.as_ref()));
                    assert_eq!((jobs.counts().work, jobs.counts().control), (0, 1));
                    checks.fetch_add(1, Ordering::SeqCst);
                    super::super::archive::backing::collected(&epoch, record, original, b)
                })
                .unwrap();
            request.matches(&proof).unwrap();
            assert_eq!(calls.load(Ordering::SeqCst), 2);
            assert_eq!(proof.native_bytes, before.checkpoint_material);
            let after = model.original.counts();
            assert_eq!(after.checkpoint_material, 7 << 30);
            assert_eq!(
                after.branch_metadata,
                2 * crate::jobs::BRANCH_BACKING_METADATA
            );
            assert_eq!(
                (after.work, after.control, after.children, after.descriptors),
                (0, 0, 0, 0)
            );
            assert_eq!(std::fs::read(&unrelated).unwrap(), b"preserved");
            assert!(
                model
                    .original
                    .engine
                    .inspect_partial_branch_disposal(&request.disposal.request, &budget())
                    .unwrap()
                    == Some(request.disposal.clone())
            );
            assert!(model
                .original
                .engine
                .owned_managers
                .lock()
                .unwrap()
                .is_empty());
            assert!(model
                .original
                .engine
                .branch_retention
                .completed
                .lock()
                .unwrap()
                .is_empty());
            assert_eq!(releases(&model).len(), 1);
            drop(sibling);
            assert_eq!(model.original.counts().checkpoint_material, 0);
            assert_eq!(
                model.original.counts().branch_metadata,
                crate::jobs::BRANCH_BACKING_METADATA
            );
        }
    }
}

#[test]
fn rows_reservations_residual_directories_symlinks_and_actual_owned_handles_retain_the_whole_charge(
) {
    for case in 0..11 {
        let (model, request) = staged(3, false);
        let before = model.original.counts();
        match case {
            0 => std::fs::remove_dir_all(&model.plan.source.path).unwrap(),
            1 => {
                model
                    .original
                    .engine
                    .db
                    .remove_vm(&request.source.name)
                    .unwrap();
            }
            _ => {
                remove_source(&model);
                match case {
                    2 => model
                        .original
                        .engine
                        .db
                        .insert_vm(&request.child.name, &model.original.child)
                        .unwrap(),
                    3 | 4 => {
                        assert!(model
                            .original
                            .engine
                            .db
                            .reserve_vm_create(
                                if case == 3 {
                                    &request.source.name
                                } else {
                                    &request.child.name
                                },
                                "inert-reservation"
                            )
                            .unwrap());
                    }
                    5 | 6 => std::fs::create_dir(if case == 5 {
                        &model.plan.source.path
                    } else {
                        &model.plan.child.path
                    })
                    .unwrap(),
                    7 | 8 => std::os::unix::fs::symlink(
                        model
                            .original
                            .engine
                            .domain
                            .directory
                            .join("missing-model-target"),
                        if case == 7 {
                            &model.plan.source.path
                        } else {
                            &model.plan.child.path
                        },
                    )
                    .unwrap(),
                    9 => model.original.engine.track_handle(&request.source).unwrap(),
                    _ => model.original.engine.track_handle(&request.child).unwrap(),
                }
            }
        }
        assert!(release(&model, &request).is_err());
        assert_eq!(model.original.counts(), before);
        assert!(releases(&model).is_empty());
    }
}

#[test]
fn second_collected_absence_pass_and_final_original_ledger_check_precede_accounting_publication() {
    for case in 0..3 {
        let (model, request) = staged(1, true);
        remove_source(&model);
        let before = model.original.counts();
        let child = model.plan.child.path.clone();
        let source = model.plan.source.path.clone();
        let ledger = model.ledger().path().to_owned();
        let calls = AtomicUsize::new(0);
        let epoch = model.epoch.clone();
        assert!(model
            .original
            .engine
            .release_partial_backing(&request, &budget(), move |record, enrollment, b| {
                if calls.fetch_add(1, Ordering::SeqCst) == 1 {
                    match case {
                        0 => std::fs::create_dir(&child).unwrap(),
                        1 => std::fs::create_dir(&source).unwrap(),
                        _ => std::fs::remove_file(&ledger).unwrap(),
                    }
                }
                super::super::archive::backing::collected(&epoch, record, enrollment, b)
            })
            .is_err());
        assert_eq!(model.original.counts(), before);
        assert!(releases(&model).is_empty());
    }
}

#[test]
fn exact_historical_partial_backing_ack_leaves_new_names_and_ownership_untouched_without_collection(
) {
    let (model, request) = staged(3, false);
    remove_source(&model);
    let proof = release(&model, &request).unwrap();
    let before = model.original.counts();
    model.original.engine.track_handle(&request.child).unwrap();
    model
        .original
        .engine
        .db
        .insert_vm(&request.child.name, &model.original.child)
        .unwrap();
    for path in [&model.plan.source.path, &model.plan.child.path] {
        std::fs::create_dir(path).unwrap();
        std::fs::write(path.join("new-occupant"), b"preserved").unwrap();
    }
    let saved = model
        .original
        .engine
        .release_partial_backing(&request, &budget(), |_, _, _| {
            panic!("historical ack cannot collect new actors")
        })
        .unwrap();
    assert!(saved == proof);
    assert_eq!(model.original.counts(), before);
    for path in [&model.plan.source.path, &model.plan.child.path] {
        assert_eq!(
            std::fs::read(path.join("new-occupant")).unwrap(),
            b"preserved"
        );
    }
    assert!(model
        .original
        .engine
        .db
        .get_vm(&request.child.name)
        .unwrap()
        .is_some());
    let mut changed = request;
    changed.operation_id = "different-partial-backing-release".into();
    changed.request_sha256 = changed.digest().unwrap();
    assert!(release(&model, &changed).is_err());
    assert_eq!(model.original.counts(), before);
}

#[test]
fn missing_archive_terminal_ledger_or_published_backing_history_never_reconstructs_authority() {
    for case in 0..4 {
        let (model, mut request) = staged(2, false);
        remove_source(&model);
        if case == 0 {
            let archive = std::mem::take(
                &mut *model
                    .original
                    .engine
                    .branch_retention
                    .partial_disposed
                    .lock()
                    .unwrap(),
            );
            let before = model.original.counts();
            assert!(release(&model, &request).is_err());
            assert_eq!(model.original.counts(), before);
            *model
                .original
                .engine
                .branch_retention
                .partial_disposed
                .lock()
                .unwrap() = archive;
            continue;
        }
        match case {
            1 => {
                request.disposal = model
                    .intent
                    .proof(PartialBranchDisposalCompletion::ResolvedAbsent)
                    .unwrap();
                request.request_sha256 = request.digest().unwrap();
                request.validate().unwrap();
            }
            2 => std::fs::remove_file(model.ledger().path()).unwrap(),
            _ => {
                release(&model, &request).unwrap();
                std::fs::remove_file(&releases(&model)[0]).unwrap();
            }
        }
        let before = model.original.counts();
        assert!(release(&model, &request).is_err());
        assert_eq!(model.original.counts(), before);
    }
}

#[test]
fn budget_confirmation_original_epoch_and_collection_failures_cannot_free_partial_backing() {
    let (model, request) = staged(0, false);
    remove_source(&model);
    let before = model.original.counts();
    let mut expired = budget();
    expired.deadline = Instant::now();
    let cancelled = budget();
    cancelled.cancel.cancel();
    let mut too_long = budget();
    too_long.deadline = Instant::now() + Duration::from_secs(31);
    for invalid in [&expired, &cancelled, &too_long] {
        assert!(model
            .original
            .engine
            .release_partial_backing(&request, invalid, |_, _, _| panic!(
                "inadmissible budget entered"
            ))
            .is_err());
    }
    assert!(model
        .original
        .engine
        .release_partial_branch_backing_checked(&request, &budget())
        .is_err());
    assert!(model
        .original
        .engine
        .release_partial_backing(&request, &budget(), |_, _, _| Err(Error::before(
            ErrorCode::Conflict
        )))
        .is_err());
    assert_eq!(model.original.counts(), before);
    assert!(releases(&model).is_empty());
}

#[test]
fn busy_ownership_archive_gates_or_reserved_control_are_nonblocking_and_keep_partial_backing() {
    let (model, request) = staged(1, false);
    remove_source(&model);
    let before = model.original.counts();
    let managers = model.original.engine.owned_managers.lock().unwrap();
    assert!(release(&model, &request).is_err());
    drop(managers);
    let archive = model
        .original
        .engine
        .branch_retention
        .partial_disposed
        .lock()
        .unwrap();
    assert!(release(&model, &request).is_err());
    drop(archive);
    for name in [&request.source.name, &request.child.name] {
        let gate = model.original.engine.observation_gate(name).unwrap();
        let lock = gate.try_lock().unwrap();
        assert!(release(&model, &request).is_err());
        drop(lock);
    }
    let control = model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    assert!(release(&model, &request).is_err());
    drop(control);
    assert_eq!(model.original.counts(), before);
    assert!(releases(&model).is_empty());
    release(&model, &request).unwrap();
    assert_eq!(model.original.counts().checkpoint_material, 0);
}

#[test]
fn cancellation_after_original_collection_keeps_backing_and_normal_worker_return_allows_explicit_cleanup(
) {
    let (model, request) = staged(2, false);
    remove_source(&model);
    let before = model.original.counts();
    let epoch = model.epoch.clone();
    let bounded = budget();
    assert!(model
        .original
        .engine
        .release_partial_backing(&request, &bounded, move |record, enrollment, b| {
            super::super::archive::backing::collected(&epoch, record, enrollment, b)?;
            b.cancel.cancel(); // Explicit in-process API cancellation; no process or VM loss.
            b.check()
        })
        .is_err());
    let collected = Instant::now() + Duration::from_secs(5);
    while model.original.counts().control != 0 && Instant::now() < collected {
        std::thread::sleep(Duration::from_millis(1));
    }
    let retained = model.original.counts();
    assert_eq!(retained.control, 0);
    assert_eq!(retained.checkpoint_material, before.checkpoint_material);
    assert_eq!(retained.branch_metadata, before.branch_metadata);
    assert!(releases(&model).is_empty());
    release(&model, &request).unwrap(); // Normal cleanup remains usable under quarantine.
    assert_eq!(model.original.counts().checkpoint_material, 0);
}

#[test]
fn source_collection_requires_the_original_epoch_quiescent_source_and_child_and_gone_source_pid() {
    for case in 0..5 {
        let (model, _) = staged(1, false);
        let record = model.ledger().read().unwrap().unwrap().0;
        if case == 0 {
            super::super::archive::backing::collected(
                &model.epoch,
                &record,
                &model.enrollment,
                &budget(),
            )
            .unwrap();
            continue;
        }
        if case == 1 {
            let root = tempfile::tempdir().unwrap();
            let (_, _, wrong) = crate::epoch::tests::fixture_for_binding_and_epoch(
                &root.path().canonicalize().unwrap(),
                None,
                model.original.engine.binding().clone(),
                "f".repeat(32),
            );
            assert!(super::super::archive::backing::collected(
                &wrong,
                &record,
                &model.enrollment,
                &budget()
            )
            .is_err());
        } else if case == 4 {
            let mut live = record;
            let owner = crate::OwnerIdentity::capture().unwrap();
            live.intent
                .publication
                .change
                .child_origin
                .intent
                .source_pid = (owner.pid, owner.birth);
            let error = super::super::archive::backing::collected(
                &model.epoch,
                &live,
                &model.enrollment,
                &budget(),
            )
            .unwrap_err();
            assert_eq!(error.code, ErrorCode::Conflict); // The live-source fence itself rejected.
        } else {
            let pending = model
                .epoch
                .begin_boot(if case == 2 {
                    &model.original.source.name
                } else {
                    &model.original.child.name
                })
                .unwrap();
            assert!(super::super::archive::backing::collected(
                &model.epoch,
                &record,
                &model.enrollment,
                &budget()
            )
            .is_err());
            drop(pending); // Private metadata only; no process was started.
        }
    }
}

#[test]
fn expected_source_head_correlates_with_durable_caller_but_partial_child_head_is_exact() {
    let (model, mut request) = staged(3, true);
    let original = request.clone();
    let head = request.source.material.as_mut().unwrap();
    head.revision += 1;
    head.chain_sha256 = "e".repeat(64);
    head.record_sha256 = "e".repeat(64);
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    remove_source(&model);
    let proof = release(&model, &request).unwrap();
    request.matches(&proof).unwrap();
    assert!(original.matches(&proof).is_err());
    assert!(release(&model, &original).is_err());
    let mut wrong = request;
    wrong.child = wrong.disposal.publication.child().clone();
    wrong.request_sha256 = wrong.digest().unwrap();
    assert!(wrong.validate().is_err());
    assert_eq!(model.original.counts().checkpoint_material, 0);
}

#[test]
fn a_valid_backing_ack_under_another_original_context_cannot_release_partial_backing() {
    let (model, request) = staged(2, true);
    remove_source(&model);
    let before = model.original.counts();
    let mut proof = BranchBackingRelease {
        schema: 1,
        publication: request.disposal.publication.clone(),
        operation_id: request.operation_id.clone(),
        request_sha256: request.request_sha256.clone(),
        native_bytes: before.checkpoint_material,
        proof_sha256: String::new(),
    };
    proof.proof_sha256 = proof.digest().unwrap();
    request.matches(&proof).unwrap(); // Correlation alone grants no native charge.
    let key = crate::material::hash(&("smolbox-branch-backing-v1", &proof.publication)).unwrap();
    let path = model
        .original
        .engine
        .domain
        .directory
        .join(format!("branch-backing-{key}.json"));
    std::fs::write(
        &path,
        serde_json::to_vec(&serde_json::json!({
            "schema": 1, "context_sha256": "f".repeat(64), "proof": proof,
        }))
        .unwrap(),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(release(&model, &request).is_err());
    assert_eq!(model.original.counts(), before);
}

#[test]
fn partial_backing_request_requires_distinct_actions_confirmations_exact_heads_and_strict_shape() {
    let (model, request) = staged(3, false);
    let before = model.original.counts();
    for case in 0..13 {
        let mut wrong = request.clone();
        let creation = &wrong.disposal.request.collection_request.creation;
        match case {
            0 => wrong.quiesced = false,
            1 => wrong.backing_removed = false,
            2 => wrong.source.owner_token = "f".repeat(64),
            3 => wrong.source = wrong.disposal.publication.previous.clone(),
            4 => wrong.child.material.as_mut().unwrap().revision += 1,
            5 => wrong.operation_id = creation.child.operation_id.clone(),
            6 => wrong.operation_id = wrong.disposal.request.operation_id.clone(),
            7 => {
                wrong.operation_id = wrong
                    .disposal
                    .request
                    .collection_request
                    .operation_id
                    .clone()
            }
            8 => {
                wrong.operation_id = wrong
                    .disposal
                    .release
                    .as_ref()
                    .unwrap()
                    .change
                    .request
                    .operation_id
                    .clone()
            }
            9 => {
                wrong.operation_id = creation
                    .initial_release
                    .as_ref()
                    .unwrap()
                    .operation_id
                    .clone()
            }
            10 => wrong.child = wrong.disposal.publication.child().clone(),
            11 => wrong.operation_id = "/private/wrong-action".into(),
            _ => wrong.request_sha256 = "f".repeat(64),
        }
        if case != 12 {
            wrong.request_sha256 = wrong.digest().unwrap();
        }
        assert!(wrong.validate().is_err());
        assert!(release(&model, &wrong).is_err());
        assert_eq!(model.original.counts(), before);
    }
    let wire = serde_json::to_value(&request).unwrap();
    for field in ["path", "pid", "native_bytes", "completion", "retirement"] {
        let mut extra = wire.clone();
        extra[field] = serde_json::json!(1);
        assert!(serde_json::from_value::<PartialBranchBackingReleaseRequest>(extra).is_err());
    }
    assert!(serde_json::from_value::<crate::UnbootedBranchBackingReleaseRequest>(wire).is_err());
    assert!(!format!("{request:?}").contains(&request.child.owner_token));
}
