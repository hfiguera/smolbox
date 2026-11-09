//! Inert original actor/file/SQLite qualification models. No manager constructor,
//! SDK lifecycle calls, VM, process loss or live persistence interruption.
use super::*;
use crate::{PartialBranchCleanupCandidate, PartialBranchCleanupState};
use std::time::{Duration, Instant};

fn staged(mode: u8) -> Model {
    let model = Model::new(mode);
    model.enter();
    model
        .original
        .engine
        .db
        .remove_vm(&model.original.child.name)
        .unwrap();
    model
}
fn qualify(model: &Model) -> Result<PartialBranchCleanupState> {
    model.original.resolution.qualify_partial_cleanup_checked(
        &model.original.engine,
        &model.intent.request,
        &model.epoch,
        |work, intent| {
            assert!(work.boot.is_none());
            if *intent != model.intent {
                return Err(Error::before(ErrorCode::Ownership));
            }
            Ok(model.enrollment.clone())
        },
        |p, s, after| {
            assert!(after);
            model.original.source_authority(p, s, after)
        },
    )
}
fn cleanup_path(model: &Model) -> std::path::PathBuf {
    super::super::residual::file(
        model.original.engine.domain.clone(),
        &model.intent.request.collection_request.creation,
    )
    .unwrap()
    .path
}
fn budget() -> ReadBudget {
    ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
}

#[test]
fn original_residual_heads_qualify_without_grant_removal_publication_or_charge_release() {
    for mode in 0..4 {
        let model = staged(mode);
        let before = model.original.counts();
        let main = std::fs::read(model.ledger().path()).unwrap();
        let child =
            std::fs::read(model.plan.child.path.join("smolbox.branch-start-v1.json")).unwrap();
        let source =
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap();
        for _ in 0..2 {
            let PartialBranchCleanupState::Residual { candidate } = qualify(&model).unwrap() else {
                panic!("residual")
            };
            candidate.matches_request(&model.intent.request).unwrap();
            assert!(candidate.publication == model.intent.publication);
            assert!(candidate.release == model.intent.release);
            assert_eq!(
                candidate.disposal_sha256,
                crate::material::hash(&model.intent).unwrap()
            );
            assert_eq!(model.original.counts(), before);
            assert_eq!(std::fs::read(model.ledger().path()).unwrap(), main);
            assert_eq!(
                std::fs::read(model.plan.child.path.join("smolbox.branch-start-v1.json")).unwrap(),
                child
            );
            assert_eq!(
                std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap(),
                source
            );
            assert!(!cleanup_path(&model).exists());
            assert!(model.plan.child.path.exists() && model.plan.snapshot.path.exists());
        }
    }
}

#[test]
fn rows_reservations_replaced_or_symlinked_roots_changed_source_and_current_handles_refuse_before_grant(
) {
    for case in 0..7 {
        let model = staged(1);
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
                    .reserve_vm_create(&model.original.child.name, "reserved-model")
                    .unwrap());
            }
            2 | 3 => {
                std::fs::rename(
                    &model.plan.child.path,
                    model.plan.child.path.with_extension("preserved-model"),
                )
                .unwrap();
                if case == 2 {
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
            4 => {
                model
                    .original
                    .engine
                    .db
                    .update_vm(&model.original.source.name, |s| s.created_at += 1)
                    .unwrap();
            }
            5 => model
                .original
                .engine
                .track_handle(model.intent.head())
                .unwrap(),
            _ => {
                std::fs::remove_file(model.ledger().path()).unwrap();
            }
        }
        let before = model.original.counts();
        assert!(qualify(&model).is_err());
        assert_eq!(model.original.counts(), before);
        assert!(!cleanup_path(&model).exists());
        assert!(model.plan.child.path.exists());
    }
}

