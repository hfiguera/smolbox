//! Owned capture orchestration. Native collection outlives caller retirement;
//! source material advances only after exact worker and parent rechecks.
use crate::{
    CaptureRequest, CaptureTransition, CreationReceipt, Engine, Error, ErrorCode, ReadBudget,
    Result,
};
use std::fs::{File, Metadata};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::sync::{Arc, Mutex};

struct Leases {
    directory: Option<tempfile::TempDir>,
    identity: (u64, u64),
    domain: Arc<crate::domain::DomainGuard>,
    jobs: crate::jobs::JobPool,
    permit: Option<crate::jobs::JobLease>,
    _machine: Option<crate::gate::MachineLease>,
    entered: bool,
    completed: bool,
    staging: Arc<crate::capture_staging::Staging>,
    ticket: Option<crate::capture_staging::Ticket>,
}
impl Leases {
    fn verify(&self) -> Result<()> {
        self.domain.verify()?;
        let directory = self
            .directory
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        crate::host::unredirected(directory.path())?;
        let metadata = std::fs::symlink_metadata(directory.path())
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if !metadata.is_dir()
            || (metadata.dev(), metadata.ino()) != self.identity
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o700
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Drop for Leases {
    fn drop(&mut self) {
        let Some(directory) = self.directory.take() else {
            return;
        };
        let trusted = self.domain.verify().is_ok()
            && std::fs::symlink_metadata(directory.path()).is_ok_and(|metadata| {
                metadata.is_dir()
                    && (metadata.dev(), metadata.ino()) == self.identity
                    && metadata.uid() == unsafe { libc::geteuid() }
                    && metadata.mode() & 0o777 == 0o700
            });
        let path = directory.keep();
        if let Some(ticket) = &self.ticket {
            if let Some(permit) = self.permit.take() {
                if !self.entered {
                    self.staging.retire_prepared(ticket, permit, trusted);
                } else {
                    self.staging.retain_collected(ticket, permit);
                    if !trusted
                        || (self.completed && self.staging.retire_completed(ticket).is_err())
                    {
                        self.jobs.quarantine();
                    }
                }
                return;
            }
        }
        if trusted && self.entered && !self.completed {
            // Collected but unresolved capture retains private output and its
            // declared allowance. Source gates may release for ordinary stop.
            if let Some(permit) = self.permit.take() {
                if let Some(ticket) = &self.ticket {
                    self.staging.retain_collected(ticket, permit);
                } else {
                    std::mem::forget(permit);
                }
            }
            return;
        }
        let cleaned = trusted && std::fs::remove_dir_all(path).is_ok();
        if !cleaned {
            self.jobs.quarantine();
            if let Some(permit) = self.permit.take() {
                std::mem::forget(permit);
            }
        }
    }
}

pub struct CapturedCheckpoint {
    transition: CaptureTransition,
    file: File,
    version: crate::checkpoint_materialize::FileVersion,
    streamed: bool,
    _leases: Leases,
}
impl CapturedCheckpoint {
    pub fn transition(&self) -> &CaptureTransition {
        &self.transition
    }
    /// Forward private captured bytes without reopening an operator-selected
    /// path. Resource/staging authority remains retained until this value drops.
    pub fn stream(
        &mut self,
        budget: &ReadBudget,
        mut consumer: impl FnMut(&[u8]) -> Result<()>,
    ) -> Result<()> {
        use sha2::{Digest, Sha256};
        budget.check()?;
        if self.streamed {
            return Err(Error::before(ErrorCode::State));
        }
        self.streamed = true;
        self._leases
            .verify()
            .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
        if crate::checkpoint_materialize::FileVersion::of(
            &self
                .file
                .metadata()
                .map_err(|_| Error::uncertain(ErrorCode::Io))?,
        ) != self.version
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let mut total = 0u64;
        let mut hash = Sha256::new();
        let mut buffer = [0; 65536];
        loop {
            budget.check()?;
            let count = self
                .file
                .read(&mut buffer)
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
            if count == 0 {
                break;
            }
            total += count as u64;
            if total > self.transition.change.artifact.size_bytes {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            hash.update(&buffer[..count]);
            consumer(&buffer[..count])?;
        }
        if total != self.transition.change.artifact.size_bytes
            || hex::encode(hash.finalize()) != self.transition.change.artifact.sha256
            || crate::checkpoint_materialize::FileVersion::of(
                &self
                    .file
                    .metadata()
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?,
            ) != self.version
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        self._leases
            .verify()
            .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
        budget.check()?;
        Ok(())
    }
}

impl Engine {
    /// Explicitly retire an entered capture after its worker is collected and
    /// the source is stopped or remains exactly owned/live. This never returns a capture artifact, removes staging or
    /// releases retained capture capacity. Persist the distinct material history
    /// before using its receipt; public adapters must not expose it as success.
    pub fn resolve_entered_capture(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        budget: &ReadBudget,
    ) -> Result<crate::CaptureResolutionTransition> {
        budget.check()?;
        let _permit = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        receipt.validate(self.binding())?;
        request.validate()?;
        if !crate::domain::valid_id(operation_id) {
            return Err(Error::before(ErrorCode::Validation));
        }
        // The worker's retained lease uses this same gate until collection.
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let directory = self.vm_directory(&receipt.name);
        if !crate::machine::marker_matches(receipt, &directory)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let journal = crate::material::MaterialJournal::at(&directory);
        if let Some(resolved) = journal.resolved_capture(receipt, operation_id, request)? {
            budget.check()?;
            self.recover_capture_handle(&resolved)?;
            return Ok(resolved);
        }
        let pid = journal.entered_capture_pid(receipt, operation_id, request)?;
        let record = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .ok_or(Error::before(ErrorCode::NotFound))?;
        budget.check()?;
        self.verify_database_identity()?;
        let authority = self.capture_source_authority(receipt, pid, &record)?;
        let transition = journal.resolve_entered_capture_authorized(
            receipt,
            operation_id,
            request,
            &record,
            &authority,
        )?;
        if authority.running() {
            self.promote_capture_handle(receipt, &transition.receipt)
                .map_err(|error| Error::uncertain(error.code))?;
        }
        Ok(transition)
    }

    /// Read only an already recorded resolution; no source or artifact adoption.
    pub fn resolved_capture_with_budget(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        budget: &ReadBudget,
    ) -> Result<Option<crate::CaptureResolutionTransition>> {
        budget.check()?;
        let _permit = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        receipt.validate(self.binding())?;
        request.validate()?;
        if !crate::domain::valid_id(operation_id) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let directory = self.vm_directory(&receipt.name);
        if !crate::machine::marker_matches(receipt, &directory)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let resolution = crate::material::MaterialJournal::at(&directory).resolved_capture(
            receipt,
            operation_id,
            request,
        )?;
        budget.check()?;
        Ok(resolution)
    }

    pub fn completed_capture_with_budget(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        budget: &ReadBudget,
    ) -> Result<Option<CaptureTransition>> {
        budget.check()?;
        let _permit = self.jobs.acquire(crate::jobs::Demand::observation())?;
        receipt.validate(self.binding())?;
        request.validate()?;
        if !crate::domain::valid_id(operation_id) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let directory = self.vm_directory(&receipt.name);
        if !crate::machine::marker_matches(receipt, &directory)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let transition = crate::material::MaterialJournal::at(&directory).completed_capture(
            receipt,
            operation_id,
            request,
        )?;
        budget.check()?;
        Ok(transition)
    }
    pub fn completed_capture(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
    ) -> Result<Option<CaptureTransition>> {
        let budget = ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::new(),
        )?;
        self.completed_capture_with_budget(receipt, operation_id, request, &budget)
    }
    pub fn capture_checkpoint(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: CaptureRequest,
        budget: ReadBudget,
    ) -> Result<CapturedCheckpoint> {
        budget.check()?;
        request.validate()?;
        let observation = self.checkpoint_preflight(
            receipt,
            &ReadBudget::new(
                budget
                    .deadline
                    .saturating_duration_since(std::time::Instant::now())
                    .min(std::time::Duration::from_secs(30)),
                budget.cancel.clone(),
            )?,
        )?;
        let machine = self
            .gate(&receipt.name)?
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_lifecycle_preconditions(receipt, &observation)?;
        let before = self.record(receipt)?;
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let (libraries, rootfs) = self.capture_assets()?;
        crate::identity::verify_boot_rootfs(&before, &rootfs)?;
        let permit = self
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(request.max_bytes)?)?;
        self.domain.verify()?;
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&self.domain.directory)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let root = std::fs::symlink_metadata(directory.path())
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let root_path = directory.path().to_owned();
        let mut leases = Leases {
            directory: Some(directory),
            identity: (root.dev(), root.ino()),
            domain: self.domain.clone(),
            jobs: self.jobs.clone(),
            permit: Some(permit),
            _machine: Some(machine),
            entered: false,
            completed: false,
            staging: self.capture_staging.clone(),
            ticket: None,
        };
        // SDK capture may materialize RAM plus both complete disk chains.
        leases
            .permit
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)?;
        let database = std::fs::symlink_metadata(&self.binding().database)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let remaining = budget
            .deadline
            .saturating_duration_since(std::time::Instant::now());
        let metadata = crate::capture_worker::Metadata {
            schema: 1,
            root: root_path.clone(),
            root_device: root.dev(),
            root_inode: root.ino(),
            database: self.binding().database.clone(),
            database_device: database.dev(),
            database_inode: database.ino(),
            source_directory: self.vm_directory(&receipt.name),
            receipt: receipt.clone(),
            request: request.clone(),
            operation_id: operation_id.into(),
            libraries,
            rootfs,
            deadline_ns: crate::buffered::monotonic_ns()?
                .checked_add(remaining.as_nanos() as u64)
                .ok_or(Error::before(ErrorCode::Validation))?,
        };
        let (bytes, expected) = metadata.encode()?;
        let prepared = supervisor.prepare_capture_owned(
            &root_path,
            &metadata.source_directory,
            &bytes,
            expected.clone(),
        )?;
        leases.ticket = Some(self.capture_staging.register_source(
            receipt,
            operation_id,
            &request,
            &root_path,
            (&expected.metadata_sha256, &before),
        )?);
        let journal = crate::material::MaterialJournal::at(&metadata.source_directory);
        let capture = journal.prepare_capture(receipt, operation_id, request, &before)?;
        if let Err(error) = budget.check() {
            journal.abort_prepared_capture(&capture)?;
            return Err(error);
        }
        journal.enter_capture(&capture)?;
        leases.entered = true;
        self.capture_staging
            .entered(
                leases
                    .ticket
                    .as_ref()
                    .ok_or(Error::uncertain(ErrorCode::Ownership))?,
            )
            .map_err(|error| Error::uncertain(error.code))?;
        let holder = Arc::new(Mutex::new(Some(leases)));
        let outcome = supervisor
            .run(
                prepared,
                Box::new(holder.clone()),
                budget.deadline,
                &budget.cancel,
            )
            .map_err(|error| Error::uncertain(error.code))?;
        let crate::transfer_supervisor::RunResult::Collected(collected) = outcome else {
            return Err(Error::uncertain(ErrorCode::Native));
        };
        let proof = collected
            .captured
            .as_ref()
            .filter(|proof| proof.matches(&expected))
            .cloned()
            .ok_or(Error::uncertain(ErrorCode::Native))?;
        if !collected.outcome.success() {
            return Err(Error::uncertain(ErrorCode::Native));
        }
        drop(collected);
        let mut leases = holder
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?
            .take()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        budget
            .check()
            .map_err(|_| Error::uncertain(ErrorCode::State))?;
        self.domain
            .verify()
            .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
        leases
            .verify()
            .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
        let after = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::uncertain(ErrorCode::Database))?
            .ok_or(Error::uncertain(ErrorCode::NotFound))?;
        if self.runtime_pid(&receipt.name) != Some(proof.source_pid.0)
            || after.pid.zip(after.pid_start_time) != Some(proof.source_pid)
            || !smolvm::process::is_alive(proof.source_pid.0)
            || smolvm::process::process_start_time(proof.source_pid.0) != Some(proof.source_pid.1)
            || crate::identity::material_hash(&after)
                .map_err(|error| Error::uncertain(error.code))?
                != proof.source_material_sha256
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let mut file = crate::artifact::open_regular(&root_path.join("capture.smolcheckpoint"))
            .map_err(|error| Error::uncertain(error.code))?;
        let observed: Metadata = file
            .metadata()
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        if (observed.dev(), observed.ino(), observed.len())
            != (proof.device, proof.inode, proof.artifact.size_bytes)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let digest = crate::artifact::copy_hash(
            &mut crate::checkpoint::Budgeted {
                input: &mut file,
                budget: &budget,
            },
            &mut std::io::sink(),
            proof.artifact.size_bytes,
        )
        .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
        if digest != proof.artifact.sha256
            || crate::checkpoint_materialize::FileVersion::of(
                &file
                    .metadata()
                    .map_err(|_| Error::uncertain(ErrorCode::Ownership))?,
            ) != crate::checkpoint_materialize::FileVersion::of(&observed)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        file.seek(SeekFrom::Start(0))
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        leases
            .verify()
            .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
        let transition = journal.complete_capture(receipt, &capture, proof.artifact, &after)?;
        self.track_handle(&transition.receipt)?;
        leases.completed = true;
        Ok(CapturedCheckpoint {
            transition,
            file,
            version: crate::checkpoint_materialize::FileVersion::of(&observed),
            streamed: false,
            _leases: leases,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    fn leases(root: &std::path::Path, entered: bool, completed: bool) -> Leases {
        let root = root.canonicalize().unwrap();
        let binding = crate::DomainBinding {
            target_id: "local".into(),
            generation: "a".repeat(32),
            database: root.join("db"),
            vm_root: root.join("vms"),
        };
        let domain = Arc::new(
            crate::domain::DomainGuard::acquire_at(&binding, root.join("private"), true).unwrap(),
        );
        let directory = tempfile::Builder::new()
            .prefix("capture-")
            .tempdir_in(&domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let metadata = std::fs::symlink_metadata(directory.path()).unwrap();
        let jobs = crate::jobs::JobPool::default();
        let staging =
            crate::capture_staging::Staging::open(&binding, domain.clone(), jobs.clone()).unwrap();
        let permit = jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        Leases {
            directory: Some(directory),
            identity: (metadata.dev(), metadata.ino()),
            domain,
            jobs,
            permit: Some(permit),
            _machine: None,
            entered,
            completed,
            staging,
            ticket: None,
        }
    }

    fn captured(root: &std::path::Path, bytes: &[u8]) -> CapturedCheckpoint {
        // A synthetic SDK-result boundary: no VM, SDK call or live process.
        let leases = leases(root, true, true);
        let path = leases
            .directory
            .as_ref()
            .unwrap()
            .path()
            .join("capture.smolcheckpoint");
        std::fs::write(&path, bytes).unwrap();
        let file = File::open(&path).unwrap();
        let version = crate::checkpoint_materialize::FileVersion::of(&file.metadata().unwrap());
        let mut record =
            smolvm::config::VmRecord::new("source".into(), 1, 512, vec![], vec![], false);
        record.forkable = true;
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record.entrypoint = vec!["/bin/true".into()];
        record.cmd.clear();
        record.env.clear();
        record.workdir = Some("/".into());
        record.user = None;
        record.state = smolvm::config::RecordState::Running;
        record.pid = Some(123);
        record.pid_start_time = Some(456);
        record.labels.insert("smolbox.owner".into(), "b".repeat(64));
        record
            .labels
            .insert("smolbox.incarnation".into(), "c".repeat(32));
        let origin = CreationReceipt {
            target_id: "local".into(),
            domain_generation: "a".repeat(32),
            name: record.name.clone(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: crate::identity::material_hash(&record).unwrap(),
            material: None,
        };
        let source = root.join("source");
        std::fs::create_dir(&source).unwrap();
        let journal = crate::material::MaterialJournal::at(&source.canonicalize().unwrap());
        let receipt = journal.initialize(&origin).unwrap();
        let permit = journal
            .prepare_capture(
                &receipt,
                "capture",
                CaptureRequest {
                    max_bytes: 1024,
                    idle: true,
                },
                &record,
            )
            .unwrap();
        journal.enter_capture(&permit).unwrap();
        record.checkpoint_head = Some("d".repeat(32));
        let transition = journal
            .complete_capture(
                &receipt,
                &permit,
                crate::CaptureArtifact {
                    sha256: hex::encode(Sha256::digest(bytes)),
                    size_bytes: bytes.len() as u64,
                    head: "d".repeat(32),
                    parent: None,
                },
                &record,
            )
            .unwrap();
        CapturedCheckpoint {
            transition,
            file,
            version,
            streamed: false,
            _leases: leases,
        }
    }

    fn budget() -> ReadBudget {
        ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::new(),
        )
        .unwrap()
    }

    fn entered_source(engine: &Engine, pid: (i32, u64)) -> CreationReceipt {
        source_boundary(engine, pid, true)
    }

    fn source_boundary(engine: &Engine, pid: (i32, u64), enter: bool) -> CreationReceipt {
        source_boundary_mode(engine, pid, enter, false)
    }

    fn source_boundary_mode(
        engine: &Engine,
        pid: (i32, u64),
        enter: bool,
        complete: bool,
    ) -> CreationReceipt {
        // A synthetic persisted SDK boundary, with no VMM or worker dispatch.
        let mut record =
            smolvm::config::VmRecord::new("unresolved".into(), 1, 512, vec![], vec![], false);
        record.forkable = true;
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record.entrypoint = vec!["/bin/true".into()];
        record.cmd.clear();
        record.env.clear();
        record.workdir = Some("/".into());
        record.user = None;
        record.state = smolvm::config::RecordState::Running;
        record.pid = Some(pid.0);
        record.pid_start_time = Some(pid.1);
        record.labels.insert("smolbox.owner".into(), "b".repeat(64));
        record
            .labels
            .insert("smolbox.incarnation".into(), "c".repeat(32));
        let origin = CreationReceipt {
            target_id: "local".into(),
            domain_generation: "a".repeat(32),
            name: record.name.clone(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: crate::identity::material_hash(&record).unwrap(),
            material: None,
        };
        let directory = engine.vm_directory(&origin.name);
        std::fs::create_dir_all(&directory).unwrap();
        let journal = crate::material::MaterialJournal::at(&directory);
        let receipt = journal.initialize(&origin).unwrap();
        std::fs::write(
            directory.join("smolbox.incarnation"),
            format!(
                "smolbox-incarnation-v1\n{}\n{}\n{}\n{}\n",
                origin.domain_generation,
                origin.owner_token,
                origin.incarnation,
                origin.material_sha256,
            ),
        )
        .unwrap();
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let permit = journal
            .prepare_capture(&receipt, "unknown", request, &record)
            .unwrap();
        if enter {
            journal.enter_capture(&permit).unwrap();
            record.checkpoint_head = Some("d".repeat(32));
            if complete {
                journal
                    .complete_capture(
                        &receipt,
                        &permit,
                        crate::CaptureArtifact {
                            sha256: "f".repeat(64),
                            size_bytes: 1,
                            head: "d".repeat(32),
                            parent: None,
                        },
                        &record,
                    )
                    .unwrap();
            } else {
                record.state = smolvm::config::RecordState::Stopped;
                record.pid = None;
                record.pid_start_time = None;
            }
        }
        engine.db.insert_vm(&record.name, &record).unwrap();
        receipt
    }

    #[test]
    fn capture_resolution_requires_quiescent_source_gate_marker_domain_and_budget() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let receipt = entered_source(&engine, (i32::MAX, 456));
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let directory = engine.vm_directory(&receipt.name);
        let journal = directory.join("smolbox.material-v2.json");
        let before = std::fs::read(&journal).unwrap();
        let gate = engine.observation_gate(&receipt.name).unwrap();
        let guard = gate.try_lock().unwrap();
        assert_eq!(
            engine
                .resolve_entered_capture(&receipt, "unknown", &request, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(guard);
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(engine
            .resolve_entered_capture(&receipt, "unknown", &request, &cancelled)
            .is_err());
        let mut foreign = receipt.clone();
        foreign.target_id = "foreign".into();
        assert!(engine
            .resolve_entered_capture(&foreign, "unknown", &request, &budget())
            .is_err());
        let marker = directory.join("smolbox.incarnation");
        std::fs::rename(&marker, directory.join("saved-marker")).unwrap();
        assert!(engine
            .resolve_entered_capture(&receipt, "unknown", &request, &budget())
            .is_err());
        std::fs::rename(directory.join("saved-marker"), &marker).unwrap();
        assert_eq!(std::fs::read(&journal).unwrap(), before);
        assert!(engine
            .resolved_capture_with_budget(&receipt, "unknown", &request, &budget())
            .unwrap()
            .is_none());
        // A retained unrelated allowance is never released by source resolution.
        let retained = engine
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        let counts = engine.jobs.counts();
        let resolved = engine
            .resolve_entered_capture(&receipt, "unknown", &request, &budget())
            .unwrap();
        resolved.validate().unwrap();
        assert_eq!(engine.jobs.counts(), counts);
        let after = std::fs::read(&journal).unwrap();
        assert_eq!(
            engine
                .resolve_entered_capture(&receipt, "unknown", &request, &budget())
                .unwrap(),
            resolved
        );
        assert_eq!(
            engine
                .resolved_capture_with_budget(&receipt, "unknown", &request, &budget())
                .unwrap(),
            Some(resolved)
        );
        assert_eq!(std::fs::read(&journal).unwrap(), after);
        assert!(engine
            .completed_capture(&receipt, "unknown", &request)
            .unwrap()
            .is_none());
        assert!(engine
            .resolve_entered_capture(&receipt, "different", &request, &budget())
            .is_err());
        drop(retained);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn running_resolution_cannot_adopt_a_live_row_or_a_tracked_receipt_without_the_sdk_handle() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let pid = std::process::id() as i32;
        let birth = smolvm::process::process_start_time(pid).unwrap();
        let receipt = entered_source(&engine, (pid, birth));
        engine
            .db
            .update_vm(&receipt.name, |record| {
                record.state = smolvm::config::RecordState::Running;
                record.pid = Some(pid);
                record.pid_start_time = Some(birth);
            })
            .unwrap();
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let journal = engine
            .vm_directory(&receipt.name)
            .join("smolbox.material-v2.json");
        let before = std::fs::read(&journal).unwrap();
        for tracked in [false, true] {
            if tracked {
                engine.track_handle(&receipt).unwrap();
            }
            assert!(engine
                .resolve_entered_capture(&receipt, "unknown", &request, &budget())
                .is_err());
            assert_eq!(std::fs::read(&journal).unwrap(), before);
        }
    }

    #[test]
    fn recorded_resolution_cannot_promote_a_copied_or_stale_handle_without_live_enrollment() {
        let fixture = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(fixture.path());
        let receipt = entered_source(&engine, (i32::MAX, 456));
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let resolved = engine
            .resolve_entered_capture(&receipt, "unknown", &request, &budget())
            .unwrap();
        engine.track_handle(&receipt).unwrap();
        assert!(engine.recover_capture_handle(&resolved).is_err());
        // A mismatched owner cannot be replaced using a recorded transition.
        let mut foreign = receipt.clone();
        foreign.incarnation = "f".repeat(32);
        engine.track_handle(&foreign).unwrap();
        assert!(engine
            .promote_capture_handle(&receipt, &resolved.receipt)
            .is_err());
        // Only the exact original owner may advance to the recorded receipt.
        engine.track_handle(&receipt).unwrap();
        engine
            .promote_capture_handle(&receipt, &resolved.receipt)
            .unwrap();
        assert!(engine
            .promote_capture_handle(&receipt, &resolved.receipt)
            .is_err());
    }

    #[test]
    fn capture_resolution_never_accepts_stopped_inventory_while_original_process_is_live() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let pid = std::process::id() as i32;
        let birth = smolvm::process::process_start_time(pid).unwrap();
        let receipt = entered_source(&engine, (pid, birth));
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let journal = engine
            .vm_directory(&receipt.name)
            .join("smolbox.material-v2.json");
        let before = std::fs::read(&journal).unwrap();
        assert_eq!(
            engine
                .resolve_entered_capture(&receipt, "unknown", &request, &budget())
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        assert_eq!(std::fs::read(&journal).unwrap(), before);
        assert!(engine
            .resolved_capture_with_budget(&receipt, "unknown", &request, &budget())
            .unwrap()
            .is_none());
    }

    #[test]
    fn capture_resolution_rejects_retained_source_ownership_even_with_stopped_inventory() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let receipt = entered_source(&engine, (i32::MAX, 456));
        engine.track_handle(&receipt).unwrap();
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let journal = engine
            .vm_directory(&receipt.name)
            .join("smolbox.material-v2.json");
        let before = std::fs::read(&journal).unwrap();
        assert_eq!(
            engine
                .resolve_entered_capture(&receipt, "unknown", &request, &budget())
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        assert_eq!(std::fs::read(&journal).unwrap(), before);
    }

    #[test]
    fn completed_lookup_checks_original_marker_domain_cancel_and_retained_gate_without_db_adoption()
    {
        let fixture = tempfile::tempdir().unwrap();
        let captured = captured(fixture.path(), b"captured bytes");
        let proof = captured.transition().clone();
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let directory = engine.vm_directory(&proof.previous.name);
        std::fs::create_dir_all(directory.parent().unwrap()).unwrap();
        std::fs::rename(fixture.path().join("source"), &directory).unwrap();
        // Synthetic completion evidence alone cannot substitute a creation marker.
        assert!(engine
            .completed_capture(&proof.previous, "capture", proof.change.request())
            .is_err());
        std::fs::write(
            directory.join("smolbox.incarnation"),
            format!(
                "smolbox-incarnation-v1\n{}\n{}\n{}\n{}\n",
                proof.previous.domain_generation,
                proof.previous.owner_token,
                proof.previous.incarnation,
                proof.previous.material_sha256,
            ),
        )
        .unwrap();
        let journal = directory.join("smolbox.material-v2.json");
        let before = std::fs::read(&journal).unwrap();
        assert_eq!(
            engine
                .completed_capture(&proof.previous, "capture", proof.change.request())
                .unwrap(),
            Some(proof.clone())
        );
        assert!(engine
            .completed_capture(&proof.previous, "absent", proof.change.request())
            .unwrap()
            .is_none());
        let mut foreign = proof.previous.clone();
        foreign.target_id = "foreign".into();
        assert!(engine
            .completed_capture(&foreign, "capture", proof.change.request())
            .is_err());
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(engine
            .completed_capture_with_budget(
                &proof.previous,
                "capture",
                proof.change.request(),
                &cancelled
            )
            .is_err());
        let gate = engine.observation_gate(&proof.previous.name).unwrap();
        let guard = gate.try_lock().unwrap();
        assert_eq!(
            engine
                .completed_capture(&proof.previous, "capture", proof.change.request())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(guard);
        assert_eq!(std::fs::read(journal).unwrap(), before);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn collected_uncertain_capture_moves_its_actual_lease_into_the_protected_stage_registry() {
        let root = tempfile::tempdir().unwrap();
        let mut leases = leases(root.path(), true, false);
        leases.directory = None;
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&leases.domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let metadata = std::fs::symlink_metadata(directory.path()).unwrap();
        let path = directory.path().to_owned();
        leases.identity = (metadata.dev(), metadata.ino());
        leases.directory = Some(directory);
        leases
            .permit
            .as_mut()
            .unwrap()
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        let mut receipt = CreationReceipt {
            target_id: "local".into(),
            domain_generation: "a".repeat(32),
            name: "source".into(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: "d".repeat(64),
            material: None,
        };
        receipt.material = Some(crate::material::root_proof(&receipt).unwrap());
        let ticket = leases
            .staging
            .register(
                &receipt,
                "unknown",
                &CaptureRequest {
                    max_bytes: 1024,
                    idle: true,
                },
                &path,
                &"e".repeat(64),
            )
            .unwrap();
        leases.staging.entered(&ticket).unwrap();
        leases.ticket = Some(ticket);
        let staging = leases.staging.clone();
        let jobs = leases.jobs.clone();
        let before = jobs.counts();
        drop(leases);
        assert!(path.exists());
        assert_eq!(jobs.counts(), before);
        drop(staging);
        assert_eq!(jobs.counts(), crate::jobs::Counts::default());
        // The on-disk ledger remains; dropping a registry is never cleanup.
        assert!(path.exists());
    }

    #[test]
    fn engine_stage_cleanup_requires_source_resolution_marker_gate_and_explicit_quiescence() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let receipt = entered_source(&engine, (i32::MAX, 456));
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&engine.domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let directory = directory.keep();
        let ticket = engine
            .capture_staging
            .register(&receipt, "unknown", &request, &directory, &"e".repeat(64))
            .unwrap();
        engine.capture_staging.entered(&ticket).unwrap();
        let mut lease = engine
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        lease
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        engine.capture_staging.retain_collected(&ticket, lease);
        let reserved = engine.jobs.counts();
        assert!(engine
            .cleanup_capture_staging(&receipt, "unknown", &request, false, &budget())
            .is_err());
        assert!(engine
            .cleanup_capture_staging(&receipt, "unknown", &request, true, &budget())
            .is_err());
        engine
            .resolve_entered_capture(&receipt, "unknown", &request, &budget())
            .unwrap();
        let gate = engine.observation_gate(&receipt.name).unwrap();
        let guard = gate.try_lock().unwrap();
        assert!(engine
            .cleanup_capture_staging(&receipt, "unknown", &request, true, &budget())
            .is_err());
        drop(guard);
        assert_eq!(engine.jobs.counts(), reserved);
        let proof = engine
            .cleanup_capture_staging(&receipt, "unknown", &request, true, &budget())
            .unwrap();
        assert_eq!(proof.previous, receipt);
        assert_eq!(proof.operation_id, "unknown");
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(!directory.exists());
        assert_eq!(
            engine
                .cleanup_capture_staging(&receipt, "unknown", &request, true, &budget())
                .unwrap(),
            proof
        );
    }

    fn retained_resolved_stage(
        engine: &Engine,
    ) -> (CreationReceipt, CreationReceipt, std::path::PathBuf) {
        let original = entered_source(engine, (i32::MAX, 456));
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&engine.domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let directory = directory.keep();
        let ticket = engine
            .capture_staging
            .register(&original, "unknown", &request, &directory, &"e".repeat(64))
            .unwrap();
        engine.capture_staging.entered(&ticket).unwrap();
        let mut lease = engine
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        lease
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        engine.capture_staging.retain_collected(&ticket, lease);
        let resolution = engine
            .resolve_entered_capture(&original, "unknown", &request, &budget())
            .unwrap();
        (original, resolution.receipt, directory)
    }

    fn model_source_removal(engine: &Engine, current: &CreationReceipt) {
        // Deterministic record/filesystem model; no SDK CLI or live VMM loss.
        engine.db.remove_vm(&current.name).unwrap();
        std::fs::remove_dir_all(engine.vm_directory(&current.name)).unwrap();
    }

    #[test]
    fn deleted_source_cleanup_requires_prior_exact_stopped_deletion_enrollment() {
        for enrolled in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let engine = crate::machine::tests::test_engine(root.path());
            let (original, current, directory) = retained_resolved_stage(&engine);
            let reserved = engine.jobs.counts();
            if enrolled {
                engine
                    .authorize_capture_staging_deletion(&current, &budget())
                    .unwrap();
                assert_eq!(engine.jobs.counts(), reserved);
            }
            model_source_removal(&engine, &current);
            let request = CaptureRequest {
                max_bytes: 1024,
                idle: true,
            };
            let result =
                engine.cleanup_capture_staging(&original, "unknown", &request, true, &budget());
            if enrolled {
                let proof = result.unwrap();
                assert_eq!(proof.previous, original);
                assert!(!directory.exists());
                assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
                assert_eq!(
                    engine
                        .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
                        .unwrap(),
                    proof
                );
            } else {
                assert!(result.is_err());
                assert!(directory.exists());
                assert_eq!(engine.jobs.counts(), reserved);
            }
        }
    }

    #[test]
    fn deletion_enrollment_and_cleanup_reject_cancelled_crossed_and_recreated_sources() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let (original, current, directory) = retained_resolved_stage(&engine);
        let cancelled = budget();
        cancelled.cancel.cancel();
        let reserved = engine.jobs.counts();
        assert!(engine
            .authorize_capture_staging_deletion(&current, &cancelled)
            .is_err());
        assert!(engine.delete_with_budget(&current, &cancelled).is_err());
        assert!(engine.db.get_vm(&current.name).unwrap().is_some());
        let mut crossed = current.clone();
        crossed.owner_token = "f".repeat(64);
        assert!(engine
            .authorize_capture_staging_deletion(&crossed, &budget())
            .is_err());
        engine
            .authorize_capture_staging_deletion(&current, &budget())
            .unwrap();
        let mut replacement = engine.db.get_vm(&current.name).unwrap().unwrap();
        model_source_removal(&engine, &current);
        replacement
            .labels
            .insert("smolbox.owner".into(), "f".repeat(64));
        engine
            .db
            .insert_vm(&replacement.name, &replacement)
            .unwrap();
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        assert!(engine
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .is_err());
        assert!(directory.exists());
        assert_eq!(engine.jobs.counts(), reserved);
        assert_eq!(
            engine.db.get_vm(&replacement.name).unwrap().unwrap().labels["smolbox.owner"],
            "f".repeat(64)
        );
    }

    #[test]
    fn deletion_authority_survives_ordinary_registry_replacement_without_restoring_source_ownership(
    ) {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let (original, current, directory) = retained_resolved_stage(&engine);
        engine
            .authorize_capture_staging_deletion(&current, &budget())
            .unwrap();
        model_source_removal(&engine, &current);
        let reserved = engine.jobs.counts();
        drop(engine);
        let replacement = crate::machine::tests::test_engine(root.path());
        assert_eq!(replacement.jobs.counts(), reserved);
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        replacement
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .unwrap();
        assert!(!directory.exists());
        assert_eq!(replacement.jobs.counts(), crate::jobs::Counts::default());
        assert!(replacement.runtime_pid(&current.name).is_none());
        assert_eq!(
            replacement.inspect(&current).unwrap().state,
            crate::ObservedState::Missing
        );
        assert!(replacement.db.get_vm(&current.name).unwrap().is_none());
    }

    #[test]
    fn uncollected_stage_blocks_delete_before_sdk_entry_without_releasing_any_stage() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let (original, current, retained) = retained_resolved_stage(&engine);
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&engine.domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        engine
            .capture_staging
            .register(
                &original,
                "uncollected",
                &CaptureRequest {
                    max_bytes: 1024,
                    idle: true,
                },
                directory.path(),
                &"e".repeat(64),
            )
            .unwrap();
        let reserved = engine.jobs.counts();
        assert_eq!(
            engine.delete(&current).unwrap_err().dispatch,
            crate::Dispatch::NotDispatched
        );
        assert!(retained.exists() && directory.path().exists());
        assert_eq!(engine.jobs.counts(), reserved);
        assert_eq!(
            engine.inspect(&current).unwrap().state,
            crate::ObservedState::Stopped
        );
    }

    #[test]
    fn cleaned_stage_proof_is_stable_across_deletion_enrollment_and_partial_source_absence_is_rejected(
    ) {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let (original, current, directory) = retained_resolved_stage(&engine);
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let proof = engine
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .unwrap();
        engine
            .authorize_capture_staging_deletion(&current, &budget())
            .unwrap();
        assert_eq!(
            engine
                .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
                .unwrap(),
            proof
        );
        model_source_removal(&engine, &current);
        std::fs::create_dir(engine.vm_directory(&current.name)).unwrap();
        assert!(engine
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .is_err());
        std::fs::remove_dir(engine.vm_directory(&current.name)).unwrap();
        assert_eq!(
            engine
                .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
                .unwrap(),
            proof
        );
        assert!(!directory.exists());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    fn prepared_stage(engine: &Engine, original: &CreationReceipt) -> std::path::PathBuf {
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&engine.domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let directory = directory.keep();
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let ticket = engine
            .capture_staging
            .register(original, "unknown", &request, &directory, &"e".repeat(64))
            .unwrap();
        let mut lease = engine
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        lease
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        // Model retirement which cannot perform its automatic cleanup. No child
        // is dispatched, killed or interrupted; the real reservation survives.
        engine
            .capture_staging
            .retire_prepared(&ticket, lease, false);
        directory
    }

    #[test]
    fn prepared_stage_abort_preserves_material_and_never_supplies_capture_or_resolution_success() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let original = source_boundary(&engine, (i32::MAX, 456), false);
        let directory = prepared_stage(&engine, &original);
        let source = engine.vm_directory(&original.name);
        let journal = crate::material::MaterialJournal::at(&source);
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let record_before = serde_json::to_vec(&engine.db.get_vm(&original.name).unwrap()).unwrap();
        let proof = engine
            .abort_capture_staging(&original, "unknown", &request, true, &budget())
            .unwrap();
        assert_eq!(proof.previous, original);
        assert!(!directory.exists() && source.exists());
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&original.name).unwrap()).unwrap(),
            record_before
        );
        journal.verify(&original).unwrap();
        assert!(journal
            .completed_capture(&original, "unknown", &request)
            .unwrap()
            .is_none());
        assert!(journal
            .resolved_capture(&original, "unknown", &request)
            .unwrap()
            .is_none());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(!engine.jobs.available());
        assert_eq!(
            engine
                .abort_capture_staging(&original, "unknown", &request, true, &budget())
                .unwrap(),
            proof
        );
        assert!(engine
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .is_err());
        // Abort is not a replay invitation: its original stage key is retired.
        let next = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&engine.domain.directory)
            .unwrap();
        std::fs::set_permissions(next.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(engine
            .capture_staging
            .register(&original, "unknown", &request, next.path(), &"e".repeat(64))
            .is_err());
    }

    #[test]
    fn prepared_abort_rejects_entered_foreign_unquiesced_cancelled_and_gated_authority() {
        for enter in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let engine = crate::machine::tests::test_engine(root.path());
            let original = source_boundary(&engine, (i32::MAX, 456), enter);
            let directory = prepared_stage(&engine, &original);
            let journal = engine
                .vm_directory(&original.name)
                .join("smolbox.material-v2.json");
            let before = std::fs::read(&journal).unwrap();
            let reserved = engine.jobs.counts();
            let request = CaptureRequest {
                max_bytes: 1024,
                idle: true,
            };
            let cancelled = budget();
            cancelled.cancel.cancel();
            assert!(engine
                .abort_capture_staging(&original, "unknown", &request, true, &cancelled)
                .is_err());
            assert!(engine
                .abort_capture_staging(&original, "unknown", &request, false, &budget())
                .is_err());
            assert!(engine
                .abort_capture_staging(&original, "foreign", &request, true, &budget())
                .is_err());
            let gate = engine.observation_gate(&original.name).unwrap();
            let guard = gate.try_lock().unwrap();
            assert!(engine
                .abort_capture_staging(&original, "unknown", &request, true, &budget())
                .is_err());
            drop(guard);
            if enter {
                assert!(engine
                    .abort_capture_staging(&original, "unknown", &request, true, &budget())
                    .is_err());
            }
            assert!(directory.exists());
            assert_eq!(std::fs::read(journal).unwrap(), before);
            assert_eq!(engine.jobs.counts(), reserved);
        }
    }

    #[test]
    fn registered_preentry_drop_clears_only_its_unentered_intent_and_keeps_a_durable_abort_receipt()
    {
        let root = tempfile::tempdir().unwrap();
        let mut engine = crate::machine::tests::test_engine(root.path());
        let original = source_boundary(&engine, (i32::MAX, 456), false);
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&engine.domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let root_identity = std::fs::symlink_metadata(directory.path()).unwrap();
        let path = directory.path().to_owned();
        let ticket = engine
            .capture_staging
            .register(&original, "unknown", &request, &path, &"e".repeat(64))
            .unwrap();
        let mut permit = engine
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        permit
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        let leases = Leases {
            directory: Some(directory),
            identity: (root_identity.dev(), root_identity.ino()),
            domain: engine.domain.clone(),
            jobs: engine.jobs.clone(),
            permit: Some(permit),
            _machine: Some(engine.gate(&original.name).unwrap().try_lock().unwrap()),
            entered: false,
            completed: false,
            staging: engine.capture_staging.clone(),
            ticket: Some(ticket),
        };
        drop(leases);
        assert!(!path.exists());
        crate::material::MaterialJournal::at(&engine.vm_directory(&original.name))
            .verify(&original)
            .unwrap();
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        let proof = engine
            .abort_capture_staging(&original, "unknown", &request, true, &budget())
            .unwrap();
        drop(engine);
        engine = crate::machine::tests::test_engine(root.path());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert_eq!(
            engine
                .abort_capture_staging(&original, "unknown", &request, true, &budget())
                .unwrap(),
            proof
        );
    }

    #[test]
    fn prepared_stage_retirement_cannot_clear_a_later_entered_or_completed_source_operation() {
        for complete in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let engine = crate::machine::tests::test_engine(root.path());
            let original = source_boundary(&engine, (i32::MAX, 456), false);
            let directory = prepared_stage(&engine, &original);
            let source = engine.vm_directory(&original.name);
            let journal = crate::material::MaterialJournal::at(&source);
            let request = CaptureRequest {
                max_bytes: 1024,
                idle: true,
            };
            journal
                .abort_capture_stage(&original, "unknown", &request)
                .unwrap();
            let mut record = engine.db.get_vm(&original.name).unwrap().unwrap();
            let later = journal
                .prepare_capture(&original, "later", request.clone(), &record)
                .unwrap();
            journal.enter_capture(&later).unwrap();
            if complete {
                record.checkpoint_head = Some("d".repeat(32));
                journal
                    .complete_capture(
                        &original,
                        &later,
                        crate::CaptureArtifact {
                            sha256: "f".repeat(64),
                            size_bytes: 1,
                            head: "d".repeat(32),
                            parent: None,
                        },
                        &record,
                    )
                    .unwrap();
                engine
                    .db
                    .update_vm(&record.name, |current| *current = record.clone())
                    .unwrap();
            }
            let before = std::fs::read(source.join("smolbox.material-v2.json")).unwrap();
            let record_before =
                serde_json::to_vec(&engine.db.get_vm(&original.name).unwrap()).unwrap();
            engine
                .abort_capture_staging(&original, "unknown", &request, true, &budget())
                .unwrap();
            assert!(!directory.exists());
            assert_eq!(
                std::fs::read(source.join("smolbox.material-v2.json")).unwrap(),
                before
            );
            assert_eq!(
                serde_json::to_vec(&engine.db.get_vm(&original.name).unwrap()).unwrap(),
                record_before
            );
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }

    fn registered_completed_guard(engine: &Engine, receipt: &CreationReceipt) -> Leases {
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&engine.domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let identity = std::fs::symlink_metadata(directory.path()).unwrap();
        let ticket = engine
            .capture_staging
            .register(
                receipt,
                "unknown",
                &CaptureRequest {
                    max_bytes: 1024,
                    idle: true,
                },
                directory.path(),
                &"e".repeat(64),
            )
            .unwrap();
        engine.capture_staging.entered(&ticket).unwrap();
        let mut permit = engine
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        permit
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        Leases {
            directory: Some(directory),
            identity: (identity.dev(), identity.ino()),
            domain: engine.domain.clone(),
            jobs: engine.jobs.clone(),
            permit: Some(permit),
            _machine: Some(engine.gate(&receipt.name).unwrap().try_lock().unwrap()),
            entered: true,
            completed: true,
            staging: engine.capture_staging.clone(),
            ticket: Some(ticket),
        }
    }

    #[test]
    fn completed_guard_closeout_preserves_source_and_durable_cleanup_across_normal_replacement() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let original = source_boundary_mode(&engine, (i32::MAX, 456), true, true);
        let guard = registered_completed_guard(&engine, &original);
        let path = guard.directory.as_ref().unwrap().path().to_owned();
        std::fs::write(path.join("captured"), b"private captured data").unwrap();
        let outside = root.path().join("outside");
        std::fs::write(&outside, b"preserve").unwrap();
        std::os::unix::fs::symlink(&outside, path.join("outside-link")).unwrap();
        let source = engine
            .vm_directory(&original.name)
            .join("smolbox.material-v2.json");
        let source_before = std::fs::read(&source).unwrap();
        let record_before = serde_json::to_vec(&engine.db.get_vm(&original.name).unwrap()).unwrap();
        assert_eq!(
            engine
                .cleanup_capture_staging(
                    &original,
                    "unknown",
                    &CaptureRequest {
                        max_bytes: 1024,
                        idle: true,
                    },
                    true,
                    &budget()
                )
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(guard);
        assert!(!path.exists());
        assert_eq!(std::fs::read(outside).unwrap(), b"preserve");
        assert_eq!(std::fs::read(&source).unwrap(), source_before);
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&original.name).unwrap()).unwrap(),
            record_before
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.jobs.available());
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let proof = engine
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .unwrap();
        drop(engine);
        let replacement = crate::machine::tests::test_engine(root.path());
        assert_eq!(replacement.jobs.counts(), crate::jobs::Counts::default());
        assert_eq!(
            replacement
                .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
                .unwrap(),
            proof
        );
    }

    #[test]
    fn completed_guard_flag_without_source_completion_cannot_remove_stage_or_release_native_allowance(
    ) {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let original = entered_source(&engine, (i32::MAX, 456));
        let guard = registered_completed_guard(&engine, &original);
        let path = guard.directory.as_ref().unwrap().path().to_owned();
        let reserved = engine.jobs.counts();
        drop(guard);
        assert!(path.exists());
        assert_eq!(engine.jobs.counts(), reserved);
        assert!(!engine.jobs.available());
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        assert!(engine
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .is_err());
        engine
            .resolve_entered_capture(&original, "unknown", &request, &budget())
            .unwrap();
        engine
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .unwrap();
        assert!(!path.exists());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn substituted_completed_stage_keeps_recoverable_allowance_until_exact_root_and_source_proof_return(
    ) {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let original = source_boundary_mode(&engine, (i32::MAX, 456), true, true);
        let guard = registered_completed_guard(&engine, &original);
        let path = guard.directory.as_ref().unwrap().path().to_owned();
        let saved = path.with_extension("original");
        let reserved = engine.jobs.counts();
        std::fs::rename(&path, &saved).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(path.join("foreign"), b"preserve").unwrap();
        drop(guard);
        assert_eq!(engine.jobs.counts(), reserved);
        assert!(!engine.jobs.available());
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        assert!(engine
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .is_err());
        assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"preserve");
        drop(engine);
        let replacement = crate::machine::tests::test_engine(root.path());
        assert_eq!(replacement.jobs.counts(), reserved);
        assert!(!replacement.jobs.available());
        let foreign = path.with_extension("foreign");
        std::fs::rename(&path, &foreign).unwrap();
        std::fs::rename(&saved, &path).unwrap();
        replacement
            .cleanup_capture_staging(&original, "unknown", &request, true, &budget())
            .unwrap();
        assert!(!path.exists());
        assert_eq!(std::fs::read(foreign.join("foreign")).unwrap(), b"preserve");
        assert_eq!(replacement.jobs.counts(), crate::jobs::Counts::default());
        assert!(!replacement.jobs.available());
    }

    fn source_bound_abort(engine: &Engine, pid: (i32, u64)) -> (CreationReceipt, CaptureRequest) {
        let original = source_boundary(engine, pid, false);
        let before = engine.db.get_vm(&original.name).unwrap().unwrap();
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&engine.domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let ticket = engine
            .capture_staging
            .register_source(
                &original,
                "unknown",
                &request,
                directory.path(),
                (&"e".repeat(64), &before),
            )
            .unwrap();
        let _ = directory.keep();
        let mut lease = engine
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        lease
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        engine.capture_staging.retire_prepared(&ticket, lease, true);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        (original, request)
    }

    #[test]
    fn aborted_source_qualification_preserves_material_and_requires_verified_original_process_absence(
    ) {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let (original, request) = source_bound_abort(&engine, (i32::MAX, 456));
        // A synthetic running inventory row never grants this engine a cache.
        assert!(engine
            .qualify_aborted_capture_source(&original, "unknown", &request, true, &budget())
            .is_err());
        engine
            .db
            .update_vm(&original.name, |record| {
                record.state = smolvm::config::RecordState::Stopped;
                record.pid = None;
                record.pid_start_time = None;
            })
            .unwrap();
        let journal = engine
            .vm_directory(&original.name)
            .join("smolbox.material-v2.json");
        let before = std::fs::read(&journal).unwrap();
        let record_before = serde_json::to_vec(&engine.db.get_vm(&original.name).unwrap()).unwrap();
        let proof = engine
            .qualify_aborted_capture_source(&original, "unknown", &request, true, &budget())
            .unwrap();
        proof.validate().unwrap();
        assert_eq!(proof.cleanup.previous, original);
        assert!(proof.state == crate::CaptureAbortSourceState::Stopped);
        assert_eq!(
            proof.record_sha256,
            original.material.as_ref().unwrap().record_sha256
        );
        assert_eq!(std::fs::read(&journal).unwrap(), before);
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&original.name).unwrap()).unwrap(),
            record_before
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        drop(engine);
        let replacement = crate::machine::tests::test_engine(root.path());
        assert_eq!(
            replacement
                .qualify_aborted_capture_source(&original, "unknown", &request, true, &budget())
                .unwrap(),
            proof
        );
    }

    #[test]
    fn aborted_source_qualification_rejects_current_live_process_disguised_as_stopped_without_signalling_it(
    ) {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let pid = std::process::id() as i32;
        let birth = smolvm::process::process_start_time(pid).unwrap();
        let (original, request) = source_bound_abort(&engine, (pid, birth));
        engine
            .db
            .update_vm(&original.name, |record| {
                record.state = smolvm::config::RecordState::Stopped;
                record.pid = None;
                record.pid_start_time = None;
            })
            .unwrap();
        assert!(engine
            .qualify_aborted_capture_source(&original, "unknown", &request, true, &budget())
            .is_err());
        assert!(smolvm::process::is_alive(pid));
        assert_eq!(smolvm::process::process_start_time(pid), Some(birth));
    }

    #[test]
    fn aborted_source_qualification_rejects_unquiesced_cancelled_foreign_gated_and_changed_material(
    ) {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let (original, request) = source_bound_abort(&engine, (i32::MAX, 456));
        engine
            .db
            .update_vm(&original.name, |record| {
                record.state = smolvm::config::RecordState::Stopped;
                record.pid = None;
                record.pid_start_time = None;
            })
            .unwrap();
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(engine
            .qualify_aborted_capture_source(&original, "unknown", &request, true, &cancelled)
            .is_err());
        assert!(engine
            .qualify_aborted_capture_source(&original, "unknown", &request, false, &budget())
            .is_err());
        assert!(engine
            .qualify_aborted_capture_source(&original, "other", &request, true, &budget())
            .is_err());
        let gate = engine.observation_gate(&original.name).unwrap();
        let guard = gate.try_lock().unwrap();
        assert!(engine
            .qualify_aborted_capture_source(&original, "unknown", &request, true, &budget())
            .is_err());
        drop(guard);
        engine
            .db
            .update_vm(&original.name, |record| {
                record.checkpoint_head = Some("d".repeat(32))
            })
            .unwrap();
        assert!(engine
            .qualify_aborted_capture_source(&original, "unknown", &request, true, &budget())
            .is_err());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn legacy_aborted_stage_cannot_invent_original_source_process_evidence() {
        let root = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(root.path());
        let original = source_boundary(&engine, (i32::MAX, 456), false);
        prepared_stage(&engine, &original);
        let request = CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        engine
            .abort_capture_staging(&original, "unknown", &request, true, &budget())
            .unwrap();
        engine
            .db
            .update_vm(&original.name, |record| {
                record.state = smolvm::config::RecordState::Stopped;
                record.pid = None;
                record.pid_start_time = None;
            })
            .unwrap();
        assert_eq!(
            engine
                .qualify_aborted_capture_source(&original, "unknown", &request, true, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Unsupported
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn stream_is_once_only_keeps_resources_and_cleans_up_after_collection() {
        let root = tempfile::tempdir().unwrap();
        let mut value = captured(root.path(), b"captured bytes");
        let path = value._leases.directory.as_ref().unwrap().path().to_owned();
        let jobs = value._leases.jobs.clone();
        let mut received = vec![];
        value
            .stream(&budget(), |chunk| {
                received.extend_from_slice(chunk);
                Ok(())
            })
            .unwrap();
        assert_eq!(received, b"captured bytes");
        assert_eq!(jobs.counts().work, 1);
        assert!(value
            .stream(&budget(), |_| panic!("must not replay"))
            .is_err());
        drop(value);
        assert!(!path.exists());
        assert_eq!(jobs.counts().work, 0);
    }

    #[test]
    fn stream_rejects_changed_bytes_before_emission_and_cannot_retry_failed_consumer() {
        let root = tempfile::tempdir().unwrap();
        let mut value = captured(root.path(), b"captured bytes");
        let path = value
            ._leases
            .directory
            .as_ref()
            .unwrap()
            .path()
            .join("capture.smolcheckpoint");
        std::fs::write(path, b"changed bytes").unwrap();
        assert!(value
            .stream(&budget(), |_| panic!("changed version must not emit"))
            .is_err());
        drop(value);
        let root = tempfile::tempdir().unwrap();
        let mut value = captured(root.path(), b"captured bytes");
        assert!(value
            .stream(&budget(), |_| Err(Error::before(ErrorCode::Io)))
            .is_err());
        assert!(value
            .stream(&budget(), |_| panic!("partial stream must not replay"))
            .is_err());
    }

    #[test]
    fn stream_shares_cancellation_through_consumer_and_never_replays_after_retirement() {
        let root = tempfile::tempdir().unwrap();
        let mut value = captured(root.path(), b"captured bytes");
        let stream_budget = budget();
        let cancel = stream_budget.cancel.clone();
        let mut calls = 0;
        assert!(value
            .stream(&stream_budget, |_| {
                calls += 1;
                cancel.cancel();
                Ok(())
            })
            .is_err());
        assert_eq!(calls, 1);
        assert!(value
            .stream(&budget(), |_| panic!("retired stream must not replay"))
            .is_err());
    }

    #[test]
    fn unresolved_entered_capture_preserves_staging_and_allowance_but_preentry_cleans_up() {
        for entered in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let leases = leases(root.path(), entered, false);
            let path = leases.directory.as_ref().unwrap().path().to_owned();
            let jobs = leases.jobs.clone();
            drop(leases);
            assert_eq!(path.exists(), entered);
            assert_eq!(jobs.counts().work, usize::from(entered));
        }
    }

    #[test]
    fn replaced_stage_is_preserved_and_quarantines_admission_without_deleting_foreign_bytes() {
        let root = tempfile::tempdir().unwrap();
        let leases = leases(root.path(), false, false);
        let path = leases.directory.as_ref().unwrap().path().to_owned();
        std::fs::rename(&path, path.with_extension("original")).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("foreign"), b"retain").unwrap();
        let jobs = leases.jobs.clone();
        assert!(leases.verify().is_err());
        drop(leases);
        assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"retain");
        assert_eq!(jobs.counts().work, 1);
        assert!(jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1).unwrap())
            .is_err());
    }
}
