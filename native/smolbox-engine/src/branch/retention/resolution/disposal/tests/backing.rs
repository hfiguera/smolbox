//! Private SDK-row/file and accounting facts only. No VM or SDK delete/boot,
//! process loss, live persistence interruption or independent CLI actor.
use super::*;
use crate::UnbootedBranchBackingReleaseRequest;

fn staged() -> (Model, UnbootedBranchBackingReleaseRequest) {
    let mut model = Model::new();
    let proof = model.run(false, |_| model.delete_projection()).unwrap();
    drop(model.entry.take());
    model
        .resolution
        .archive_checked(&model.engine, &proof)
        .unwrap();
    let mut request = UnbootedBranchBackingReleaseRequest {
        source: proof.publication.receipt.clone(),
        child: proof.publication.child().clone(),
        disposal: proof,
        operation_id: "remove-disposed-backing".into(),
        request_sha256: String::new(),
        quiesced: true,
        backing_removed: true,
    };
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    (model, request)
}
fn budget() -> ReadBudget {
    ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
}
fn remove_source(model: &Model) {
    model.engine.db.remove_vm(&model.source.name).unwrap();
    std::fs::remove_dir_all(model.engine.vm_directory(&model.source.name)).unwrap();
}
fn release(
    model: &Model,
    request: &UnbootedBranchBackingReleaseRequest,
) -> Result<crate::BranchBackingRelease> {
    let expected = request.disposal.clone();
    model
        .engine
        .release_unbooted_backing(request, &budget(), move |record| {
            assert!(record.proof.as_ref() == Some(&expected));
            Ok(()) // Inert original-source collection facts; no enrolled process.
        })
}
#[test]
fn exact_original_disposal_retires_only_its_charge_and_preserves_sibling_and_metadata() {
    let (model, request) = staged();
    let original = model.counts();
    let mut work = model
        .engine
        .jobs
        .acquire(crate::jobs::Demand::branch_source())
        .unwrap();
    work.promote_branch_preparation().unwrap();
    work.promote_branch_backing(7 << 30).unwrap();
    let sibling = work.handoff_disposed_branch().unwrap();
    drop(work);
    remove_source(&model);
    let unrelated = model
        .engine
        .domain
        .directory
        .join("unrelated-backing-model");
    std::fs::write(&unrelated, b"preserved").unwrap();
    let source_gate = model.engine.observation_gate(&model.source.name).unwrap();
    let child_gate = model.engine.observation_gate(&model.child.name).unwrap();
    let jobs = model.engine.jobs.clone();
    let proof = model
        .engine
        .release_unbooted_backing(&request, &budget(), move |_| {
            assert!(source_gate.try_lock().is_err() && child_gate.try_lock().is_err());
            assert_eq!(jobs.counts().control, 1);
            assert_eq!(jobs.counts().work, 0);
            Ok(())
        })
        .unwrap();
    request.matches(&proof).unwrap();
    assert_eq!(proof.native_bytes, original.checkpoint_material);
    let after = model.counts();
    assert_eq!(after.checkpoint_material, 7 << 30);
    assert_eq!(
        after.branch_metadata,
        2 * crate::jobs::BRANCH_BACKING_METADATA
    );
    assert_eq!(
        (after.work, after.children, after.control, after.descriptors),
        (0, 0, 0, 0)
    );
    assert_eq!(std::fs::read(unrelated).unwrap(), b"preserved");
    assert!(model.engine.owned_managers.lock().unwrap().is_empty());
    assert!(model
        .engine
        .branch_retention
        .completed
        .lock()
        .unwrap()
        .is_empty());
    assert!(
        model
            .engine
            .inspect_unbooted_branch_disposal(
                &request.disposal.creation,
                &request.disposal.request,
                &budget(),
            )
            .unwrap()
            == Some(request.disposal)
    );
    drop(sibling);
    assert_eq!(model.counts().checkpoint_material, 0);
    assert_eq!(
        model.counts().branch_metadata,
        crate::jobs::BRANCH_BACKING_METADATA
    );
}
#[test]
fn row_reservation_residual_directory_and_symlink_each_retain_the_whole_charge() {
    for case in 0..7 {
        let (model, request) = staged();
        let before = model.counts();
        if case == 0 {
            std::fs::remove_dir_all(model.engine.vm_directory(&model.source.name)).unwrap();
        } else if case == 1 {
            model.engine.db.remove_vm(&model.source.name).unwrap();
        } else {
            remove_source(&model);
            match case {
                2 => model
                    .engine
                    .db
                    .insert_vm(&model.child.name, &model.child)
                    .unwrap(),
                3 | 4 => {
                    let name = if case == 3 {
                        &model.source.name
                    } else {
                        &model.child.name
                    };
                    model
                        .engine
                        .db
                        .reserve_vm_create(name, "private-model")
                        .unwrap();
                }
                5 => std::fs::create_dir(model.engine.vm_directory(&model.child.name)).unwrap(),
                _ => std::os::unix::fs::symlink(
                    model.engine.domain.directory.join("absent-target"),
                    model.engine.vm_directory(&model.source.name),
                )
                .unwrap(),
            }
        }
        assert!(release(&model, &request).is_err());
        assert_eq!(model.counts(), before);
    }
}
#[test]
fn source_collection_failure_and_missing_original_epoch_do_not_publish_capacity() {
    let (model, request) = staged();
    remove_source(&model);
    let before = model.counts();
    let public = model
        .engine
        .release_unbooted_branch_backing_checked(&request, &budget())
        .unwrap_err();
    assert_eq!(public.dispatch, crate::Dispatch::NotDispatched);
    assert!(model
        .engine
        .release_unbooted_backing(&request, &budget(), |_| {
            Err(Error::before(ErrorCode::Conflict))
        })
        .is_err());
    assert_eq!(model.counts(), before);
    release(&model, &request).unwrap();
    assert_eq!(model.counts().checkpoint_material, 0);
}
#[test]
fn historical_backing_ack_preserves_recreated_names_and_never_requalifies_or_double_releases() {
    let (model, request) = staged();
    remove_source(&model);
    let proof = release(&model, &request).unwrap();
    let before = model.counts();
    let mut foreign = model.child.clone();
    foreign.created_at += 42;
    model.engine.db.insert_vm(&foreign.name, &foreign).unwrap();
    for name in [&model.source.name, &model.child.name] {
        let directory = model.engine.vm_directory(name);
        std::fs::create_dir(&directory).unwrap();
        std::fs::write(directory.join("foreign"), b"preserved").unwrap();
    }
    let again = model
        .engine
        .release_unbooted_backing(&request, &budget(), |_| {
            panic!("known exact release cannot requalify current namespace")
        })
        .unwrap();
    assert!(proof == again);
    assert_eq!(model.counts(), before);
    for name in [&model.source.name, &model.child.name] {
        assert_eq!(
            std::fs::read(model.engine.vm_directory(name).join("foreign")).unwrap(),
            b"preserved"
        );
    }
    assert_eq!(
        model
            .engine
            .db
            .get_vm(&foreign.name)
            .unwrap()
            .unwrap()
            .created_at,
        foreign.created_at
    );
    let mut changed = request;
    changed.operation_id = "different-backing-release".into();
    changed.request_sha256 = changed.digest().unwrap();
    assert!(release(&model, &changed).is_err());
    assert_eq!(model.counts(), before);
}
#[test]
fn altered_disposal_or_missing_archive_and_ledger_cannot_reconstruct_native_authority() {
    for case in 0..4 {
        let (model, mut request) = staged();
        remove_source(&model);
        if case == 0 {
            request.disposal.disposal_sha256 = "f".repeat(64);
            request.disposal.proof_sha256 = request.disposal.digest().unwrap();
            request.request_sha256 = request.digest().unwrap();
            request.validate().unwrap();
        } else if case == 1 {
            // Pure absent-registry model; the original native lease stays local.
            let archived =
                std::mem::take(&mut *model.engine.branch_retention.disposed.lock().unwrap());
            let before = model.counts();
            assert!(release(&model, &request).is_err());
            assert_eq!(model.counts(), before);
            *model.engine.branch_retention.disposed.lock().unwrap() = archived;
            continue;
        } else if case == 2 {
            std::fs::remove_file(
                Ledger::new(model.engine.domain.clone(), &request.disposal.creation)
                    .unwrap()
                    .path(),
            )
            .unwrap();
        } else {
            release(&model, &request).unwrap();
            let releases: Vec<_> = std::fs::read_dir(&model.engine.domain.directory)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .filter(|path| {
                    path.file_name()
                        .unwrap()
                        .to_string_lossy()
                        .starts_with("branch-backing-")
                })
                .collect();
            assert_eq!(releases.len(), 1);
            std::fs::remove_file(&releases[0]).unwrap();
        }
        let before = model.counts();
        assert!(release(&model, &request).is_err());
        assert_eq!(model.counts(), before);
    }
}
#[test]
fn confirmations_full_requests_heads_and_strict_wire_shape_are_bound() {
    let (model, request) = staged();
    let before = model.counts();
    for case in 0..10 {
        let mut wrong = request.clone();
        match case {
            0 => wrong.quiesced = false,
            1 => wrong.backing_removed = false,
            2 => wrong.source.owner_token = "f".repeat(64),
            3 => wrong.source = wrong.disposal.publication.previous.clone(),
            4 => wrong.child.material.as_mut().unwrap().revision += 1,
            5 => wrong.operation_id = wrong.disposal.creation.child.operation_id.clone(),
            6 => wrong.operation_id = wrong.disposal.request.operation_id.clone(),
            7 => {
                wrong.operation_id = wrong
                    .disposal
                    .creation
                    .initial_release
                    .as_ref()
                    .unwrap()
                    .operation_id
                    .clone()
            }
            8 => wrong.child = wrong.disposal.creation.source.clone(),
            _ => wrong.request_sha256 = "f".repeat(64),
        }
        wrong.request_sha256 = if case == 9 {
            wrong.request_sha256.clone()
        } else {
            wrong.digest().unwrap()
        };
        assert!(wrong.validate().is_err());
        assert!(release(&model, &wrong).is_err());
        assert_eq!(model.counts(), before);
    }
    let value = serde_json::to_value(&request).unwrap();
    let roundtrip: UnbootedBranchBackingReleaseRequest =
        serde_json::from_value(value.clone()).unwrap();
    assert!(roundtrip == request);
    for field in ["path", "pid", "native_bytes", "completion"] {
        let mut extra = value.clone();
        extra[field] = serde_json::json!(1);
        assert!(serde_json::from_value::<UnbootedBranchBackingReleaseRequest>(extra).is_err());
    }
    assert!(!format!("{request:?}").contains(&request.child.owner_token));
}
#[test]
fn cancellation_expired_budget_busy_gates_and_control_admission_cannot_free_backing() {
    let (model, request) = staged();
    remove_source(&model);
    let before = model.counts();
    let cancelled = budget();
    cancelled.cancel.cancel();
    assert!(model
        .engine
        .release_unbooted_backing(&request, &cancelled, |_| panic!("cancelled"))
        .is_err());
    let mut expired = budget();
    expired.deadline = Instant::now();
    assert!(model
        .engine
        .release_unbooted_backing(&request, &expired, |_| panic!("expired"))
        .is_err());
    let control = model
        .engine
        .jobs
        .acquire(crate::jobs::Demand::material_resolution())
        .unwrap();
    assert!(release(&model, &request).is_err());
    drop(control);
    let gate = model.engine.observation_gate(&model.source.name).unwrap();
    let lock = gate.try_lock().unwrap();
    assert!(release(&model, &request).is_err());
    drop(lock);
    assert_eq!(model.counts(), before);
    release(&model, &request).unwrap();
    assert_eq!(model.counts().checkpoint_material, 0);
}

