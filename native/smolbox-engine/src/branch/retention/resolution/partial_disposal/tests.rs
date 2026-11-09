//! Inert actor/row/file projections; no manager constructor, SDK delete, VMM,
//! global SDK namespace, process loss or live persistence interruption.
use super::super::disposal::tests::Model as Original;
use super::*;
use crate::branch_boot::{Lifecycle, Plan};
use crate::PartialBranchCollectionRequest;
use std::cell::Cell;
use std::os::unix::fs::PermissionsExt;
#[path = "tests/absence.rs"]
mod absence;
#[path = "tests/archive.rs"]
mod archive;
#[path = "tests/backing.rs"]
mod backing;
#[path = "tests/qualification.rs"]
mod qualification;
#[path = "tests/residual.rs"]
mod residual;

pub(in crate::branch::retention) struct Model {
    pub(super) original: Original,
    pub(super) _actors: tempfile::TempDir,
    pub(super) epoch: crate::epoch::ActorEpoch,
    pub(super) enrollment: Arc<crate::epoch::BootEnrollment>,
    pub(super) plan: Plan,
    pub(in crate::branch::retention) intent: PartialDisposalIntent,
    pub(super) sdk_entry: Arc<Mutex<RetainedSdkEntry>>,
}
impl Model {
    pub(in crate::branch::retention) fn new(mode: u8) -> Self {
        let original = Original::new();
        let rootfs = original
            .engine
            .domain
            .directory
            .join("partial-rootfs-model");
        std::fs::create_dir(&rootfs).unwrap();
        std::fs::set_permissions(&rootfs, std::fs::Permissions::from_mode(0o700)).unwrap();
        let plan = {
            let work = original.entry().work.lock().unwrap();
            let snapshot = work.snapshot.as_ref().unwrap();
            Plan {
                schema: 1,
                publication: original.publication.clone(),
                source: Directory::capture(&original.entry().ownership.intent.guard.source_root)
                    .unwrap(),
                child: Directory::capture(&snapshot._child).unwrap(),
                snapshot: Directory::capture(&snapshot._snapshot).unwrap(),
                rootfs: Directory::capture(&crate::export_source::Root::open(&rootfs).unwrap())
                    .unwrap(),
            }
        };
        let actors = tempfile::tempdir().unwrap();
        let (_, _, epoch) = crate::epoch::tests::fixture_for_binding_and_epoch(
            &actors.path().canonicalize().unwrap(),
            None,
            original.engine.binding().clone(),
            original
                .publication
                .change
                .child_origin
                .intent
                .epoch
                .clone(),
        );
        let lifecycle = Lifecycle::at(&plan.child.path);
        lifecycle.prepare(&plan).unwrap();
        // Production retires collected preparation spools before entering boot.
        // Keep this booted model distinct from the retained unbooted model.
        drop(original.entry().work.lock().unwrap().collected.take());
        let dispatch = epoch.begin_boot(&original.child.name).unwrap();
        lifecycle.enter(&plan, &dispatch, &epoch).unwrap();
        let boot = dispatch.intent();
        let enrollment = Arc::new(crate::epoch::tests::complete_model(dispatch));
        lifecycle
            .returned(&plan, &boot, Some(&enrollment), mode != 0)
            .unwrap();
        let mut row = original.child.clone();
        row.state = smolvm::config::RecordState::Running;
        row.pid = Some(enrollment.child().pid);
        row.pid_start_time = Some(enrollment.child().birth);
        let mut release = None;
        if mode != 0 {
            let identity = crate::branch_identity::Intent::new(&row.name, &enrollment).unwrap();
            lifecycle
                .enter_identity(&plan, &identity, &enrollment)
                .unwrap();
            lifecycle
                .identity_ready(
                    &plan,
                    &enrollment,
                    &crate::branch_identity::tests::confirmed_model(&identity),
                )
                .unwrap();
            if mode >= 2 {
                let request = original
                    .resolution
                    .creation
                    .initial_release
                    .clone()
                    .unwrap_or(crate::BranchReleaseRequest {
                        operation_id: "partial-release-model".into(),
                        request_sha256: "d".repeat(64),
                    });
                let intent = crate::branch_release::Intent::issue(
                    &original.publication,
                    &row,
                    &enrollment,
                    &identity.digest().unwrap(),
                    &request,
                )
                .unwrap();
                crate::material::MaterialJournal::at(&plan.child.path)
                    .begin_branch_release(&intent, &row)
                    .unwrap();
                lifecycle
                    .enter_release(&plan, &intent, &enrollment)
                    .unwrap();
                if mode == 3 {
                    row = intent.released_record(&row).unwrap();
                    release = Some(intent.transition);
                }
            }
        }
        original
            .engine
            .db
            .update_vm(&row.name, |actual| *actual = row.clone())
            .unwrap();
        original.entry().work.lock().unwrap().phase = match mode {
            0 => Phase::BootEntered,
            1 => Phase::IdentityReady,
            _ => Phase::ReleaseEntered,
        };
        let mut collection_request = PartialBranchCollectionRequest {
            creation: original.resolution.creation.clone(),
            operation_id: "partial-collection-model".into(),
            request_sha256: String::new(),
            quiesced: true,
        };
        collection_request.request_sha256 = collection_request.digest().unwrap();
        lifecycle
            .begin_partial_collection(&plan, &collection_request, &enrollment)
            .unwrap();
        let collected = epoch.collect_enrolled(&row.name, &enrollment).unwrap();
        let collection = lifecycle
            .finish_partial_collection(&plan, &collection_request, &collected)
            .unwrap();
        assert!(
            lifecycle
                .partial_disposal_release(
                    &plan,
                    &collection_request,
                    &collection,
                    &enrollment,
                    &row
                )
                .unwrap()
                == release
        );
        let mut request = PartialBranchDisposalRequest {
            collection_request,
            collection,
            operation_id: "dispose-partial-model".into(),
            request_sha256: String::new(),
            quiesced: true,
        };
        request.request_sha256 = request.digest().unwrap();
        let mut stopped = row.clone();
        stopped.state = smolvm::config::RecordState::Stopped;
        stopped.pid = None;
        stopped.pid_start_time = None;
        let intent = PartialDisposalIntent {
            request,
            publication: original.publication.clone(),
            release,
            metadata_sha256: original.entry().expected.metadata_sha256.clone(),
            source: plan.source.clone(),
            child: plan.child.clone(),
            snapshot: plan.snapshot.clone(),
            source_sha256: crate::material::hash(&original.source).unwrap(),
            before_sha256: crate::material::hash(&row).unwrap(),
            stopped_sha256: crate::material::hash(&stopped).unwrap(),
        };
        intent.validate().unwrap();
        let sdk_entry = Arc::new(Mutex::new(RetainedSdkEntry::new(&intent).unwrap()));
        Self {
            sdk_entry,
            original,
            _actors: actors,
            epoch,
            enrollment,
            plan,
            intent,
        }
    }
    pub(in crate::branch::retention) fn publication_domain(
        &self,
    ) -> Arc<crate::domain::DomainGuard> {
        self.original.engine.domain.clone()
    }
    pub(in crate::branch::retention) fn publication_path(&self) -> std::path::PathBuf {
        self.ledger().path.clone()
    }
    pub(super) fn ledger(&self) -> Ledger {
        Ledger::new(
            self.original.engine.domain.clone(),
            &self.intent.request.collection_request.creation,
        )
        .unwrap()
    }
    pub(in crate::branch::retention) fn enter(&self) {
        self.ledger()
            .write(
                &Record {
                    schema: 1,
                    intent: self.intent.clone(),
                    stage: Stage::Entered,
                    proof: None,
                },
                None,
            )
            .unwrap();
    }
    pub(super) fn application(&self) -> Application {
        let active = Arc::new(());
        self.original.entry().work.lock().unwrap().worker = Arc::downgrade(&active);
        Application {
            sdk_entry: self.sdk_entry.clone(),
            enrollment: self.enrollment.clone(),
            plan: self.plan.clone(),
            entry: self.original.entry().clone(),
            intent: self.intent.clone(),
            epoch: self.epoch.clone(),
            domain: self.original.engine.domain.clone(),
            db: self.original.engine.db.clone(),
            database: self.original.engine.binding().database.clone(),
            identity: self.original.engine.database_identity,
            budget: self.original.resolution.budget.clone(),
            _active: active,
            _control: self
                .original
                .engine
                .jobs
                .acquire(crate::jobs::Demand::material_resolution())
                .unwrap(),
        }
    }
    pub(super) fn delete(&self) -> Result<()> {
        let (record, _) = self.ledger().read()?.unwrap();
        assert!(
            record.intent == self.intent
                && record.stage == Stage::Entered
                && record.proof.is_none()
        );
        let row = self
            .original
            .engine
            .db
            .get_vm(&self.original.child.name)
            .unwrap()
            .unwrap();
        assert_eq!(crate::material::hash(&row)?, self.intent.stopped_sha256);
        assert!(row.pid.is_none() && row.pid_start_time.is_none());
        self.original.engine.db.remove_vm(&row.name).unwrap();
        std::fs::remove_dir_all(&self.plan.child.path).unwrap();
        Ok(())
    }
    pub(super) fn finish(
        &self,
        completion: PartialBranchDisposalCompletion,
    ) -> Result<PartialBranchDisposal> {
        self.original.resolution.finish_partial_disposal(
            &self.original.engine,
            self.original.entry(),
            &self.intent,
            completion,
            &|p, s, after| self.original.source_authority(p, s, after),
        )
    }
}
#[test]
fn collected_failed_boot_identity_and_both_entered_release_heads_dispose_once_without_releasing_backing(
) {
    for mode in 0..4 {
        let model = Model::new(mode);
        let before = model.original.counts();
        let source =
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap();
        model.enter();
        let observer = model
            .original
            .engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        model
            .application()
            .run(|name, path| {
                assert_eq!(name, model.original.child.name);
                assert_eq!(path, model.plan.child.path);
                model.delete()
            })
            .unwrap();
        drop(observer);
        let proof = model
            .finish(PartialBranchDisposalCompletion::Deleted)
            .unwrap();
        proof.validate().unwrap();
        assert!(proof.request == model.intent.request && proof.release == model.intent.release);
        assert!(model.plan.source.path.exists() && model.plan.snapshot.path.exists());
        assert_eq!(
            source,
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap()
        );
        assert_eq!(model.original.counts(), before);
        assert!(model
            .original
            .engine
            .owned_managers
            .lock()
            .unwrap()
            .is_empty());
        let (record, version) = model.ledger().read().unwrap().unwrap();
        assert!(record.proof == Some(proof));
        model.ledger().synchronize(&version).unwrap();
        let calls = Cell::new(0);
        assert!(model
            .application()
            .run(|_, _| {
                calls.set(calls.get() + 1);
                Ok(())
            })
            .is_err());
        assert_eq!(calls.get(), 0);
    }
}
#[test]
fn entered_error_can_only_observe_positive_absence_and_never_replay_sdk_deletion() {
    let model = Model::new(1);
    model.enter();
    model
        .application()
        .run(|_, _| {
            model.delete()?;
            Err(Error::uncertain(ErrorCode::Io))
        })
        .unwrap_err();
    assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
    let proof = model
        .finish(PartialBranchDisposalCompletion::ResolvedAbsent)
        .unwrap();
    assert_eq!(
        proof.completion,
        PartialBranchDisposalCompletion::ResolvedAbsent
    );
    assert!(proof.release.is_none());
}
#[test]
fn source_child_lifecycle_and_root_substitutions_reject_before_delete() {
    for mode in 0..4 {
        let model = Model::new(1);
        model.enter();
        match mode {
            0 => model
                .original
                .engine
                .db
                .update_vm(&model.original.source.name, |row| {
                    row.env.push(("changed".into(), "1".into()))
                })
                .map(|_| ())
                .unwrap(),
            1 => model
                .original
                .engine
                .db
                .update_vm(&model.original.child.name, |row| row.forkpoint_held = false)
                .map(|_| ())
                .unwrap(),
            2 => {
                std::fs::remove_file(model.plan.child.path.join("smolbox.branch-start-v1.json"))
                    .unwrap();
            }
            _ => {
                std::fs::rename(
                    &model.plan.child.path,
                    model.plan.child.path.with_extension("original-model"),
                )
                .unwrap();
                std::fs::create_dir(&model.plan.child.path).unwrap();
                std::fs::set_permissions(
                    &model.plan.child.path,
                    std::fs::Permissions::from_mode(0o700),
                )
                .unwrap();
            }
        }
        let calls = Cell::new(0);
        assert!(model
            .application()
            .run(|_, _| {
                calls.set(calls.get() + 1);
                Ok(())
            })
            .is_err());
        assert_eq!(calls.get(), 0);
        assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
    }
}
#[test]
fn missing_or_crossed_entered_grant_and_current_actor_do_not_mint_disposal() {
    for mode in 0..3 {
        let model = Model::new(1);
        if mode != 0 {
            model.enter();
        }
        let mut app = model.application();
        if mode == 1 {
            app.intent.request.operation_id = "foreign-disposal".into();
            app.intent.request.request_sha256 = app.intent.request.digest().unwrap();
        }
        if mode == 2 {
            app.intent.request.collection.collection_sha256 = "f".repeat(64);
        }
        assert!(app
            .run(|_, _| panic!("missing original grant must not delete"))
            .is_err());
        assert!(model
            .original
            .engine
            .db
            .get_vm(&model.original.child.name)
            .unwrap()
            .is_some());
    }
}
#[test]
fn request_ids_quiescence_hashes_and_proof_substitution_are_strict() {
    let model = Model::new(3);
    let request = &model.intent.request;
    request.validate().unwrap();
    for id in [
        &request.collection.operation_id,
        &request.collection_request.creation.child.operation_id,
    ] {
        let mut crossed = request.clone();
        crossed.operation_id = id.clone();
        crossed.request_sha256 = crossed.digest().unwrap();
        assert!(crossed.validate().is_err());
    }
    let mut crossed = request.clone();
    crossed.quiesced = false;
    crossed.request_sha256 = crossed.digest().unwrap();
    assert!(crossed.validate().is_err());
    let proof = model
        .intent
        .proof(PartialBranchDisposalCompletion::Deleted)
        .unwrap();
    let mut wrong = proof.clone();
    wrong
        .publication
        .change
        .child_origin
        .intent
        .child
        .operation_id = "foreign-creation".into();
    assert!(wrong.validate().is_err());
    assert!(!format!("{:?}", proof).contains(&proof.proof_sha256));
    assert!(!format!("{:?}", request).contains(&request.request_sha256));
    let mut value = serde_json::to_value(&proof).unwrap();
    value["child_absent"] = serde_json::json!(true);
    assert!(serde_json::from_value::<PartialBranchDisposal>(value).is_err());
}

