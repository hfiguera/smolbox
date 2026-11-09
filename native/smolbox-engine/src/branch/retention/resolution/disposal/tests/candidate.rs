//! Original context facts only; no SDK entry, VM, owner loss or native cleanup.
use super::*;
fn probe(model: &Model) -> Result<UnbootedBranchDisposalCandidate> {
    model
        .resolution
        .candidate_checked(&model.engine, |p, source, after| {
            model.source_authority(p, source, after)
        })
}
#[test]
fn candidate_is_readonly_exact_original_publication_and_never_absence_or_release() {
    let model = Model::new();
    let before = model.counts();
    let source_path = model
        .engine
        .vm_directory(&model.source.name)
        .join("smolbox.material-v2.json");
    let bytes = std::fs::read(&source_path).unwrap();
    let result = probe(&model).unwrap();
    result.validate().unwrap();
    assert!(
        result.creation == model.resolution.creation && result.publication == model.publication
    );
    assert_eq!(
        result.preparation_sha256,
        model.entry().expected.metadata_sha256
    );
    assert_eq!(model.counts(), before);
    assert_eq!(std::fs::read(source_path).unwrap(), bytes);
    assert!(model.engine.vm_directory(&model.child.name).exists());
    assert!(Ledger::new(model.engine.domain.clone(), &result.creation)
        .unwrap()
        .read()
        .unwrap()
        .is_none());
    assert!(model.entry().work.lock().unwrap().phase == Phase::Published);
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
    assert!(!format!("{result:?}").contains(&result.creation.child.owner_token));
    let wire = serde_json::to_value(&result).unwrap();
    assert!(
        serde_json::from_value::<UnbootedBranchDisposalCandidate>(wire.clone()).unwrap() == result
    );
    let mut extra = wire;
    extra["dispatched"] = serde_json::json!(true);
    assert!(serde_json::from_value::<UnbootedBranchDisposalCandidate>(extra).is_err());
}
#[test]
fn phases_workers_and_existing_disposal_grants_cannot_become_a_fresh_candidate() {
    for phase in [
        Phase::Prepared,
        Phase::Entered,
        Phase::Verified,
        Phase::DisposalEntered,
        Phase::Disposed,
        Phase::BootEntered,
        Phase::Booted,
        Phase::IdentityReady,
        Phase::Released,
    ] {
        let model = Model::new();
        let counts = model.counts();
        model.entry().work.lock().unwrap().phase = phase;
        assert!(probe(&model).is_err());
        assert_eq!(model.counts(), counts);
    }
    let model = Model::new();
    let worker = Arc::new(());
    model.entry().work.lock().unwrap().worker = Arc::downgrade(&worker);
    assert!(probe(&model).is_err());
    drop(worker);
    let work = model.entry().work.lock().unwrap();
    let original = intent(
        model.entry(),
        work.snapshot.as_ref().unwrap(),
        &model.publication,
        &model.request,
    )
    .unwrap();
    drop(work);
    Ledger::new(model.engine.domain.clone(), &model.resolution.creation)
        .unwrap()
        .write(
            &Record {
                schema: 1,
                intent: original,
                stage: Stage::Entered,
                proof: None,
            },
            None,
        )
        .unwrap();
    assert!(probe(&model).is_err());
}
#[test]
fn original_epoch_budget_control_and_changed_source_are_required_without_effect() {
    let model = Model::new();
    let before = model.counts();
    assert!(model
        .resolution
        .inspect_disposal_candidate(&model.engine)
        .is_err());
    let control = model
        .engine
        .jobs
        .acquire(crate::jobs::Demand::branch_retirement())
        .unwrap();
    assert!(probe(&model).is_err());
    drop(control);
    model
        .engine
        .db
        .update_vm(&model.source.name, |row| row.mem += 1)
        .unwrap();
    assert!(probe(&model).is_err());
    model
        .engine
        .db
        .update_vm(&model.source.name, |row| *row = model.source.clone())
        .unwrap();
    model.resolution.budget.cancel.cancel();
    assert!(probe(&model).is_err());
    assert_eq!(model.counts(), before);
    let mut expired = Model::new();
    expired.resolution.budget.deadline = Instant::now();
    assert!(probe(&expired).is_err());
}
#[test]
fn candidate_hashes_cannot_rebind_initial_release_publication_or_schema() {
    let model = Model::new();
    let proof = probe(&model).unwrap();
    for case in 0..4 {
        let mut wrong = proof.clone();
        match case {
            0 => {
                wrong
                    .creation
                    .initial_release
                    .as_mut()
                    .unwrap()
                    .operation_id = "changed-activation".into()
            }
            1 => wrong.publication.change.child_origin.intent.child.name = "changed-child".into(),
            2 => wrong.schema = 2,
            _ => wrong.preparation_sha256 = "not-a-digest".into(),
        }
        if case == 0 {
            wrong.proof_sha256 = crate::material::hash(&(
                "smolbox-original-unbooted-disposal-candidate-v1",
                wrong.schema,
                &wrong.creation,
                &wrong.publication,
                &wrong.preparation_sha256,
            ))
            .unwrap();
            wrong.validate().unwrap();
            assert!(wrong.matches(&proof.creation).is_err());
        } else {
            assert!(wrong.validate().is_err());
        }
    }
}