#[test]
fn positive_original_absence_resolves_existing_disposal_instead_of_creating_cleanup() {
    for mode in 0..4 {
        let model = staged(mode);
        std::fs::remove_dir_all(&model.plan.child.path).unwrap();
        let before = model.original.counts();
        let PartialBranchCleanupState::Disposed { proof } = qualify(&model).unwrap() else {
            panic!("terminal")
        };
        assert!(proof.completion == PartialBranchDisposalCompletion::ResolvedAbsent);
        assert!(proof.request == model.intent.request);
        assert!(model.ledger().read().unwrap().unwrap().0.proof.as_ref() == Some(&*proof));
        assert!(!cleanup_path(&model).exists());
        assert_eq!(model.original.counts(), before);
        assert!(model.plan.source.path.exists() && model.plan.snapshot.path.exists());
        assert!(
            matches!(qualify(&model).unwrap(), PartialBranchCleanupState::Disposed { proof: saved } if saved == proof)
        );
    }
}

#[test]
fn retained_and_archived_terminal_disposal_preserve_both_original_completion_provenances() {
    for mode in 0..4 {
        for resolved in [false, true] {
            let mut model = Model::new(mode);
            let proof = model.disposed(resolved);
            let before = model.original.counts();
            assert!(
                matches!(qualify(&model).unwrap(), PartialBranchCleanupState::Disposed { proof: saved } if *saved == proof)
            );
            assert_eq!(model.original.counts(), before);
            drop(model.original.entry.take());
            model.archive(&proof).unwrap();
            let archived = model.original.counts();
            // Historical proof lookup does not touch newly recreated names or
            // require a live source. No new manager or namespace owner is adopted.
            model
                .original
                .engine
                .db
                .remove_vm(&model.original.source.name)
                .unwrap();
            std::fs::remove_dir_all(&model.plan.source.path).unwrap();
            model
                .original
                .engine
                .db
                .insert_vm(&model.original.child.name, &model.original.child)
                .unwrap();
            std::fs::create_dir(&model.plan.child.path).unwrap();
            std::fs::write(model.plan.child.path.join("foreign"), b"preserved").unwrap();
            model
                .original
                .engine
                .track_handle(model.intent.head())
                .unwrap();
            let saved = model
                .original
                .engine
                .qualify_partial_branch_cleanup(&model.intent.request, &budget())
                .unwrap();
            assert!(
                matches!(saved, PartialBranchCleanupState::Disposed { proof: saved } if *saved == proof)
            );
            assert_eq!(
                std::fs::read(model.plan.child.path.join("foreign")).unwrap(),
                b"preserved"
            );
            assert_eq!(model.original.counts(), archived);
            assert!(!cleanup_path(&model).exists());
        }
    }
}

#[test]
fn an_existing_cleanup_history_cannot_be_reinterpreted_as_fresh_eligibility_or_ordinary_disposal() {
    for terminal in [false, true] {
        let mut model = Model::new(1);
        let proof = if terminal {
            Some(model.disposed(false))
        } else {
            model.enter();
            None
        };
        // A malformed private cleanup path must also refuse; a successful read
        // is not needed to identify that no fresh public action may be minted.
        std::fs::write(cleanup_path(&model), b"{}").unwrap();
        std::fs::set_permissions(cleanup_path(&model), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let before = model.original.counts();
        assert!(qualify(&model).is_err());
        assert_eq!(model.original.counts(), before);
        if let Some(proof) = proof {
            drop(model.original.entry.take());
            model.archive(&proof).unwrap();
            assert!(model
                .original
                .engine
                .qualify_partial_branch_cleanup(&model.intent.request, &budget())
                .is_err());
        }
        assert_eq!(std::fs::read(cleanup_path(&model)).unwrap(), b"{}");
    }
}

#[test]
fn absent_paths_without_original_rows_collection_or_source_never_supply_qualification() {
    for case in 0..4 {
        let model = staged(0);
        std::fs::remove_dir_all(&model.plan.child.path).unwrap();
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
                    .reserve_vm_create(&model.original.child.name, "retained-model")
                    .unwrap());
            }
            2 => {
                model
                    .original
                    .engine
                    .db
                    .remove_vm(&model.original.source.name)
                    .unwrap();
            }
            _ => {
                std::fs::remove_file(model.ledger().path()).unwrap();
            }
        }
        let before = model.original.counts();
        assert!(qualify(&model).is_err());
        assert_eq!(model.original.counts(), before);
        assert!(!cleanup_path(&model).exists());
    }
}