#[test]
fn original_boot_tracking_survives_candidate_inspection_and_retires_after_exact_collection_proof() {
    for mode in 0..4 {
        let model = Model::new(mode);
        let engine = &model.original.engine;
        let handle = model.plan.publication.child();
        let journal = model.plan.child.path.join("smolbox.branch-start-v1.json");
        let before = std::fs::read(&journal).unwrap();
        let counts = model.original.counts();
        // Match production's pre-SDK shutdown registration; the original
        // enrollment and protected lifecycle remain separate requirements.
        engine.track_handle(handle).unwrap();
        assert!(engine.require_unhanded_branch_child(&handle.name).is_err());
        engine.require_original_branch_handle(handle).unwrap();
        Lifecycle::at(&model.plan.child.path)
            .inspect_partial_collection(
                &model.plan,
                &model.intent.request.collection_request,
                &model.enrollment,
            )
            .unwrap();
        assert_eq!(std::fs::read(&journal).unwrap(), before);
        // This inert model has already published a synthetic original actor
        // collection. Inspection alone did not remove shutdown tracking.
        assert!(engine.require_unhanded_branch_child(&handle.name).is_err());
        model
            .intent
            .request
            .collection_request
            .matches(&model.intent.request.collection)
            .unwrap();
        engine.retire_collected_branch_handle(handle).unwrap();
        engine.require_unhanded_branch_child(&handle.name).unwrap();
        assert_eq!(model.original.counts(), counts);
        assert_eq!(std::fs::read(&journal).unwrap(), before);
        assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
    }
}

