//! Receipt-bound stopped source admission, not export or publication success.
use crate::{CreationReceipt, Engine, Error, ErrorCode, ReadBudget, Result};
use smolvm::config::{RecordState, VmRecord};
use std::fs::{File, OpenOptions};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportSourceMode {
    Bare,
    Container,
}

/// Movable source gate and work allowance. Only the engine can construct one;
/// inventory, paths, manifest metadata and caller rows cannot supply authority.
pub struct QualifiedExportSource {
    receipt: CreationReceipt,
    record_sha256: String,
    mode: ExportSourceMode,
    root: Root,
    budget: ReadBudget,
    _machine: crate::gate::MachineLease,
    _job: crate::jobs::JobLease,
    // Release the domain lock after the root, source gate and accounting.
    domain: Arc<crate::domain::DomainGuard>,
}
impl std::fmt::Debug for QualifiedExportSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QualifiedExportSource")
            .field("mode", &self.mode)
            .finish_non_exhaustive()
    }
}
impl QualifiedExportSource {
    pub(crate) fn same_domain(&self, domain: &Arc<crate::domain::DomainGuard>) -> bool {
        Arc::ptr_eq(&self.domain, domain)
    }
    pub(crate) fn promote_stage(&mut self) -> Result<()> {
        self._job.promote_export_stage()
    }
    pub(crate) fn receipt(&self) -> &CreationReceipt {
        &self.receipt
    }
    pub(crate) fn budget(&self) -> &ReadBudget {
        &self.budget
    }
    pub(crate) fn directory(&self) -> &Path {
        &self.root.path
    }
    pub(crate) fn promote_disks(&mut self) -> Result<()> {
        self._job.promote_export_disks()
    }
    pub(crate) fn promote_conversion(&mut self) -> Result<()> {
        self._job.promote_export_conversion()
    }

    pub fn mode(&self) -> ExportSourceMode {
        self.mode
    }
    /// Recheck before dispatch/collection with the original absolute budget.
    /// A replacement engine cannot consume a lease from another owner epoch.
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        self.checked_record(engine).map(|_| ())
    }
    pub(crate) fn checked_record(&self, engine: &Engine) -> Result<VmRecord> {
        self.budget.check()?;
        if !Arc::ptr_eq(&self.domain, &engine.domain) || !engine.available() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.root.verify()?;
        let record = engine.export_source_record(&self.receipt, &self.budget)?;
        if record_digest(&record)? != self.record_sha256 || mode(&record)? != self.mode {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.root.verify()?;
        self.budget.check()?;
        Ok(record)
    }
}

