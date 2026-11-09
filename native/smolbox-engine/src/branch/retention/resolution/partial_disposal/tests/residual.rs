//! Inert original actor/SQLite/file/row projections. No AgentManager, SDK
//! deletion, VM, owner loss or live persistence interruption is exercised.
use super::super::residual::RetainedCleanup;
use super::*;
use crate::{PartialBranchDisposalCleanup, PartialBranchDisposalCleanupRequest};
use std::time::{Duration, Instant};

type Cached = Arc<Mutex<RetainedCleanup>>;
fn staged(mode: u8) -> (Model, PartialBranchDisposalCleanupRequest, Cached) {
    let model = Model::new(mode);
    model.enter();
    // A private projection of SDK deletion removing its row while retaining the
    // original child directory. No SDK call or process action occurs.
    model
        .original
        .engine
        .db
        .remove_vm(&model.original.child.name)
        .unwrap();
    let mut request = PartialBranchDisposalCleanupRequest {
        disposal_request: model.intent.request.clone(),
        operation_id: "cleanup-original-partial".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    let cached = Arc::new(Mutex::new(RetainedCleanup::new(&request).unwrap()));
    (model, request, cached)
}
fn run(
    model: &Model,
    request: &PartialBranchDisposalCleanupRequest,
    cached: &Cached,
    maximum: usize,
) -> Result<PartialBranchDisposalCleanup> {
    model.original.resolution.cleanup_partial_checked(
        &model.original.engine,
        request,
        &model.epoch,
        |_, intent| {
            if *intent != model.intent {
                return Err(Error::before(ErrorCode::Ownership));
            }
            Ok((model.enrollment.clone(), cached.clone()))
        },
        |p, s, after| {
            assert!(after);
            model.original.source_authority(p, s, after)
        },
        |application| application.run(maximum),
    )
}
fn file(model: &Model) -> Ledger {
    super::super::residual::file(
        model.original.engine.domain.clone(),
        &model.intent.request.collection_request.creation,
    )
    .unwrap()
}
fn budget() -> ReadBudget {
    ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
}

#[test]
fn all_partial_heads_cleanup_only_original_residuals_and_keep_source_snapshot_backing_and_work() {
    for mode in 0..4 {
        let (model, request, cached) = staged(mode);
        let before = model.original.counts();
        let source =
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap();
        let outside = model.original.engine.domain.directory.join("outside-model");
        std::fs::write(&outside, b"preserved").unwrap();
        std::os::unix::fs::symlink(&outside, model.plan.child.path.join("outside-link")).unwrap();
        let proof = run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).unwrap();
        request.matches(&proof).unwrap();
        assert!(proof.disposal.completion == PartialBranchDisposalCompletion::ResolvedAbsent);
        assert!(proof.disposal.release == model.intent.release);
        assert!(
            !model.plan.child.path.exists()
                && model.plan.source.path.exists()
                && model.plan.snapshot.path.exists()
        );
        assert_eq!(std::fs::read(&outside).unwrap(), b"preserved");
        assert_eq!(
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap(),
            source
        );
        assert_eq!(model.original.counts(), before);
        let saved = run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).unwrap();
        assert!(saved == proof);
        assert!(model.ledger().read().unwrap().unwrap().0.proof == Some(proof.disposal));
    }
}

#[test]
fn row_reservation_missing_root_replacement_symlink_and_changed_source_cannot_mint_cleanup_authority(
) {
    for case in 0..7 {
        let (model, request, cached) = staged(1);
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
                    .reserve_vm_create(&model.original.child.name, "inert-reservation")
                    .unwrap());
            }
            2 => std::fs::remove_dir_all(&model.plan.child.path).unwrap(),
            3 | 4 => {
                std::fs::rename(
                    &model.plan.child.path,
                    model.plan.child.path.with_extension("kept-model"),
                )
                .unwrap();
                if case == 3 {
                    std::fs::create_dir(&model.plan.child.path).unwrap();
                    std::fs::set_permissions(
                        &model.plan.child.path,
                        std::fs::Permissions::from_mode(0o700),
                    )
                    .unwrap();
                } else {
                    std::os::unix::fs::symlink(&model.plan.source.path, &model.plan.child.path)
                        .unwrap();
                }
            }
            5 => {
                model
                    .original
                    .engine
                    .db
                    .update_vm(&model.original.source.name, |s| s.created_at += 1)
                    .unwrap();
            }
            _ => model
                .original
                .engine
                .track_handle(model.intent.head())
                .unwrap(),
        }
        let before = model.original.counts();
        assert!(run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
        assert_eq!(model.original.counts(), before);
        assert!(!file(&model).path.exists());
    }
}