#[test]
fn original_actor_epoch_and_pending_source_or_child_are_required_collection_facts() {
    use super::super::archive::backing::collected;
    for case in 0..5 {
        let (model, request) = staged();
        let mut record = Ledger::new(model.engine.domain.clone(), &request.disposal.creation)
            .unwrap()
            .read()
            .unwrap()
            .unwrap()
            .0;
        let root = tempfile::tempdir().unwrap();
        let mut identity = request
            .disposal
            .publication
            .change
            .child_origin
            .intent
            .epoch
            .clone();
        if case == 1 {
            identity = "f".repeat(32);
        }
        let (_host, _launcher, actors) = crate::epoch::tests::fixture_for_binding_and_epoch(
            &root.path().canonicalize().unwrap(),
            None,
            model.engine.binding().clone(),
            identity,
        );
        let pending = if case == 2 || case == 3 {
            Some(
                actors
                    .begin_boot(if case == 2 {
                        &model.source.name
                    } else {
                        &model.child.name
                    })
                    .unwrap(),
            )
        } else {
            None
        };
        if case == 4 {
            // Read-only liveness boundary using this test process, never a VM
            // or a signal/termination campaign. A live original cannot retire.
            let live = crate::OwnerIdentity::capture().unwrap();
            record
                .intent
                .publication
                .change
                .child_origin
                .intent
                .source_pid = (live.pid, live.birth);
        }
        if case == 0 {
            collected(&actors, &record).unwrap();
        } else {
            assert!(collected(&actors, &record).is_err());
        }
        // Only private pending metadata exists; no process was dispatched.
        drop(pending);
    }
}

#[test]
fn expected_source_head_correlates_with_the_caller_while_the_never_booted_child_root_stays_exact() {
    let (model, mut request) = staged();
    let original = request.clone();
    let head = request.source.material.as_mut().unwrap();
    head.revision += 1;
    head.chain_sha256 = "e".repeat(64);
    head.record_sha256 = "e".repeat(64);
    request.request_sha256 = request.digest().unwrap();
    request.validate().unwrap();
    assert_ne!(request.request_sha256, original.request_sha256);
    remove_source(&model);
    let proof = release(&model, &request).unwrap();
    request.matches(&proof).unwrap();
    assert!(proof.publication == original.disposal.publication);
    // The native proof correlates with the caller's expected head; it does not
    // synthesize SDK history for a namespace that is already absent.
    assert!(original.matches(&proof).is_err());
    assert!(release(&model, &original).is_err());
    assert_eq!(model.counts().checkpoint_material, 0);
}
