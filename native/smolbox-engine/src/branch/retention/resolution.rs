//! Exclusive access to an original entered branch after its creation borrower
//! retires. Phase lookup is distinct from explicit unbooted disposal and its
//! proof. Boot, activation, source/snapshot cleanup and backing release remain
//! separate original-context operations.
use super::*;
mod collection;
pub(super) mod disposal;
pub(super) mod partial_disposal;
mod ready;
pub use disposal::{
    UnbootedBranchDisposal, UnbootedBranchDisposalCandidate, UnbootedBranchDisposalCompletion,
    UnbootedBranchDisposalRequest,
};
use std::time::{Duration, Instant};

const CREATION_BYTES: usize = 16 * 1024;
pub(super) fn validate_creation(request: &BranchCreateRequest) -> Result<()> {
    request.validate_declaration()?;
    if serde_json::to_vec(request)
        .map_err(|_| Error::before(ErrorCode::Io))?
        .len()
        > CREATION_BYTES
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(())
}
fn validate_budget(budget: &ReadBudget) -> Result<()> {
    budget.check()?;
    if budget.deadline.saturating_duration_since(Instant::now()) > Duration::from_secs(30) {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(())
}
/// An exclusive borrow of the same retained job, never reconstructed SDK
/// authority. The registry retains its original gates, runtime, manager and full
/// backing until explicit lifecycle handoff. Dropping this token releases only
/// the borrow. Its finite
/// captured deadline and cancellation cannot be refreshed through state lookup.
pub struct RetainedBranchResolution {
    original: RetainedBranchPreparation,
    creation: BranchCreateRequest,
    budget: ReadBudget,
}
impl std::fmt::Debug for RetainedBranchResolution {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RetainedBranchResolution")
            .finish_non_exhaustive()
    }
}
impl RetainedBranchResolution {
    /// Original in-memory phase only. This is not current process liveness,
    /// child absence/readiness, permission to replay, or capacity-release proof.
    pub fn state(&self, engine: &Engine) -> Result<BranchPreparationState> {
        validate_budget(&self.budget)?;
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        self.verify_epoch(engine)?;
        self.state_checked(engine)
    }
    fn verify_epoch(&self, engine: &Engine) -> Result<()> {
        self.budget.check()?;
        let entry = self.original.entry(engine)?;
        if engine.observation_epoch().as_deref() != Some(&entry.ownership.intent.intent.epoch) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn state_checked(&self, engine: &Engine) -> Result<BranchPreparationState> {
        self.budget.check()?;
        engine.verify_database_identity()?;
        let entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
        let state = self.original.state(engine)?;
        self.budget.check()?;
        Ok(state)
    }
}
fn verify_original(engine: &Engine, entry: &Entry, creation: &BranchCreateRequest) -> Result<()> {
    let original = &entry.ownership.intent;
    if entry.ownership.creation.as_ref() != Some(creation)
        || !Arc::ptr_eq(&original.guard.domain, &engine.domain)
        || !Arc::ptr_eq(&original.guard._runtime, &engine.runtime)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    original.intent.matches_creation(creation)?;
    original.guard.source_root.verify()?;
    engine.domain.verify()?;
    require_marker(engine, &original.intent.source)
}
impl Engine {
    /// Retain only a known original entered job after explicit request
    /// quiescence. Missing registry state proves no absence. Prepared-only and
    /// completed creations use their separate APIs. No SDK call or journal
    /// mutation occurs here, and no manager is reconstructed from inventory.
    pub fn retain_branch_resolution(
        &self,
        creation: &BranchCreateRequest,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<Option<RetainedBranchResolution>> {
        validate_budget(budget)?;
        creation.validate(self)?;
        validate_creation(creation)?;
        if !quiesced {
            return Err(Error::before(ErrorCode::Validation));
        }
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        self.domain.verify()?;
        self.verify_database_identity()?;
        let original = self
            .branch_retention
            .claim_resolution(self, creation, budget)?;
        if let Some(token) = &original {
            token.verify_epoch(self)?;
            token.state_checked(self)?;
        }
        budget.check()?;
        Ok(original)
    }
}
impl Registry {
    // The public wrapper checks the live engine epoch before returning a token.
    // Private tests use inert original-entry models, never VMM enrollment.
    fn claim_resolution(
        self: &Arc<Self>,
        engine: &Engine,
        creation: &BranchCreateRequest,
        budget: &ReadBudget,
    ) -> Result<Option<RetainedBranchResolution>> {
        validate_budget(budget)?;
        validate_creation(creation)?;
        if !Arc::ptr_eq(self, &engine.branch_retention)
            || !Arc::ptr_eq(&self.domain, &engine.domain)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.domain.verify()?;
        let entries = self
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let completed = self
            .completed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if super::super::creation::select_completion(
            creation,
            completed.values().map(|child| &child.result),
            budget,
        )?
        .is_some()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let origin = |receipt: &CreationReceipt| {
            let mut root = receipt.clone();
            root.material = None;
            root
        };
        let mut selected = None;
        for (key, entry) in entries.iter() {
            budget.check()?;
            let intent = &entry.ownership.intent.intent;
            if intent.child.name != creation.child.name
                && !(intent.child.operation_id == creation.child.operation_id
                    && origin(&intent.source) == origin(&creation.source))
            {
                continue;
            }
            verify_original(engine, entry, creation)?;
            if selected.is_some() {
                return Err(Error::before(ErrorCode::Ownership));
            }
            selected = Some((key, entry));
        }
        let Some((key, entry)) = selected else {
            return Ok(None);
        };
        let mut borrower = entry
            .borrower
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if borrower.upgrade().is_some() || work.worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if work.phase == Phase::Prepared {
            return Err(Error::before(ErrorCode::State));
        }
        budget.check()?;
        let owner = Arc::new(());
        *borrower = Arc::downgrade(&owner);
        Ok(Some(RetainedBranchResolution {
            original: RetainedBranchPreparation {
                registry: Arc::downgrade(self),
                key: key.clone(),
                borrower: owner,
            },
            creation: creation.clone(),
            budget: budget.clone(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn budget() -> ReadBudget {
        ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
    }
    fn creation(entry: &Entry) -> BranchCreateRequest {
        entry.ownership.creation.clone().unwrap()
    }
    fn entered(engine: &Engine, entry: &Entry, metadata: &crate::branch_worker::Metadata) {
        let record = engine
            .db
            .get_vm(&metadata.grant.intent.source.name)
            .unwrap()
            .unwrap();
        entry.work.lock().unwrap().phase = Phase::Entered;
        crate::material::MaterialJournal::at(&metadata.source_directory)
            .enter_branch_preparation(&metadata.grant, &entry.expected, &record)
            .unwrap();
    }
    // Only inert private metadata/PID/spool models are used. No test enters the
    // SDK, starts/stops a VMM, loses an owner, or creates branch backing disks.
    fn finish_model(engine: &Engine, entry: Arc<Entry>) {
        engine.branch_retention.entries.lock().unwrap().clear();
        drop(entry);
    }
    #[test]
    fn exact_full_creation_reborrows_only_the_original_entered_context_and_keeps_all_charges() {
        let (_temp, engine, metadata, original) = super::super::tests::fixture_bound(true);
        let entry = original.entry(&engine).unwrap();
        let request = creation(&entry);
        entered(&engine, &entry, &metadata);
        let counts = engine.jobs.counts();
        let bytes =
            std::fs::read(metadata.source_directory.join("smolbox.material-v2.json")).unwrap();
        assert_eq!(
            engine
                .branch_retention
                .claim_resolution(&engine, &request, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(original);
        let resolution = engine
            .branch_retention
            .claim_resolution(&engine, &request, &budget())
            .unwrap()
            .unwrap();
        let selected = resolution.original.entry(&engine).unwrap();
        assert!(Arc::ptr_eq(&selected, &entry));
        assert!(Arc::ptr_eq(&selected.ownership, &entry.ownership));
        assert!(Arc::ptr_eq(
            &selected.ownership.intent.guard._runtime,
            &engine.runtime
        ));
        drop(selected);
        assert_eq!(
            resolution.state_checked(&engine).unwrap(),
            BranchPreparationState::Unresolved
        );
        assert_eq!(
            resolution.state(&engine).unwrap_err().code,
            ErrorCode::Ownership
        ); // No live epoch exists.
        assert_eq!(engine.jobs.counts(), counts);
        assert_eq!(
            engine
                .branch_retention
                .claim_resolution(&engine, &request, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        assert!(engine
            .observation_gate(&request.source.name)
            .unwrap()
            .try_lock()
            .is_err());
        assert!(engine
            .observation_gate(&request.child.name)
            .unwrap()
            .try_lock()
            .is_err());
        assert!(!format!("{resolution:?}").contains(&request.child.owner_token));
        assert_eq!(
            std::fs::read(metadata.source_directory.join("smolbox.material-v2.json")).unwrap(),
            bytes
        );
        drop(resolution);
        assert_eq!(engine.jobs.counts(), counts);
        let again = engine
            .branch_retention
            .claim_resolution(&engine, &request, &budget())
            .unwrap()
            .unwrap();
        assert_eq!(
            again.original.prepare_fork(&engine).unwrap_err().code,
            ErrorCode::State
        );
        assert_eq!(
            again.original.abort(&engine, &budget()).unwrap_err().code,
            ErrorCode::State
        );
        assert_eq!(engine.jobs.counts(), counts);
        finish_model(&engine, entry);
    }
    #[test]
    fn active_workers_and_prepared_only_or_legacy_unbound_entries_cannot_be_claimed() {
        for bound in [false, true] {
            let (_temp, engine, metadata, original) = super::super::tests::fixture_bound(bound);
            let entry = original.entry(&engine).unwrap();
            let request = if bound {
                creation(&entry)
            } else {
                crate::branch::prepared_retirement::tests::request(&metadata.grant.intent).creation
            };
            drop(original);
            assert!(engine
                .branch_retention
                .claim_resolution(&engine, &request, &budget())
                .is_err());
            entered(&engine, &entry, &metadata);
            let worker = Arc::new(());
            entry.work.lock().unwrap().worker = Arc::downgrade(&worker);
            assert!(engine
                .branch_retention
                .claim_resolution(&engine, &request, &budget())
                .is_err());
            drop(worker); // Pure collection-state model; no process exists.
            if bound {
                let resolution = engine
                    .branch_retention
                    .claim_resolution(&engine, &request, &budget())
                    .unwrap()
                    .unwrap();
                drop(resolution);
            } else {
                assert_eq!(
                    engine
                        .branch_retention
                        .claim_resolution(&engine, &request, &budget())
                        .unwrap_err()
                        .code,
                    ErrorCode::Ownership
                );
            }
            finish_model(&engine, entry);
        }
    }
    #[test]
    fn changed_source_child_policy_or_unused_initial_release_cannot_replace_frozen_creation() {
        let (_temp, engine, metadata, original) = super::super::tests::fixture_bound(true);
        let entry = original.entry(&engine).unwrap();
        let request = creation(&entry);
        assert!(request.initial_release.is_some());
        entered(&engine, &entry, &metadata);
        drop(original);
        let counts = engine.jobs.counts();
        for field in 0..8 {
            let mut changed = request.clone();
            match field {
                0 => changed.source.owner_token = "e".repeat(64),
                1 => changed.source.domain_generation = "e".repeat(32),
                2 => changed.child.owner_token = "e".repeat(64),
                3 => changed.child.operation_id = "other-operation".into(),
                4 => changed.child.name = "another-child".into(),
                5 => changed.approval.resources.disk_gb += 1,
                6 => {
                    changed.initial_release.as_mut().unwrap().operation_id =
                        "other-activation".into()
                }
                _ => changed.initial_release.as_mut().unwrap().request_sha256 = "e".repeat(64),
            }
            validate_creation(&changed).unwrap();
            assert_eq!(
                engine
                    .branch_retention
                    .claim_resolution(&engine, &changed, &budget())
                    .unwrap_err()
                    .code,
                ErrorCode::Ownership
            );
            assert_eq!(engine.jobs.counts(), counts);
        }
        finish_model(&engine, entry);
    }
    #[test]
    fn cancellation_deadline_and_foreign_owner_do_not_release_or_refresh_the_original_job() {
        let (_temp, engine, metadata, original) = super::super::tests::fixture_bound(true);
        let entry = original.entry(&engine).unwrap();
        let request = creation(&entry);
        entered(&engine, &entry, &metadata);
        drop(original);
        let counts = engine.jobs.counts();
        let other_root = tempfile::tempdir().unwrap();
        let other = crate::machine::tests::test_engine(other_root.path());
        assert_eq!(
            engine
                .branch_retention
                .claim_resolution(&other, &request, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(
            engine
                .retain_branch_resolution(&request, false, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Validation
        );
        let long = ReadBudget::for_checkpoint_work(
            Duration::from_secs(60),
            crate::Cancellation::default(),
        )
        .unwrap();
        assert_eq!(
            engine
                .retain_branch_resolution(&request, true, &long)
                .unwrap_err()
                .code,
            ErrorCode::Validation
        );
        let cancel = crate::Cancellation::default();
        let cancelled = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
        let mut resolution = engine
            .branch_retention
            .claim_resolution(&engine, &request, &cancelled)
            .unwrap()
            .unwrap();
        cancel.cancel();
        assert_eq!(
            resolution.state_checked(&engine).unwrap_err().code,
            ErrorCode::State
        );
        resolution.budget = budget(); // Private test can restore only the budget value, never engine authority.
        resolution.budget.deadline = Instant::now();
        assert_eq!(
            resolution.state_checked(&engine).unwrap_err().code,
            ErrorCode::State
        );
        assert_eq!(engine.jobs.counts(), counts);
        drop(resolution);
        // Public acquisition still cannot mint live epoch authority from this model.
        assert_eq!(
            engine
                .retain_branch_resolution(&request, true, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(engine.jobs.counts(), counts);
        finish_model(&engine, entry);
    }
    #[test]
    fn absent_retention_never_adopts_matching_inventory_and_replaced_source_root_rejects() {
        let (_temp, engine, metadata, original) = super::super::tests::fixture_bound(true);
        let entry = original.entry(&engine).unwrap();
        let request = creation(&entry);
        entered(&engine, &entry, &metadata);
        drop(original);
        let previous = metadata.source_directory.with_extension("retained");
        std::fs::rename(&metadata.source_directory, &previous).unwrap();
        std::fs::create_dir(&metadata.source_directory).unwrap();
        assert_eq!(
            engine
                .branch_retention
                .claim_resolution(&engine, &request, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        std::fs::remove_dir(&metadata.source_directory).unwrap();
        std::fs::rename(previous, &metadata.source_directory).unwrap();
        let mut decoy = engine.db.get_vm(&request.source.name).unwrap().unwrap();
        decoy.name = request.child.name.clone();
        decoy.state = smolvm::config::RecordState::Created;
        decoy.pid = None;
        decoy.pid_start_time = None;
        engine.db.insert_vm(&decoy.name, &decoy).unwrap();
        finish_model(&engine, entry);
        assert!(engine
            .retain_branch_resolution(&request, true, &budget())
            .unwrap()
            .is_none());
        assert!(engine.db.get_vm(&request.child.name).unwrap().is_some());
    }
    #[test]
    fn phase_lookup_is_only_in_memory_state_and_never_creates_missing_boot_or_snapshot_authority() {
        let (_temp, engine, metadata, original) = super::super::tests::fixture_bound(true);
        let entry = original.entry(&engine).unwrap();
        let request = creation(&entry);
        entered(&engine, &entry, &metadata);
        drop(original);
        let counts = engine.jobs.counts();
        for (phase, expected) in [
            (Phase::Entered, BranchPreparationState::Unresolved),
            (Phase::Verified, BranchPreparationState::Collected),
            (Phase::Published, BranchPreparationState::MaterialPublished),
            (Phase::BootEntered, BranchPreparationState::Unresolved),
            (Phase::Booted, BranchPreparationState::Booted),
            (Phase::IdentityEntered, BranchPreparationState::Unresolved),
            (Phase::IdentityReady, BranchPreparationState::IdentityReady),
            (Phase::ReleaseEntered, BranchPreparationState::Unresolved),
            (Phase::Released, BranchPreparationState::Released),
        ] {
            entry.work.lock().unwrap().phase = phase;
            let resolution = engine
                .branch_retention
                .claim_resolution(&engine, &request, &budget())
                .unwrap()
                .unwrap();
            assert_eq!(resolution.state_checked(&engine).unwrap(), expected);
            assert!(entry.work.lock().unwrap().snapshot.is_none());
            assert!(entry.work.lock().unwrap().boot.is_none());
            assert!(engine.owned_managers.lock().unwrap().is_empty());
            assert_eq!(
                resolution.state(&engine).unwrap_err().code,
                ErrorCode::Ownership
            );
            assert_eq!(engine.jobs.counts(), counts);
        }
        finish_model(&engine, entry);
    }
}
