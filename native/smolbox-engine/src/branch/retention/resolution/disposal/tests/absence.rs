//! Inert original disposal, SDK-row and namespace models. No VM, SDK deletion,
//! process loss, persistence interruption or independent CLI writer is run.
use super::*;
use crate::{UnbootedBranchChildAbsence, UnbootedBranchChildAbsenceRequest};
fn staged() -> (Model, UnbootedBranchChildAbsenceRequest) {
    let mut model = Model::new();
    let disposal = model.run(false, |_| model.delete_projection()).unwrap();
    drop(model.entry.take());
    model
        .resolution
        .archive_checked(&model.engine, &disposal)
        .unwrap();
    let mut request = UnbootedBranchChildAbsenceRequest {
        disposal,
        operation_id: "retire-original-disposed-child".into(),
        request_sha256: String::new(),
        quiesced: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    (model, request)
}
fn budget() -> ReadBudget {
    ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
}
fn observe(
    model: &Model,
    request: &UnbootedBranchChildAbsenceRequest,
) -> Result<UnbootedBranchChildAbsence> {
    model
        .engine
        .qualify_unbooted_child_absence(request, &budget(), |record| {
            assert!(record.proof.as_ref() == Some(&request.disposal));
            Ok(()) // Original child epoch quiescence as an inert fact only.
        })
}
#[test]
fn positive_fresh_absence_keeps_source_running_snapshot_siblings_and_all_backing_charged() {
    let (model, request) = staged();
    let before = model.counts();
    let source_path = model
        .engine
        .vm_directory(&model.source.name)
        .join("smolbox.material-v2.json");
    let original = std::fs::read(&source_path).unwrap();
    let checked = Cell::new(0);
    let source_gate = model.engine.observation_gate(&model.source.name).unwrap();
    let child_gate = model.engine.observation_gate(&model.child.name).unwrap();
    let proof = model
        .engine
        .qualify_unbooted_child_absence(&request, &budget(), |_| {
            assert!(source_gate.try_lock().is_err() && child_gate.try_lock().is_err());
            assert_eq!(model.counts().control, 1);
            checked.set(checked.get() + 1);
            Ok(())
        })
        .unwrap();
    request.matches(&proof).unwrap();
    assert_eq!(checked.get(), 2);
    assert_eq!(model.counts(), before);
    assert!(before.checkpoint_material > 0);
    assert_eq!(std::fs::read(source_path).unwrap(), original);
    assert!(model
        .engine
        .vm_directory(&model.source.name)
        .join("s/aabbccdd")
        .exists());
    assert!(
        model
            .engine
            .db
            .get_vm(&model.source.name)
            .unwrap()
            .unwrap()
            .state
            == RecordState::Running
    );
    assert!(observe(&model, &request).unwrap() == proof);
    assert_eq!(model.counts(), before);
    assert!(!format!("{proof:?}").contains(&request.disposal.creation.child.owner_token));
}
#[test]
fn fresh_observations_refuse_recreated_rows_reservations_directories_and_redirects_without_cleanup()
{
    for case in 0..4 {
        let (model, request) = staged();
        let proof = observe(&model, &request).unwrap();
        let before = model.counts();
        let child_path = model.engine.vm_directory(&model.child.name);
        match case {
            0 => model
                .engine
                .db
                .insert_vm(&model.child.name, &model.child)
                .unwrap(),
            1 => {
                assert!(model
                    .engine
                    .db
                    .reserve_vm_create(&model.child.name, "private-model")
                    .unwrap());
            }
            2 => std::fs::create_dir(&child_path).unwrap(),
            _ => std::os::unix::fs::symlink(
                model.engine.domain.directory.join("absent-target"),
                &child_path,
            )
            .unwrap(),
        }
        assert!(observe(&model, &request).is_err());
        request.matches(&proof).unwrap();
        assert_eq!(model.counts(), before);
        if case >= 2 {
            assert!(std::fs::symlink_metadata(&child_path).is_ok());
        }
    }
}
#[test]
fn final_recheck_cannot_publish_a_proof_if_the_inert_namespace_projection_changes() {
    let (model, request) = staged();
    let before = model.counts();
    let calls = Cell::new(0);
    let child = model.engine.vm_directory(&model.child.name);
    assert!(model
        .engine
        .qualify_unbooted_child_absence(&request, &budget(), |_| {
            calls.set(calls.get() + 1);
            if calls.get() == 2 {
                std::fs::create_dir(&child).unwrap();
            }
            Ok(())
        })
        .is_err());
    assert_eq!(calls.get(), 2);
    assert!(child.exists());
    assert_eq!(model.counts(), before);
}
#[test]
fn only_the_exact_original_archive_and_protected_ledger_can_authorize_absence() {
    for case in 0..3 {
        let (model, mut request) = staged();
        let before = model.counts();
        if case == 0 {
            request.disposal.disposal_sha256 = "f".repeat(64);
            request.disposal.proof_sha256 = request.disposal.digest().unwrap();
            request.request_sha256 = request.digest().unwrap();
            request.validate().unwrap();
        } else if case == 1 {
            let archived =
                std::mem::take(&mut *model.engine.branch_retention.disposed.lock().unwrap());
            assert!(observe(&model, &request).is_err());
            assert_eq!(model.counts(), before);
            *model.engine.branch_retention.disposed.lock().unwrap() = archived;
            continue;
        } else {
            std::fs::remove_file(
                Ledger::new(model.engine.domain.clone(), &request.disposal.creation)
                    .unwrap()
                    .path(),
            )
            .unwrap();
        }
        assert!(observe(&model, &request).is_err());
        assert_eq!(model.counts(), before);
    }
}
#[test]
fn cancelled_expired_busy_control_or_gates_and_missing_epoch_leave_all_charges_unchanged() {
    let (model, request) = staged();
    let before = model.counts();
    assert!(model
        .engine
        .qualify_unbooted_branch_child_absence(&request, &budget())
        .is_err());
    let cancelled = budget();
    cancelled.cancel.cancel();
    assert!(model
        .engine
        .qualify_unbooted_child_absence(&request, &cancelled, |_| panic!("cancelled"))
        .is_err());
    let mut expired = budget();
    expired.deadline = Instant::now();
    assert!(model
        .engine
        .qualify_unbooted_child_absence(&request, &expired, |_| panic!("expired"))
        .is_err());
    let control = model
        .engine
        .jobs
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    assert!(observe(&model, &request).is_err());
    drop(control);
    for name in [&model.source.name, &model.child.name] {
        let gate = model.engine.observation_gate(name).unwrap();
        let locked = gate.try_lock().unwrap();
        assert!(observe(&model, &request).is_err());
        drop(locked);
    }
    assert_eq!(model.counts(), before);
}
#[test]
fn original_child_epoch_quiescence_is_required_while_a_pending_source_remains_independent() {
    use super::super::archive::absence::collected;
    let (model, request) = staged();
    let ledger = Ledger::new(model.engine.domain.clone(), &request.disposal.creation).unwrap();
    let (record, _) = ledger.read().unwrap().unwrap();
    for case in 0..3 {
        let root = tempfile::tempdir().unwrap();
        let epoch = if case == 1 {
            "f".repeat(32)
        } else {
            record
                .intent
                .publication
                .change
                .child_origin
                .intent
                .epoch
                .clone()
        };
        let (_host, _launcher, actors) = crate::epoch::tests::fixture_for_binding_and_epoch(
            &root.path().canonicalize().unwrap(),
            None,
            model.engine.binding().clone(),
            epoch,
        );
        let pending = if case == 2 {
            Some(actors.begin_boot(&model.child.name).unwrap())
        } else if case == 0 {
            Some(actors.begin_boot(&model.source.name).unwrap())
        } else {
            None
        };
        assert_eq!(collected(&actors, &record).is_ok(), case == 0);
        drop(pending); // Inert pending record only; no child or SDK boot existed.
    }
}
#[test]
fn shared_readers_bind_provenance_full_creation_canonical_request_and_strict_bounds() {
    let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
        "../../../../../../../smolbox-protocol/fixtures/unbooted-branch-child-absence-v1.json"
    ))
    .unwrap();
    for row in rows {
        let proof: UnbootedBranchChildAbsence =
            serde_json::from_value(row["proof"].clone()).unwrap();
        proof.request.matches(&proof).unwrap();
        assert!(UnbootedBranchChildAbsence::issue(proof.request.clone()).unwrap() == proof);
        for case in 0..5 {
            let mut request = proof.request.clone();
            match case {
                0 => request.quiesced = false,
                1 => request.operation_id = request.disposal.creation.child.operation_id.clone(),
                2 => request.operation_id = request.disposal.request.operation_id.clone(),
                3 => request.disposal.disposal_sha256 = "f".repeat(64),
                _ => request.request_sha256 = "f".repeat(64),
            }
            if case != 4 {
                request.request_sha256 = request.digest().unwrap();
            }
            assert!(request.validate().is_err());
        }
        for key in ["completion", "path", "pid", "backing_removed"] {
            let mut changed = row["proof"].clone();
            changed[key] = serde_json::json!(true);
            assert!(serde_json::from_value::<UnbootedBranchChildAbsence>(changed).is_err());
        }
    }
}
