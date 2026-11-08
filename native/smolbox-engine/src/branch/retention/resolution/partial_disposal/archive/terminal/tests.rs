//! Private original actor/cache/file projections; no SDK manager/deletion,
//! VMM, owner loss, live persistence interruption or independent CLI race.
use super::*;
use crate::branch::retention::resolution::partial_disposal::{tests::Model, RetainedCleanup};
use std::os::unix::fs::PermissionsExt;

type Cache = Arc<Mutex<RetainedCleanup>>;
fn request(model: &Model) -> PartialBranchDisposalCleanupRequest {
    let mut request = PartialBranchDisposalCleanupRequest {
        disposal_request: model.intent.request.clone(),
        operation_id: "original-unused-enrollment".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request
}
fn budget() -> ReadBudget {
    ReadBudget::new(
        std::time::Duration::from_secs(30),
        crate::Cancellation::default(),
    )
    .unwrap()
}
fn fact(cache: Option<&Cache>) -> Result<CleanupHandoff> {
    match cache {
        None => Ok(CleanupHandoff::NeverEnrolled),
        Some(cache) => RetainedCleanup::handoff(cache),
    }
}
fn select(
    model: &Model,
    request: &PartialBranchDisposalCleanupRequest,
    cache: Option<&Cache>,
) -> Result<Option<PartialBranchDisposal>> {
    model.original.resolution.unneeded_terminal_checked(
        &model.original.engine,
        request,
        &model.epoch,
        |work, intent| {
            assert!(work.boot.is_none());
            if *intent != model.intent {
                return Err(Error::before(ErrorCode::Ownership));
            }
            Ok((model.enrollment.clone(), fact(cache)?))
        },
    )
}
fn assert_held(model: &Model, counts: crate::jobs::Counts) {
    assert_eq!(model.original.counts(), counts);
    assert_eq!(
        model
            .original
            .engine
            .branch_retention
            .entries
            .lock()
            .unwrap()
            .len(),
        1
    );
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
}
fn resolve(
    model: &Model,
    request: &PartialBranchDisposalCleanupRequest,
) -> Result<Option<crate::PartialBranchDisposalCleanupUnneeded>> {
    model
        .original
        .engine
        .resolve_unneeded_partial_cleanup(request, &budget())
}

#[test]
fn terminal_original_selection_and_handoff_cover_both_unused_origins_all_heads_and_provenances() {
    for mode in 0..4 {
        for absent in [false, true] {
            for enrolled in [false, true] {
                let mut model = Model::new(mode);
                let proof = model.disposed(absent);
                let request = request(&model);
                let cache =
                    enrolled.then(|| Arc::new(Mutex::new(RetainedCleanup::new(&request).unwrap())));
                drop(model.original.entry.take());
                let before = model.original.counts();
                let main = std::fs::read(model.ledger().path()).unwrap();
                assert!(select(&model, &request, cache.as_ref()).unwrap() == Some(proof.clone()));
                assert_held(&model, before);
                let observer = model
                    .original
                    .engine
                    .jobs
                    .acquire(crate::jobs::Demand::observation())
                    .unwrap();
                let sibling = model
                    .original
                    .engine
                    .jobs
                    .acquire(crate::jobs::Demand::observation())
                    .unwrap();
                drop((observer, sibling));
                assert_held(&model, before);
                assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
                let handed = model
                    .archive_with_cleanup_handoff(&proof, fact(cache.as_ref()).unwrap())
                    .unwrap();
                assert!(handed == proof);
                drop(cache);
                let after = model.original.counts();
                assert!(model
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
                    .observation_gate(&model.original.source.name)
                    .unwrap()
                    .try_lock()
                    .is_ok());
                let ack = resolve(&model, &request).unwrap().unwrap();
                assert!(ack.disposal == proof);
                ack.matches_request(&request).unwrap();
                assert!(resolve(&model, &request).unwrap() == Some(ack));
                assert_eq!(model.original.counts(), after);
                assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
                assert!(!model
                    .ledger()
                    .path()
                    .with_extension("cleanup.json")
                    .exists());
                assert!(
                    model.plan.source.path.exists()
                        && model.plan.snapshot.path.exists()
                        && !model.plan.child.path.exists()
                );
            }
        }
    }
}

#[test]
fn unused_enrollment_is_an_original_exclusive_cache_fact_not_absent_files() {
    let model = Model::new(1);
    let request = request(&model);
    let cache = Arc::new(Mutex::new(RetainedCleanup::new(&request).unwrap()));
    assert!(matches!(
        fact(Some(&cache)).unwrap(),
        CleanupHandoff::EnrolledUnattempted { .. }
    ));
    let other = cache.clone();
    assert!(fact(Some(&cache)).is_err());
    drop(other);
    let locked = cache.lock().unwrap();
    assert!(fact(Some(&cache)).is_err());
    drop(locked);
    assert!(matches!(
        fact(Some(&cache)).unwrap(),
        CleanupHandoff::EnrolledUnattempted { .. }
    ));
    assert!(!model
        .ledger()
        .path()
        .with_extension("cleanup.json")
        .exists());
}

#[test]
fn unused_enrollment_binds_its_exact_request_before_and_after_handoff() {
    let mut model = Model::new(1);
    let proof = model.disposed(false);
    let request = request(&model);
    let cache = Arc::new(Mutex::new(RetainedCleanup::new(&request).unwrap()));
    drop(model.original.entry.take());
    let counts = model.original.counts();
    let mut crossed = request.clone();
    crossed.operation_id = "another-original-cleanup".into();
    crossed.request_sha256 = crossed.digest().unwrap();
    assert!(select(&model, &crossed, Some(&cache)).is_err());
    assert_held(&model, counts);
    model
        .archive_with_cleanup_handoff(&proof, fact(Some(&cache)).unwrap())
        .unwrap();
    drop(cache);
    assert!(resolve(&model, &crossed).is_err());
    assert!(!model
        .ledger()
        .path()
        .with_extension("cleanup-unneeded.json")
        .exists());
    assert!(resolve(&model, &request).unwrap().is_some());
}

#[test]
fn absent_namespace_without_terminal_proof_never_completes_or_archives_disposal() {
    let mut model = Model::new(1);
    model.enter();
    let request = request(&model);
    model
        .original
        .engine
        .db
        .remove_vm(&model.original.child.name)
        .unwrap();
    std::fs::remove_dir_all(&model.plan.child.path).unwrap();
    drop(model.original.entry.take());
    let counts = model.original.counts();
    assert!(model
        .original
        .resolution
        .unneeded_terminal_checked(
            &model.original.engine,
            &request,
            &model.epoch,
            |_, _| panic!("nonterminal files cannot borrow owner provenance")
        )
        .unwrap()
        .is_none());
    assert_held(&model, counts);
    assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
}

#[test]
fn protected_terminal_file_without_original_owner_cache_fact_is_not_authority() {
    let mut model = Model::new(1);
    model.disposed(true);
    let request = request(&model);
    drop(model.original.entry.take());
    let counts = model.original.counts();
    assert!(model
        .original
        .resolution
        .unneeded_terminal_checked(&model.original.engine, &request, &model.epoch, |_, _| Err(
            Error::before(ErrorCode::Ownership)
        ))
        .is_err());
    assert_held(&model, counts);
}

#[test]
fn foreign_cleanup_or_unneeded_files_block_terminal_handoff_selection() {
    for suffix in ["cleanup.json", "cleanup-unneeded.json"] {
        let mut model = Model::new(1);
        model.disposed(true);
        let request = request(&model);
        drop(model.original.entry.take());
        std::fs::write(
            model.ledger().path().with_extension(suffix),
            b"foreign-history",
        )
        .unwrap();
        let counts = model.original.counts();
        assert!(select(&model, &request, None).is_err());
        assert_held(&model, counts);
    }
}

#[test]
fn historical_selection_leaves_recreated_sdk_names_and_files_untouched() {
    let mut model = Model::new(1);
    let proof = model.disposed(false);
    let request = request(&model);
    drop(model.original.entry.take());
    std::fs::create_dir(&model.plan.child.path).unwrap();
    std::fs::set_permissions(
        &model.plan.child.path,
        std::fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    let occupant = model.plan.child.path.join("recreated-occupant");
    std::fs::write(&occupant, b"keep").unwrap();
    model
        .original
        .engine
        .db
        .insert_vm(&model.original.child.name, &model.original.child)
        .unwrap();
    assert!(select(&model, &request, None).unwrap() == Some(proof.clone()));
    model
        .archive_with_cleanup_handoff(&proof, CleanupHandoff::NeverEnrolled)
        .unwrap();
    assert!(resolve(&model, &request).unwrap().is_some());
    assert_eq!(std::fs::read(&occupant).unwrap(), b"keep");
    assert!(model
        .original
        .engine
        .db
        .get_vm(&model.original.child.name)
        .unwrap()
        .is_some());
}

#[test]
fn active_worker_and_competing_child_owner_preserve_original_work_and_backing() {
    let mut model = Model::new(1);
    let proof = model.disposed(true);
    let request = request(&model);
    drop(model.original.entry.take());
    let entry = model
        .original
        .resolution
        .original
        .entry(&model.original.engine)
        .unwrap();
    let active = Arc::new(());
    entry.work.lock().unwrap().worker = Arc::downgrade(&active);
    let counts = model.original.counts();
    assert!(select(&model, &request, None).is_err());
    assert_held(&model, counts);
    drop(active);
    drop(entry);
    model
        .original
        .engine
        .track_handle(model.intent.head())
        .unwrap();
    assert!(model
        .archive_with_cleanup_handoff(&proof, CleanupHandoff::NeverEnrolled)
        .is_err());
    assert_held(&model, counts);
}

#[test]
fn exhausted_material_control_or_cancelled_budget_cannot_release_original_terminal_work() {
    let mut model = Model::new(1);
    model.disposed(true);
    let request = request(&model);
    drop(model.original.entry.take());
    let control = model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    let other = model
        .original
        .engine
        .jobs
        .acquire(crate::jobs::Demand::observation())
        .unwrap();
    let counts = model.original.counts();
    assert!(select(&model, &request, None).is_err());
    assert_held(&model, counts);
    drop(control);
    drop(other);
    let cancel = crate::Cancellation::default();
    cancel.cancel();
    model.original.resolution.budget =
        ReadBudget::new(std::time::Duration::from_secs(30), cancel).unwrap();
    let counts = model.original.counts();
    assert!(select(&model, &request, None).is_err());
    assert_held(&model, counts);
}

#[test]
fn missing_original_registry_cannot_be_rebuilt_from_a_terminal_ledger() {
    let mut model = Model::new(1);
    model.disposed(true);
    let request = request(&model);
    model
        .original
        .engine
        .branch_retention
        .entries
        .lock()
        .unwrap()
        .clear();
    drop(model.original.entry.take());
    let counts = model.original.counts();
    assert!(resolve(&model, &request).unwrap().is_none());
    assert_eq!(model.original.counts(), counts);
    assert!(!model
        .ledger()
        .path()
        .with_extension("cleanup-unneeded.json")
        .exists());
}

#[test]
fn foreign_actor_epoch_cannot_select_original_terminal_handoff() {
    let mut model = Model::new(1);
    model.disposed(false);
    let request = request(&model);
    drop(model.original.entry.take());
    let actors = tempfile::tempdir().unwrap();
    let (_, _, epoch) = crate::epoch::tests::fixture_for_binding_and_epoch(
        &actors.path().canonicalize().unwrap(),
        None,
        model.original.engine.binding().clone(),
        "f".repeat(32),
    );
    let counts = model.original.counts();
    assert!(model
        .original
        .resolution
        .unneeded_terminal_checked(&model.original.engine, &request, &epoch, |_, _| Ok((
            model.enrollment.clone(),
            CleanupHandoff::NeverEnrolled
        )))
        .is_err());
    assert_held(&model, counts);
}
