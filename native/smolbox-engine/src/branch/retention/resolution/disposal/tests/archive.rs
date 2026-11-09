//! Pure terminal-job/accounting models; no native manager, VMM or SDK dispatch.
use super::*;

fn historical(model: &Model) -> Result<Option<UnbootedBranchDisposal>> {
    model.engine.inspect_unbooted_branch_disposal(
        &model.resolution.creation,
        &model.request,
        &ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap(),
    )
}
#[test]
fn exact_disposal_retires_only_transient_work_and_preserves_backing_and_publication() {
    let mut model = Model::new();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    let before = model.counts();
    let journal = model
        .engine
        .vm_directory(&model.source.name)
        .join("smolbox.material-v2.json");
    let source_bytes = std::fs::read(&journal).unwrap();
    drop(model.entry.take());
    let completed = model
        .resolution
        .archive_checked(&model.engine, &proof)
        .unwrap();
    assert!(completed == proof);
    assert!(model
        .engine
        .branch_retention
        .entries
        .lock()
        .unwrap()
        .is_empty());
    let after = model.counts();
    assert_eq!(after.checkpoint_material, before.checkpoint_material);
    assert!(after.checkpoint_material > 0);
    assert_eq!(after.branch_metadata, crate::jobs::BRANCH_BACKING_METADATA);
    assert_eq!(
        (after.work, after.children, after.descriptors, after.control),
        (0, 0, 0, 0)
    );
    assert_eq!(
        (after.staging, after.checkpoint_metadata, after.metadata),
        (0, 0, 0)
    );
    assert!(model.engine.owned_managers.lock().unwrap().is_empty());
    assert!(model
        .engine
        .branch_retention
        .completed
        .lock()
        .unwrap()
        .is_empty());
    for name in [&model.source.name, &model.child.name] {
        assert!(model
            .engine
            .observation_gate(name)
            .unwrap()
            .try_lock()
            .is_ok());
    }
    assert!(model
        .engine
        .vm_directory(&model.source.name)
        .join("s/aabbccdd")
        .exists());
    assert_eq!(std::fs::read(journal).unwrap(), source_bytes);
    assert!(historical(&model).unwrap() == Some(proof.clone()));
    assert!(
        model
            .resolution
            .archive_checked(&model.engine, &proof)
            .unwrap()
            == proof
    );
    assert_eq!(model.counts(), after);
    assert!(model.resolution.state_checked(&model.engine).is_err());
}
#[test]
fn additional_original_owners_block_handoff_and_retry_after_they_retire_keeps_exact_charge() {
    let mut model = Model::new();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    let extra = model.entry.take().unwrap();
    let counts = model.counts();
    assert_eq!(
        model
            .resolution
            .archive_checked(&model.engine, &proof)
            .unwrap_err()
            .code,
        ErrorCode::Conflict
    );
    assert_eq!(model.counts(), counts);
    assert!(historical(&model).unwrap().is_none());
    drop(extra);
    model
        .resolution
        .archive_checked(&model.engine, &proof)
        .unwrap();
    assert_eq!(
        model.counts().checkpoint_material,
        counts.checkpoint_material
    );
}
#[test]
fn a_weak_original_reference_blocks_unique_conversion_without_losing_the_registry_entry() {
    let mut model = Model::new();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    let weak = Arc::downgrade(model.entry());
    let counts = model.counts();
    drop(model.entry.take());
    assert_eq!(
        model
            .resolution
            .archive_checked(&model.engine, &proof)
            .unwrap_err()
            .code,
        ErrorCode::Conflict
    );
    assert!(weak.upgrade().is_some());
    assert_eq!(model.counts(), counts);
    assert_eq!(
        model.engine.branch_retention.entries.lock().unwrap().len(),
        1
    );
    drop(weak);
    model
        .resolution
        .archive_checked(&model.engine, &proof)
        .unwrap();
    assert_eq!(
        model.counts().checkpoint_material,
        counts.checkpoint_material
    );
}
#[test]
fn a_rehashed_proof_without_its_exact_completed_ledger_cannot_retire_work() {
    for missing in [false, true] {
        let mut model = Model::new();
        let mut proof = model.run(false, |_| model.delete_projection()).unwrap();
        let counts = model.counts();
        drop(model.entry.take());
        if missing {
            std::fs::remove_file(
                Ledger::new(model.engine.domain.clone(), &model.resolution.creation)
                    .unwrap()
                    .path(),
            )
            .unwrap();
        } else {
            proof.completion = UnbootedBranchDisposalCompletion::ResolvedAbsent;
            proof.proof_sha256 = proof.digest().unwrap();
            proof.validate().unwrap();
        }
        assert!(model
            .resolution
            .archive_checked(&model.engine, &proof)
            .is_err());
        assert_eq!(model.counts(), counts);
        assert!(model
            .engine
            .observation_gate(&model.source.name)
            .unwrap()
            .try_lock()
            .is_err());
        assert!(historical(&model).unwrap().is_none());
    }
}
#[test]
fn control_cancel_deadline_and_missing_live_epoch_preserve_the_whole_job() {
    for case in 0..4 {
        let mut model = Model::new();
        let proof = model.run(false, |_| model.delete_projection()).unwrap();
        drop(model.entry.take());
        let counts = model.counts();
        let occupied = if case == 0 {
            Some(
                model
                    .engine
                    .jobs
                    .acquire(crate::jobs::Demand::branch_retirement())
                    .unwrap(),
            )
        } else {
            None
        };
        if case == 1 {
            model.resolution.budget.cancel.cancel();
        } else if case == 2 {
            model.resolution.budget.deadline = Instant::now();
        }
        let result = if case == 3 {
            model
                .resolution
                .finish_unbooted_disposal(&model.engine, &proof)
        } else {
            model.resolution.archive_checked(&model.engine, &proof)
        };
        assert!(result.is_err());
        drop(occupied);
        assert_eq!(model.counts(), counts);
        assert!(model
            .engine
            .branch_retention
            .disposed
            .lock()
            .unwrap()
            .is_empty());
    }
}
#[test]
fn observed_absence_handoff_preserves_its_provenance_without_boot_or_sdk_replay() {
    let mut model = Model::new();
    assert!(model
        .run(false, |_| {
            model.delete_projection()?;
            Err(Error::uncertain(ErrorCode::Native))
        })
        .is_err());
    let proof = model
        .run(true, |_| panic!("absence resolution never dispatches SDK"))
        .unwrap();
    assert_eq!(
        proof.completion,
        UnbootedBranchDisposalCompletion::ResolvedAbsent
    );
    drop(model.entry.take());
    model
        .resolution
        .archive_checked(&model.engine, &proof)
        .unwrap();
    assert!(historical(&model).unwrap() == Some(proof));
    assert!(model
        .engine
        .branch_child_unstarted(&model.child.name)
        .is_ok());
}
#[test]
fn historical_archive_never_adopts_recreated_material_or_changed_requests() {
    let mut model = Model::new();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    drop(model.entry.take());
    model
        .resolution
        .archive_checked(&model.engine, &proof)
        .unwrap();
    let counts = model.counts();
    let mut foreign = model.child.clone();
    foreign.created_at += 7;
    model.engine.db.insert_vm(&foreign.name, &foreign).unwrap();
    let path = model.engine.vm_directory(&foreign.name);
    std::fs::create_dir(&path).unwrap();
    std::fs::write(path.join("foreign"), b"preserved").unwrap();
    model
        .engine
        .db
        .update_vm(&model.source.name, |row| {
            row.state = RecordState::Stopped;
            row.pid = None;
            row.pid_start_time = None;
        })
        .unwrap();
    assert!(historical(&model).unwrap() == Some(proof.clone()));
    assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"preserved");
    assert_eq!(model.counts(), counts);
    let mut changed = model.request.clone();
    changed.operation_id = "other-disposal".into();
    changed.request_sha256 = changed.digest(&model.resolution.creation).unwrap();
    let budget = ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap();
    assert!(model
        .engine
        .inspect_unbooted_branch_disposal(&model.resolution.creation, &changed, &budget)
        .is_err());
    let mut creation = model.resolution.creation.clone();
    creation.initial_release.as_mut().unwrap().operation_id = "different-release".into();
    changed = model.request.clone();
    changed.request_sha256 = changed.digest(&creation).unwrap();
    assert!(model
        .engine
        .inspect_unbooted_branch_disposal(&creation, &changed, &budget)
        .is_err());
    assert!(
        model
            .resolution
            .archive_checked(&model.engine, &proof)
            .unwrap()
            == proof
    );
}
#[test]
fn missing_archived_ledger_cannot_be_recreated_from_saved_memory() {
    let mut model = Model::new();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    drop(model.entry.take());
    model
        .resolution
        .archive_checked(&model.engine, &proof)
        .unwrap();
    let counts = model.counts();
    std::fs::remove_file(
        Ledger::new(model.engine.domain.clone(), &model.resolution.creation)
            .unwrap()
            .path(),
    )
    .unwrap();
    assert!(historical(&model).is_err());
    assert!(model
        .resolution
        .archive_checked(&model.engine, &proof)
        .is_err());
    assert_eq!(model.counts(), counts);
}

