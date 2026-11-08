//! Private row/file/lease models. No SDK fork, boot, deletion, VM enrollment or
//! live persistence failure is performed. Source process facts are synthetic.
use super::*;
use crate::material::MaterialJournal;
use smolvm::config::RecordState;
use std::os::unix::fs::PermissionsExt;

struct Model {
    _root: tempfile::TempDir,
    engine: Engine,
    entry: Arc<Entry>,
    resolution: RetainedBranchResolution,
    publication: crate::BranchPublication,
}
fn budget() -> ReadBudget {
    ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
}
impl Model {
    fn new(pending: bool) -> Self {
        let mut expired = budget();
        expired.deadline = Instant::now();
        let (root, mut engine, metadata, original) =
            crate::branch::retention::tests::fixture_bound_with_budget(true, expired);
        let path = root.path().canonicalize().unwrap();
        std::fs::create_dir_all(path.join("lib")).unwrap();
        std::fs::set_permissions(path.join("lib"), std::fs::Permissions::from_mode(0o700)).unwrap();
        crate::machine::tests::test_model_host_epoch(
            &mut engine,
            &path,
            &metadata.grant.intent.epoch,
        );
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
        let (publication, _) = crate::BranchPublication::issue(
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
        engine.db.insert_vm(&raw.name, &raw).unwrap();
        let child_path = engine.vm_directory(&raw.name);
        let snapshot_path = metadata.source_directory.join("s/aabbccdd");
        for path in [&child_path, &snapshot_path] {
            std::fs::create_dir_all(path).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        if pending {
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
        }
        {
            let mut work = entry.work.lock().unwrap();
            let prepared = work.prepared.take().unwrap();
            work.collected = Some(Box::new(Collected::model_branch_projection(prepared)));
            work.phase = Phase::Verified;
            work.snapshot = Some(VerifiedSnapshot {
                before,
                source,
                child: raw,
                _snapshot: crate::export_source::Root::open(&snapshot_path).unwrap(),
                _child: crate::export_source::Root::open(&child_path).unwrap(),
            });
        }
        engine.track_handle(&metadata.grant.intent.source).unwrap();
        let creation = entry.ownership.creation.clone().unwrap();
        drop(original);
        let resolution = engine
            .retain_branch_resolution(&creation, true, &budget())
            .unwrap()
            .unwrap();
        Self {
            _root: root,
            engine,
            entry,
            resolution,
            publication,
        }
    }
    fn publish(&self) -> Result<crate::BranchPublication> {
        self.resolution
            .publish_checked(&self.engine, |original, budget| {
                self.publish_rows(original, budget)
            })
    }
    fn publish_rows(
        &self,
        original: &RetainedBranchPreparation,
        budget: &ReadBudget,
    ) -> Result<crate::BranchPublication> {
        original.publish_material_checked(
            &self.engine,
            budget,
            || Ok(()), // Private namespace model; no default SDK path qualification.
            |intent, source, child, _| {
                assert!(intent == &self.publication.change.child_origin.intent);
                assert_eq!(child.name, intent.child.name);
                crate::capture_resolution::SourceAuthority::verify(
                    source,
                    intent.source_pid,
                    crate::capture_resolution::SourceFacts {
                        owner: Some(true),
                        runtime_pid: Some(intent.source_pid.0),
                        original_alive: true,
                        observed_birth: Some(intent.source_pid.1),
                        excluded: false,
                    },
                )
            },
        )
    }
}
impl Drop for Model {
    fn drop(&mut self) {
        // Only inert model records are cleared. Product callers cannot retire
        // an entered original job or its leases this way.
        self.engine.branch_retention.entries.lock().unwrap().clear();
    }
}

#[test]
fn fresh_control_finishes_only_original_collected_publication_and_retains_all_backing() {
    for pending in [false, true] {
        let model = Model::new(pending);
        let counts = model.engine.jobs.counts();
        let original_budget = &model.entry.ownership.intent.guard.budget;
        assert!(original_budget.check().is_err());
        assert!(model
            .resolution
            .original
            .publish_material_checked(
                &model.engine,
                original_budget,
                || Ok(()),
                |_, _, _, _| panic!("expired original cannot mutate"),
            )
            .is_err());
        let publication = model.publish().unwrap();
        assert!(publication == model.publication);
        let child = model
            .engine
            .db
            .get_vm(&publication.child().name)
            .unwrap()
            .unwrap();
        assert!(publication.child().matches(&child).unwrap());
        assert!(child.pid.is_none() && child.state == RecordState::Created);
        assert!(model.engine.owned_managers.lock().unwrap().is_empty());
        assert_eq!(model.engine.jobs.counts(), counts);
        assert!(model
            .engine
            .observation_gate(&publication.child().name)
            .unwrap()
            .try_lock()
            .is_err());
        assert!(model
            .engine
            .observation_gate(&publication.receipt.name)
            .unwrap()
            .try_lock()
            .is_err());
        let before = serde_json::to_vec(&child).unwrap();
        assert!(model.publish().unwrap() == publication);
        assert_eq!(
            serde_json::to_vec(&model.engine.db.get_vm(&child.name).unwrap().unwrap()).unwrap(),
            before
        );
        assert_eq!(model.engine.jobs.counts(), counts);
    }
}

#[test]
fn recorded_publication_lookup_preserves_inactive_later_phase_and_all_original_charges() {
    for phase in [
        Phase::BootEntered,
        Phase::Booted,
        Phase::IdentityEntered,
        Phase::IdentityReady,
        Phase::ReleaseEntered,
        Phase::Released,
    ] {
        let model = Model::new(false);
        let publication = model.publish().unwrap();
        let counts = model.engine.jobs.counts();
        let journal = model
            .entry
            .ownership
            .intent
            .guard
            .source_root
            .path()
            .join("smolbox.material-v2.json");
        let before = std::fs::read(&journal).unwrap();
        let records = || {
            [&publication.receipt.name, &publication.child().name]
                .into_iter()
                .map(|name| {
                    serde_json::to_vec(&model.engine.db.get_vm(name).unwrap().unwrap()).unwrap()
                })
                .collect::<Vec<_>>()
        };
        let before_records = records();
        model.entry.work.lock().unwrap().phase = phase;

        // Only the retained in-memory phase is projected. The already completed
        // material proof is historical; this model enters no boot/SDK operation
        // and the lookup must not regress phase or grant manager ownership.
        let saved = model
            .resolution
            .publish_collected_material(&model.engine)
            .unwrap();
        assert!(saved == publication);
        assert!(model.entry.work.lock().unwrap().phase == phase);
        assert!(model.engine.owned_managers.lock().unwrap().is_empty());
        assert_eq!(std::fs::read(&journal).unwrap(), before);
        assert_eq!(records(), before_records);
        assert_eq!(model.engine.jobs.counts(), counts);
    }
}

#[test]
fn later_phase_without_recorded_material_cannot_enter_the_publisher_or_release_charges() {
    for phase in [
        Phase::BootEntered,
        Phase::Booted,
        Phase::IdentityEntered,
        Phase::IdentityReady,
        Phase::ReleaseEntered,
        Phase::Released,
    ] {
        let model = Model::new(false);
        let counts = model.engine.jobs.counts();
        model.entry.work.lock().unwrap().phase = phase;
        assert_eq!(
            model
                .resolution
                .publish_checked(&model.engine, |_, _| panic!(
                    "no fresh later-phase publication"
                ))
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        assert!(model.entry.work.lock().unwrap().phase == phase);
        assert_eq!(model.engine.jobs.counts(), counts);
    }
}

#[test]
fn recorded_material_lookup_keeps_active_work_deadline_epoch_and_original_owner_fences() {
    let mut model = Model::new(false);
    let publication = model.publish().unwrap();
    let counts = model.engine.jobs.counts();
    model.entry.work.lock().unwrap().phase = Phase::Booted;

    let active = Arc::new(());
    model.entry.work.lock().unwrap().worker = Arc::downgrade(&active);
    assert_eq!(
        model
            .resolution
            .publish_collected_material(&model.engine)
            .unwrap_err()
            .code,
        ErrorCode::Conflict
    );
    model.entry.work.lock().unwrap().worker = Weak::new();
    drop(active);

    model.resolution.budget.deadline = Instant::now();
    assert!(model
        .resolution
        .publish_collected_material(&model.engine)
        .is_err());
    let cancel = crate::Cancellation::default();
    model.resolution.budget = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
    cancel.cancel();
    assert!(model
        .resolution
        .publish_collected_material(&model.engine)
        .is_err());

    model.resolution.budget = budget();
    let epoch = model.entry.ownership.intent.intent.epoch.clone();
    let root = model._root.path().canonicalize().unwrap();
    crate::machine::tests::test_model_host_epoch(&mut model.engine, &root, &"f".repeat(32));
    assert_eq!(
        model
            .resolution
            .publish_collected_material(&model.engine)
            .unwrap_err()
            .code,
        ErrorCode::Ownership
    );
    crate::machine::tests::test_model_host_epoch(&mut model.engine, &root, &epoch);
    assert!(
        model
            .resolution
            .publish_collected_material(&model.engine)
            .unwrap()
            == publication
    );

    // Clearing this inert fixture's registry is not a product cleanup path.
    // An on-disk publication alone cannot restore the original native borrow.
    model
        .engine
        .branch_retention
        .entries
        .lock()
        .unwrap()
        .clear();
    assert_eq!(
        model
            .resolution
            .publish_collected_material(&model.engine)
            .unwrap_err()
            .code,
        ErrorCode::Ownership
    );
    assert!(model.entry.work.lock().unwrap().phase == Phase::Booted);
    assert_eq!(model.engine.jobs.counts(), counts);
}

#[test]
fn control_budget_phase_epoch_and_original_evidence_precede_any_publication() {
    let mut model = Model::new(false);
    let counts = model.engine.jobs.counts();
    for phase in [
        Phase::Prepared,
        Phase::Entered,
        Phase::BootEntered,
        Phase::Disposed,
    ] {
        model.entry.work.lock().unwrap().phase = phase;
        assert!(model
            .resolution
            .publish_checked(&model.engine, |_, _| panic!("wrong phase"))
            .is_err());
    }
    model.entry.work.lock().unwrap().phase = Phase::Verified;
    let cancel = crate::Cancellation::default();
    model.resolution.budget = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
    cancel.cancel();
    assert!(model
        .resolution
        .publish_checked(&model.engine, |_, _| panic!("cancelled"))
        .is_err());
    model.resolution.budget = budget();
    let epoch = model.entry.ownership.intent.intent.epoch.clone();
    let root = model._root.path().canonicalize().unwrap();
    crate::machine::tests::test_model_host_epoch(&mut model.engine, &root, &"f".repeat(32));
    assert!(model
        .resolution
        .publish_checked(&model.engine, |_, _| panic!("wrong epoch"))
        .is_err());
    crate::machine::tests::test_model_host_epoch(&mut model.engine, &root, &epoch);
    let creation = model.resolution.creation.clone();
    model.resolution.creation.child.owner_token = "f".repeat(64);
    assert!(model
        .resolution
        .publish_checked(&model.engine, |_, _| panic!("crossed declaration"))
        .is_err());
    model.resolution.creation = creation;
    model.resolution.budget.deadline = Instant::now();
    assert!(model
        .resolution
        .publish_checked(&model.engine, |_, _| panic!("expired"))
        .is_err());
    model.resolution.budget = budget();
    let held = [
        model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap(),
        model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap(),
    ];
    assert!(model
        .resolution
        .publish_checked(&model.engine, |_, _| panic!("no control capacity"))
        .is_err());
    drop(held);
    model.entry.work.lock().unwrap().snapshot.take();
    assert!(model.publish().is_err());
    assert_eq!(model.engine.jobs.counts(), counts);
}

#[test]
fn active_work_missing_metadata_and_changed_rows_keep_unknown_and_all_charges() {
    for failure in 0..3 {
        let model = Model::new(true);
        let counts = model.engine.jobs.counts();
        let active = Arc::new(());
        match failure {
            0 => model.entry.work.lock().unwrap().worker = Arc::downgrade(&active),
            1 => {
                model.entry.work.lock().unwrap().collected.take();
            }
            _ => {
                model
                    .engine
                    .db
                    .update_vm(&model.publication.child().name, |row| {
                        row.labels
                            .insert("model-changed-row".into(), "different".into());
                    })
                    .unwrap();
            }
        }
        let before = serde_json::to_vec(
            &model
                .engine
                .db
                .get_vm(&model.publication.child().name)
                .unwrap(),
        )
        .unwrap();
        assert!(model.publish().is_err());
        assert_eq!(model.engine.jobs.counts(), counts);
        assert_eq!(
            serde_json::to_vec(
                &model
                    .engine
                    .db
                    .get_vm(&model.publication.child().name)
                    .unwrap()
            )
            .unwrap(),
            before
        );
        assert!(model.entry.work.lock().unwrap().phase == Phase::Verified);
        assert!(model.engine.owned_managers.lock().unwrap().is_empty());
    }
}

#[test]
fn late_publication_acknowledgement_stays_uncertain_with_protected_completion_and_charges() {
    let mut model = Model::new(true);
    let cancel = crate::Cancellation::default();
    model.resolution.budget = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
    let counts = model.engine.jobs.counts();
    let result = model
        .resolution
        .publish_checked(&model.engine, |original, budget| {
            let proof = model.publish_rows(original, budget)?;
            cancel.cancel();
            Ok(proof)
        });
    assert!(result.unwrap_err().dispatch == crate::Dispatch::MayHaveDispatched);
    assert!(model.entry.work.lock().unwrap().phase == Phase::Published);
    assert_eq!(model.engine.jobs.counts(), counts);
    assert!(model.engine.owned_managers.lock().unwrap().is_empty());
    let intent = &model.entry.ownership.intent.intent;
    let completed = MaterialJournal::at(model.entry.ownership.intent.guard.source_root.path())
        .completed_branch_publication(
            &intent.source,
            &intent.child.operation_id,
            &intent.request_sha256,
        )
        .unwrap()
        .unwrap();
    assert!(completed == model.publication);
    assert!(model
        .resolution
        .publish_checked(&model.engine, |_, _| panic!(
            "cancelled control cannot refresh"
        ))
        .is_err());
}

#[test]
fn pending_owned_row_marker_and_child_journal_resume_only_the_exact_original_publication() {
    for stage in 0..3 {
        let model = Model::new(true);
        let counts = model.engine.jobs.counts();
        let owned = {
            let work = model.entry.work.lock().unwrap();
            let snapshot = work.snapshot.as_ref().unwrap();
            crate::BranchPublication::issue(
                &model.entry.ownership.intent.intent,
                &snapshot.before,
                &snapshot.source,
                &snapshot.child,
                "aabbccdd",
            )
            .unwrap()
            .1
        };
        model
            .engine
            .db
            .update_vm(&owned.name, |row| *row = owned.clone())
            .unwrap();
        let directory = model.engine.vm_directory(&owned.name);
        if stage >= 1 {
            crate::machine::publish_branch_marker(model.publication.child(), &directory).unwrap();
        }
        if stage >= 2 {
            MaterialJournal::at(&directory)
                .initialize_branch_child(&model.publication, &owned)
                .unwrap();
        }
        let before = serde_json::to_vec(&owned).unwrap();
        let publication = model.publish().unwrap();
        assert!(publication == model.publication);
        assert_eq!(
            serde_json::to_vec(&model.engine.db.get_vm(&owned.name).unwrap().unwrap()).unwrap(),
            before
        );
        assert_eq!(model.engine.jobs.counts(), counts);
        assert!(
            model
                .resolution
                .original
                .publish_material(&model.engine)
                .unwrap()
                == publication
        );
        assert!(
            model
                .resolution
                .publish_collected_material(&model.engine)
                .unwrap()
                == publication
        );
        assert_eq!(model.engine.jobs.counts(), counts);
    }
}

#[test]
fn exact_persisted_material_never_reconstructs_missing_original_registry_authority() {
    let model = Model::new(true);
    model.publish().unwrap();
    let counts = model.engine.jobs.counts();
    model
        .engine
        .branch_retention
        .entries
        .lock()
        .unwrap()
        .clear();
    assert!(model
        .resolution
        .publish_collected_material(&model.engine)
        .is_err());
    assert_eq!(model.engine.jobs.counts(), counts);
    assert!(model.engine.owned_managers.lock().unwrap().is_empty());
}