#[test]
fn cancelled_expired_busy_worker_and_unavailable_control_cannot_qualify_or_publish() {
    for case in 0..4 {
        let mut model = staged(3);
        let active = Arc::new(());
        let mut controls = vec![];
        match case {
            0 => model.original.resolution.budget.cancel.cancel(),
            1 => model.original.resolution.budget.deadline = Instant::now(),
            2 => model.original.entry().work.lock().unwrap().worker = Arc::downgrade(&active),
            _ => {
                while let Ok(lease) = model
                    .original
                    .engine
                    .jobs
                    .acquire(crate::jobs::Demand::material_resolution())
                {
                    controls.push(lease);
                }
            }
        }
        let before = model.original.counts();
        assert!(qualify(&model).is_err());
        assert_eq!(model.original.counts(), before);
        assert!(model.ledger().read().unwrap().unwrap().0.proof.is_none());
        assert!(!cleanup_path(&model).exists());
    }
}

#[test]
fn source_or_primary_history_change_during_qualification_cannot_issue_a_candidate() {
    for case in 0..2 {
        let model = staged(2);
        let calls = Cell::new(0);
        let result = model.original.resolution.qualify_partial_cleanup_checked(
            &model.original.engine,
            &model.intent.request,
            &model.epoch,
            |_, _| Ok(model.enrollment.clone()),
            |p, s, after| {
                model.original.source_authority(p, s, after)?;
                calls.set(calls.get() + 1);
                if calls.get() == 1 {
                    if case == 0 {
                        model
                            .original
                            .engine
                            .db
                            .update_vm(&model.original.source.name, |s| s.created_at += 1)
                            .unwrap();
                    } else {
                        let (record, version) = model.ledger().read().unwrap().unwrap();
                        model.ledger().write(&record, Some(version)).unwrap();
                    }
                }
                Ok(())
            },
        );
        assert!(result.is_err());
        assert!(!cleanup_path(&model).exists());
    }
}

#[test]
fn candidate_hashes_are_strict_redacted_and_cannot_be_used_as_disposal_or_cleanup_proof() {
    let model = staged(3);
    let PartialBranchCleanupState::Residual { candidate } = qualify(&model).unwrap() else {
        panic!("candidate")
    };
    let value = serde_json::to_value(&candidate).unwrap();
    assert!(serde_json::from_value::<crate::PartialBranchDisposal>(value.clone()).is_err());
    assert!(serde_json::from_value::<crate::PartialBranchDisposalCleanup>(value.clone()).is_err());
    let parsed: PartialBranchCleanupCandidate = serde_json::from_value(value.clone()).unwrap();
    parsed.matches_request(&model.intent.request).unwrap();
    assert!(!format!("{parsed:?}").contains(&parsed.proof_sha256));
    let mut altered = value.clone();
    altered["completion"] = serde_json::json!("resolved_absent");
    assert!(serde_json::from_value::<PartialBranchCleanupCandidate>(altered).is_err());
    let mut changed = parsed.clone();
    changed.disposal_sha256 = "0".repeat(64);
    assert!(changed.validate().is_err());
    let mut request = model.intent.request.clone();
    request.operation_id = "other-disposal".into();
    request.request_sha256 = request.digest().unwrap();
    assert!(parsed.matches_request(&request).is_err());
    assert!(
        serde_json::to_vec(&parsed).unwrap().len() <= crate::PARTIAL_BRANCH_CLEANUP_CANDIDATE_BYTES
    );
}