#[test]
fn bounded_partial_removal_resumes_only_the_same_protected_request_and_original_inode() {
    let (model, request, cached) = staged(3);
    for name in ["one", "two", "three"] {
        std::fs::write(model.plan.child.path.join(name), b"data").unwrap();
    }
    let before = model.original.counts();
    assert!(run(&model, &request, &cached, 1).is_err());
    assert!(file(&model).path.exists() && model.plan.child.path.exists());
    assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
    assert_eq!(model.original.counts(), before);
    let mut wrong = request.clone();
    wrong.operation_id = "different-cleanup".into();
    wrong.request_sha256 = wrong.digest().unwrap();
    assert!(run(&model, &wrong, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
    let recreated = Arc::new(Mutex::new(RetainedCleanup::new(&request).unwrap()));
    assert!(run(&model, &request, &recreated, crate::VOLUME_DELETE_ENTRIES).is_err());
    let proof = run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).unwrap();
    request.matches(&proof).unwrap();
    assert_eq!(model.original.counts(), before);
}

#[test]
fn a_missing_published_cleanup_ledger_or_replaced_directory_never_reopens_removal() {
    for case in 0..2 {
        let (model, request, cached) = staged(2);
        assert!(run(&model, &request, &cached, 1).is_err());
        let before = model.original.counts();
        if case == 0 {
            std::fs::remove_file(&file(&model).path).unwrap();
        } else {
            std::fs::rename(
                &model.plan.child.path,
                model.plan.child.path.with_extension("kept-model"),
            )
            .unwrap();
            std::fs::create_dir(&model.plan.child.path).unwrap();
            std::fs::set_permissions(
                &model.plan.child.path,
                std::fs::Permissions::from_mode(0o700),
            )
            .unwrap();
            std::fs::write(model.plan.child.path.join("foreign"), b"preserved").unwrap();
        }
        assert!(run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
        assert_eq!(model.original.counts(), before);
        if case == 1 {
            assert_eq!(
                std::fs::read(model.plan.child.path.join("foreign")).unwrap(),
                b"preserved"
            );
        }
    }
}

#[test]
fn historical_acknowledgement_after_archive_preserves_recreated_names_handles_and_source_deletion()
{
    let (mut model, request, cached) = staged(3);
    let proof = run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).unwrap();
    drop(model.original.entry.take());
    model.archive(&proof.disposal).unwrap();
    model
        .original
        .engine
        .db
        .remove_vm(&model.original.source.name)
        .unwrap();
    std::fs::remove_dir_all(&model.plan.source.path).unwrap();
    std::fs::create_dir(&model.plan.child.path).unwrap();
    std::fs::write(model.plan.child.path.join("foreign"), b"preserved").unwrap();
    model
        .original
        .engine
        .track_handle(model.intent.head())
        .unwrap();
    let before = model.original.counts();
    assert!(
        model
            .original
            .resolution
            .cleanup_partial_disposal(&model.original.engine, &request)
            .unwrap()
            == proof
    );
    assert_eq!(model.original.counts(), before);
    assert!(
        model
            .original
            .engine
            .inspect_partial_disposal_cleanup(&request, &budget())
            .unwrap()
            == Some(proof)
    );
    assert_eq!(
        std::fs::read(model.plan.child.path.join("foreign")).unwrap(),
        b"preserved"
    );
    assert_eq!(model.original.counts(), before);
    std::fs::remove_file(&file(&model).path).unwrap();
    assert!(model
        .original
        .engine
        .inspect_partial_disposal_cleanup(&request, &budget())
        .is_err());
    assert_eq!(model.original.counts(), before);
}

#[test]
fn primary_completion_with_a_pending_cleanup_receipt_resynchronizes_only_that_original_action() {
    for archived in [false, true] {
        let (mut model, request, cached) = staged(3);
        let proof = run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).unwrap();
        let path = file(&model).path;
        let mut record: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        record["stage"] = serde_json::json!("cleaning");
        record["proof"] = serde_json::Value::Null;
        // Private completed/pending file projection, never a live writer interruption.
        std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
        if archived {
            drop(model.original.entry.take());
            model.archive(&proof.disposal).unwrap();
            model
                .original
                .engine
                .db
                .remove_vm(&model.original.source.name)
                .unwrap();
            std::fs::remove_dir_all(&model.plan.source.path).unwrap();
        }
        std::fs::create_dir(&model.plan.child.path).unwrap();
        std::fs::write(model.plan.child.path.join("foreign"), b"preserved").unwrap();
        model
            .original
            .engine
            .track_handle(model.intent.head())
            .unwrap();
        let before = model.original.counts();
        let saved = if archived {
            model
                .original
                .engine
                .inspect_partial_disposal_cleanup(&request, &budget())
                .unwrap()
                .unwrap()
        } else {
            run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).unwrap()
        };
        assert!(saved == proof);
        assert_eq!(
            std::fs::read(model.plan.child.path.join("foreign")).unwrap(),
            b"preserved"
        );
        assert_eq!(model.original.counts(), before);
    }
}