impl Engine {
    pub fn qualify_export_source(
        &self,
        receipt: &CreationReceipt,
        budget: &ReadBudget,
    ) -> Result<QualifiedExportSource> {
        budget.check()?;
        receipt.validate(self.binding())?;
        if receipt.material.is_none() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let job = self.jobs.acquire(crate::jobs::Demand::export_source())?;
        let root = Root::open(&self.vm_directory(&receipt.name))?;
        let record = self.export_source_record(receipt, budget)?;
        let source = QualifiedExportSource {
            domain: self.domain.clone(),
            receipt: receipt.clone(),
            record_sha256: record_digest(&record)?,
            mode: mode(&record)?,
            root,
            budget: budget.clone(),
            _machine: machine,
            _job: job,
        };
        source.recheck(self)?;
        Ok(source)
    }
    fn export_source_record(
        &self,
        receipt: &CreationReceipt,
        budget: &ReadBudget,
    ) -> Result<VmRecord> {
        let record = self
            .observation_record(&receipt.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_record(receipt, &record)?;
        mode(&record)?;
        if self.runtime_pid(&receipt.name).is_some() || self.oci_manager_busy(&receipt.name)? {
            return Err(Error::before(ErrorCode::State));
        }
        if crate::sdk_compat::has_source_dependents(
            &self.binding().database,
            self.database_identity,
            &receipt.name,
            budget,
        )? {
            return Err(Error::before(ErrorCode::State));
        }
        budget.check()?;
        Ok(record)
    }
}
fn mode(record: &VmRecord) -> Result<ExportSourceMode> {
    if record.state != RecordState::Stopped
        || record.pid.is_some()
        || record.pid_start_time.is_some()
        || record.paused_checkpoint.is_some()
    {
        return Err(Error::before(ErrorCode::State));
    }
    Ok(if record.image.is_some() {
        ExportSourceMode::Container
    } else {
        ExportSourceMode::Bare
    })
}
fn record_digest(record: &VmRecord) -> Result<String> {
    crate::material::hash(&("smolbox-stopped-export-source-v1", record))
}

pub(crate) struct Root {
    path: PathBuf,
    file: File,
    stamp: (u64, u64, u32, u32),
}
impl Root {
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }
    pub(crate) fn descriptor(&self) -> &File {
        &self.file
    }
    pub(crate) fn open(path: &Path) -> Result<Self> {
        crate::host::unredirected(path)?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        let root = Self {
            path: path.to_path_buf(),
            file,
            stamp: Self::stamp(&metadata)?,
        };
        root.verify()?;
        Ok(root)
    }
    fn stamp(metadata: &std::fs::Metadata) -> Result<(u64, u64, u32, u32)> {
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o022 != 0
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok((
            metadata.dev(),
            metadata.ino(),
            metadata.uid(),
            metadata.mode(),
        ))
    }
    pub(crate) fn verify(&self) -> Result<()> {
        crate::host::unredirected(&self.path)?;
        let descriptor = self
            .file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let path =
            std::fs::symlink_metadata(&self.path).map_err(|_| Error::before(ErrorCode::Io))?;
        if Self::stamp(&descriptor)? != self.stamp || Self::stamp(&path)? != self.stamp {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{Cancellation, Dispatch};
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::time::Duration;

    pub(crate) fn fixture(root: &Path, image: bool) -> (Engine, CreationReceipt) {
        fixture_record(root, image, |_| {})
    }
    pub(crate) fn fixture_record(
        root: &Path,
        image: bool,
        edit: impl FnOnce(&mut VmRecord),
    ) -> (Engine, CreationReceipt) {
        let engine = crate::machine::tests::test_engine(root);
        let mut record = VmRecord::new("export-source".into(), 1, 512, vec![], vec![], false);
        record.state = RecordState::Stopped;
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record.env = vec![("SECRET".into(), "private-env-value".into())];
        if image {
            record.image = Some(format!(
                "registry.example/team/app@sha256:{}",
                "d".repeat(64)
            ));
        }
        record.labels.insert("smolbox.owner".into(), "b".repeat(64));
        edit(&mut record);
        let origin = CreationReceipt {
            target_id: engine.binding().target_id.clone(),
            domain_generation: engine.binding().generation.clone(),
            name: record.name.clone(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: crate::identity::material_hash(&record).unwrap(),
            material: None,
        };
        let directory = engine.vm_directory(&record.name);
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        engine
            .db
            .insert_vm_if_not_exists(&record.name, &record)
            .unwrap();
        crate::machine::tests::fixture_marker(&origin, &directory);
        let receipt = crate::material::MaterialJournal::at(&directory)
            .initialize(&origin)
            .unwrap();
        (engine, receipt)
    }
    fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(3600), Cancellation::default()).unwrap()
    }

    #[test]
    fn source_qualification_is_receipt_bound_nonmutating_and_retains_gate_and_work_allowance() {
        for image in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let (engine, receipt) = fixture(temp.path(), image);
            let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
            let source = engine.qualify_export_source(&receipt, &budget()).unwrap();
            assert_eq!(
                source.mode(),
                if image {
                    ExportSourceMode::Container
                } else {
                    ExportSourceMode::Bare
                }
            );
            source.recheck(&engine).unwrap();
            assert_eq!(engine.jobs.counts().work, 1);
            assert_eq!(engine.jobs.counts().children, 0);
            assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
            assert!(engine
                .observation_gate(&receipt.name)
                .unwrap()
                .try_lock()
                .is_err());
            let debug = format!("{source:?}");
            assert!(!debug.contains("private-env-value"));
            assert!(!debug.contains(&receipt.owner_token));
            assert_eq!(
                before,
                serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap()
            );
            drop(source);
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
            assert!(engine
                .observation_gate(&receipt.name)
                .unwrap()
                .try_lock()
                .is_ok());
        }
    }
    #[test]
    fn recheck_rejects_full_record_changes_and_shared_cancellation() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = fixture(temp.path(), false);
        let source = engine.qualify_export_source(&receipt, &budget()).unwrap();
        engine
            .db
            .update_vm(&receipt.name, |r| {
                r.labels.insert("diagnostic-note".into(), "changed".into());
            })
            .unwrap();
        assert!(source.recheck(&engine).is_err());
        drop(source);
        engine
            .db
            .update_vm(&receipt.name, |r| {
                r.labels.remove("diagnostic-note");
            })
            .unwrap();
        let other_temp = tempfile::tempdir().unwrap();
        let (other, _) = fixture(other_temp.path(), false);
        let source = engine.qualify_export_source(&receipt, &budget()).unwrap();
        assert!(source.recheck(&other).is_err());
        drop(source);
        let cancel = Cancellation::default();
        let work = ReadBudget::for_export_work(Duration::from_secs(1), cancel.clone()).unwrap();
        let source = engine.qualify_export_source(&receipt, &work).unwrap();
        cancel.cancel();
        assert!(source.recheck(&engine).is_err());
        drop(source);
    }
    #[test]
    fn cancellation_and_legacy_or_crossed_receipts_reject_without_dispatch_or_retained_capacity() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = fixture(temp.path(), false);
        let cancel = Cancellation::default();
        cancel.cancel();
        let stopped = ReadBudget::for_export_work(Duration::from_secs(1), cancel).unwrap();
        assert!(engine.qualify_export_source(&receipt, &stopped).is_err());
        for case in 0..3 {
            let mut crossed = receipt.clone();
            match case {
                0 => crossed.material = None,
                1 => crossed.owner_token = "f".repeat(64),
                _ => crossed.incarnation = "f".repeat(32),
            }
            let error = engine
                .qualify_export_source(&crossed, &budget())
                .err()
                .unwrap();
            assert_eq!(error.dispatch, Dispatch::NotDispatched);
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
        assert!(ReadBudget::for_export_work(Duration::ZERO, Cancellation::default()).is_err());
        assert!(
            ReadBudget::for_export_work(Duration::from_secs(86401), Cancellation::default())
                .is_err()
        );
        assert!(ReadBudget::new(Duration::from_secs(3600), Cancellation::default()).is_err());
    }
    #[test]
    fn source_root_replacement_redirection_and_unsafe_modes_reject_without_deletion() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().canonicalize().unwrap().join("source");
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let root = Root::open(&path).unwrap();
        let moved = path.with_file_name("retained");
        std::fs::rename(&path, &moved).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(root.verify().is_err());
        std::fs::remove_dir(&path).unwrap();
        symlink(&moved, &path).unwrap();
        assert!(Root::open(&path).is_err());
        std::fs::remove_file(&path).unwrap();
        std::fs::rename(&moved, &path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(root.verify().is_err());
        assert!(path.exists());
    }
    #[test]
    fn running_created_paused_or_pid_ambiguous_rows_never_supply_stopped_export_authority() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = fixture(temp.path(), false);
        let original = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        for case in 0..5 {
            let mut record = original.clone();
            match case {
                0 => record.state = RecordState::Created,
                1 => record.state = RecordState::Running,
                2 => record.state = RecordState::Paused,
                3 => record.pid = Some(std::process::id() as i32),
                _ => record.pid_start_time = Some(1),
            }
            engine
                .db
                .update_vm(&receipt.name, |r| *r = record.clone())
                .unwrap();
            assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }
    #[test]
    fn dependency_presence_and_malformed_inventory_block_without_adopting_or_mutating_rows() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = fixture(temp.path(), false);
        let mut child = VmRecord::new("dependent".into(), 1, 512, vec![], vec![], false);
        child.golden = Some(receipt.name.clone());
        engine
            .db
            .insert_vm_if_not_exists(&child.name, &child)
            .unwrap();
        let before = serde_json::to_vec(&engine.db.list_vms().unwrap()).unwrap();
        assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
        assert_eq!(
            before,
            serde_json::to_vec(&engine.db.list_vms().unwrap()).unwrap()
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        let writer = rusqlite::Connection::open(&engine.binding().database).unwrap();
        writer
            .execute("UPDATE vms SET data='{' WHERE name='dependent'", [])
            .unwrap();
        assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn source_lease_keeps_domain_enrolled_after_normal_empty_engine_drop() {
        // No VM/worker/helper process exists; this is an in-process lease model.
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = fixture(temp.path(), false);
        let binding = engine.binding().clone();
        let source = engine.qualify_export_source(&receipt, &budget()).unwrap();
        drop(engine);
        let private = temp.path().canonicalize().unwrap().join("private");
        assert_eq!(std::sync::Arc::strong_count(&source.domain), 1);
        assert_eq!(
            crate::domain::DomainGuard::acquire_at(&binding, private.clone(), false)
                .err()
                .unwrap()
                .code,
            ErrorCode::Conflict
        );
        drop(source);
        // Parallel ordinary subprocess startup can briefly inherit a CLOEXEC
        // descriptor until exec. No Rust lease remains; allow only a bounded
        // OS lock conflict, never ownership/I/O errors or an unbounded wait.
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        loop {
            match crate::domain::DomainGuard::acquire_at(&binding, private.clone(), false) {
                Ok(_) => break,
                Err(error)
                    if error.code == ErrorCode::Conflict
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(5))
                }
                Err(error) => panic!("normal domain release failed: {error:?}"),
            }
        }
    }
}
