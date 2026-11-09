//! Inert private SDK-row/file projections only. No VMM, SDK fork/delete call,
//! forced process termination, live persistence failure or CLI race is created.
use super::*;
use crate::material::MaterialJournal;
use smolvm::config::{RecordState, VmRecord};
use std::cell::Cell;
use std::os::unix::fs::PermissionsExt;
#[path = "tests/absence.rs"]
mod absence;
#[path = "tests/archive.rs"]
mod archive;
#[path = "tests/backing.rs"]
mod backing;
#[path = "tests/candidate.rs"]
mod candidate;

struct Model {
    _root: tempfile::TempDir,
    engine: Engine,
    entry: Option<Arc<Entry>>,
    resolution: RetainedBranchResolution,
    request: UnbootedBranchDisposalRequest,
    publication: crate::BranchPublication,
    source: VmRecord,
    child: VmRecord,
}
impl Model {
    fn new() -> Self {
        let (root, engine, metadata, original) = super::super::super::tests::fixture_bound(true);
        let entry = original.entry(&engine).unwrap();
        let before = engine
            .db
            .get_vm(&metadata.grant.intent.source.name)
            .unwrap()
            .unwrap();
        let mut source = before.clone();
        if cfg!(target_os = "linux") {
            source.fork_lineage_pid_start_time = source.pid_start_time;
        }
        let mut raw = source.clone();
        raw.name = metadata.grant.intent.child.name.clone();
        raw.state = RecordState::Created;
        raw.pid = None;
        raw.pid_start_time = None;
        raw.created_at += 1;
        raw.golden = Some(source.name.clone());
        raw.fork_overlay_owner = Some(source.name.clone());
        raw.fork_generation = Some("aabbccdd".into());
        raw.fork_lineage_pid_start_time = None;
        raw.forkable = false;
        raw.forkpoint_held = true;
        raw.fork_env.clear();
        let (publication, child) = crate::BranchPublication::issue(
            &metadata.grant.intent,
            &before,
            &source,
            &raw,
            "aabbccdd",
        )
        .unwrap();
        let journal = MaterialJournal::at(&metadata.source_directory);
        journal
            .enter_branch_preparation(&metadata.grant, &entry.expected, &before)
            .unwrap();
        engine
            .db
            .update_vm(&source.name, |row| *row = source.clone())
            .unwrap();
        engine.db.insert_vm(&child.name, &child).unwrap();
        let child_path = engine.vm_directory(&child.name);
        let snapshot_path = metadata.source_directory.join("s/aabbccdd");
        for path in [&child_path, &snapshot_path] {
            std::fs::create_dir_all(path).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        journal
            .begin_branch_publication(
                &metadata.grant,
                &entry.expected,
                &publication,
                &before,
                &source,
                &raw,
            )
            .unwrap();
        crate::machine::publish_branch_marker(publication.child(), &child_path).unwrap();
        MaterialJournal::at(&child_path)
            .initialize_branch_child(&publication, &child)
            .unwrap();
        let authority = authority(&source, metadata.grant.intent.source_pid).unwrap();
        journal
            .complete_branch_publication(
                &metadata.grant,
                &entry.expected,
                &publication,
                (&source, &child),
                &child_path,
                &authority,
            )
            .unwrap();
        {
            let mut work = entry.work.lock().unwrap();
            work.prepared.take();
            work.phase = Phase::Published;
            work.snapshot = Some(VerifiedSnapshot {
                before,
                source: source.clone(),
                child: raw,
                _snapshot: crate::export_source::Root::open(&snapshot_path).unwrap(),
                _child: crate::export_source::Root::open(&child_path).unwrap(),
            });
        }
        let creation = entry.ownership.creation.clone().unwrap();
        drop(original);
        let budget =
            ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap();
        let resolution = engine
            .branch_retention
            .claim_resolution(&engine, &creation, &budget)
            .unwrap()
            .unwrap();
        let mut request = UnbootedBranchDisposalRequest {
            operation_id: "dispose-original-child".into(),
            request_sha256: String::new(),
            quiesced: true,
        };
        request.request_sha256 = request.digest(&creation).unwrap();
        Self {
            _root: root,
            engine,
            entry: Some(entry),
            resolution,
            request,
            publication,
            source,
            child,
        }
    }
    fn entry(&self) -> &Arc<Entry> {
        self.entry.as_ref().unwrap()
    }
    fn source_authority(
        &self,
        publication: &crate::BranchPublication,
        source: &VmRecord,
        after: bool,
    ) -> Result<()> {
        assert!(*publication == self.publication);
        assert!(crate::material::hash(source)? == crate::material::hash(&self.source)?);
        let authority = authority(source, publication.change.child_origin.intent.source_pid)?;
        if !authority.running() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let dependents = crate::sdk_compat::source_dependents(
            &self.engine.binding().database,
            self.engine.database_identity,
            &source.name,
            &self.resolution.budget,
        )?;
        assert_eq!(dependents.contains(&self.child.name), !after);
        Ok(())
    }
    fn delete_projection(&self) -> Result<()> {
        let ledger = Ledger::new(self.engine.domain.clone(), &self.resolution.creation)?;
        let (record, _) = ledger.read()?.unwrap();
        assert!(record.stage == Stage::Entered && record.proof.is_none());
        assert!(record.intent.request == self.request);
        self.engine.db.remove_vm(&self.child.name).unwrap();
        std::fs::remove_dir_all(self.engine.vm_directory(&self.child.name)).unwrap();
        Ok(())
    }
    fn run(
        &self,
        observe: bool,
        delete: impl FnOnce(&str) -> Result<()>,
    ) -> Result<UnbootedBranchDisposal> {
        self.resolution.dispose_checked(
            &self.engine,
            &self.request,
            observe,
            |p, s, after| self.source_authority(p, s, after),
            delete,
        )
    }
    fn counts(&self) -> crate::jobs::Counts {
        self.engine.jobs.counts()
    }
}
impl Drop for Model {
    fn drop(&mut self) {
        // This model never entered the SDK or created branch backing disks.
        // Product APIs cannot clear an unresolved entry this way.
        self.engine.branch_retention.entries.lock().unwrap().clear();
        self.engine
            .branch_retention
            .disposed
            .lock()
            .unwrap()
            .clear();
    }
}
fn authority(
    source: &VmRecord,
    pid: (i32, u64),
) -> Result<crate::capture_resolution::SourceAuthority> {
    crate::capture_resolution::SourceAuthority::verify(
        source,
        pid,
        crate::capture_resolution::SourceFacts {
            owner: Some(true),
            runtime_pid: Some(pid.0),
            original_alive: true,
            observed_birth: Some(pid.1),
            excluded: false,
        },
    )
}
#[test]
fn original_published_unbooted_disposal_persists_entry_before_effect_and_keeps_source_snapshot_and_all_charges(
) {
    let model = Model::new();
    let counts = model.counts();
    let source_bytes = std::fs::read(
        model
            .engine
            .vm_directory(&model.source.name)
            .join("smolbox.material-v2.json"),
    )
    .unwrap();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    proof.validate().unwrap();
    assert_eq!(proof.completion, UnbootedBranchDisposalCompletion::Deleted);
    let wire = serde_json::to_value(&proof).unwrap();
    let restored: UnbootedBranchDisposal = serde_json::from_value(wire.clone()).unwrap();
    assert!(restored == proof);
    let mut missing = wire.clone();
    missing.as_object_mut().unwrap().remove("completion");
    assert!(serde_json::from_value::<UnbootedBranchDisposal>(missing).is_err());
    let mut extra = wire;
    extra["native_pid"] = serde_json::json!(123);
    assert!(serde_json::from_value::<UnbootedBranchDisposal>(extra).is_err());
    assert!(proof.publication == model.publication && proof.creation == model.resolution.creation);
    assert_eq!(model.counts(), counts);
    assert!(!model.engine.vm_directory(&model.child.name).exists());
    assert!(model
        .engine
        .vm_directory(&model.source.name)
        .join("s/aabbccdd")
        .exists());
    assert_eq!(
        std::fs::read(
            model
                .engine
                .vm_directory(&model.source.name)
                .join("smolbox.material-v2.json")
        )
        .unwrap(),
        source_bytes
    );
    assert!(model
        .engine
        .observation_gate(&model.source.name)
        .unwrap()
        .try_lock()
        .is_err());
    assert!(model
        .engine
        .observation_gate(&model.child.name)
        .unwrap()
        .try_lock()
        .is_err());
    assert!(model.entry().work.lock().unwrap().phase == Phase::Disposed);
    let again = model
        .run(false, |_| {
            panic!("completed disposal cannot call SDK again")
        })
        .unwrap();
    assert!(again == proof);
    assert!(
        model
            .run(true, |_| panic!("observation cannot call SDK"))
            .unwrap()
            == proof
    );
    assert!(
        !format!("{proof:?} {:?}", model.request).contains(&model.child.labels["smolbox.owner"])
    );
}
#[test]
fn entered_unknown_result_never_replays_sdk_and_only_exact_positive_absence_can_acknowledge() {
    let model = Model::new();
    let counts = model.counts();
    let calls = Cell::new(0);
    let error = model
        .run(false, |_| {
            calls.set(calls.get() + 1);
            model.delete_projection()?;
            Err(Error::uncertain(ErrorCode::Native))
        })
        .unwrap_err();
    assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
    assert!(model.entry().work.lock().unwrap().phase == Phase::DisposalEntered);
    assert!(model
        .run(false, |_| {
            calls.set(calls.get() + 1);
            Ok(())
        })
        .is_err());
    assert_eq!(calls.get(), 1);
    let proof = model
        .run(true, |_| panic!("resolve cannot dispatch deletion"))
        .unwrap();
    proof.validate().unwrap();
    assert_eq!(
        proof.completion,
        UnbootedBranchDisposalCompletion::ResolvedAbsent
    );
    assert_eq!(model.counts(), counts);
}
#[test]
fn unchanged_child_after_failed_sdk_return_keeps_grant_uncertain_and_cannot_retry_or_resolve() {
    let model = Model::new();
    let counts = model.counts();
    assert!(model
        .run(false, |_| Err(Error::uncertain(ErrorCode::Native)))
        .is_err());
    assert!(model.run(false, |_| panic!("no replay")).is_err());
    assert!(model
        .run(true, |_| panic!("no deletion in observer"))
        .is_err());
    assert!(model.engine.db.get_vm(&model.child.name).unwrap().is_some());
    assert_eq!(model.counts(), counts);
}
#[test]
fn boot_entry_changed_child_cache_or_source_cannot_enter_unbooted_disposal() {
    for case in 0..5 {
        let model = Model::new();
        let counts = model.counts();
        match case {
            0 => model.entry().work.lock().unwrap().phase = Phase::BootEntered,
            1 => {
                model
                    .engine
                    .db
                    .update_vm(&model.child.name, |row| {
                        row.state = RecordState::Running;
                        row.pid = Some(234);
                        row.pid_start_time = Some(567);
                    })
                    .unwrap();
            }
            2 => std::fs::create_dir(model.engine.vm_directory(&model.child.name).join("pack"))
                .unwrap(),
            3 => {
                model
                    .engine
                    .db
                    .update_vm(&model.source.name, |row| {
                        row.mem += 1;
                    })
                    .unwrap();
            }
            _ => std::fs::write(
                model
                    .engine
                    .vm_directory(&model.child.name)
                    .join("smolbox.branch-start-v1.json"),
                b"unproved boot journal",
            )
            .unwrap(),
        }
        assert!(model
            .run(false, |_| panic!("unsafe precondition must not dispatch"))
            .is_err());
        assert_eq!(model.counts(), counts);
    }
}
#[test]
fn request_and_proof_domains_bind_creation_activation_and_distinct_disposal_intent() {
    let model = Model::new();
    let counts = model.counts();
    for case in 0..4 {
        let mut request = model.request.clone();
        match case {
            0 => request.quiesced = false,
            1 => request.operation_id = model.resolution.creation.child.operation_id.clone(),
            2 => {
                request.operation_id = model
                    .resolution
                    .creation
                    .initial_release
                    .as_ref()
                    .unwrap()
                    .operation_id
                    .clone()
            }
            _ => request.request_sha256 = "e".repeat(64),
        }
        if case < 3 {
            request.request_sha256 = request.digest(&model.resolution.creation).unwrap();
        }
        assert!(model
            .resolution
            .dispose_checked(
                &model.engine,
                &request,
                false,
                |_, _, _| Ok(()),
                |_| panic!("invalid request cannot dispatch")
            )
            .is_err());
        assert_eq!(model.counts(), counts);
    }
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    for case in 0..4 {
        let mut changed = proof.clone();
        match case {
            0 => {
                changed
                    .creation
                    .initial_release
                    .as_mut()
                    .unwrap()
                    .operation_id = "substituted".into()
            }
            1 => changed.publication.change.child_origin.intent.child.name = "substituted".into(),
            2 => changed.request.operation_id = "substituted".into(),
            _ => changed.schema = 2,
        }
        changed.proof_sha256 = changed.digest().unwrap();
        assert!(changed.validate().is_err());
    }
    let mut changed = model.request.clone();
    changed.operation_id = "other-disposal".into();
    changed.request_sha256 = changed.digest(&model.resolution.creation).unwrap();
    assert!(model
        .resolution
        .dispose_checked(
            &model.engine,
            &changed,
            false,
            |_, _, _| Ok(()),
            |_| panic!("changed request cannot delete")
        )
        .is_err());
}
#[test]
fn public_api_requires_original_epoch_and_cancelled_or_expired_resolution_cannot_enter() {
    let mut model = Model::new();
    let counts = model.counts();
    assert_eq!(
        model
            .resolution
            .dispose_unbooted_child(&model.engine, &model.request)
            .unwrap_err()
            .code,
        ErrorCode::Ownership
    );
    let cancel = crate::Cancellation::default();
    model.resolution.budget = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
    cancel.cancel();
    assert!(model
        .run(false, |_| panic!("cancelled input cannot dispatch"))
        .is_err());
    model.resolution.budget =
        ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap();
    model.resolution.budget.deadline = Instant::now();
    assert!(model
        .run(false, |_| panic!("expired input cannot dispatch"))
        .is_err());
    assert_eq!(model.counts(), counts);
}
#[test]
fn control_admission_precedes_disposal_and_remains_available_after_completion() {
    let model = Model::new();
    let counts = model.counts();
    let occupied = model
        .engine
        .jobs
        .acquire(crate::jobs::Demand::branch_retirement())
        .unwrap();
    assert_eq!(
        model
            .run(false, |_| panic!("no disposal without control admission"))
            .unwrap_err()
            .code,
        ErrorCode::Admission
    );
    assert!(model.entry().work.lock().unwrap().phase == Phase::Published);
    assert!(
        Ledger::new(model.engine.domain.clone(), &model.resolution.creation)
            .unwrap()
            .read()
            .unwrap()
            .is_none()
    );
    drop(occupied);
    model.run(false, |_| model.delete_projection()).unwrap();
    assert_eq!(model.counts(), counts);
    let _control = model
        .engine
        .jobs
        .acquire(crate::jobs::Demand::branch_retirement())
        .unwrap();
}
#[test]
fn protected_ledger_refuses_unsafe_modes_corrupt_records_and_changed_original_child_directory() {
    use std::os::unix::fs::symlink;
    for case in 0..4 {
        let model = Model::new();
        let counts = model.counts();
        let file = Ledger::new(model.engine.domain.clone(), &model.resolution.creation).unwrap();
        match case {
            0 => {
                std::fs::write(file.path(), b"{}").unwrap();
                std::fs::set_permissions(file.path(), std::fs::Permissions::from_mode(0o644))
                    .unwrap();
            }
            1 => {
                let target = model.engine.domain.directory.join("foreign-record");
                std::fs::write(&target, b"{}").unwrap();
                symlink(&target, file.path()).unwrap();
            }
            2 => {
                std::fs::write(file.path(), b"{}").unwrap();
                std::fs::set_permissions(file.path(), std::fs::Permissions::from_mode(0o600))
                    .unwrap();
            }
            _ => {
                let path = model.engine.vm_directory(&model.child.name);
                std::fs::rename(&path, path.with_extension("original")).unwrap();
                std::fs::create_dir(&path).unwrap();
            }
        }
        assert!(model
            .run(false, |_| panic!("unproved custody cannot dispatch"))
            .is_err());
        assert_eq!(model.counts(), counts);
    }
}

#[test]
fn exact_prepared_boot_plan_is_still_unentered_and_has_no_manager_or_guest_effect() {
    let model = Model::new();
    let rootfs = model.engine.domain.directory.join("inert-rootfs");
    std::fs::create_dir(&rootfs).unwrap();
    std::fs::set_permissions(&rootfs, std::fs::Permissions::from_mode(0o700)).unwrap();
    let work = model.entry().work.lock().unwrap();
    let snapshot = work.snapshot.as_ref().unwrap();
    let plan = crate::branch_boot::Plan {
        schema: 1,
        publication: model.publication.clone(),
        source: Directory::capture(&model.entry().ownership.intent.guard.source_root).unwrap(),
        child: Directory::capture(&snapshot._child).unwrap(),
        snapshot: Directory::capture(&snapshot._snapshot).unwrap(),
        rootfs: Directory::capture(&crate::export_source::Root::open(&rootfs).unwrap()).unwrap(),
    };
    crate::branch_boot::Lifecycle::at(snapshot._child.path())
        .prepare(&plan)
        .unwrap();
    drop(work);
    let counts = model.counts();
    assert!(model.run(false, |_| model.delete_projection()).is_ok());
    assert!(model.engine.owned_managers.lock().unwrap().is_empty());
    assert_eq!(model.counts(), counts);
}

#[test]
fn partial_delete_directory_and_sdk_reservation_keep_absence_unproved_until_both_are_gone() {
    let model = Model::new();
    let counts = model.counts();
    assert!(model
        .run(false, |_| {
            model.engine.db.remove_vm(&model.child.name).unwrap();
            Err(Error::uncertain(ErrorCode::Native))
        })
        .is_err());
    assert!(model
        .run(true, |_| panic!("observer cannot delete residual files"))
        .is_err());
    std::fs::remove_dir_all(model.engine.vm_directory(&model.child.name)).unwrap();
    let owner = "reservation-model";
    assert!(model
        .engine
        .db
        .reserve_vm_create(&model.child.name, owner)
        .unwrap());
    assert!(model
        .run(true, |_| panic!("reservation cannot become absence"))
        .is_err());
    model
        .engine
        .db
        .release_vm_create_reservation(&model.child.name, owner)
        .unwrap();
    let proof = model
        .run(true, |_| panic!("positive resolution never calls SDK"))
        .unwrap();
    assert_eq!(
        proof.completion,
        UnbootedBranchDisposalCompletion::ResolvedAbsent
    );
    assert_eq!(model.counts(), counts);
}

#[test]
fn valid_entered_or_returned_boot_journals_cannot_be_treated_as_unentered() {
    for returned in [false, true] {
        let model = Model::new();
        let counts = model.counts();
        let work = model.entry().work.lock().unwrap();
        let snapshot = work.snapshot.as_ref().unwrap();
        let plan = crate::branch_boot::Plan {
            schema: 1,
            publication: model.publication.clone(),
            source: Directory::capture(&model.entry().ownership.intent.guard.source_root).unwrap(),
            child: Directory::capture(&snapshot._child).unwrap(),
            snapshot: Directory::capture(&snapshot._snapshot).unwrap(),
            rootfs: Directory::capture(&snapshot._snapshot).unwrap(),
        };
        let boot = serde_json::json!({
            "owner": {"pid": 123, "birth": 456, "uid": unsafe { libc::geteuid() }},
            "directory_identity": [1, 1], "epoch": model.publication.change.child_origin.intent.epoch,
            "machine": smolvm::agent::vm_dir_hash(&model.child.name), "operation": "a".repeat(32)
        });
        let phase = if returned {
            serde_json::json!({"state":"returned", "boot": boot, "child": null, "sdk_succeeded": false})
        } else {
            serde_json::json!({"state":"entered", "boot": boot})
        };
        let path = snapshot._child.path().join("smolbox.branch-start-v1.json");
        std::fs::write(
            &path,
            serde_json::to_vec(&serde_json::json!({"plan":plan,"phase":phase})).unwrap(),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        drop(work);
        assert!(model
            .run(false, |_| panic!("entered boot is not an unbooted child"))
            .is_err());
        assert_eq!(model.counts(), counts);
    }
}

#[test]
fn historical_completion_never_deletes_or_claims_current_absence_of_recreated_material() {
    let model = Model::new();
    let counts = model.counts();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    let path = model.engine.vm_directory(&model.child.name);
    std::fs::create_dir(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(path.join("foreign-data"), b"preserve this incarnation").unwrap();
    let mut foreign = model.child.clone();
    foreign
        .labels
        .insert("smolbox.owner".into(), "e".repeat(64));
    model.engine.db.insert_vm(&foreign.name, &foreign).unwrap();
    assert!(
        model
            .run(false, |_| panic!(
                "historical result cannot delete recreated material"
            ))
            .unwrap()
            == proof
    );
    assert_eq!(
        std::fs::read(path.join("foreign-data")).unwrap(),
        b"preserve this incarnation"
    );
    assert_eq!(
        crate::material::hash(&model.engine.db.get_vm(&foreign.name).unwrap().unwrap()).unwrap(),
        crate::material::hash(&foreign).unwrap()
    );
    assert_eq!(model.counts(), counts);
}

#[test]
fn missing_protected_completion_is_not_rebuilt_from_memory_phase_or_empty_namespace() {
    let model = Model::new();
    let counts = model.counts();
    model.run(false, |_| model.delete_projection()).unwrap();
    let file = Ledger::new(model.engine.domain.clone(), &model.resolution.creation).unwrap();
    std::fs::remove_file(file.path()).unwrap(); // Inert record-integrity model; no live SDK boundary.
    assert!(model
        .run(false, |_| panic!(
            "missing history cannot authorize a second delete"
        ))
        .is_err());
    assert!(model
        .run(true, |_| panic!(
            "namespace absence cannot reconstruct the original proof"
        ))
        .is_err());
    assert_eq!(model.counts(), counts);
}
