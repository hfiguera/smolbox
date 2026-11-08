//! Protected capture-stage accounting. Inventory paths never create ownership.
use crate::{CaptureRequest, CreationReceipt, Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const RECORD_BYTES: u64 = 16 * 1024;
const RECORDS: usize = 1024;
const LEDGER: &str = "capture-stages-v1";

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Prepared,
    Entered,
    Collected,
    Cleaning,
    Cleaned,
    Aborting,
    Aborted,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureStagingCleanupReceipt {
    pub schema: u8,
    pub previous: CreationReceipt,
    pub operation_id: String,
    pub request: CaptureRequest,
    pub stage_sha256: String,
}
impl std::fmt::Debug for CaptureStagingCleanupReceipt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CaptureStagingCleanupReceipt")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl CaptureStagingCleanupReceipt {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        if self.schema != 1
            || self.previous.material.is_none()
            || !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.stage_sha256, 64)
            || !crate::domain::valid_id(&self.previous.target_id)
            || !crate::domain::valid_id(&self.previous.name)
            || !crate::domain::valid_hex(&self.previous.domain_generation, 32)
            || !crate::domain::valid_hex(&self.previous.owner_token, 64)
            || !crate::domain::valid_hex(&self.previous.incarnation, 32)
            || !crate::domain::valid_hex(&self.previous.material_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.previous
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .validate()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    schema: u8,
    receipt: CreationReceipt,
    operation_id: String,
    request: CaptureRequest,
    directory: String,
    device: u64,
    inode: u64,
    metadata_sha256: String,
    phase: Phase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    deletion_receipt: Option<CreationReceipt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_intent: Option<crate::capture_material::Intent>,
}
impl Record {
    fn key(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-capture-stage-v1",
            &self.receipt,
            &self.operation_id,
            &self.request,
        ))
    }
    fn valid(&self) -> Result<()> {
        self.request.validate()?;
        if self.schema != 1
            || self.receipt.material.is_none()
            || !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_id(&self.directory)
            || !self.directory.starts_with(".capture-")
            || self.inode == 0
            || !crate::domain::valid_hex(&self.metadata_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(current) = &self.deletion_receipt {
            if !same_origin(&self.receipt, current)
                || current.material.as_ref().is_none_or(|proof| {
                    proof.validate().is_err()
                        || self
                            .receipt
                            .material
                            .as_ref()
                            .is_none_or(|before| proof.revision <= before.revision)
                })
                || !matches!(
                    self.phase,
                    Phase::Collected | Phase::Cleaning | Phase::Cleaned
                )
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        if self.source_intent.as_ref().is_some_and(|intent| {
            !intent.valid()
                || intent.operation_id != self.operation_id
                || intent.request != self.request
                || self.receipt.material.as_ref() != Some(&intent.previous)
        }) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
struct Entry {
    record: Record,
    lease: Option<crate::jobs::JobLease>,
}
pub(crate) struct Staging {
    binding: crate::DomainBinding,
    domain: Arc<crate::domain::DomainGuard>,
    jobs: crate::jobs::JobPool,
    entries: Mutex<BTreeMap<String, Entry>>,
    ledger_identity: Mutex<Option<(u64, u64)>>,
}
pub(crate) struct Ticket {
    key: String,
}

impl Staging {
    pub(crate) fn aborted_source(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
    ) -> Result<(
        CaptureStagingCleanupReceipt,
        crate::capture_material::Intent,
    )> {
        self.domain.verify()?;
        receipt.validate(&self.binding)?;
        request.validate()?;
        let key =
            crate::material::hash(&("smolbox-capture-stage-v1", receipt, operation_id, request))?;
        let entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let entry = entries
            .get(&key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_ledger()?;
        let (stored, _) = read(&self.path(&key))?;
        if stored != entry.record || stored.phase != Phase::Aborted || entry.lease.is_some() {
            return Err(Error::before(ErrorCode::State));
        }
        stored.valid()?;
        let intent = stored
            .source_intent
            .clone()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        Ok((Self::cleanup_receipt(&stored)?, intent))
    }
    fn cleanup_receipt(record: &Record) -> Result<CaptureStagingCleanupReceipt> {
        let domain = if matches!(record.phase, Phase::Aborting | Phase::Aborted) {
            "smolbox-capture-stage-abort-v1"
        } else {
            "smolbox-capture-stage-cleanup-v1"
        };
        let mut identity = record.clone();
        identity.phase = Phase::Prepared;
        // Deletion enrollment authorizes later cleanup, not a different stage.
        identity.deletion_receipt = None;
        let receipt = CaptureStagingCleanupReceipt {
            schema: 1,
            previous: record.receipt.clone(),
            operation_id: record.operation_id.clone(),
            request: record.request.clone(),
            stage_sha256: crate::material::hash(&(domain, identity))?,
        };
        receipt.validate()?;
        Ok(receipt)
    }

    /// Called under the stopped source gate before SDK deletion can remove its
    /// journal. Store only exact completed/resolved stage authority; no paths or
    /// inventory become ownership. Uncollected stages block source disposal.
    pub(crate) fn authorize_source_deletion(
        &self,
        current: &CreationReceipt,
        journal: &crate::material::MaterialJournal,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.domain.verify()?;
        current.validate(&self.binding)?;
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let selected: Vec<String> = entries
            .iter()
            .filter(|(_, entry)| same_origin(&entry.record.receipt, current))
            .map(|(key, _)| key.clone())
            .collect();
        if selected.is_empty() {
            return Ok(());
        }
        self.verify_ledger()?;
        journal.verify(current)?;
        // Validate the whole selection before publishing any deletion intent.
        for key in &selected {
            budget.check()?;
            let entry = &entries[key];
            let (stored, _) = read(&self.path(key))?;
            if stored == entry.record && stored.phase == Phase::Aborted {
                continue;
            }
            if stored != entry.record
                || !matches!(
                    stored.phase,
                    Phase::Collected | Phase::Cleaning | Phase::Cleaned
                )
                || (journal
                    .completed_capture(&stored.receipt, &stored.operation_id, &stored.request)?
                    .is_none()
                    && journal
                        .resolved_capture(&stored.receipt, &stored.operation_id, &stored.request)?
                        .is_none())
            {
                return Err(Error::before(ErrorCode::State));
            }
        }
        for key in selected {
            budget.check()?;
            let entry = entries
                .get_mut(&key)
                .ok_or(Error::before(ErrorCode::Ownership))?;
            let (stored, version) = read(&self.path(&key))?;
            if stored != entry.record {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if stored.phase == Phase::Aborted {
                continue;
            }
            if stored.deletion_receipt.as_ref() == Some(current) {
                continue;
            }
            let mut enrolled = stored;
            enrolled.deletion_receipt = Some(current.clone());
            enrolled.valid()?;
            self.publish(&key, &enrolled, Some(version))?;
            entry.record = enrolled;
        }
        Ok(())
    }

    fn deletion_authority(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
    ) -> Result<CreationReceipt> {
        let key =
            crate::material::hash(&("smolbox-capture-stage-v1", receipt, operation_id, request))?;
        let entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let entry = entries
            .get(&key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_ledger()?;
        let (stored, _) = read(&self.path(&key))?;
        stored.valid()?;
        if stored != entry.record {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let current = stored
            .deletion_receipt
            .ok_or(Error::before(ErrorCode::State))?;
        current.validate(&self.binding)?;
        Ok(current)
    }

    pub(crate) fn cleanup(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        budget: &crate::ReadBudget,
    ) -> Result<CaptureStagingCleanupReceipt> {
        self.remove_stage(receipt, operation_id, request, budget, false)
    }

    /// Only after engine source/gate/quiescence qualification. Correlated source
    /// completion/resolution proves collection even when a stage-marker update
    /// failed. Root identity must still match before recording collection.
    fn qualified_cleanup(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        budget: &crate::ReadBudget,
    ) -> Result<CaptureStagingCleanupReceipt> {
        budget.check()?;
        let key =
            crate::material::hash(&("smolbox-capture-stage-v1", receipt, operation_id, request))?;
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let entry = entries
            .get_mut(&key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if matches!(entry.record.phase, Phase::Entered | Phase::Prepared) {
            if entry.lease.is_none() {
                return Err(Error::before(ErrorCode::State));
            }
            self.verify_ledger()?;
            self.verify_stage(&entry.record)?;
            let (stored, version) = read(&self.path(&key))?;
            if stored != entry.record {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let mut collected = stored;
            collected.phase = Phase::Collected;
            self.publish(&key, &collected, Some(version))?;
            entry.record = collected;
        }
        drop(entries);
        self.cleanup(receipt, operation_id, request, budget)
    }

    pub(crate) fn abort_prepared(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        budget: &crate::ReadBudget,
    ) -> Result<CaptureStagingCleanupReceipt> {
        budget.check()?;
        self.domain.verify()?;
        receipt.validate(&self.binding)?;
        request.validate()?;
        let key =
            crate::material::hash(&("smolbox-capture-stage-v1", receipt, operation_id, request))?;
        let entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let entry = entries
            .get(&key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_ledger()?;
        let (stored, _) = read(&self.path(&key))?;
        let mut prior = stored.clone();
        prior.phase = entry.record.phase;
        if stored != entry.record
            && !(stored.phase == Phase::Aborted
                && entry.record.phase == Phase::Aborting
                && prior == entry.record)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if !matches!(
            stored.phase,
            Phase::Prepared | Phase::Aborting | Phase::Aborted
        ) {
            return Err(Error::before(ErrorCode::State));
        }
        let terminal = stored.phase == Phase::Aborted;
        if stored.phase == Phase::Prepared {
            self.verify_stage(&stored)?;
        }
        if !terminal && entry.lease.is_none() {
            return Err(Error::before(ErrorCode::State));
        }
        drop(entries);
        if stored.phase == Phase::Prepared {
            let source = self
                .binding
                .vm_root
                .join(smolvm::agent::vm_dir_hash(&receipt.name));
            if !crate::machine::marker_matches(receipt, &source)? {
                return Err(Error::before(ErrorCode::Ownership));
            }
            budget.check()?;
            crate::material::MaterialJournal::at(&source).abort_capture_stage(
                receipt,
                operation_id,
                request,
            )?;
        }
        budget.check()?;
        self.remove_stage(receipt, operation_id, request, budget, true)
    }

    /// No SDK child was spawned: keep the actual allowance recoverable even if
    /// automatic pre-entry retirement fails. The caller still holds its gate.
    pub(crate) fn retire_prepared(
        &self,
        ticket: &Ticket,
        lease: crate::jobs::JobLease,
        trusted: bool,
    ) {
        let authority = {
            let mut entries = self
                .entries
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            match entries.get_mut(&ticket.key) {
                Some(entry) if entry.record.phase == Phase::Prepared && entry.lease.is_none() => {
                    entry.lease = Some(lease);
                    Some((
                        entry.record.receipt.clone(),
                        entry.record.operation_id.clone(),
                        entry.record.request.clone(),
                    ))
                }
                _ => {
                    std::mem::forget(lease);
                    None
                }
            }
        };
        let result = authority
            .filter(|_| trusted)
            .ok_or(Error::before(ErrorCode::Ownership))
            .and_then(|(receipt, id, request)| {
                let _control = self
                    .jobs
                    .acquire(crate::jobs::Demand::material_resolution())?;
                let budget = crate::ReadBudget::new(
                    std::time::Duration::from_secs(30),
                    crate::Cancellation::default(),
                )?;
                self.abort_prepared(&receipt, &id, &request, &budget)
            });
        if result.is_err() {
            self.jobs.quarantine();
        }
    }

    fn remove_stage(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        budget: &crate::ReadBudget,
        abort: bool,
    ) -> Result<CaptureStagingCleanupReceipt> {
        let (initial, cleaning, completed) = if abort {
            (Phase::Prepared, Phase::Aborting, Phase::Aborted)
        } else {
            (Phase::Collected, Phase::Cleaning, Phase::Cleaned)
        };
        budget.check()?;
        self.domain.verify()?;
        receipt.validate(&self.binding)?;
        request.validate()?;
        let key =
            crate::material::hash(&("smolbox-capture-stage-v1", receipt, operation_id, request))?;
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let entry = entries
            .get_mut(&key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_ledger()?;
        let (stored, mut version) = read(&self.path(&key))?;
        if stored != entry.record {
            let mut prior = stored.clone();
            prior.phase = entry.record.phase;
            if entry.record.phase == cleaning && stored.phase == completed && prior == entry.record
            {
                File::open(&self.domain.directory)
                    .and_then(|file| file.sync_all())
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                File::open(self.ledger())
                    .and_then(|file| file.sync_all())
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                let proof = Self::cleanup_receipt(&stored)?;
                entry.record = stored;
                entry.lease = None;
                return Ok(proof);
            }
            return Err(Error::before(ErrorCode::Ownership));
        }
        if stored.phase == completed {
            return Self::cleanup_receipt(&stored);
        }
        if ![initial, cleaning].contains(&stored.phase) || entry.lease.is_none() {
            return Err(Error::before(ErrorCode::State));
        }
        let parent = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&self.domain.directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let parent_metadata = parent
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let current_parent = private_directory(&self.domain.directory)?;
        if (parent_metadata.dev(), parent_metadata.ino())
            != (current_parent.dev(), current_parent.ino())
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if entry.record.phase == initial {
            self.verify_stage(&entry.record)?;
            let mut entered = entry.record.clone();
            entered.phase = cleaning;
            self.publish(&key, &entered, Some(version))?;
            entry.record = entered;
            version = read(&self.path(&key))?.1;
        }
        let name = std::ffi::CString::new(entry.record.directory.as_str())
            .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
        let raw = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if raw < 0 {
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::NotFound {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            // Only the protected prior Cleaning entry may finish known absence.
            require_absent(&parent, &name)?;
        } else {
            use std::os::fd::FromRawFd;
            let directory = unsafe { File::from_raw_fd(raw) };
            verify_directory(&directory, &entry.record)?;
            crate::volumes::remove_owned_tree(&directory, budget, crate::VOLUME_DELETE_ENTRIES)
                .map_err(|error| Error::uncertain(error.code))?;
            directory
                .sync_all()
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
            budget
                .check()
                .map_err(|error| Error::uncertain(error.code))?;
            self.verify_stage(&entry.record)
                .map_err(|error| Error::uncertain(error.code))?;
            if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } != 0
            {
                return Err(Error::uncertain(ErrorCode::Io));
            }
            require_absent(&parent, &name)?;
        }
        parent
            .sync_all()
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        self.domain
            .verify()
            .map_err(|error| Error::uncertain(error.code))?;
        let mut cleaned = entry.record.clone();
        cleaned.phase = completed;
        self.publish(&key, &cleaned, Some(version))
            .map_err(|error| Error::uncertain(error.code))?;
        let proof =
            Self::cleanup_receipt(&cleaned).map_err(|error| Error::uncertain(error.code))?;
        entry.record = cleaned;
        entry.lease = None;
        Ok(proof)
    }
    /// Read existing records without initializing or cleaning any stage. An
    /// unknown legacy directory quarantines work rather than supplying a lease.
    pub(crate) fn open(
        binding: &crate::DomainBinding,
        domain: Arc<crate::domain::DomainGuard>,
        jobs: crate::jobs::JobPool,
    ) -> Result<Arc<Self>> {
        domain.verify()?;
        let this = Arc::new(Self {
            binding: binding.clone(),
            domain,
            jobs,
            entries: Mutex::new(BTreeMap::new()),
            ledger_identity: Mutex::new(None),
        });
        let ledger = this.ledger();
        let mut uncertain_stage = false;
        match std::fs::symlink_metadata(&ledger) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Error::before(ErrorCode::Ownership)),
            Ok(_) => {
                this.verify_ledger()?;
                let mut entries = this
                    .entries
                    .lock()
                    .map_err(|_| Error::before(ErrorCode::Native))?;
                for item in std::fs::read_dir(&ledger).map_err(|_| Error::before(ErrorCode::Io))? {
                    if entries.len() >= RECORDS {
                        return Err(Error::before(ErrorCode::Admission));
                    }
                    let item = item.map_err(|_| Error::before(ErrorCode::Io))?;
                    let name = item
                        .file_name()
                        .into_string()
                        .map_err(|_| Error::before(ErrorCode::Ownership))?;
                    let key = name
                        .strip_suffix(".json")
                        .filter(|key| crate::domain::valid_hex(key, 64))
                        .ok_or(Error::before(ErrorCode::Ownership))?;
                    this.verify_ledger()?;
                    let (record, _) = read(&item.path())?;
                    record.valid()?;
                    record.receipt.validate(&this.binding)?;
                    if record.key()? != key {
                        return Err(Error::before(ErrorCode::Ownership));
                    }
                    let lease = if matches!(record.phase, Phase::Cleaned | Phase::Aborted) {
                        uncertain_stage |= !matches!(std::fs::symlink_metadata(this.domain.directory.join(&record.directory)), Err(error) if error.kind() == std::io::ErrorKind::NotFound);
                        None
                    } else {
                        uncertain_stage |= this.verify_stage(&record).is_err();
                        let mut lease = this.jobs.acquire(
                            crate::jobs::Demand::checkpoint_prepare(record.request.max_bytes)?,
                        )?;
                        lease.promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)?;
                        Some(lease)
                    };
                    entries.insert(key.into(), Entry { record, lease });
                }
            }
        }
        if uncertain_stage {
            this.jobs.quarantine();
        }
        let entries = this
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        for item in
            std::fs::read_dir(&this.domain.directory).map_err(|_| Error::before(ErrorCode::Io))?
        {
            let item = item.map_err(|_| Error::before(ErrorCode::Io))?;
            if item.file_name().to_string_lossy().starts_with(".capture-")
                && !entries
                    .values()
                    .any(|entry| item.file_name() == std::ffi::OsStr::new(&entry.record.directory))
            {
                this.jobs.quarantine();
            }
        }
        drop(entries);
        Ok(this)
    }
    #[cfg(test)]
    pub(crate) fn register(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        directory: &Path,
        metadata_sha256: &str,
    ) -> Result<Ticket> {
        self.register_bound(
            receipt,
            operation_id,
            request,
            directory,
            (metadata_sha256, None),
        )
    }

    pub(crate) fn register_source(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        directory: &Path,
        source: (&str, &smolvm::config::VmRecord),
    ) -> Result<Ticket> {
        let intent = crate::material::capture_source_intent(
            receipt,
            operation_id,
            request.clone(),
            source.1,
        )?;
        self.register_bound(
            receipt,
            operation_id,
            request,
            directory,
            (source.0, Some(intent)),
        )
    }

    fn register_bound(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        directory: &Path,
        source: (&str, Option<crate::capture_material::Intent>),
    ) -> Result<Ticket> {
        self.domain.verify()?;
        receipt.validate(&self.binding)?;
        if directory.parent() != Some(self.domain.directory.as_path()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let metadata = private_directory(directory)?;
        let record = Record {
            schema: 1,
            receipt: receipt.clone(),
            operation_id: operation_id.into(),
            request: request.clone(),
            directory: directory
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or(Error::before(ErrorCode::Ownership))?
                .into(),
            device: metadata.dev(),
            inode: metadata.ino(),
            metadata_sha256: source.0.into(),
            phase: Phase::Prepared,
            deletion_receipt: None,
            source_intent: source.1,
        };
        record.valid()?;
        let key = record.key()?;
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if entries.len() >= RECORDS || entries.contains_key(&key) {
            return Err(Error::before(ErrorCode::Conflict));
        }
        File::open(&self.domain.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        self.publish(&key, &record, None)?;
        entries.insert(
            key.clone(),
            Entry {
                record,
                lease: None,
            },
        );
        Ok(Ticket { key })
    }
    pub(crate) fn entered(&self, ticket: &Ticket) -> Result<()> {
        self.advance(ticket, Phase::Entered)
    }
    fn advance(&self, ticket: &Ticket, phase: Phase) -> Result<()> {
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let entry = entries
            .get_mut(&ticket.key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_stage(&entry.record)?;
        self.verify_ledger()?;
        let (stored, version) = read(&self.path(&ticket.key))?;
        if stored != entry.record {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut record = stored;
        record.phase = phase;
        self.publish(&ticket.key, &record, Some(version))?;
        entry.record = record;
        Ok(())
    }
    /// Called only when the supervisor's owned guard can drop: the exact child
    /// is collected or was never spawned. Unknown collectors retain that guard.
    pub(crate) fn retain_collected(&self, ticket: &Ticket, lease: crate::jobs::JobLease) {
        let updated = self.advance(ticket, Phase::Collected);
        if updated.is_err() {
            self.jobs.quarantine();
        }
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if let Some(entry) = entries.get_mut(&ticket.key) {
            if entry.lease.is_none() {
                entry.lease = Some(lease);
                return;
            }
        }
        self.jobs.quarantine();
        std::mem::forget(lease);
    }
    /// Only after verified own stage removal. No missing-path inventory adopts
    /// an unrecorded cleanup or releases a retained uncertain lease.
    #[cfg(test)]
    pub(crate) fn forget_cleaned(&self, ticket: &Ticket) -> Result<()> {
        self.domain.verify()?;
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let entry = entries
            .get(&ticket.key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let path = self.domain.directory.join(&entry.record.directory);
        match std::fs::symlink_metadata(path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            _ => return Err(Error::before(ErrorCode::Ownership)),
        }
        let (stored, _) = read(&self.path(&ticket.key))?;
        self.verify_ledger()?;
        if stored != entry.record || entry.lease.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        File::open(&self.domain.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        std::fs::remove_file(self.path(&ticket.key)).map_err(|_| Error::before(ErrorCode::Io))?;
        File::open(self.ledger())
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        entries.remove(&ticket.key);
        Ok(())
    }

    /// Completed guard closeout runs while the caller still holds its source
    /// gate. Unlike legacy record removal, durable cleanup remains observable.
    pub(crate) fn retire_completed(&self, ticket: &Ticket) -> Result<CaptureStagingCleanupReceipt> {
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let budget = crate::ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )?;
        self.domain.verify()?;
        let entries = self
            .entries
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let entry = entries
            .get(&ticket.key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_ledger()?;
        let (record, _) = read(&self.path(&ticket.key))?;
        if record != entry.record || record.phase != Phase::Collected || entry.lease.is_none() {
            return Err(Error::before(ErrorCode::State));
        }
        drop(entries);
        let source = self
            .binding
            .vm_root
            .join(smolvm::agent::vm_dir_hash(&record.receipt.name));
        if !crate::machine::marker_matches(&record.receipt, &source)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()?;
        if crate::material::MaterialJournal::at(&source)
            .completed_capture(&record.receipt, &record.operation_id, &record.request)?
            .is_none()
        {
            return Err(Error::before(ErrorCode::State));
        }
        self.cleanup(
            &record.receipt,
            &record.operation_id,
            &record.request,
            &budget,
        )
    }
    fn ledger(&self) -> PathBuf {
        self.domain.directory.join(LEDGER)
    }
    fn path(&self, key: &str) -> PathBuf {
        self.ledger().join(format!("{key}.json"))
    }
    fn verify_stage(&self, record: &Record) -> Result<()> {
        self.domain.verify()?;
        let metadata = private_directory(&self.domain.directory.join(&record.directory))?;
        if (metadata.dev(), metadata.ino()) != (record.device, record.inode) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn verify_ledger(&self) -> Result<std::fs::Metadata> {
        self.domain.verify()?;
        let metadata = private_directory(&self.ledger())?;
        let observed = (metadata.dev(), metadata.ino());
        let mut identity = self
            .ledger_identity
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        match *identity {
            Some(expected) if expected != observed => {
                return Err(Error::before(ErrorCode::Ownership))
            }
            None => *identity = Some(observed),
            _ => {}
        }
        Ok(metadata)
    }
    fn publish(
        &self,
        key: &str,
        record: &Record,
        expected: Option<crate::checkpoint_materialize::FileVersion>,
    ) -> Result<()> {
        self.domain.verify()?;
        let ledger = self.ledger();
        match std::fs::DirBuilder::new().mode(0o700).create(&ledger) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => return Err(Error::before(ErrorCode::Io)),
        }
        let parent = self.verify_ledger()?;
        File::open(&self.domain.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let bytes = serde_json::to_vec(record).map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > RECORD_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        let mut temporary =
            tempfile::NamedTempFile::new_in(&ledger).map_err(|_| Error::before(ErrorCode::Io))?;
        temporary
            .as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))
            .and_then(|()| temporary.write_all(&bytes))
            .and_then(|()| temporary.as_file().sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let observed = self.verify_ledger()?;
        if (parent.dev(), parent.ino()) != (observed.dev(), observed.ino()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let path = self.path(key);
        if let Some(expected) = expected {
            if read(&path)?.1 != expected {
                return Err(Error::before(ErrorCode::Ownership));
            }
            temporary
                .persist(&path)
                .map_err(|_| Error::before(ErrorCode::Io))?;
        } else {
            temporary
                .persist_noclobber(&path)
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
        }
        File::open(ledger)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))
    }
}
fn verify_directory(directory: &File, record: &Record) -> Result<()> {
    let metadata = directory
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o700
        || (metadata.dev(), metadata.ino()) != (record.device, record.inode)
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    Ok(())
}
fn require_absent(parent: &File, name: &std::ffi::CString) -> Result<()> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } == -1
        && std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound
    {
        Ok(())
    } else {
        Err(Error::uncertain(ErrorCode::Ownership))
    }
}

impl crate::Engine {
    /// Retire only a registered stage whose source capture never entered.
    /// This produces no material transition or successful capture result.
    pub fn abort_capture_staging(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        quiesced: bool,
        budget: &crate::ReadBudget,
    ) -> Result<CaptureStagingCleanupReceipt> {
        if !quiesced || !crate::domain::valid_id(operation_id) {
            return Err(Error::before(ErrorCode::Validation));
        }
        budget.check()?;
        receipt.validate(self.binding())?;
        request.validate()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        self.capture_staging
            .abort_prepared(receipt, operation_id, request, budget)
    }
    pub(crate) fn authorize_capture_staging_deletion(
        &self,
        current: &CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        if self.inspect(current)?.state != crate::ObservedState::Stopped {
            return Err(Error::before(ErrorCode::State));
        }
        self.capture_staging.authorize_source_deletion(
            current,
            &crate::material::MaterialJournal::at(&self.vm_directory(&current.name)),
            budget,
        )
    }
    /// Explicit owned native-stage cleanup. Source-only qualification or artifact
    /// absence alone cannot release these executing/retained native allowances.
    pub fn cleanup_capture_staging(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &CaptureRequest,
        quiesced: bool,
        budget: &crate::ReadBudget,
    ) -> Result<CaptureStagingCleanupReceipt> {
        if !quiesced || !crate::domain::valid_id(operation_id) {
            return Err(Error::before(ErrorCode::Validation));
        }
        budget.check()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        receipt.validate(self.binding())?;
        request.validate()?;
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let directory = self.vm_directory(&receipt.name);
        match std::fs::symlink_metadata(&directory) {
            Ok(_) => {
                if !crate::machine::marker_matches(receipt, &directory)? {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let journal = crate::material::MaterialJournal::at(&directory);
                if journal
                    .completed_capture(receipt, operation_id, request)?
                    .is_none()
                    && journal
                        .resolved_capture(receipt, operation_id, request)?
                        .is_none()
                {
                    return Err(Error::before(ErrorCode::State));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let current =
                    self.capture_staging
                        .deletion_authority(receipt, operation_id, request)?;
                if self.inspect(&current)?.state != crate::ObservedState::Missing {
                    return Err(Error::before(ErrorCode::State));
                }
            }
            Err(_) => return Err(Error::before(ErrorCode::Ownership)),
        }
        budget.check()?;
        self.capture_staging
            .qualified_cleanup(receipt, operation_id, request, budget)
    }
}
fn same_origin(left: &CreationReceipt, right: &CreationReceipt) -> bool {
    let mut left = left.clone();
    let mut right = right.clone();
    left.material = None;
    right.material = None;
    left == right
}
fn private_directory(path: &Path) -> Result<std::fs::Metadata> {
    crate::host::unredirected(path)?;
    let metadata =
        std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o700
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(metadata)
}
fn read(path: &Path) -> Result<(Record, crate::checkpoint_materialize::FileVersion)> {
    crate::host::unredirected(path)?;
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() > RECORD_BYTES
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let version = crate::checkpoint_materialize::FileVersion::of(&metadata);
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(RECORD_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    if bytes.len() as u64 != metadata.len()
        || crate::checkpoint_materialize::FileVersion::of(
            &file.metadata().map_err(|_| Error::before(ErrorCode::Io))?,
        ) != version
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let record = serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
    Ok((record, version))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> (
        tempfile::TempDir,
        crate::DomainBinding,
        Arc<crate::domain::DomainGuard>,
        crate::jobs::JobPool,
        Arc<Staging>,
        CreationReceipt,
    ) {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let binding = crate::DomainBinding {
            target_id: "local".into(),
            generation: "a".repeat(32),
            database: root.join("db"),
            vm_root: root.join("vms"),
        };
        let domain = Arc::new(
            crate::domain::DomainGuard::acquire_at(&binding, root.join("private"), true).unwrap(),
        );
        let jobs = crate::jobs::JobPool::default();
        let staging = Staging::open(&binding, domain.clone(), jobs.clone()).unwrap();
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
        (temp, binding, domain, jobs, staging, receipt)
    }
    fn stage(domain: &crate::domain::DomainGuard) -> PathBuf {
        let directory = tempfile::Builder::new()
            .prefix(".capture-")
            .tempdir_in(&domain.directory)
            .unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        directory.keep()
    }
    fn request() -> CaptureRequest {
        CaptureRequest {
            max_bytes: 1024,
            idle: true,
        }
    }
    fn lease(jobs: &crate::jobs::JobPool) -> crate::jobs::JobLease {
        let mut lease = jobs
            .acquire(crate::jobs::Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        lease
            .promote_checkpoint_material(crate::JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        lease
    }
    #[test]
    fn retained_collected_stage_keeps_actual_lease_and_replacement_restores_its_full_allowance() {
        let (_temp, binding, domain, jobs, staging, receipt) = setup();
        let directory = stage(&domain);
        let permit = lease(&jobs);
        let reserved = jobs.counts();
        let ticket = staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        staging.entered(&ticket).unwrap();
        staging.retain_collected(&ticket, permit);
        assert_eq!(jobs.counts(), reserved);
        assert!(staging.forget_cleaned(&ticket).is_err());
        drop(staging);
        assert_eq!(jobs.counts(), crate::jobs::Counts::default());
        let replacement_jobs = crate::jobs::JobPool::default();
        let replacement =
            Staging::open(&binding, domain.clone(), replacement_jobs.clone()).unwrap();
        assert_eq!(replacement_jobs.counts(), reserved);
        assert!(directory.exists());
        assert!(
            replacement
                .entries
                .lock()
                .unwrap()
                .values()
                .next()
                .unwrap()
                .record
                .phase
                == Phase::Collected
        );
    }
    #[test]
    fn registration_never_adopts_foreign_domain_request_stage_alias_or_existing_ticket() {
        let (_temp, _binding, domain, _jobs, staging, receipt) = setup();
        let directory = stage(&domain);
        let mut foreign = receipt.clone();
        foreign.domain_generation = "f".repeat(32);
        assert!(staging
            .register(&foreign, "capture", &request(), &directory, &"e".repeat(64))
            .is_err());
        let ticket = staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        assert!(staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .is_err());
        let other = stage(&domain);
        let old = directory.with_extension("saved");
        std::fs::rename(&directory, &old).unwrap();
        std::os::unix::fs::symlink(&other, &directory).unwrap();
        assert!(staging.entered(&ticket).is_err());
        assert!(old.exists() && other.exists());
    }
    #[test]
    fn ordinary_own_cleanup_removes_only_the_matching_unretained_registration() {
        let (_temp, _binding, domain, jobs, staging, receipt) = setup();
        let directory = stage(&domain);
        let ticket = staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        assert!(staging.forget_cleaned(&ticket).is_err());
        std::fs::remove_dir(&directory).unwrap();
        staging.forget_cleaned(&ticket).unwrap();
        assert!(!staging.path(&ticket.key).exists());
        assert_eq!(jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn indexed_missing_stage_keeps_restored_capacity_and_only_quarantines_work() {
        let (_temp, binding, domain, jobs, staging, receipt) = setup();
        let directory = stage(&domain);
        let permit = lease(&jobs);
        let reserved = jobs.counts();
        let ticket = staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        staging.entered(&ticket).unwrap();
        staging.retain_collected(&ticket, permit);
        std::fs::remove_dir(&directory).unwrap();
        drop(staging);
        let restored_jobs = crate::jobs::JobPool::default();
        let restored = Staging::open(&binding, domain, restored_jobs.clone()).unwrap();
        assert_eq!(restored_jobs.counts(), reserved);
        assert!(!restored_jobs.available());
        assert!(restored_jobs
            .acquire(crate::jobs::Demand::observation())
            .is_ok());
        assert!(restored.forget_cleaned(&ticket).is_err());
    }

    #[test]
    fn copied_ledger_directory_cannot_replace_the_retained_parent_identity() {
        let (_temp, _binding, domain, jobs, staging, receipt) = setup();
        let directory = stage(&domain);
        let ticket = staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        let bytes = std::fs::read(staging.path(&ticket.key)).unwrap();
        let original = staging.ledger().with_extension("saved");
        std::fs::rename(staging.ledger(), &original).unwrap();
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(staging.ledger())
            .unwrap();
        std::fs::write(staging.path(&ticket.key), bytes).unwrap();
        std::fs::set_permissions(
            staging.path(&ticket.key),
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        assert!(staging.entered(&ticket).is_err());
        assert!(original.exists() && directory.exists());
        assert_eq!(jobs.counts(), crate::jobs::Counts::default());
    }

    fn budget() -> crate::ReadBudget {
        crate::ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap()
    }
    fn retained(
        staging: &Staging,
        domain: &crate::domain::DomainGuard,
        jobs: &crate::jobs::JobPool,
        receipt: &CreationReceipt,
    ) -> (Ticket, PathBuf) {
        let directory = stage(domain);
        let ticket = staging
            .register(receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        staging.entered(&ticket).unwrap();
        staging.retain_collected(&ticket, lease(jobs));
        (ticket, directory)
    }
    #[test]
    fn explicit_cleanup_uses_recorded_stage_identity_and_releases_only_after_synced_completion() {
        let (temp, binding, domain, jobs, staging, receipt) = setup();
        let (_ticket, directory) = retained(&staging, &domain, &jobs, &receipt);
        let outside = temp.path().join("outside");
        std::fs::write(&outside, b"outside").unwrap();
        std::fs::create_dir(directory.join("nested")).unwrap();
        std::fs::write(directory.join("nested/file"), b"retained").unwrap();
        std::os::unix::fs::symlink(&outside, directory.join("outside-link")).unwrap();
        std::fs::hard_link(&outside, directory.join("outside-hardlink")).unwrap();
        let proof = staging
            .cleanup(&receipt, "capture", &request(), &budget())
            .unwrap();
        proof.validate().unwrap();
        assert!(!directory.exists());
        assert_eq!(std::fs::read(&outside).unwrap(), b"outside");
        assert_eq!(jobs.counts(), crate::jobs::Counts::default());
        assert_eq!(
            staging
                .cleanup(&receipt, "capture", &request(), &budget())
                .unwrap(),
            proof
        );
        drop(staging);
        let restored_jobs = crate::jobs::JobPool::default();
        let restored = Staging::open(&binding, domain, restored_jobs.clone()).unwrap();
        assert_eq!(restored_jobs.counts(), crate::jobs::Counts::default());
        assert_eq!(
            restored
                .cleanup(&receipt, "capture", &request(), &budget())
                .unwrap(),
            proof
        );
    }
    #[test]
    fn cleanup_rejects_uncollected_foreign_replaced_and_unproved_absent_stages_without_freeing_capacity(
    ) {
        let (_temp, _binding, domain, jobs, staging, receipt) = setup();
        let directory = stage(&domain);
        let ticket = staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        staging.entered(&ticket).unwrap();
        let permit = lease(&jobs);
        let reserved = jobs.counts();
        assert!(staging
            .cleanup(&receipt, "capture", &request(), &budget())
            .is_err());
        staging.retain_collected(&ticket, permit);
        assert!(staging
            .cleanup(&receipt, "different", &request(), &budget())
            .is_err());
        let original = directory.with_extension("saved");
        std::fs::rename(&directory, &original).unwrap();
        std::os::unix::fs::symlink(&original, &directory).unwrap();
        assert!(staging
            .cleanup(&receipt, "capture", &request(), &budget())
            .is_err());
        std::fs::remove_file(&directory).unwrap();
        assert!(staging
            .cleanup(&receipt, "capture", &request(), &budget())
            .is_err());
        assert_eq!(jobs.counts(), reserved);
        assert!(original.exists());
    }
    #[test]
    fn protected_cleaning_models_resume_partial_tree_or_known_removed_root_without_artifact_success(
    ) {
        for missing in [false, true] {
            let (_temp, binding, domain, jobs, staging, receipt) = setup();
            let (ticket, directory) = retained(&staging, &domain, &jobs, &receipt);
            staging.advance(&ticket, Phase::Cleaning).unwrap();
            if missing {
                std::fs::remove_dir(&directory).unwrap();
            } else {
                std::fs::write(directory.join("remaining"), b"partial").unwrap();
            }
            let reserved = jobs.counts();
            drop(staging);
            let restored_jobs = crate::jobs::JobPool::default();
            let restored = Staging::open(&binding, domain, restored_jobs.clone()).unwrap();
            assert_eq!(restored_jobs.counts(), reserved);
            let proof = restored
                .cleanup(&receipt, "capture", &request(), &budget())
                .unwrap();
            proof.validate().unwrap();
            assert!(!directory.exists());
            assert_eq!(restored_jobs.counts(), crate::jobs::Counts::default());
            if missing {
                assert!(!restored_jobs.available());
            }
        }
    }
    #[test]
    fn cancelled_cleanup_and_wrong_immutable_completion_keep_the_exact_retained_lease() {
        let (_temp, _binding, domain, jobs, staging, receipt) = setup();
        let (ticket, directory) = retained(&staging, &domain, &jobs, &receipt);
        std::fs::write(directory.join("artifact"), b"unknown").unwrap();
        let reserved = jobs.counts();
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(staging
            .cleanup(&receipt, "capture", &request(), &cancelled)
            .is_err());
        assert_eq!(
            std::fs::read(directory.join("artifact")).unwrap(),
            b"unknown"
        );
        staging.advance(&ticket, Phase::Cleaning).unwrap();
        let (mut wrong, _) = read(&staging.path(&ticket.key)).unwrap();
        wrong.phase = Phase::Cleaned;
        wrong.metadata_sha256 = "f".repeat(64);
        let (_record, version) = read(&staging.path(&ticket.key)).unwrap();
        staging.publish(&ticket.key, &wrong, Some(version)).unwrap();
        assert!(staging
            .cleanup(&receipt, "capture", &request(), &budget())
            .is_err());
        assert_eq!(jobs.counts(), reserved);
    }

    #[test]
    fn an_exact_published_cleaned_record_can_finish_sync_and_release_after_a_modeled_reply_loss() {
        let (_temp, _binding, domain, jobs, staging, receipt) = setup();
        let (ticket, directory) = retained(&staging, &domain, &jobs, &receipt);
        staging.advance(&ticket, Phase::Cleaning).unwrap();
        std::fs::remove_dir(&directory).unwrap();
        let (mut completed, version) = read(&staging.path(&ticket.key)).unwrap();
        completed.phase = Phase::Cleaned;
        staging
            .publish(&ticket.key, &completed, Some(version))
            .unwrap();
        // Model a completed private publication with the previous in-memory
        // state/lease still retained. No persistence interruption is injected.
        assert!(jobs.counts().work > 0);
        staging
            .cleanup(&receipt, "capture", &request(), &budget())
            .unwrap();
        assert_eq!(jobs.counts(), crate::jobs::Counts::default());
    }
    fn source_for_abort(binding: &crate::DomainBinding, receipt: &CreationReceipt) {
        let source = binding
            .vm_root
            .join(smolvm::agent::vm_dir_hash(&receipt.name));
        std::fs::create_dir_all(&source).unwrap();
        let mut origin = receipt.clone();
        origin.material = None;
        assert_eq!(
            crate::material::MaterialJournal::at(&source)
                .initialize(&origin)
                .unwrap(),
            *receipt
        );
        std::fs::write(
            source.join("smolbox.incarnation"),
            format!(
                "smolbox-incarnation-v1\n{}\n{}\n{}\n{}\n",
                receipt.domain_generation,
                receipt.owner_token,
                receipt.incarnation,
                receipt.material_sha256,
            ),
        )
        .unwrap();
    }

    #[test]
    fn prepared_abort_resumes_only_protected_partial_or_known_removed_attempts() {
        for missing in [false, true] {
            let (temp, binding, domain, jobs, staging, receipt) = setup();
            source_for_abort(&binding, &receipt);
            let directory = stage(&domain);
            let ticket = staging
                .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
                .unwrap();
            staging.retire_prepared(&ticket, lease(&jobs), false);
            let outside = temp.path().join("outside");
            std::fs::write(&outside, b"preserved").unwrap();
            if !missing {
                std::os::unix::fs::symlink(&outside, directory.join("link")).unwrap();
                std::fs::write(directory.join("partial"), b"remaining").unwrap();
            }
            staging.advance(&ticket, Phase::Aborting).unwrap();
            if missing {
                std::fs::remove_dir(&directory).unwrap();
            }
            let reserved = jobs.counts();
            drop(staging);
            let restored_jobs = crate::jobs::JobPool::default();
            let restored = Staging::open(&binding, domain, restored_jobs.clone()).unwrap();
            assert_eq!(restored_jobs.counts(), reserved);
            let proof = restored
                .abort_prepared(&receipt, "capture", &request(), &budget())
                .unwrap();
            assert!(!directory.exists());
            assert_eq!(std::fs::read(outside).unwrap(), b"preserved");
            assert_eq!(restored_jobs.counts(), crate::jobs::Counts::default());
            assert_eq!(
                restored
                    .abort_prepared(&receipt, "capture", &request(), &budget())
                    .unwrap(),
                proof
            );
            assert!(restored
                .cleanup(&receipt, "capture", &request(), &budget())
                .is_err());
        }
    }

    #[test]
    fn exact_published_abort_can_finish_bookkeeping_but_unrecorded_absence_cannot() {
        let (_temp, binding, domain, jobs, staging, receipt) = setup();
        source_for_abort(&binding, &receipt);
        let directory = stage(&domain);
        let ticket = staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        staging.retire_prepared(&ticket, lease(&jobs), false);
        let reserved = jobs.counts();
        std::fs::remove_dir(&directory).unwrap();
        assert!(staging
            .abort_prepared(&receipt, "capture", &request(), &budget())
            .is_err());
        assert_eq!(jobs.counts(), reserved);
        // Construct protected fixture state for a distinct recorded-removal
        // scenario. No API infers this authority from the missing path.
        let (mut recorded, version) = read(&staging.path(&ticket.key)).unwrap();
        recorded.phase = Phase::Aborting;
        staging
            .publish(&ticket.key, &recorded, Some(version))
            .unwrap();
        staging
            .entries
            .lock()
            .unwrap()
            .get_mut(&ticket.key)
            .unwrap()
            .record = recorded.clone();
        // Model a known removal followed by completed durable publication.
        let expected = Staging::cleanup_receipt(&recorded).unwrap();
        let normal = {
            let mut other = recorded.clone();
            other.phase = Phase::Cleaned;
            Staging::cleanup_receipt(&other).unwrap()
        };
        assert_ne!(expected.stage_sha256, normal.stage_sha256);
        let version = read(&staging.path(&ticket.key)).unwrap().1;
        recorded.phase = Phase::Aborted;
        staging
            .publish(&ticket.key, &recorded, Some(version))
            .unwrap();
        assert_eq!(
            staging
                .abort_prepared(&receipt, "capture", &request(), &budget())
                .unwrap(),
            expected
        );
        assert_eq!(jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn unindexed_legacy_stage_quarantines_work_and_corrupt_record_cannot_recover_capacity() {
        let (_temp, binding, domain, jobs, staging, receipt) = setup();
        let directory = stage(&domain);
        let reopened = Staging::open(&binding, domain.clone(), jobs.clone()).unwrap();
        assert!(!jobs.available() && directory.exists());
        drop(reopened);
        let ticket = staging
            .register(&receipt, "capture", &request(), &directory, &"e".repeat(64))
            .unwrap();
        std::fs::write(staging.path(&ticket.key), b"{}\n").unwrap();
        assert!(Staging::open(&binding, domain.clone(), crate::jobs::JobPool::default()).is_err());
    }
}