#[test]
fn cleanup_grant_links_modes_limits_and_original_primary_history_are_checked_before_resuming() {
    for case in 0..5 {
        let (model, request, cached) = staged(1);
        assert!(run(&model, &request, &cached, 1).is_err());
        let path = file(&model).path;
        match case {
            0 => std::fs::remove_file(model.ledger().path()).unwrap(),
            1 => {
                let kept = path.with_extension("kept-model");
                std::fs::rename(&path, &kept).unwrap();
                std::os::unix::fs::symlink(kept, &path).unwrap();
            }
            2 => std::fs::hard_link(&path, path.with_extension("kept-model")).unwrap(),
            3 => std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap(),
            _ => std::fs::write(&path, vec![b'x'; 256 * 1024 + 1]).unwrap(),
        }
        let before = model.original.counts();
        assert!(run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
        assert_eq!(model.original.counts(), before);
        assert!(model.plan.child.path.exists());
    }
}

#[test]
fn cancellation_budget_busy_worker_and_reserved_control_reject_without_filesystem_mutation() {
    let (mut model, request, cached) = staged(0);
    let before = model.original.counts();
    let control = model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    assert!(run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
    drop(control);
    let lock = cached.lock().unwrap();
    assert!(run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
    drop(lock);
    let active = Arc::new(());
    model.original.entry().work.lock().unwrap().worker = Arc::downgrade(&active);
    assert!(run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
    drop(active);
    model.original.resolution.budget.deadline = Instant::now();
    assert!(run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
    model.original.resolution.budget = budget();
    model.original.resolution.budget.cancel.cancel();
    assert!(run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
    assert!(model.plan.child.path.exists() && !file(&model).path.exists());
    assert_eq!(model.original.counts(), before);
}

#[test]
fn strict_action_and_proof_readers_bind_the_prior_collection_disposal_and_absence_provenance() {
    let (model, request, cached) = staged(3);
    let before = model.original.counts();
    let creation = &request.disposal_request.collection_request.creation;
    for id in [
        &request.disposal_request.operation_id,
        &request.disposal_request.collection_request.operation_id,
        &creation.child.operation_id,
        &creation.initial_release.as_ref().unwrap().operation_id,
    ] {
        let mut wrong = request.clone();
        wrong.operation_id = id.clone();
        wrong.request_sha256 = wrong.digest().unwrap();
        assert!(wrong.validate().is_err());
        assert!(run(&model, &wrong, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
    }
    let mut wrong = request.clone();
    wrong.operation_id = model
        .intent
        .release
        .as_ref()
        .unwrap()
        .change
        .request
        .operation_id
        .clone();
    wrong.request_sha256 = wrong.digest().unwrap();
    assert!(run(&model, &wrong, &cached, crate::VOLUME_DELETE_ENTRIES).is_err());
    assert_eq!(model.original.counts(), before);
    let proof = run(&model, &request, &cached, crate::VOLUME_DELETE_ENTRIES).unwrap();
    assert!(!format!("{proof:?}").contains(&creation.child.owner_token));
    let decoded: PartialBranchDisposalCleanup =
        serde_json::from_slice(&serde_json::to_vec(&proof).unwrap()).unwrap();
    request.matches(&decoded).unwrap();
    let mut wrong = request.clone();
    wrong.quiesced = false;
    wrong.request_sha256 = wrong.digest().unwrap();
    assert!(wrong.validate().is_err());
    let mut other = request.clone();
    other.operation_id = "another-valid-cleanup".into();
    other.request_sha256 = other.digest().unwrap();
    let crossed = PartialBranchDisposalCleanup::issue(&other, proof.disposal.clone()).unwrap();
    assert!(request.matches(&crossed).is_err());
    let mut changed = proof.clone();
    changed.proof_sha256 = "f".repeat(64);
    assert!(changed.validate().is_err());
    for field in ["path", "pid", "release", "completion"] {
        let mut wrong = serde_json::to_value(&request).unwrap();
        wrong[field] = serde_json::json!(1);
        assert!(serde_json::from_value::<PartialBranchDisposalCleanupRequest>(wrong).is_err());
        let mut wrong = serde_json::to_value(&proof).unwrap();
        wrong[field] = serde_json::json!(1);
        assert!(serde_json::from_value::<PartialBranchDisposalCleanup>(wrong).is_err());
    }
    let mut wrong = proof;
    wrong.disposal.completion = PartialBranchDisposalCompletion::Deleted;
    assert!(wrong.validate().is_err());
}

#[test]
fn unneeded_receipt_history_cannot_be_reinterpreted_as_residual_cleanup_enrollment_or_removal() {
    let (model, request, _) = staged(1);
    let path = model
        .ledger()
        .path()
        .with_extension("cleanup-unneeded.json");
    std::fs::write(&path, b"present-history").unwrap();
    let before = model.original.counts();
    let error = model
        .original
        .resolution
        .cleanup_partial_checked(
            &model.original.engine,
            &request,
            &model.epoch,
            |_, _| panic!("unneeded history cannot enroll a new cleanup"),
            |_, _, _| panic!("unneeded history must refuse before namespace observation"),
            |_| panic!("unneeded history cannot dispatch residual removal"),
        )
        .unwrap_err();
    assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
    assert_eq!(model.original.counts(), before);
    assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
    assert!(!file(&model).path.exists());
}