#[test]
fn original_database_pid_is_not_a_runtime_handoff_or_a_collection_capability() {
    let model = Model::new(1);
    let name = &model.original.child.name;
    assert_eq!(
        model.original.engine.runtime.pid(name),
        Some(model.enrollment.child().pid)
    );
    model
        .original
        .engine
        .require_unhanded_branch_child(name)
        .unwrap();
    assert!(model.original.engine.branch_child_unstarted(name).is_err());
    // This inert model has no live engine epoch or native manager. Empty maps
    // and the synthetically collected actor cannot mint public SDK authority.
    assert!(model
        .original
        .resolution
        .dispose_partial_child(&model.original.engine, &model.intent.request)
        .is_err());
    assert!(model.ledger().read().unwrap().is_none());
    model
        .original
        .engine
        .track_handle(model.intent.publication.child())
        .unwrap();
    assert!(model
        .original
        .engine
        .require_unhanded_branch_child(name)
        .is_err());
}
#[test]
fn published_primary_selects_only_original_context_and_exact_history_precedes_namespace_observation(
) {
    let model = Model::new(1);
    let pending = Record {
        schema: 1,
        intent: model.intent.clone(),
        stage: Stage::Entered,
        proof: None,
    };
    let cached = Some((&model.intent, true));
    // Structural selection grants no SDK entry: the cached/protected entry
    // fence and original context are independently mandatory in the application.
    assert!(matches!(
        select_disposal(cached, Some(&pending), &model.intent.request, false).unwrap(),
        Selected::Published(_)
    ));
    assert!(matches!(
        select_disposal(cached, Some(&pending), &model.intent.request, true).unwrap(),
        Selected::Observe(_)
    ));
    assert!(select_disposal(cached, None, &model.intent.request, false).is_err());
    assert!(select_disposal(None, Some(&pending), &model.intent.request, true).is_err());
    for observe in [false, true] {
        assert!(matches!(select_disposal(
            Some((&model.intent, false)), Some(&pending), &model.intent.request, observe
        ).unwrap(), Selected::Synchronize(intent) if intent == model.intent));
    }
    assert!(select_disposal(None, None, &model.intent.request, true).is_err());
    assert!(matches!(
        select_disposal(None, None, &model.intent.request, false).unwrap(),
        Selected::Fresh
    ));
    let proof = model
        .intent
        .proof(PartialBranchDisposalCompletion::Deleted)
        .unwrap();
    let completed = Record {
        schema: 1,
        intent: model.intent.clone(),
        stage: Stage::Deleted,
        proof: Some(proof.clone()),
    };
    assert!(
        matches!(select_disposal(cached, Some(&completed), &model.intent.request, false).unwrap(), Selected::Historical(p) if p == proof)
    );
    for observe in [false, true] {
        assert!(select_disposal(
            Some((&model.intent, false)),
            Some(&completed),
            &model.intent.request,
            observe
        )
        .is_err());
    }
    let mut crossed = model.intent.request.clone();
    crossed.operation_id = "other-disposal".into();
    crossed.request_sha256 = crossed.digest().unwrap();
    assert!(select_disposal(cached, Some(&completed), &crossed, true).is_err());
}
#[test]
fn protected_disposal_history_rejects_symlink_hardlink_permissions_and_oversize() {
    for mode in 0..4 {
        let model = Model::new(1);
        model.enter();
        let path = model.ledger().path().to_owned();
        match mode {
            0 => std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap(),
            1 => {
                let other = path.with_extension("linked-model");
                std::fs::hard_link(&path, other).unwrap();
            }
            2 => {
                let other = path.with_extension("target-model");
                std::fs::rename(&path, &other).unwrap();
                std::os::unix::fs::symlink(other, &path).unwrap();
            }
            _ => std::fs::write(&path, vec![b' '; 128 * 1024 + 1]).unwrap(),
        }
        assert!(model.ledger().read().is_err());
        assert!(model
            .application()
            .run(|_, _| panic!("invalid protected grant cannot enter SDK deletion"))
            .is_err());
    }
}
#[test]
fn failed_delete_without_absence_keeps_unknown_entry_and_original_allocations() {
    let model = Model::new(0);
    let counts = model.original.counts();
    model.enter();
    assert!(model
        .application()
        .run(|_, _| Err(Error::uncertain(ErrorCode::Native)))
        .is_err());
    assert!(model
        .finish(PartialBranchDisposalCompletion::ResolvedAbsent)
        .is_err());
    assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
    assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
    assert_eq!(model.original.counts(), counts);
}

