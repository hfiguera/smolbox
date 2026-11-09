//! Private row/enrollment models. The current test process supplies a read-only
//! PID/birth observation; no SDK manager, VM, signal or lifecycle action runs.
use super::*;
use crate::machine::tests::{install_record, test_engine};
use std::cell::Cell;

struct Model {
    _root: tempfile::TempDir,
    engine: crate::Engine,
    receipt: CreationReceipt,
    _actors: tempfile::TempDir,
    _epoch: crate::epoch::ActorEpoch,
    owned: Arc<crate::runtime_boot::Owned>,
    child: crate::OwnerIdentity,
    directory: std::path::PathBuf,
}
impl Model {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let engine = test_engine(root.path());
        let receipt = install_record(&engine);
        let child = crate::OwnerIdentity::capture().unwrap();
        engine
            .db
            .update_vm(&receipt.name, |row| {
                row.state = smolvm::config::RecordState::Running;
                row.pid = Some(child.pid);
                row.pid_start_time = Some(child.birth);
            })
            .unwrap();
        let actors = tempfile::tempdir().unwrap();
        let (_, _, epoch) = crate::epoch::tests::fixture_for_binding(
            &actors.path().canonicalize().unwrap(),
            None,
            engine.binding().clone(),
        );
        let owned = engine
            .runtime_boots
            .reserve(&receipt, &engine.jobs)
            .unwrap();
        owned
            .enroll(
                crate::epoch::tests::complete_model_with_child(
                    epoch.begin_boot(&receipt.name).unwrap(),
                    child,
                ),
                &epoch,
            )
            .unwrap();
        let directory = engine.vm_directory(&receipt.name);
        Self {
            _root: root,
            engine,
            receipt,
            _actors: actors,
            _epoch: epoch,
            owned,
            child,
            directory,
        }
    }
    fn observation(&self) -> BootObservation<'_> {
        BootObservation {
            domain: &self.engine.domain,
            database: &self.engine.binding().database,
            database_identity: self.engine.database_identity,
            directory: &self.directory,
            receipt: &self.receipt,
            owned: &self.owned,
        }
    }
    fn row(&self) -> Vec<u8> {
        serde_json::to_vec(&self.engine.db.get_vm(&self.receipt.name).unwrap()).unwrap()
    }
    fn wait(
        &self,
        budget: &crate::ReadBudget,
        probe: impl FnMut(&crate::ReadBudget) -> Result<()>,
    ) -> Result<Observation> {
        crate::runtime_boot::wait_until_ready(
            budget,
            || {
                self.observation()
                    .observe(Some(self.child.pid), budget)
                    .map(|(observation, _)| observation)
            },
            probe,
        )
    }
}
fn budget() -> crate::ReadBudget {
    crate::ReadBudget::new(Duration::from_secs(2), Cancellation::default()).unwrap()
}

#[test]
fn original_image_boot_snapshot_waits_without_mutating_rows_or_releasing_metadata() {
    let model = Model::new();
    let row = model.row();
    let counts = model.engine.jobs.counts();
    let probes = Cell::new(0);
    let original_budget = budget();
    let observed = model
        .wait(&original_budget, |attempt| {
            assert!(attempt.deadline <= original_budget.deadline);
            probes.set(probes.get() + 1);
            if probes.get() < 3 {
                Err(Error::uncertain(ErrorCode::Native))
            } else {
                Ok(())
            }
        })
        .unwrap();
    assert_eq!(probes.get(), 3);
    assert_eq!(observed.state, ObservedState::Running);
    assert_eq!(
        observed.pid_identity,
        Some((model.child.pid, model.child.birth))
    );
    assert_eq!(observed.resources.unwrap().storage_gib, 1);
    assert_eq!(model.row(), row);
    assert_eq!(model.engine.jobs.counts(), counts);
}

#[test]
fn image_boot_snapshot_rejects_missing_manager_foreign_material_marker_and_child() {
    let model = Model::new();
    for pid in [None, Some(model.child.pid + 1)] {
        assert_eq!(
            model
                .observation()
                .observe(pid, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
    }
    for alteration in 0..4 {
        let model = Model::new();
        model
            .engine
            .db
            .update_vm(&model.receipt.name, |row| match alteration {
                0 => row.cpus += 1,
                1 => row.pid_start_time = Some(model.child.birth + 1),
                2 => {
                    row.state = smolvm::config::RecordState::Stopped;
                    row.pid = None;
                    row.pid_start_time = None;
                }
                _ => row.pid_start_time = None,
            })
            .unwrap();
        assert_eq!(
            model
                .wait(&budget(), |_| panic!("invalid origin was probed"))
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
    }
    std::fs::write(model.directory.join("smolbox.incarnation"), b"foreign").unwrap();
    assert!(model
        .wait(&budget(), |_| panic!("foreign marker was probed"))
        .is_err());
}

#[test]
fn image_boot_changed_after_ping_cannot_reach_bootstrap_or_replace_original_authority() {
    let model = Model::new();
    let counts = model.engine.jobs.counts();
    let probes = Cell::new(0);
    let error = model
        .wait(&budget(), |_| {
            probes.set(probes.get() + 1);
            model
                .engine
                .db
                .update_vm(&model.receipt.name, |row| row.cpus += 1)
                .unwrap();
            Ok(())
        })
        .unwrap_err();
    assert_eq!(error, Error::uncertain(ErrorCode::Ownership));
    assert_eq!(probes.get(), 1);
    assert_eq!(model.engine.jobs.counts(), counts);
    assert!(Arc::ptr_eq(
        &model
            .engine
            .runtime_boots
            .get(&model.receipt)
            .unwrap()
            .unwrap(),
        &model.owned
    ));
}

#[test]
fn image_boot_cancel_and_late_ping_keep_original_row_and_retained_enrollment() {
    let model = Model::new();
    let row = model.row();
    let counts = model.engine.jobs.counts();
    let original_budget = budget();
    let error = model
        .wait(&original_budget, |_| {
            original_budget.cancel.cancel();
            Ok(())
        })
        .unwrap_err();
    assert_eq!(error, Error::uncertain(ErrorCode::State));
    assert_eq!(model.row(), row);
    assert_eq!(model.engine.jobs.counts(), counts);
    assert!(model
        .engine
        .runtime_boots
        .contains(&model.receipt.name)
        .unwrap());
}