#[test]
fn acknowledgement_resynchronization_requires_the_exact_original_record_version() {
    let model = Model::new();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    let ledger = Ledger::new(model.engine.domain.clone(), &model.resolution.creation).unwrap();
    let (record, version) = ledger.read().unwrap().unwrap();
    ledger.synchronize(&version).unwrap();
    let replacement = model
        .engine
        .domain
        .directory
        .join("inert-ledger-replacement");
    std::fs::write(&replacement, serde_json::to_vec(&record).unwrap()).unwrap();
    std::fs::set_permissions(&replacement, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::rename(&replacement, ledger.path()).unwrap();
    assert_eq!(
        ledger.synchronize(&version).unwrap_err().code,
        ErrorCode::Ownership
    );
    let (current, next) = ledger.read().unwrap().unwrap();
    assert!(current.proof.as_ref() == Some(&proof));
    ledger.synchronize(&next).unwrap();
    std::fs::remove_file(ledger.path()).unwrap();
    assert!(ledger.synchronize(&next).is_err());
}

#[test]
fn proved_disposal_can_retire_transient_work_during_quarantine_without_reopening_admission() {
    let mut model = Model::new();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    let bytes = model.counts().checkpoint_material;
    model.engine.jobs.quarantine(); // Counter model only; no owner or process loss.
    assert!(model
        .entry()
        .ownership
        .intent
        .guard
        ._job
        .check_branch_handoff()
        .is_err());
    drop(model.entry.take());
    model
        .resolution
        .archive_checked(&model.engine, &proof)
        .unwrap();
    assert!(!model.engine.jobs.available());
    assert_eq!(model.counts().work, 0);
    assert_eq!(model.counts().children, 0);
    assert_eq!(model.counts().descriptors, 0);
    assert_eq!(model.counts().checkpoint_material, bytes);
    assert_eq!(
        model.counts().branch_metadata,
        crate::jobs::BRANCH_BACKING_METADATA
    );
    assert!(historical(&model).unwrap() == Some(proof));
    assert!(model
        .engine
        .jobs
        .acquire(crate::jobs::Demand::branch_source())
        .is_err());
}
