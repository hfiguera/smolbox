//! Explicit accounting release after source/child absence and host confirmation.
//! No SDK cleanup, dependency retirement, file removal or reconstructed ownership.
use super::*;
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

const MAX_BYTES: u64 = 80 * 1024;

/// Acknowledged host backing-removal assertion plus verified source/child
/// absence. Historical evidence; this does not delete files or retire lineage.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchBackingRelease {
    pub schema: u8,
    pub publication: crate::BranchPublication,
    pub operation_id: String,
    pub request_sha256: String,
    pub native_bytes: u64,
    pub proof_sha256: String,
}
impl std::fmt::Debug for BranchBackingRelease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchBackingRelease")
            .field("schema", &self.schema)
            .field("native_bytes", &self.native_bytes)
            .finish_non_exhaustive()
    }
}
impl BranchBackingRelease {
    pub fn validate(&self) -> Result<()> {
        self.publication.validate()?;
        if self.schema != 1
            || !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || self.native_bytes
                != self
                    .publication
                    .change
                    .child_origin
                    .intent
                    .plan
                    .preparation_disk_bytes()?
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > crate::BRANCH_BACKING_PROOF_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(super) fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-branch-backing-release-v1",
            self.schema,
            &self.publication,
            &self.operation_id,
            &self.request_sha256,
            self.native_bytes,
        ))
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    schema: u8,
    context_sha256: String,
    proof: BranchBackingRelease,
}
pub(super) struct Ledger {
    domain: Arc<crate::domain::DomainGuard>,
    path: std::path::PathBuf,
    context_sha256: String,
}
impl Ledger {
    pub(super) fn new(
        domain: Arc<crate::domain::DomainGuard>,
        publication: &crate::BranchPublication,
        context_sha256: String,
    ) -> Result<Self> {
        publication.validate()?;
        if !crate::domain::valid_hex(&context_sha256, 64) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let key = crate::material::hash(&("smolbox-branch-backing-v1", publication))?;
        let path = domain.directory.join(format!("branch-backing-{key}.json"));
        Ok(Self {
            domain,
            path,
            context_sha256,
        })
    }
    fn validate(&self, record: &Record) -> Result<()> {
        record.proof.validate()?;
        if record.schema != 1
            || record.context_sha256 != self.context_sha256
            || Self::new(
                self.domain.clone(),
                &record.proof.publication,
                record.context_sha256.clone(),
            )?
            .path
                != self.path
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn read(&self) -> Result<Option<Record>> {
        self.domain.verify()?;
        match std::fs::symlink_metadata(&self.path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(Error::before(ErrorCode::Ownership)),
            Ok(_) => {}
        }
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&self.path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o600
            || metadata.nlink() != 1
            || metadata.len() > MAX_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let before = crate::checkpoint_materialize::FileVersion::of(&metadata);
        let mut bytes = Vec::new();
        std::io::Read::by_ref(&mut file)
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        let record: Record =
            serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
        self.validate(&record)?;
        for metadata in [file.metadata(), std::fs::symlink_metadata(&self.path)] {
            if crate::checkpoint_materialize::FileVersion::of(
                &metadata.map_err(|_| Error::before(ErrorCode::Ownership))?,
            ) != before
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        self.domain.verify()?;
        Ok(Some(record))
    }
    fn publish(&self, proof: &BranchBackingRelease) -> Result<()> {
        let record = Record {
            schema: 1,
            context_sha256: self.context_sha256.clone(),
            proof: proof.clone(),
        };
        self.validate(&record)?;
        let bytes = serde_json::to_vec(&record).map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        self.domain.verify()?;
        let mut file = tempfile::NamedTempFile::new_in(&self.domain.directory)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        file.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))
            .and_then(|()| file.write_all(&bytes))
            .and_then(|()| file.as_file().sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        self.domain.verify()?;
        file.persist_noclobber(&self.path)
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.sync()
    }
    fn sync(&self) -> Result<()> {
        self.domain.verify()?;
        File::open(&self.domain.directory)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        self.domain.verify()
    }
    pub(super) fn release(
        &self,
        expected: &BranchBackingRelease,
        backing: &mut crate::jobs::BranchBackingLease,
        budget: &ReadBudget,
        verify_absent: impl FnOnce() -> Result<()>,
    ) -> Result<BranchBackingRelease> {
        budget.check()?;
        expected.validate()?;
        if let Some(record) = self.read()? {
            if record.proof != *expected {
                return Err(Error::before(ErrorCode::Conflict));
            }
            // Re-synchronize even after an earlier publication sync failed.
            self.sync()?;
        } else {
            if backing.material_bytes() != expected.native_bytes {
                return Err(Error::before(ErrorCode::Ownership));
            }
            verify_absent()?;
            budget.check()?;
            self.publish(expected)
                .map_err(|e| Error::uncertain(e.code))?;
            if self.read()?.is_none_or(|record| record.proof != *expected) {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
        }
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        backing
            .release_material(expected.native_bytes)
            .map_err(|e| Error::uncertain(e.code))?;
        Ok(expected.clone())
    }
}
struct Absence<'a> {
    plan: &'a crate::branch_boot::Plan,
    epoch: &'a crate::epoch::ActorEpoch,
    enrollment: &'a crate::epoch::BootEnrollment,
    database: &'a std::path::Path,
    database_identity: (u64, u64),
}
impl Absence<'_> {
    fn verify(&self, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        self.plan.validate()?;
        let publication = &self.plan.publication;
        let intent = &publication.change.child_origin.intent;
        if self.epoch.identity() != intent.epoch
            || !self.epoch.quiescent_for(&intent.source.name)?
            || !crate::epoch::gone(crate::OwnerIdentity {
                pid: intent.source_pid.0,
                birth: intent.source_pid.1,
                uid: unsafe { libc::geteuid() },
            })?
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        self.epoch
            .collect_enrolled(&intent.child.name, self.enrollment)?;
        for (name, directory) in [
            (&intent.source.name, &self.plan.source.path),
            (&intent.child.name, &self.plan.child.path),
        ] {
            if !crate::sdk_compat::observe_absence_budget(
                self.database,
                self.database_identity,
                name,
                budget,
                || {
                    crate::host::unredirected(
                        directory
                            .parent()
                            .ok_or(Error::before(ErrorCode::Ownership))?,
                    )?;
                    Ok(matches!(std::fs::symlink_metadata(directory), Err(error)
                        if error.kind() == std::io::ErrorKind::NotFound))
                },
            )? {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        budget.check()
    }
}
impl Engine {
    /// Release native branch backing accounting only after explicit host removal
    /// confirmation and source/child absence. No filesystem or SDK deletion.
    pub fn release_branch_backing(
        &self,
        child: &CreationReceipt,
        operation_id: &str,
        request_sha256: &str,
        quiesced: bool,
        backing_removed: bool,
        budget: &ReadBudget,
    ) -> Result<BranchBackingRelease> {
        self.release_branch_backing_with_completion(
            child,
            (operation_id, request_sha256),
            (quiesced, backing_removed),
            None,
            budget,
        )
    }
    pub(crate) fn release_branch_backing_with_completion(
        &self,
        child: &CreationReceipt,
        request: (&str, &str),
        confirmations: (bool, bool),
        expected: Option<&crate::BranchCompletion>,
        budget: &ReadBudget,
    ) -> Result<BranchBackingRelease> {
        let (operation_id, request_sha256) = request;
        let (quiesced, backing_removed) = confirmations;
        let expected = expected.cloned();
        if !quiesced
            || !backing_removed
            || !crate::domain::valid_id(operation_id)
            || !crate::domain::valid_hex(request_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        budget.check()?;
        child.validate(self.binding())?;
        self.verify_database_identity()?;
        let control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self.retained_branch_context(child)?;
        let source = &context.plan.publication.previous;
        let source_gate = self.observation_gate(&source.name)?;
        let child_gate = self.observation_gate(&child.name)?;
        let gates =
            crate::gate::lock_pair((&source.name, &source_gate), (&child.name, &child_gate))
                .map_err(|()| Error::before(ErrorCode::Conflict))?;
        let epoch = self.collection_epoch()?.clone();
        if !epoch.bound_to(self.binding()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let registry = self.branch_retention.clone();
        let database = self.binding().database.clone();
        let database_identity = self.database_identity;
        let child = child.clone();
        let request = (operation_id.to_owned(), request_sha256.to_owned());
        let work_budget = budget.clone();
        let runtime = self.runtime.clone();
        let proof =
            crate::oci_start::observe_owned(
                self.jobs.clone(),
                budget.deadline,
                budget.cancel.clone(),
                move || {
                    let _control = control;
                    let _gates = gates;
                    let mut completed = registry
                        .completed
                        .lock()
                        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                    let mut matches = completed
                        .values_mut()
                        .filter(|entry| Arc::ptr_eq(&entry._context, &context));
                    let entry = matches.next().ok_or(Error::before(ErrorCode::Ownership))?;
                    if matches.next().is_some() {
                        return Err(Error::before(ErrorCode::Ownership));
                    }
                    entry.result.validate()?;
                    if expected.as_ref().is_some_and(|expected| {
                        entry.result != *expected || entry.borrower.upgrade().is_some()
                    }) {
                        return Err(Error::before(ErrorCode::Conflict));
                    }
                    let mut origin = entry.result.child.clone();
                    origin.material = None;
                    crate::material::check_origin(&origin, &child)?;
                    let context_sha256 = crate::material::hash(&(
                        "smolbox-original-branch-backing-v1",
                        &entry.result,
                        &context.plan,
                        context.enrollment.intent(),
                        context.enrollment.child(),
                        &context.identity_sha256,
                    ))?;
                    let mut proof = BranchBackingRelease {
                        schema: 1,
                        publication: entry.result.publication.clone(),
                        operation_id: request.0,
                        request_sha256: request.1,
                        native_bytes: entry
                            .result
                            .publication
                            .change
                            .child_origin
                            .intent
                            .plan
                            .preparation_disk_bytes()?,
                        proof_sha256: String::new(),
                    };
                    proof.proof_sha256 = proof.digest()?;
                    Ledger::new(registry.domain.clone(), &proof.publication, context_sha256)?
                        .release(&proof, &mut entry._backing, &work_budget, || {
                            if runtime.pid(&proof.publication.previous.name).is_some()
                                || runtime.pid(&child.name).is_some()
                            {
                                return Err(Error::before(ErrorCode::Conflict));
                            }
                            Absence {
                                plan: &context.plan,
                                epoch: &epoch,
                                enrollment: &context.enrollment,
                                database: &database,
                                database_identity,
                            }
                            .verify(&work_budget)?;
                            // Collection is positive before forgetting this original
                            // manager's process; never signal it through Drop.
                            context
                                .manager
                                .try_lock()
                                .map_err(|_| Error::before(ErrorCode::Conflict))?
                                .mark_stopped();
                            Ok(())
                        })
                },
            )
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch_boot::tests::{identity_model, IdentityModel};
    use std::time::Duration;

    fn budget() -> ReadBudget {
        ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
    }
    fn fixture() -> (
        IdentityModel,
        Ledger,
        BranchBackingRelease,
        crate::jobs::BranchBackingLease,
    ) {
        let model = identity_model(true);
        let publication = model.plan.publication.clone();
        let mut proof = BranchBackingRelease {
            schema: 1,
            native_bytes: publication
                .change
                .child_origin
                .intent
                .plan
                .preparation_disk_bytes()
                .unwrap(),
            publication,
            operation_id: "release-backing".into(),
            request_sha256: "d".repeat(64),
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest().unwrap();
        proof.validate().unwrap();
        let ledger = Ledger::new(
            model.engine.domain.clone(),
            &proof.publication,
            "e".repeat(64),
        )
        .unwrap();
        let mut work = model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        work.promote_branch_preparation().unwrap();
        work.promote_branch_backing(proof.native_bytes).unwrap();
        let backing = work.handoff_branch().unwrap();
        (model, ledger, proof, backing)
    }
    fn absent<'a>(model: &'a IdentityModel, epoch: &'a crate::epoch::ActorEpoch) -> Absence<'a> {
        Absence {
            plan: &model.plan,
            epoch,
            enrollment: &model.enrollment,
            database: &model.engine.binding().database,
            database_identity: model.engine.database_identity,
        }
    }
    fn remove_original(model: &IdentityModel) {
        for (name, directory) in [
            (
                &model.plan.publication.previous.name,
                &model.plan.source.path,
            ),
            (&model.plan.publication.child().name, &model.plan.child.path),
        ] {
            model.engine.db.remove_vm(name).unwrap();
            std::fs::remove_dir_all(directory).unwrap(); // Private ordinary result model only.
        }
    }
    #[test]
    fn backing_release_requires_explicit_host_confirmation_and_original_context() {
        let (model, ledger, proof, _backing) = fixture();
        let counts = model.engine.jobs.counts();
        for (quiesced, removed, operation, hash) in [
            (false, true, "release", "d".repeat(64)),
            (true, false, "release", "d".repeat(64)),
            (true, true, "../release", "d".repeat(64)),
            (true, true, "release", "invalid".into()),
            (true, true, "release", "d".repeat(64)),
        ] {
            let error = model
                .engine
                .release_branch_backing(
                    proof.publication.child(),
                    operation,
                    &hash,
                    quiesced,
                    removed,
                    &budget(),
                )
                .unwrap_err();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(model.engine.jobs.counts(), counts);
        }
        assert!(ledger.read().unwrap().is_none());
    }
    #[test]
    fn source_and_child_rows_reservations_and_directories_all_block_material_release() {
        let (model, ledger, proof, mut backing) = fixture();
        let work = budget();
        let verify = || absent(&model, &model.actors).verify(&work);
        assert!(ledger.release(&proof, &mut backing, &work, verify).is_err());
        for name in [
            &proof.publication.previous.name,
            &proof.publication.child().name,
        ] {
            model.engine.db.remove_vm(name).unwrap();
        }
        assert!(ledger.release(&proof, &mut backing, &work, verify).is_err());
        std::fs::remove_dir_all(&model.plan.child.path).unwrap();
        assert!(ledger.release(&proof, &mut backing, &work, verify).is_err());
        std::fs::remove_dir_all(&model.plan.source.path).unwrap();
        let writer = rusqlite::Connection::open(&model.engine.binding().database).unwrap();
        for name in [
            &proof.publication.previous.name,
            &proof.publication.child().name,
        ] {
            writer
                .execute(
                    "INSERT INTO vm_create_reservations VALUES (?1,'pending',-1,0)",
                    [name],
                )
                .unwrap();
            assert!(ledger.release(&proof, &mut backing, &work, verify).is_err());
            writer
                .execute("DELETE FROM vm_create_reservations WHERE name=?1", [name])
                .unwrap();
        }
        assert!(ledger.read().unwrap().is_none());
        assert_eq!(
            model.engine.jobs.counts().checkpoint_material,
            proof.native_bytes
        );
        ledger.release(&proof, &mut backing, &work, verify).unwrap();
        assert_eq!(model.engine.jobs.counts().checkpoint_material, 0);
    }
    #[test]
    fn positive_release_preserves_history_other_backing_control_and_quarantine() {
        let (model, ledger, proof, mut backing) = fixture();
        let mut sibling_work = model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        sibling_work.promote_branch_preparation().unwrap();
        sibling_work.promote_branch_backing(7 << 30).unwrap();
        let sibling = sibling_work.handoff_branch().unwrap();
        drop(sibling_work);
        remove_original(&model);
        let rootfs = model.plan.rootfs.path.clone();
        model.engine.jobs.quarantine(); // Counter model only.
        let _control = model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())
            .unwrap();
        let _observer = model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        let work = budget();
        let actual = ledger
            .release(&proof, &mut backing, &work, || {
                absent(&model, &model.actors).verify(&work)
            })
            .unwrap();
        assert_eq!(actual, proof);
        actual.validate().unwrap();
        let counts = model.engine.jobs.counts();
        assert_eq!(counts.checkpoint_material, 7 << 30);
        assert_eq!(
            counts.branch_metadata,
            2 * crate::jobs::BRANCH_BACKING_METADATA
        );
        assert_eq!(counts.work, 0);
        assert_eq!(counts.control, 2);
        assert!(!model.engine.jobs.available() && rootfs.exists());
        let bytes = std::fs::read(&ledger.path).unwrap();
        assert_eq!(
            ledger
                .release(&proof, &mut backing, &work, || panic!(
                    "known receipt must not requalify"
                ))
                .unwrap(),
            proof
        );
        assert_eq!(std::fs::read(&ledger.path).unwrap(), bytes);
        assert_eq!(model.engine.jobs.counts(), counts);
        drop((backing, sibling));
        assert_eq!(model.engine.jobs.counts().branch_metadata, 0);
        assert_eq!(model.engine.jobs.counts().checkpoint_material, 0);
    }
    #[test]
    fn published_but_unacknowledged_release_can_retire_only_its_original_charge() {
        let (model, ledger, proof, mut backing) = fixture();
        remove_original(&model);
        let work = budget();
        absent(&model, &model.actors).verify(&work).unwrap();
        ledger.publish(&proof).unwrap(); // Private result-before-ack model; no live interruption.
        assert_eq!(backing.material_bytes(), proof.native_bytes);
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(ledger
            .release(&proof, &mut backing, &cancelled, || panic!(
                "historical only"
            ))
            .is_err());
        assert_eq!(backing.material_bytes(), proof.native_bytes);
        std::fs::create_dir(&model.plan.source.path).unwrap();
        let marker = model.plan.source.path.join("new-source-model");
        std::fs::write(&marker, b"new").unwrap();
        assert_eq!(
            ledger
                .release(&proof, &mut backing, &work, || panic!(
                    "historical proof only"
                ))
                .unwrap(),
            proof
        );
        assert_eq!(std::fs::read(marker).unwrap(), b"new");
        assert_eq!(backing.material_bytes(), 0);
        let mut crossed = proof;
        crossed.request_sha256 = "f".repeat(64);
        crossed.proof_sha256 = crossed.digest().unwrap();
        assert!(ledger
            .release(&crossed, &mut backing, &work, || Ok(()))
            .is_err());
    }
    #[test]
    fn foreign_or_pending_collection_and_cancellation_keep_the_whole_charge() {
        let (model, ledger, proof, mut backing) = fixture();
        remove_original(&model);
        let foreign = identity_model(true);
        let work = budget();
        assert!(ledger
            .release(&proof, &mut backing, &work, || absent(
                &model,
                &foreign.actors
            )
            .verify(&work))
            .is_err());
        let pending = model
            .actors
            .begin_boot(&proof.publication.previous.name)
            .unwrap();
        assert!(ledger
            .release(&proof, &mut backing, &work, || absent(
                &model,
                &model.actors
            )
            .verify(&work))
            .is_err());
        drop(pending); // Private unreturned-dispatch model only; no live child.
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(ledger
            .release(&proof, &mut backing, &cancelled, || panic!(
                "cancelled before dispatch"
            ))
            .is_err());
        assert_eq!(backing.material_bytes(), proof.native_bytes);
        assert!(ledger.read().unwrap().is_none());
    }
    #[test]
    fn proof_and_protected_record_reject_corruption_crossed_context_and_unsafe_files() {
        let (model, ledger, proof, mut backing) = fixture();
        let mut wrong = proof.clone();
        wrong.native_bytes += 1;
        wrong.proof_sha256 = wrong.digest().unwrap();
        assert!(wrong.validate().is_err());
        remove_original(&model);
        ledger.publish(&proof).unwrap();
        let alternate = Ledger::new(
            model.engine.domain.clone(),
            &proof.publication,
            "a".repeat(64),
        )
        .unwrap();
        assert!(alternate.read().is_err());
        let saved = std::fs::read(&ledger.path).unwrap();
        std::fs::set_permissions(&ledger.path, std::fs::Permissions::from_mode(0o640)).unwrap();
        assert!(ledger
            .release(&proof, &mut backing, &budget(), || Ok(()))
            .is_err());
        std::fs::set_permissions(&ledger.path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let other = ledger.path.with_extension("link");
        std::fs::hard_link(&ledger.path, &other).unwrap();
        assert!(ledger.read().is_err());
        std::fs::remove_file(&other).unwrap();
        std::fs::remove_file(&ledger.path).unwrap();
        std::os::unix::fs::symlink(&other, &ledger.path).unwrap();
        assert!(ledger.read().is_err());
        std::fs::remove_file(&ledger.path).unwrap();
        std::fs::write(&ledger.path, b"{}").unwrap();
        std::fs::set_permissions(&ledger.path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(ledger.read().is_err());
        std::fs::write(&ledger.path, saved).unwrap();
        assert!(ledger.read().unwrap().is_some());
        assert_eq!(backing.material_bytes(), proof.native_bytes);
    }
    #[test]
    fn changed_or_unproved_retired_charge_cannot_mint_a_release_receipt() {
        let (model, ledger, proof, mut backing) = fixture();
        let mut work = model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        work.promote_branch_preparation().unwrap();
        work.promote_branch_backing(proof.native_bytes + (1 << 30))
            .unwrap();
        let mut wrong = work.handoff_branch().unwrap();
        drop(work);
        let before = model.engine.jobs.counts();
        assert!(ledger
            .release(&proof, &mut wrong, &budget(), || panic!("wrong charge"))
            .is_err());
        assert_eq!(model.engine.jobs.counts(), before);
        // Bookkeeping-only illegal prior release model: no receipt can be minted.
        backing.release_material(proof.native_bytes).unwrap();
        assert!(ledger
            .release(&proof, &mut backing, &budget(), || panic!(
                "unproved charge"
            ))
            .is_err());
        assert!(ledger.read().unwrap().is_none());
        assert_eq!(wrong.material_bytes(), proof.native_bytes + (1 << 30));
    }
}
