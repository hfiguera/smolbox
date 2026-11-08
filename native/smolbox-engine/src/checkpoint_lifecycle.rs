//! Receipt-bound, explicit first-start intent. Missing inputs never select cold
//! boot, and observed SDK state cannot complete or replay an entered restore.
use crate::checkpoint_install::Proof;
use crate::{CreationReceipt, Error, ErrorCode, ReadBudget, Resources, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolvm::config::VmRecord;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub(crate) const FILE_NAME: &str = "smolbox.checkpoint-start-v1.json";
pub(crate) const LABEL: &str = "smolbox.checkpoint-start-sha256";
const MAX_BYTES: u64 = 64 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Root {
    schema: u8,
    target: String,
    domain: String,
    name: String,
    owner: String,
    incarnation: String,
    source_sha256: String,
    cpus: u8,
    memory_mib: u32,
    storage_gib: u64,
    overlay_gib: u64,
    installation: Proof,
}
impl Root {
    pub(crate) fn new(
        binding: &crate::DomainBinding,
        name: &str,
        owner: &str,
        incarnation: &str,
        source: &str,
        resources: Resources,
        installation: Proof,
    ) -> Result<Self> {
        let root = Self {
            schema: 1,
            target: binding.target_id.clone(),
            domain: binding.generation.clone(),
            name: name.into(),
            owner: owner.into(),
            incarnation: incarnation.into(),
            source_sha256: source.into(),
            cpus: resources.cpus,
            memory_mib: resources.memory_mib,
            storage_gib: resources.storage_gib,
            overlay_gib: resources.overlay_gib,
            installation,
        };
        root.validate()?;
        Ok(root)
    }
    fn resources(&self) -> Resources {
        Resources {
            cpus: self.cpus,
            memory_mib: self.memory_mib,
            storage_gib: self.storage_gib,
            overlay_gib: self.overlay_gib,
        }
    }
    fn validate(&self) -> Result<()> {
        if self.schema != 1
            || !crate::domain::valid_id(&self.target)
            || !crate::domain::valid_id(&self.name)
            || !crate::domain::valid_hex(&self.domain, 32)
            || !crate::domain::valid_hex(&self.owner, 64)
            || !crate::domain::valid_hex(&self.incarnation, 32)
            || !crate::domain::valid_hex(&self.source_sha256, 64)
            || !self.installation.matches(&self.installation.expected)
            || self.installation.storage_gib != self.storage_gib
            || self.installation.overlay_gib != self.overlay_gib
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.resources().validate()
    }
    pub(crate) fn sha256(&self) -> Result<String> {
        self.validate()?;
        Ok(hex::encode(Sha256::digest(
            serde_json::to_vec(self).map_err(|_| Error::before(ErrorCode::Validation))?,
        )))
    }
    fn bound(&self, receipt: &CreationReceipt, record: &VmRecord) -> Result<()> {
        self.validate()?;
        if !receipt.matches(record)?
            || self.target != receipt.target_id
            || self.domain != receipt.domain_generation
            || self.name != receipt.name
            || self.owner != receipt.owner_token
            || self.incarnation != receipt.incarnation
            || record.labels.get(LABEL) != Some(&self.sha256()?)
            || record.labels.get("smolbox.checkpoint-sha256") != Some(&self.source_sha256)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", deny_unknown_fields)]
enum Phase {
    Pending,
    Entered {
        operation: String,
    },
    Consumed {
        operation: String,
        pid: i32,
        birth: u64,
    },
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    root: Root,
    phase: Phase,
}
impl Journal {
    fn validate(&self) -> Result<()> {
        self.root.validate()?;
        match &self.phase {
            Phase::Pending => Ok(()),
            Phase::Entered { operation } if crate::domain::valid_hex(operation, 32) => Ok(()),
            Phase::Consumed {
                operation,
                pid,
                birth,
            } if crate::domain::valid_hex(operation, 32) && *pid > 0 && *birth > 0 => Ok(()),
            _ => Err(Error::before(ErrorCode::Ownership)),
        }
    }
}
pub(crate) struct StartPermit {
    journal: Journal,
    inode: crate::checkpoint_materialize::FileVersion,
    root: (u64, u64),
}
pub(crate) struct Lifecycle {
    directory: PathBuf,
}
impl Lifecycle {
    pub(crate) fn at(directory: &Path) -> Self {
        Self {
            directory: directory.into(),
        }
    }
    pub(crate) fn initialize(&self, root: Root) -> Result<()> {
        self.write(
            &Journal {
                root,
                phase: Phase::Pending,
            },
            None,
        )
    }

    /// Read-only truth classification. An entered operation remains unknown even
    /// when SDK inventory looks stopped or the pending marker disappeared.
    pub(crate) fn uncertain(
        &self,
        receipt: &CreationReceipt,
        record: &VmRecord,
        budget: &ReadBudget,
    ) -> Result<bool> {
        if !record.labels.contains_key("smolbox.checkpoint-sha256") {
            if record.labels.contains_key(LABEL)
                || std::fs::symlink_metadata(self.directory.join(FILE_NAME)).is_ok()
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            return Ok(false);
        }
        let (journal, _) = self.load(budget)?;
        journal.root.bound(receipt, record)?;
        match journal.phase {
            Phase::Entered { .. } => Ok(true),
            Phase::Pending => {
                self.verify_pending(&journal.root, budget)?;
                Ok(false)
            }
            Phase::Consumed { .. } => {
                self.verify_consumed_inputs()?;
                Ok(false)
            }
        }
    }
    pub(crate) fn prepare(
        &self,
        receipt: &CreationReceipt,
        record: &VmRecord,
        budget: &ReadBudget,
    ) -> Result<Option<StartPermit>> {
        if !record.labels.contains_key("smolbox.checkpoint-sha256") {
            self.uncertain(receipt, record, budget)?;
            return Ok(None);
        }
        let (journal, inode) = self.load(budget)?;
        journal.root.bound(receipt, record)?;
        match journal.phase {
            Phase::Pending => {
                if record.cpus != journal.root.cpus
                    || record.mem != journal.root.memory_mib
                    || record.storage_gb != Some(journal.root.storage_gib)
                    || record.overlay_gb != Some(journal.root.overlay_gib)
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                self.verify_pending(&journal.root, budget)?;
                Ok(Some(StartPermit {
                    journal,
                    inode,
                    root: self.identity()?,
                }))
            }
            Phase::Entered { .. } => Err(Error::uncertain(ErrorCode::State)),
            Phase::Consumed { .. } => {
                self.verify_consumed_inputs()?;
                Ok(None)
            }
        }
    }
    pub(crate) fn enter(
        &self,
        mut permit: StartPermit,
        operation: &str,
        budget: &ReadBudget,
    ) -> Result<StartPermit> {
        budget.check()?;
        if permit.journal.phase != Phase::Pending
            || !crate::domain::valid_hex(operation, 32)
            || self.identity()? != permit.root
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.verify_pending(&permit.journal.root, budget)?;
        permit.journal.phase = Phase::Entered {
            operation: operation.into(),
        };
        self.write(&permit.journal, Some(permit.inode))?;
        permit.inode = self.file_identity()?;
        Ok(permit)
    }
    pub(crate) fn complete(
        &self,
        mut permit: StartPermit,
        receipt: &CreationReceipt,
        record: &VmRecord,
        pid: (i32, u64),
        budget: &ReadBudget,
    ) -> Result<()> {
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        permit
            .journal
            .root
            .bound(receipt, record)
            .map_err(|error| Error::uncertain(error.code))?;
        if self.identity()? != permit.root
            || record.state != smolvm::config::RecordState::Running
            || record.pid.zip(record.pid_start_time) != Some(pid)
            || pid.0 <= 0
            || pid.1 == 0
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let Phase::Entered { operation } = &permit.journal.phase else {
            return Err(Error::uncertain(ErrorCode::Ownership));
        };
        self.verify_consumed_inputs()
            .map_err(|error| Error::uncertain(error.code))?;
        permit.journal.phase = Phase::Consumed {
            operation: operation.clone(),
            pid: pid.0,
            birth: pid.1,
        };
        self.write(&permit.journal, Some(permit.inode))
            .map_err(|error| Error::uncertain(error.code))
    }
    fn verify_pending(&self, root: &Root, budget: &ReadBudget) -> Result<()> {
        let actual = crate::checkpoint_install::installed_proof(
            &self.directory,
            root.resources(),
            root.installation.expected.clone(),
            budget,
        )?;
        if actual != root.installation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn verify_consumed_inputs(&self) -> Result<()> {
        if smolvm::portable_checkpoint::pending_dir(&self.directory).is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // SDK cleanup can leave payload files after removing its pending marker.
        // A marker without a complete payload must not silently select cold boot.
        let root = self.directory.join("portable-checkpoint");
        match std::fs::symlink_metadata(root.join("pending")) {
            Ok(_) => Err(Error::before(ErrorCode::Ownership)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err(Error::before(ErrorCode::Ownership)),
        }
    }
    fn identity(&self) -> Result<(u64, u64)> {
        crate::host::private_directory(&self.directory)?;
        let metadata = std::fs::symlink_metadata(&self.directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        Ok((metadata.dev(), metadata.ino()))
    }
    fn file_identity(&self) -> Result<crate::checkpoint_materialize::FileVersion> {
        let metadata = std::fs::symlink_metadata(self.directory.join(FILE_NAME))
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o600
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(crate::checkpoint_materialize::FileVersion::of(&metadata))
    }
    fn load(
        &self,
        budget: &ReadBudget,
    ) -> Result<(Journal, crate::checkpoint_materialize::FileVersion)> {
        budget.check()?;
        let directory = self.identity()?;
        let path = self.directory.join(FILE_NAME);
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let metadata = file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if metadata.len() > MAX_BYTES
            || !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o600
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        budget.check()?;
        if bytes.len() as u64 > MAX_BYTES
            || self.identity()? != directory
            || self.file_identity()? != crate::checkpoint_materialize::FileVersion::of(&metadata)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let journal: Journal =
            serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
        journal.validate()?;
        Ok((
            journal,
            crate::checkpoint_materialize::FileVersion::of(&metadata),
        ))
    }
    fn write(
        &self,
        journal: &Journal,
        expected: Option<crate::checkpoint_materialize::FileVersion>,
    ) -> Result<()> {
        journal.validate()?;
        let directory = self.identity()?;
        let path = self.directory.join(FILE_NAME);
        let bytes = serde_json::to_vec(journal).map_err(|_| Error::before(ErrorCode::Ownership))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut file = tempfile::NamedTempFile::new_in(&self.directory)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        file.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        file.write_all(&bytes)
            .and_then(|()| file.as_file().sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if self.identity()? != directory {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(expected) = expected {
            if self.file_identity()? != expected {
                return Err(Error::before(ErrorCode::Ownership));
            }
            file.persist(&path)
                .map_err(|_| Error::before(ErrorCode::Io))?;
        } else {
            file.persist_noclobber(&path)
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
        }
        File::open(&self.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::uncertain(ErrorCode::Io))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::checkpoint_install::Expected;
    struct Fixture {
        _temp: tempfile::TempDir,
        lifecycle: Lifecycle,
        receipt: CreationReceipt,
        record: VmRecord,
    }
    fn budget() -> ReadBudget {
        ReadBudget::for_checkpoint_work(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap()
    }
    fn fixture() -> Fixture {
        let temp = tempfile::tempdir().unwrap();
        let directory = temp.path().canonicalize().unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let pending = directory.join("portable-checkpoint");
        std::fs::create_dir(&pending).unwrap();
        for (name, bytes) in [
            ("pending", b"1\n".as_slice()),
            ("checkpoint.bin", b"state".as_slice()),
            ("memory.bin", b"memory".as_slice()),
            ("manifest.bin", b"layout".as_slice()),
        ] {
            std::fs::write(pending.join(name), bytes).unwrap();
            std::fs::set_permissions(pending.join(name), std::fs::Permissions::from_mode(0o600))
                .unwrap();
        }
        for role in ["storage", "overlay"] {
            let path = directory.join(format!("{role}.raw"));
            File::create(&path).unwrap().set_len(1 << 30).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
            let path = directory.join(format!("{role}.formatted"));
            std::fs::write(&path, b"1").unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let resources = Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let installation = crate::checkpoint_install::installed_proof(
            &directory,
            resources,
            Expected {
                metadata_sha256: "a".repeat(64),
                ticket_sha256: "b".repeat(64),
            },
            &budget(),
        )
        .unwrap();
        let binding = crate::DomainBinding {
            target_id: "local".into(),
            generation: "c".repeat(32),
            database: directory.join("db"),
            vm_root: directory.clone(),
        };
        let root = Root::new(
            &binding,
            "first-start-model",
            &"d".repeat(64),
            &"e".repeat(32),
            &"f".repeat(64),
            resources,
            installation,
        )
        .unwrap();
        let mut record = VmRecord::new(
            root.name.clone(),
            resources.cpus,
            resources.memory_mib,
            vec![],
            vec![],
            false,
        );
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record
            .labels
            .insert("smolbox.owner".into(), root.owner.clone());
        record
            .labels
            .insert("smolbox.incarnation".into(), root.incarnation.clone());
        record.labels.insert(
            "smolbox.checkpoint-sha256".into(),
            root.source_sha256.clone(),
        );
        record.labels.insert(LABEL.into(), root.sha256().unwrap());
        let receipt = CreationReceipt {
            target_id: binding.target_id,
            domain_generation: binding.generation,
            name: root.name.clone(),
            owner_token: root.owner.clone(),
            incarnation: root.incarnation.clone(),
            material_sha256: crate::identity::material_hash(&record).unwrap(),
            material: None,
        };
        let lifecycle = Lifecycle::at(&directory);
        lifecycle.initialize(root).unwrap();
        Fixture {
            _temp: temp,
            lifecycle,
            receipt,
            record,
        }
    }

    #[test]
    fn legacy_records_skip_checkpoint_authority_and_inplace_journal_changes_fence_old_permits() {
        let fixture = fixture();
        let mut legacy = fixture.record.clone();
        legacy.labels.remove("smolbox.checkpoint-sha256");
        legacy.labels.remove(LABEL);
        let directory = tempfile::tempdir().unwrap();
        let absent = Lifecycle::at(directory.path());
        assert!(!absent
            .uncertain(&fixture.receipt, &legacy, &budget())
            .unwrap());
        assert!(absent
            .prepare(&fixture.receipt, &legacy, &budget())
            .unwrap()
            .is_none());
        let lifecycle = &fixture.lifecycle;
        let permit = lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .unwrap()
            .unwrap();
        let path = lifecycle.directory.join(FILE_NAME);
        let mut bytes = std::fs::read(&path).unwrap();
        bytes.push(b' ');
        std::fs::write(&path, bytes).unwrap(); // same file, altered size/version
        assert!(lifecycle.enter(permit, &"4".repeat(32), &budget()).is_err());
        assert!(matches!(
            lifecycle.load(&budget()).unwrap().0.phase,
            Phase::Pending
        ));
    }

    #[test]
    fn pending_inputs_and_original_receipt_are_required_before_dispatch_without_fallback() {
        let fixture = fixture();
        let lifecycle = &fixture.lifecycle;
        assert!(!lifecycle
            .uncertain(&fixture.receipt, &fixture.record, &budget())
            .unwrap());
        assert!(lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .unwrap()
            .is_some());
        let mut crossed = fixture.receipt.clone();
        crossed.owner_token = "0".repeat(64);
        assert!(lifecycle
            .prepare(&crossed, &fixture.record, &budget())
            .is_err());
        let mut crossed = fixture.receipt.clone();
        crossed.material_sha256 = "0".repeat(64);
        assert!(lifecycle
            .prepare(&crossed, &fixture.record, &budget())
            .is_err());
        std::fs::remove_file(lifecycle.directory.join("portable-checkpoint/memory.bin")).unwrap();
        assert!(lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .is_err());
        assert!(lifecycle
            .uncertain(&fixture.receipt, &fixture.record, &budget())
            .is_err());
        assert!(matches!(
            lifecycle.load(&budget()).unwrap().0.phase,
            Phase::Pending
        ));
    }

    #[test]
    fn entered_intent_stays_unknown_after_sdk_consumption_and_cannot_replay_from_inventory() {
        let fixture = fixture();
        let lifecycle = &fixture.lifecycle;
        let permit = lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .unwrap()
            .unwrap();
        let permit = lifecycle.enter(permit, &"1".repeat(32), &budget()).unwrap();
        assert!(lifecycle
            .uncertain(&fixture.receipt, &fixture.record, &budget())
            .unwrap());
        assert!(lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .is_err());
        // Pure filesystem model; no VM, owner loss, signals or live store fault.
        smolvm::portable_checkpoint::consume(&lifecycle.directory).unwrap();
        assert!(lifecycle
            .uncertain(&fixture.receipt, &fixture.record, &budget())
            .unwrap());
        assert!(lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .is_err());
        assert!(lifecycle
            .complete(
                permit,
                &fixture.receipt,
                &fixture.record,
                (123, 456),
                &budget()
            )
            .is_err());
        assert!(matches!(
            lifecycle.load(&budget()).unwrap().0.phase,
            Phase::Entered { .. }
        ));
    }

    #[test]
    fn explicit_completion_correlates_pid_and_consumption_then_later_start_does_not_reapply_ram() {
        let mut fixture = fixture();
        let lifecycle = &fixture.lifecycle;
        let permit = lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .unwrap()
            .unwrap();
        let permit = lifecycle.enter(permit, &"2".repeat(32), &budget()).unwrap();
        smolvm::portable_checkpoint::consume(&lifecycle.directory).unwrap();
        // Synthetic SDK-success observation for this non-VM state model.
        fixture.record.pid = Some(123);
        fixture.record.pid_start_time = Some(456);
        fixture.record.state = smolvm::config::RecordState::Running;
        lifecycle
            .complete(
                permit,
                &fixture.receipt,
                &fixture.record,
                (123, 456),
                &budget(),
            )
            .unwrap();
        assert!(!lifecycle
            .uncertain(&fixture.receipt, &fixture.record, &budget())
            .unwrap());
        assert!(lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .unwrap()
            .is_none());
        assert!(matches!(
            lifecycle.load(&budget()).unwrap().0.phase,
            Phase::Consumed { .. }
        ));
        std::fs::create_dir_all(lifecycle.directory.join("portable-checkpoint")).unwrap();
        std::fs::write(
            lifecycle.directory.join("portable-checkpoint/pending"),
            b"1\n",
        )
        .unwrap();
        assert!(lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .is_err());
    }

    #[test]
    fn missing_or_replaced_journal_and_late_cancellation_cannot_supply_authority() {
        let fixture = fixture();
        let lifecycle = &fixture.lifecycle;
        let permit = lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .unwrap()
            .unwrap();
        let path = lifecycle.directory.join(FILE_NAME);
        let bytes = std::fs::read(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        assert!(lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .is_err());
        std::fs::write(&path, bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(lifecycle.enter(permit, &"3".repeat(32), &budget()).is_err());
        let permit = lifecycle
            .prepare(&fixture.receipt, &fixture.record, &budget())
            .unwrap()
            .unwrap();
        let cancel = crate::Cancellation::default();
        let stopped =
            ReadBudget::for_checkpoint_work(std::time::Duration::from_secs(30), cancel.clone())
                .unwrap();
        cancel.cancel();
        assert!(lifecycle.enter(permit, &"3".repeat(32), &stopped).is_err());
        assert!(matches!(
            lifecycle.load(&budget()).unwrap().0.phase,
            Phase::Pending
        ));
    }
}