#[test]
fn cancellation_or_expiry_before_application_entry_preserves_every_original_charge() {
    for expire in [false, true] {
        let model = Model::new(1);
        model.enter();
        let counts = model.original.counts();
        let mut app = model.application();
        if expire {
            app.budget.deadline = Instant::now() - Duration::from_millis(1);
        } else {
            app.budget.cancel.cancel();
        }
        assert!(app
            .run(|_, _| panic!("spent disposal budget cannot enter SDK deletion"))
            .is_err());
        assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
        assert_eq!(model.original.counts(), counts);
        assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
    }
}
#[test]
fn partial_removal_is_not_positive_absence_and_keeps_the_original_dependency_and_backing() {
    let model = Model::new(0);
    model.enter();
    let counts = model.original.counts();
    assert!(model
        .application()
        .run(|name, _| {
            model.original.engine.db.remove_vm(name).unwrap();
            Err(Error::uncertain(ErrorCode::Io))
        })
        .is_err());
    assert!(model
        .finish(PartialBranchDisposalCompletion::ResolvedAbsent)
        .is_err());
    assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
    assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
    assert_eq!(model.original.counts(), counts);
}

#[test]
fn only_the_original_disposal_target_is_exempt_from_clean_sibling_head_validation() {
    let model = Model::new(3);
    let receipt = &model.intent.publication.receipt;
    let child = &model.original.child.name;
    let engine = &model.original.engine;
    let children = crate::sdk_compat::source_dependents(
        &engine.binding().database,
        engine.database_identity,
        &receipt.name,
        &model.original.resolution.budget,
    )
    .unwrap();
    // The target's release was entered; its material journal is intentionally
    // unfinished even though the frozen lifecycle identifies the exact after-head.
    assert!(
        !crate::material::MaterialJournal::at(&model.plan.source.path)
            .branch_dependencies(
                receipt,
                None,
                &children,
                &engine.binding().database,
                engine.database_identity,
                &model.original.resolution.budget
            )
            .unwrap()
    );
    assert!(engine
        .branch_disposal_dependencies(receipt, child, &model.original.resolution.budget)
        .unwrap());
    let mut sibling = model.original.child.clone();
    sibling.name = "foreign-sibling-model".into();
    engine.db.insert_vm(&sibling.name, &sibling).unwrap();
    assert!(!engine
        .branch_disposal_dependencies(receipt, child, &model.original.resolution.budget)
        .unwrap());
    assert!(engine.db.get_vm(&sibling.name).unwrap().is_some());
}
