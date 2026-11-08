//! Protected export scratch authority. Existing files never enroll themselves.
use crate::{CreationReceipt, DomainBinding, Error, ErrorCode, ReadBudget, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

#[path = "export_layer.rs"]
pub(crate) mod layer;

pub const EXPORT_RECORD_BYTES: u64 = 16 * 1024;
const RECORD_BYTES: u64 = EXPORT_RECORD_BYTES;
pub const EXPORT_RECORDS: usize = 256;
const RECORDS: usize = EXPORT_RECORDS;
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Preparing,
    Ready,
    Packing,
    Packed,
    Cleaning,
    Cleaned,
    NoStage,
    Admitted,
    Entering,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    schema: u8,
    source: CreationReceipt,
    operation_id: String,
    request_sha256: String,
    max_bytes: u64,
    directory: String,
    device: u64,
    inode: u64,
    phase: Phase,
    files: Vec<ExportStagedFile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    publication: Option<Publication>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    admission: Option<Admission>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    helper: Option<Helper>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    layer: Option<layer::Layer>,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum HelperPhase {
    Reserved,
    Owned,
    Removing,
    Removed,
    SdkPreparing,
    SdkPrepared,
    LaunchEntering,
    LaunchReturned,
    LaunchCollecting,
    LaunchCollected,
    RuntimePrepared,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Helper {
    name: String,
    resources: crate::ExportConversionResources,
    budget: crate::ExportConversionBudget,
    phase: HelperPhase,
    root: Option<HelperRoot>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    files: Vec<HelperFile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    launch: Option<HelperLaunch>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    runtime: Option<crate::export_runtime::Snapshot>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HelperLaunch {
    intent: crate::epoch::BootIntent,
    child: Option<crate::OwnerIdentity>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HelperFile {
    name: String,
    version: Version,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HelperRoot {
    device: u64,
    inode: u64,
    uid: u32,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
impl HelperRoot {
    fn of(file: &File) -> Result<Self> {
        let m = file.metadata().map_err(|_| before(ErrorCode::Io))?;
        if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o777 != 0o700 {
            return Err(before(ErrorCode::Ownership));
        }
        Ok(Self {
            device: m.dev(),
            inode: m.ino(),
            uid: m.uid(),
            mtime: m.mtime(),
            mtime_ns: m.mtime_nsec(),
            ctime: m.ctime(),
            ctime_ns: m.ctime_nsec(),
        })
    }
}
impl Helper {
    fn same_anchor(&self, root: &File) -> Result<bool> {
        let current = HelperRoot::of(root)?;
        Ok(self.root.as_ref().is_some_and(|old| {
            current.device == old.device && current.inode == old.inode && current.uid == old.uid
        }))
    }
    fn verify_files(&self, path: &Path, removing: bool) -> Result<()> {
        let entries = std::fs::read_dir(path).map_err(|_| before(ErrorCode::Io))?;
        let mut count = 0;
        for entry in entries {
            count += 1;
            if count > 6 {
                return Err(before(ErrorCode::Ownership));
            }
            let entry = entry.map_err(|_| before(ErrorCode::Io))?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| before(ErrorCode::Ownership))?;
            let expected = self
                .files
                .iter()
                .find(|file| file.name == name)
                .ok_or(before(ErrorCode::Ownership))?;
            if Version::of(&plain(&entry.path())?)? != expected.version {
                return Err(before(ErrorCode::Ownership));
            }
        }
        if !removing && count != self.files.len() {
            return Err(before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn path(&self, binding: &DomainBinding) -> PathBuf {
        binding.vm_root.join(smolvm::agent::vm_dir_hash(&self.name))
    }
    fn validate(&self, record: &Record) -> Result<()> {
        if self.name
            != format!(
                "smolbox-export-{}",
                key(&record.source, &record.operation_id, &record.request_sha256)?
            )
            || self.budget.max_staging_bytes != record.max_bytes
            || self.budget != self.resources.rebuild(&self.budget)?
            || (self.phase == HelperPhase::Reserved && self.root.is_some())
            || (matches!(
                self.phase,
                HelperPhase::Owned
                    | HelperPhase::Removing
                    | HelperPhase::SdkPreparing
                    | HelperPhase::SdkPrepared
                    | HelperPhase::LaunchEntering
                    | HelperPhase::LaunchReturned
                    | HelperPhase::LaunchCollecting
                    | HelperPhase::LaunchCollected
                    | HelperPhase::RuntimePrepared
            ) && self.root.is_none())
            || self.root.as_ref().is_some_and(|r| {
                r.device == 0
                    || r.inode == 0
                    || r.uid != unsafe { libc::geteuid() }
                    || r.mtime <= 0
                    || r.ctime <= 0
                    || !(0..1_000_000_000).contains(&r.mtime_ns)
                    || !(0..1_000_000_000).contains(&r.ctime_ns)
            })
        {
            return Err(before(ErrorCode::Ownership));
        }
        if (record.schema == 6
            && (!self.files.is_empty()
                || matches!(
                    self.phase,
                    HelperPhase::SdkPreparing | HelperPhase::SdkPrepared
                )))
            || (self.phase == HelperPhase::SdkPreparing && !self.files.is_empty())
            || self.files.len() > 6
        {
            return Err(before(ErrorCode::Ownership));
        }
        if record.schema == 7
            && (!matches!(
                self.phase,
                HelperPhase::SdkPreparing
                    | HelperPhase::SdkPrepared
                    | HelperPhase::Removing
                    | HelperPhase::Removed
            ) || self.root.is_none())
        {
            return Err(before(ErrorCode::Ownership));
        }
        if record.schema < 8 && self.launch.is_some() {
            return Err(before(ErrorCode::Ownership));
        }
        if record.schema < 9 && self.runtime.is_some() {
            return Err(before(ErrorCode::Ownership));
        }
        if record.schema == 9 || (matches!(record.schema, 10 | 11) && self.runtime.is_some()) {
            let runtime = self.runtime.as_ref().ok_or(before(ErrorCode::Ownership))?;
            runtime.validate(&self.name, &self.budget)?;
            if !matches!(
                self.phase,
                HelperPhase::RuntimePrepared | HelperPhase::Removing | HelperPhase::Removed
            ) || self.root.is_none()
                || !matches!(self.files.len(), 4 | 6)
                || self
                    .launch
                    .as_ref()
                    .is_none_or(|l| !l.intent.valid_for(&self.name) || l.child.is_none())
                || self
                    .launch
                    .as_ref()
                    .and_then(|l| l.child)
                    .is_some_and(|child| {
                        child.pid <= 0
                            || child.birth == 0
                            || child.uid != unsafe { libc::geteuid() }
                            || self
                                .launch
                                .as_ref()
                                .is_some_and(|l| child.pid == l.intent.owner().pid)
                    })
            {
                return Err(before(ErrorCode::Ownership));
            }
        } else if self.phase == HelperPhase::RuntimePrepared {
            return Err(before(ErrorCode::Ownership));
        }
        if record.schema == 8 || (record.schema == 10 && self.runtime.is_none()) {
            let launch = self.launch.as_ref().ok_or(before(ErrorCode::Ownership))?;
            if !launch.intent.valid_for(&self.name)
                || self.root.is_none()
                || !matches!(self.files.len(), 4 | 6)
                || !matches!(
                    self.phase,
                    HelperPhase::LaunchEntering
                        | HelperPhase::LaunchReturned
                        | HelperPhase::LaunchCollecting
                        | HelperPhase::LaunchCollected
                )
                || (self.phase == HelperPhase::LaunchEntering && launch.child.is_some())
                || (self.phase != HelperPhase::LaunchEntering && launch.child.is_none())
                || launch.child.is_some_and(|child| {
                    child.pid <= 0
                        || child.birth == 0
                        || child.pid == launch.intent.owner().pid
                        || child.uid != launch.intent.owner().uid
                })
            {
                return Err(before(ErrorCode::Ownership));
            }
        } else if matches!(
            self.phase,
            HelperPhase::LaunchEntering
                | HelperPhase::LaunchReturned
                | HelperPhase::LaunchCollecting
                | HelperPhase::LaunchCollected
        ) {
            return Err(before(ErrorCode::Ownership));
        }
        let mut names = std::collections::BTreeSet::new();
        for file in &self.files {
            let maximum = match file.name.as_str() {
                "name" => 128,
                "storage.formatted" | "overlay.formatted" => 1,
                "storage.raw" => self.budget.storage_gib * (1 << 30),
                "overlay.raw" => self.budget.overlay_gib * (1 << 30),
                "export-source.qcow2" => self.budget.source_storage_bytes * 2,
                _ => return Err(before(ErrorCode::Ownership)),
            };
            if !names.insert(&file.name)
                || file.version.2 > maximum
                || self
                    .root
                    .as_ref()
                    .is_none_or(|r| file.version.0 != r.device)
            {
                return Err(before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
}
fn helper_forward(old: &Option<Helper>, new: &Option<Helper>) -> bool {
    match (old, new) {
        (None, Some(next)) => next.phase == HelperPhase::Reserved && next.root.is_none(),
        (Some(old), Some(next)) => {
            if old.phase == HelperPhase::LaunchCollected
                && next.phase == HelperPhase::RuntimePrepared
            {
                return old.name == next.name
                    && old.resources == next.resources
                    && old.budget == next.budget
                    && old.files == next.files
                    && old.launch == next.launch
                    && old.runtime.is_none()
                    && next.runtime.is_some()
                    && old
                        .root
                        .as_ref()
                        .zip(next.root.as_ref())
                        .is_some_and(|(a, b)| {
                            a.device == b.device && a.inode == b.inode && a.uid == b.uid
                        });
            }
            if matches!(
                (old.phase, next.phase),
                (HelperPhase::SdkPrepared, HelperPhase::LaunchEntering)
                    | (HelperPhase::LaunchEntering, HelperPhase::LaunchReturned)
            ) {
                let launch_forward = match (&old.launch, &next.launch) {
                    (None, Some(next)) => next.child.is_none(),
                    (Some(old), Some(next)) => {
                        old.intent == next.intent && old.child.is_none() && next.child.is_some()
                    }
                    _ => false,
                };
                return old.name == next.name
                    && old.resources == next.resources
                    && old.budget == next.budget
                    && old.root == next.root
                    && old.files == next.files
                    && launch_forward;
            }
            if old.phase == HelperPhase::SdkPreparing && next.phase == HelperPhase::SdkPrepared {
                return old.name == next.name
                    && old.resources == next.resources
                    && old.budget == next.budget
                    && old.files.is_empty()
                    && old
                        .root
                        .as_ref()
                        .zip(next.root.as_ref())
                        .is_some_and(|(a, b)| {
                            a.device == b.device && a.inode == b.inode && a.uid == b.uid
                        });
            }
            old.name == next.name
                && old.resources == next.resources
                && old.budget == next.budget
                && (old.root == next.root
                    || (old.phase == HelperPhase::Reserved && old.root.is_none()))
                && old.files == next.files
                && old.launch == next.launch
                && old.runtime == next.runtime
                && matches!(
                    (old.phase, next.phase),
                    (
                        HelperPhase::Reserved,
                        HelperPhase::Owned | HelperPhase::Removing | HelperPhase::Removed
                    ) | (
                        HelperPhase::Owned,
                        HelperPhase::Removing | HelperPhase::Removed
                    ) | (HelperPhase::Removing, HelperPhase::Removed)
                        | (
                            HelperPhase::SdkPrepared,
                            HelperPhase::Removing | HelperPhase::Removed
                        )
                        | (HelperPhase::LaunchReturned, HelperPhase::LaunchCollecting)
                        | (HelperPhase::LaunchCollecting, HelperPhase::LaunchCollected)
                        | (
                            HelperPhase::RuntimePrepared,
                            HelperPhase::Removing | HelperPhase::Removed
                        )
                )
        }
        _ => false,
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Admission {
    maximum: u64,
    request_identity_sha256: String,
}
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum PublicationPhase {
    Prepared,
    Entered,
    Completed,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Publication {
    identity: crate::ExportPublicationIdentity,
    phase: PublicationPhase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    proof_sha256: Option<String>,
}
fn publication_forward(old: &Option<Publication>, new: &Option<Publication>) -> bool {
    match (old, new) {
        (None, _) => true,
        (Some(old), Some(new)) => {
            old.identity == new.identity
                && old.phase <= new.phase
                && (old.phase != PublicationPhase::Completed
                    || old.proof_sha256 == new.proof_sha256)
        }
        _ => false,
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportStagedFile {
    pub name: String,
    pub size_bytes: u64,
    pub sha256: String,
    version: Version,
}
impl std::fmt::Debug for ExportStagedFile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExportStagedFile")
            .field("size_bytes", &self.size_bytes)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportStageCleanup {
    pub schema: u8,
    pub source: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub stage_sha256: String,
}
impl std::fmt::Debug for ExportStageCleanup {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExportStageCleanup")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
struct Entry {
    record: Record,
    live: Weak<()>,
    allowance: Option<crate::jobs::ExportStagingLease>,
}
pub(crate) struct Staging {
    binding: DomainBinding,
    jobs: crate::jobs::JobPool,
    entries: Mutex<BTreeMap<String, Entry>>,
    ledger: Mutex<Option<(u64, u64)>>,
    domain: Arc<crate::domain::DomainGuard>,
}
pub(crate) struct Stage {
    key: String,
    root: File,
    live: Arc<()>,
    registry: Arc<Staging>,
    written: AtomicU64,
    reserved: AtomicU64,
}
fn before(code: ErrorCode) -> Error {
    Error::before(code)
}
fn hash(value: &impl Serialize) -> Result<String> {
    crate::material::hash(value)
}
fn key(source: &CreationReceipt, id: &str, request: &str) -> Result<String> {
    hash(&("smolbox-export-stage-v1", source, id, request))
}
impl Record {
    fn publication_receipt(&self, publication: &Publication) -> Result<crate::ExportPublication> {
        crate::ExportPublication::new(
            self.source.clone(),
            self.operation_id.clone(),
            self.request_sha256.clone(),
            publication.identity.clone(),
        )
    }
    fn valid(&self, binding: &DomainBinding) -> Result<()> {
        self.source.validate(binding)?;
        if !matches!(self.schema, 1..=11)
            || self.source.material.is_none()
            || !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || self.directory
                != format!(
                    ".export-{}",
                    key(&self.source, &self.operation_id, &self.request_sha256)?
                )
            || self.files.len() > 3
            || (self.schema == 1
                && (matches!(self.phase, Phase::Packing | Phase::Packed)
                    || self
                        .files
                        .iter()
                        .any(|file| file.name == "artifact.smolmachine")))
        {
            return Err(before(ErrorCode::Ownership));
        }
        if let Some(admission) = &self.admission {
            if !matches!(self.schema, 5..=11)
                || admission.maximum == 0
                || admission.maximum > crate::JOB_EXPORT_STAGING_BYTES
                || !crate::domain::valid_hex(&admission.request_identity_sha256, 64)
            {
                return Err(before(ErrorCode::Ownership));
            }
        } else if matches!(self.schema, 5..=11) {
            return Err(before(ErrorCode::Ownership));
        }
        if self.schema <= 4 && self.admission.is_some() {
            return Err(before(ErrorCode::Ownership));
        }
        if let Some(helper) = &self.helper {
            if !matches!(self.schema, 6..=11)
                || (!matches!(self.schema, 10 | 11) && !self.files.is_empty())
                || (self.schema != 11 && self.publication.is_some())
                || (self.schema != 11
                    && !matches!(
                        self.phase,
                        Phase::Preparing | Phase::Cleaning | Phase::Cleaned
                    ))
                || (self.phase == Phase::Cleaned && helper.phase != HelperPhase::Removed)
                || (self.schema == 8 && self.phase != Phase::Preparing)
            {
                return Err(before(ErrorCode::Ownership));
            }
            helper.validate(self)?;
        } else if matches!(self.schema, 6..=11) {
            return Err(before(ErrorCode::Ownership));
        }
        if matches!(self.schema, 10 | 11) {
            self.layer
                .as_ref()
                .ok_or(before(ErrorCode::Ownership))?
                .validate(self)?;
        } else if self.layer.is_some() {
            return Err(before(ErrorCode::Ownership));
        }
        if matches!(
            self.phase,
            Phase::Admitted | Phase::Entering | Phase::NoStage
        ) {
            let admitted = self.schema == 5 && self.admission.is_some();
            if (!admitted && (self.schema != 4 || self.phase != Phase::NoStage))
                || self.max_bytes != 0
                || self.device != 0
                || self.inode != 0
                || !self.files.is_empty()
                || self.publication.is_some()
            {
                return Err(before(ErrorCode::Ownership));
            }
            return Ok(());
        }
        if self.schema == 4
            || (matches!(self.schema, 5..=11)
                && self
                    .admission
                    .as_ref()
                    .is_none_or(|a| a.maximum != self.max_bytes))
        {
            return Err(before(ErrorCode::Ownership));
        }
        if self.max_bytes == 0
            || self.max_bytes > crate::jobs::JOB_EXPORT_STAGING_BYTES
            || self.device == 0
            || self.inode == 0
        {
            return Err(before(ErrorCode::Ownership));
        }
        if let Some(publication) = &self.publication {
            publication.identity.validate()?;
            if !matches!(self.schema, 3 | 5 | 11)
                || !matches!(self.phase, Phase::Packed | Phase::Cleaning | Phase::Cleaned)
                || !self.files.iter().any(|file| {
                    file.name == "artifact.smolmachine"
                        && file.sha256 == publication.identity.content_sha256
                        && file.size_bytes == publication.identity.size_bytes
                })
            {
                return Err(before(ErrorCode::Ownership));
            }
            let proof = self.publication_receipt(publication)?;
            if (publication.phase == PublicationPhase::Completed
                && publication.proof_sha256.as_deref() != Some(proof.proof_sha256.as_str()))
                || (publication.phase != PublicationPhase::Completed
                    && publication.proof_sha256.is_some())
            {
                return Err(before(ErrorCode::Ownership));
            }
        }
        let mut names = std::collections::BTreeSet::new();
        let mut bytes = 0u64;
        for file in &self.files {
            if !matches!(
                file.name.as_str(),
                "storage.raw" | "overlay.raw" | "artifact.smolmachine" | "layer.tar"
            ) || (file.name == "layer.tar" && !matches!(self.schema, 10 | 11))
                || !names.insert(&file.name)
                || file.size_bytes == 0
                || file.version.2 != file.size_bytes
                || file.version.0 != self.device
                || !crate::domain::valid_hex(&file.sha256, 64)
            {
                return Err(before(ErrorCode::Ownership));
            }
            bytes = bytes
                .checked_add(file.size_bytes)
                .ok_or(before(ErrorCode::Ownership))?;
        }
        let raw = names.contains(&"storage.raw".to_string())
            && names.contains(&"overlay.raw".to_string());
        if bytes > self.max_bytes
            || (!matches!(self.schema, 10 | 11)
                && ((matches!(self.phase, Phase::Ready | Phase::Packing)
                    && (!raw || self.files.len() != 2))
                    || (self.phase == Phase::Packed && (!raw || self.files.len() != 3))
                    || (self.phase == Phase::Preparing && !self.files.is_empty())))
        {
            return Err(before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Staging {
    fn ledger_path(&self) -> PathBuf {
        self.domain.directory.join("export-stages-v1")
    }
    fn path(&self, key: &str) -> PathBuf {
        self.ledger_path().join(format!("{key}.json"))
    }
    fn root_path(&self, record: &Record) -> PathBuf {
        self.domain.directory.join(&record.directory)
    }
    fn verify(&self) -> Result<()> {
        self.domain.verify()?;
        let identity = *self.ledger.lock().map_err(|_| before(ErrorCode::Native))?;
        if let Some(identity) = identity {
            crate::host::private_directory(&self.ledger_path())?;
            let metadata =
                std::fs::symlink_metadata(self.ledger_path()).map_err(|_| before(ErrorCode::Io))?;
            if (metadata.dev(), metadata.ino()) != identity {
                return Err(before(ErrorCode::Ownership));
            }
        } else if !matches!(std::fs::symlink_metadata(self.ledger_path()),Err(error) if error.kind()==std::io::ErrorKind::NotFound)
        {
            return Err(before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn ensure_ledger(&self) -> Result<()> {
        self.domain.verify()?;
        let mut identity = self.ledger.lock().map_err(|_| before(ErrorCode::Native))?;
        if identity.is_none() {
            std::fs::create_dir(self.ledger_path()).map_err(|_| before(ErrorCode::Ownership))?;
            std::fs::set_permissions(self.ledger_path(), std::fs::Permissions::from_mode(0o700))
                .map_err(|_| before(ErrorCode::Io))?;
            crate::host::private_directory(&self.ledger_path())?;
            let metadata =
                std::fs::symlink_metadata(self.ledger_path()).map_err(|_| before(ErrorCode::Io))?;
            *identity = Some((metadata.dev(), metadata.ino()));
            File::open(&self.domain.directory)
                .and_then(|file| file.sync_all())
                .map_err(|_| before(ErrorCode::Io))?;
        }
        drop(identity);
        self.verify()
    }
    pub(crate) fn open(
        binding: &DomainBinding,
        domain: Arc<crate::domain::DomainGuard>,
        jobs: crate::jobs::JobPool,
    ) -> Result<Arc<Self>> {
        domain.verify()?;
        let path = domain.directory.join("export-stages-v1");
        let identity = match std::fs::symlink_metadata(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return Err(before(ErrorCode::Io)),
            Ok(metadata) => {
                crate::host::private_directory(&path)?;
                Some((metadata.dev(), metadata.ino()))
            }
        };
        let registry = Arc::new(Self {
            binding: binding.clone(),
            jobs,
            entries: Mutex::new(BTreeMap::new()),
            ledger: Mutex::new(identity),
            domain,
        });
        let mut entries = registry
            .entries
            .lock()
            .map_err(|_| before(ErrorCode::Native))?;
        for item in if identity.is_some() {
            Some(std::fs::read_dir(&path).map_err(|_| before(ErrorCode::Io))?)
        } else {
            None
        }
        .into_iter()
        .flatten()
        {
            if entries.len() >= RECORDS {
                return Err(before(ErrorCode::Admission));
            }
            let item = item.map_err(|_| before(ErrorCode::Io))?;
            let name = item
                .file_name()
                .into_string()
                .map_err(|_| before(ErrorCode::Ownership))?;
            let id = name
                .strip_suffix(".json")
                .filter(|s| crate::domain::valid_hex(s, 64))
                .ok_or(before(ErrorCode::Ownership))?
                .to_owned();
            let (record, _) = read(&item.path())?;
            record.valid(binding)?;
            if key(&record.source, &record.operation_id, &record.request_sha256)? != id {
                return Err(before(ErrorCode::Ownership));
            }
            let terminal = matches!(record.phase, Phase::Cleaned | Phase::NoStage);
            let root_absent = absent_path(&registry.root_path(&record));
            let dormant = record.phase == Phase::Admitted && root_absent;
            let allowance = if terminal || dormant {
                None
            } else {
                let maximum = record
                    .admission
                    .as_ref()
                    .map_or(record.max_bytes, |a| a.maximum);
                Some(registry.jobs.export_staging(maximum, true)?)
            };
            if !terminal && !dormant {
                registry.jobs.quarantine();
            }
            if terminal && !root_absent {
                registry.jobs.quarantine();
            }
            entries.insert(
                id,
                Entry {
                    record,
                    live: Weak::new(),
                    allowance,
                },
            );
        }
        for item in
            std::fs::read_dir(&registry.domain.directory).map_err(|_| before(ErrorCode::Io))?
        {
            let item = item.map_err(|_| before(ErrorCode::Io))?;
            if let Some(name) = item
                .file_name()
                .to_str()
                .filter(|name| name.starts_with(".export-"))
            {
                if !entries.values().any(|entry| entry.record.directory == name) {
                    return Err(before(ErrorCode::Ownership));
                }
            }
        }
        drop(entries);
        registry.verify()?;
        Ok(registry)
    }
    fn publish(&self, id: &str, record: &Record, expected: Option<Version>) -> Result<()> {
        self.verify()?;
        record.valid(&self.binding)?;
        let bytes = serde_json::to_vec(record).map_err(|_| before(ErrorCode::Validation))?;
        if bytes.len() as u64 > RECORD_BYTES {
            return Err(before(ErrorCode::OutputLimit));
        }
        let mut temp = tempfile::NamedTempFile::new_in(self.ledger_path())
            .map_err(|_| before(ErrorCode::Io))?;
        temp.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|_| before(ErrorCode::Io))?;
        temp.write_all(&bytes)
            .and_then(|_| temp.as_file().sync_all())
            .map_err(|_| before(ErrorCode::Io))?;
        self.verify()?;
        if let Some(expected) = expected {
            if read(&self.path(id))?.1 != expected {
                return Err(before(ErrorCode::Ownership));
            }
            temp.persist(self.path(id))
                .map_err(|_| before(ErrorCode::Io))?;
        } else {
            temp.persist_noclobber(self.path(id))
                .map_err(|_| before(ErrorCode::Conflict))?;
        }
        File::open(self.ledger_path())
            .and_then(|f| f.sync_all())
            .map_err(|_| before(ErrorCode::Io))?;
        self.verify()
    }
    pub(crate) fn create(
        self: &Arc<Self>,
        source: &CreationReceipt,
        id: &str,
        request: &str,
        max_bytes: u64,
        budget: &ReadBudget,
    ) -> Result<Stage> {
        budget.check()?;
        source.validate(&self.binding)?;
        if source.material.is_none()
            || !crate::domain::valid_id(id)
            || !crate::domain::valid_hex(request, 64)
            || max_bytes == 0
            || max_bytes > crate::jobs::JOB_EXPORT_STAGING_BYTES
        {
            return Err(before(ErrorCode::Validation));
        }
        let mut entries = self.entries.lock().map_err(|_| before(ErrorCode::Native))?;
        self.verify()?;
        self.ensure_ledger()?;
        let key = key(source, id, request)?;
        let mut origin = source.clone();
        origin.material = None;
        let admitted = if let Some(entry) = entries.get(&key) {
            let (stored, version) = read(&self.path(&key))?;
            stored.valid(&self.binding)?;
            if stored != entry.record
                || stored.phase != Phase::Admitted
                || entry.allowance.is_some()
                || stored
                    .admission
                    .as_ref()
                    .is_none_or(|a| a.maximum != max_bytes)
                || !absent_path(&self.root_path(&stored))
            {
                return Err(before(ErrorCode::Conflict));
            }
            Some((stored, version))
        } else {
            None
        };
        if (admitted.is_none() && entries.len() >= RECORDS)
            || entries.values().any(|entry| {
                let mut previous = entry.record.source.clone();
                previous.material = None;
                previous == origin
                    && entry.record.operation_id == id
                    && admitted
                        .as_ref()
                        .is_none_or(|(stored, _)| stored != &entry.record)
            })
        {
            return Err(before(ErrorCode::Conflict));
        }
        let mut allowance = Some(self.jobs.export_staging(max_bytes, false)?);
        let admission = admitted.as_ref().and_then(|(r, _)| r.admission.clone());
        let expected = if let Some((mut entering, version)) = admitted {
            entering.phase = Phase::Entering;
            if let Err(error) = self.publish(&key, &entering, Some(version)) {
                // Publication may have reached the protected ledger before a
                // sync error. Keep its ceiling charged until explicit cleanup
                // proves retirement, even when the in-memory phase lags.
                self.jobs.quarantine();
                let entry = entries.get_mut(&key).ok_or(before(ErrorCode::Ownership))?;
                entry.allowance = allowance.take();
                return Err(Error::uncertain(error.code));
            }
            let entry = entries.get_mut(&key).ok_or(before(ErrorCode::Ownership))?;
            entry.record = entering;
            entry.allowance = allowance.take();
            Some(read(&self.path(&key))?.1)
        } else {
            None
        };
        let directory = format!(".export-{key}");
        let path = self.domain.directory.join(&directory);
        std::fs::create_dir(&path).map_err(|_| before(ErrorCode::Conflict))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| before(ErrorCode::Io))?;
        let root = open_root(&path)?;
        let metadata = root.metadata().map_err(|_| before(ErrorCode::Io))?;
        let record = Record {
            schema: if admission.is_some() { 5 } else { 3 },
            source: source.clone(),
            operation_id: id.into(),
            request_sha256: request.into(),
            max_bytes,
            directory,
            device: metadata.dev(),
            inode: metadata.ino(),
            phase: Phase::Preparing,
            files: vec![],
            publication: None,
            admission,
            helper: None,
            layer: None,
        };
        let published = File::open(&self.domain.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| before(ErrorCode::Io))
            .and_then(|_| self.publish(&key, &record, expected));
        if let Err(error) = published {
            self.jobs.quarantine();
            if let Some(allowance) = allowance.take() {
                std::mem::forget(allowance);
            }
            return Err(error);
        }
        let live = Arc::new(());
        let allowance = if expected.is_some() {
            entries.get_mut(&key).and_then(|e| e.allowance.take())
        } else {
            allowance.take()
        };
        entries.insert(
            key.clone(),
            Entry {
                record,
                live: Arc::downgrade(&live),
                allowance,
            },
        );
        Ok(Stage {
            key,
            root,
            live,
            registry: self.clone(),
            written: AtomicU64::new(0),
            reserved: AtomicU64::new(0),
        })
    }
    pub(crate) fn inspect_publication(
        &self,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        budget: &ReadBudget,
    ) -> Result<Option<crate::ExportPublication>> {
        budget.check()?;
        source.validate(&self.binding)?;
        if !crate::domain::valid_id(operation) || !crate::domain::valid_hex(request, 64) {
            return Err(before(ErrorCode::Validation));
        }
        let _job = self
            .jobs
            .acquire(crate::jobs::Demand::export_observation())?;
        self.verify()?;
        let entries = self.entries.lock().map_err(|_| before(ErrorCode::Native))?;
        let id = key(source, operation, request)?;
        let Some(entry) = entries.get(&id) else {
            return Ok(None);
        };
        let (record, _) = read(&self.path(&id))?;
        record.valid(&self.binding)?;
        if record != entry.record {
            return Err(before(ErrorCode::Ownership));
        }
        budget.check()?;
        match &record.publication {
            Some(publication) if publication.phase == PublicationPhase::Completed => {
                Ok(Some(record.publication_receipt(publication)?))
            }
            _ => Ok(None),
        }
    }
    pub(crate) fn cleanup(
        &self,
        source: &CreationReceipt,
        id: &str,
        request: &str,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<ExportStageCleanup> {
        if !quiesced || !crate::domain::valid_id(id) || !crate::domain::valid_hex(request, 64) {
            return Err(before(ErrorCode::Validation));
        }
        self.remove(&key(source, id, request)?, None, budget)
    }

    fn registered(&self, source: &CreationReceipt, id: &str, request: &str) -> Result<bool> {
        self.verify()?;
        let entries = self.entries.lock().map_err(|_| before(ErrorCode::Native))?;
        Ok(entries.contains_key(&key(source, id, request)?))
    }

    fn admit(
        &self,
        source: &CreationReceipt,
        id: &str,
        request: &str,
        maximum: u64,
        identity: &str,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.verify()?;
        let record = Record {
            schema: 5,
            source: source.clone(),
            operation_id: id.into(),
            request_sha256: request.into(),
            max_bytes: 0,
            directory: format!(".export-{}", key(source, id, request)?),
            device: 0,
            inode: 0,
            phase: Phase::Admitted,
            files: vec![],
            publication: None,
            admission: Some(Admission {
                maximum,
                request_identity_sha256: identity.into(),
            }),
            helper: None,
            layer: None,
        };
        record.valid(&self.binding)?;
        let key = key(source, id, request)?;
        let mut entries = self.entries.lock().map_err(|_| before(ErrorCode::Native))?;
        if let Some(entry) = entries.get(&key) {
            let (stored, _) = read(&self.path(&key))?;
            if stored != entry.record
                || stored != record
                || entry.allowance.is_some()
                || !absent_path(&self.root_path(&stored))
            {
                return Err(before(ErrorCode::Conflict));
            }
            return Ok(());
        }
        let mut origin = source.clone();
        origin.material = None;
        if entries.len() >= RECORDS
            || entries.values().any(|entry| {
                let mut previous = entry.record.source.clone();
                previous.material = None;
                previous == origin && entry.record.operation_id == id
            })
        {
            return Err(before(ErrorCode::Conflict));
        }
        if !absent_path(&self.root_path(&record)) {
            return Err(before(ErrorCode::Ownership));
        }
        if !absent_path(&self.path(&key)) {
            let (stored, _) = read(&self.path(&key))?;
            if stored != record {
                return Err(before(ErrorCode::Ownership));
            }
        } else {
            self.ensure_ledger()?;
            budget.check()?;
            self.publish(&key, &record, None)
                .map_err(|e| Error::uncertain(e.code))?;
        }
        entries.insert(
            key,
            Entry {
                record,
                live: Weak::new(),
                allowance: None,
            },
        );
        Ok(())
    }

    fn check_admission(
        &self,
        source: &CreationReceipt,
        id: &str,
        request: &str,
        maximum: u64,
        identity: &str,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.verify()?;
        let entries = self.entries.lock().map_err(|_| before(ErrorCode::Native))?;
        let key = key(source, id, request)?;
        let entry = entries.get(&key).ok_or(before(ErrorCode::Ownership))?;
        let (stored, _) = read(&self.path(&key))?;
        stored.valid(&self.binding)?;
        if stored != entry.record
            || stored.phase != Phase::Admitted
            || entry.allowance.is_some()
            || stored
                .admission
                .as_ref()
                .is_none_or(|a| a.maximum != maximum || a.request_identity_sha256 != identity)
            || !absent_path(&self.root_path(&stored))
        {
            return Err(before(ErrorCode::Conflict));
        }
        budget.check()
    }

    // Called only after authenticated source qualification under its gate and
    // reserved control admission. Zero bytes grant no artifact or source absence.
    fn retire_unstaged(
        &self,
        source: &CreationReceipt,
        id: &str,
        request: &str,
        budget: &ReadBudget,
    ) -> Result<ExportStageCleanup> {
        budget.check()?;
        self.verify()?;
        let mut entries = self.entries.lock().map_err(|_| before(ErrorCode::Native))?;
        let key = key(source, id, request)?;
        let mut origin = source.clone();
        origin.material = None;
        if entries.len() >= RECORDS
            || entries.values().any(|entry| {
                let mut previous = entry.record.source.clone();
                previous.material = None;
                previous == origin && entry.record.operation_id == id
            })
        {
            return Err(before(ErrorCode::Conflict));
        }
        let record = Record {
            schema: 4,
            source: source.clone(),
            operation_id: id.into(),
            request_sha256: request.into(),
            max_bytes: 0,
            directory: format!(".export-{key}"),
            device: 0,
            inode: 0,
            phase: Phase::NoStage,
            files: vec![],
            publication: None,
            admission: None,
            helper: None,
            layer: None,
        };
        let absent = |path: &Path| matches!(std::fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound);
        if !absent(&self.root_path(&record)) {
            return Err(before(ErrorCode::Ownership));
        }
        if !absent(&self.path(&key)) {
            let (stored, _) = read(&self.path(&key))?;
            stored.valid(&self.binding)?;
            if stored != record {
                return Err(before(ErrorCode::Ownership));
            }
            let proof = cleanup_proof(&stored)?;
            entries.insert(
                key,
                Entry {
                    record: stored,
                    live: Weak::new(),
                    allowance: None,
                },
            );
            return Ok(proof);
        }
        // An unindexed export root is uncertain ownership, never an empty stage.
        // Whole-directory traversal is finite even when unrelated private files
        // exist; no request path or unbounded discovery is admitted.
        for (count, item) in std::fs::read_dir(&self.domain.directory)
            .map_err(|_| before(ErrorCode::Io))?
            .enumerate()
        {
            budget.check()?;
            if count >= 4096 {
                return Err(before(ErrorCode::OutputLimit));
            }
            let item = item.map_err(|_| before(ErrorCode::Io))?;
            if item.file_name().to_string_lossy().starts_with(".export-")
                && !entries
                    .values()
                    .any(|entry| item.file_name() == std::ffi::OsStr::new(&entry.record.directory))
            {
                return Err(before(ErrorCode::Ownership));
            }
        }
        self.ensure_ledger()?;
        budget.check()?;
        self.publish(&key, &record, None)
            .map_err(|error| Error::uncertain(error.code))?;
        let proof = cleanup_proof(&record)?;
        entries.insert(
            key,
            Entry {
                record,
                live: Weak::new(),
                allowance: None,
            },
        );
        Ok(proof)
    }
    fn remove(
        &self,
        id: &str,
        live: Option<&Arc<()>>,
        budget: &ReadBudget,
    ) -> Result<ExportStageCleanup> {
        budget.check()?;
        let _control = self.jobs.acquire(crate::jobs::Demand::export_cleanup())?;
        self.verify()?;
        let mut entries = self.entries.lock().map_err(|_| before(ErrorCode::Native))?;
        let entry = entries.get_mut(id).ok_or(before(ErrorCode::Ownership))?;
        if let Some(active) = entry.live.upgrade() {
            if live.is_none_or(|owner| !Arc::ptr_eq(owner, &active)) {
                return Err(before(ErrorCode::Conflict));
            }
        }
        let (stored, version) = read(&self.path(id))?;
        stored.valid(&self.binding)?;
        if stored != entry.record {
            let mut original = stored.clone();
            original.phase = entry.record.phase;
            original.files = entry.record.files.clone();
            original.publication = entry.record.publication.clone();
            let container_ready = entry.record.schema == 10
                && stored.schema == 11
                && entry.record.phase == Phase::Preparing
                && stored.phase == Phase::Ready
                && entry.record.helper == stored.helper
                && entry.record.layer == stored.layer;
            if container_ready {
                original.schema = entry.record.schema;
            }
            let layer_advanced = layer::forward(&entry.record.layer, &stored.layer);
            if layer_advanced {
                original.layer = entry.record.layer.clone();
                original.schema = entry.record.schema;
            }
            let helper_advanced = helper_forward(&entry.record.helper, &stored.helper);
            if helper_advanced {
                original.helper = entry.record.helper.clone();
                original.schema = entry.record.schema;
            }
            let forward = matches!(
                (entry.record.phase, stored.phase),
                (Phase::Admitted, Phase::Entering | Phase::NoStage)
                    | (Phase::Entering, Phase::NoStage)
                    | (
                        Phase::Preparing,
                        Phase::Ready
                            | Phase::Packing
                            | Phase::Packed
                            | Phase::Cleaning
                            | Phase::Cleaned
                    )
                    | (
                        Phase::Ready,
                        Phase::Packing | Phase::Packed | Phase::Cleaning | Phase::Cleaned
                    )
                    | (
                        Phase::Packing,
                        Phase::Packed | Phase::Cleaning | Phase::Cleaned
                    )
                    | (Phase::Packed, Phase::Cleaning | Phase::Cleaned)
                    | (Phase::Cleaning, Phase::Cleaned)
            );
            let publication_advanced =
                publication_forward(&entry.record.publication, &stored.publication);
            let forward = forward
                || helper_advanced
                || layer_advanced
                || container_ready
                || (entry.record.phase == stored.phase
                    && entry.record.publication != stored.publication
                    && publication_advanced);
            if original != entry.record || !forward || !publication_advanced {
                return Err(before(ErrorCode::Ownership));
            }
            entry.record = stored.clone();
        }
        if matches!(stored.schema, 10 | 11) {
            layer::verify_cleanup(self, &stored, budget)?;
        }
        let (stored, version) = if stored.helper.is_some() {
            self.retire_helper(id, entry, budget)?;
            read(&self.path(id))?
        } else {
            (stored, version)
        };
        let proof = cleanup_proof(&stored)?;
        if matches!(stored.phase, Phase::Admitted | Phase::Entering) {
            if !absent_path(&self.root_path(&stored)) {
                return Err(before(ErrorCode::Ownership));
            }
            let mut retired = stored;
            retired.phase = Phase::NoStage;
            self.publish(id, &retired, Some(version))
                .map_err(|e| Error::uncertain(e.code))?;
            let proof = cleanup_proof(&retired)?;
            entry.record = retired;
            entry.allowance.take();
            return Ok(proof);
        }
        if matches!(stored.phase, Phase::Cleaned | Phase::NoStage) {
            if !matches!(std::fs::symlink_metadata(self.root_path(&stored)),Err(error) if error.kind()==std::io::ErrorKind::NotFound)
            {
                return Err(before(ErrorCode::Ownership));
            }
            entry.allowance.take();
            return Ok(proof);
        }
        let mut cleaning = stored.clone();
        cleaning.phase = Phase::Cleaning;
        let version = if stored.phase != Phase::Cleaning {
            verify_root(&open_root(&self.root_path(&stored))?, &stored)?;
            self.publish(id, &cleaning, Some(version))?;
            entry.record = cleaning.clone();
            read(&self.path(id))?.1
        } else {
            version
        };
        let completed = (|| -> Result<ExportStageCleanup> {
            match open_root(&self.root_path(&cleaning)) {
                Ok(root) => {
                    verify_root(&root, &cleaning)?;
                    crate::volumes::remove_owned_tree(&root, budget, crate::VOLUME_DELETE_ENTRIES)?;
                    root.sync_all().map_err(|_| before(ErrorCode::Io))?;
                    verify_root(&open_root(&self.root_path(&cleaning))?, &cleaning)?;
                    let parent = open_root(&self.domain.directory)?;
                    let name = std::ffi::CString::new(cleaning.directory.as_str())
                        .map_err(|_| before(ErrorCode::Ownership))?;
                    self.domain.verify()?;
                    if unsafe {
                        libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR)
                    } != 0
                    {
                        return Err(before(ErrorCode::Io));
                    }
                    if !matches!(std::fs::symlink_metadata(self.root_path(&cleaning)),Err(error) if error.kind()==std::io::ErrorKind::NotFound)
                    {
                        return Err(before(ErrorCode::Ownership));
                    }
                }
                Err(_)
                    if stored.phase == Phase::Cleaning
                        && matches!(std::fs::symlink_metadata(self.root_path(&stored)),Err(e) if e.kind()==std::io::ErrorKind::NotFound) =>
                    {}
                Err(error) => return Err(error),
            }
            File::open(&self.domain.directory)
                .and_then(|f| f.sync_all())
                .map_err(|_| before(ErrorCode::Io))?;
            budget.check()?;
            let mut cleaned = cleaning;
            cleaned.phase = Phase::Cleaned;
            self.publish(id, &cleaned, Some(version))?;
            entry.record = cleaned;
            entry.allowance.take();
            Ok(proof)
        })();
        completed.map_err(|error| Error::uncertain(error.code))
    }
    fn retire_helper(&self, id: &str, entry: &mut Entry, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        let mut record = entry.record.clone();
        let helper = record.helper.clone().ok_or(before(ErrorCode::Ownership))?;
        if let Some(runtime) = &helper.runtime {
            if helper.phase == HelperPhase::Removed {
                runtime.verify_removed_marker()?;
            }
        }
        let path = helper.path(&self.binding);
        if matches!(
            helper.phase,
            HelperPhase::SdkPreparing
                | HelperPhase::LaunchEntering
                | HelperPhase::LaunchReturned
                | HelperPhase::LaunchCollecting
                | HelperPhase::LaunchCollected
        ) {
            return Err(before(ErrorCode::Conflict));
        }
        if helper.phase == HelperPhase::Removed {
            return if absent_path(&path) {
                Ok(())
            } else {
                Err(before(ErrorCode::Ownership))
            };
        }
        if helper.phase == HelperPhase::Reserved {
            if !absent_path(&path) {
                return Err(before(ErrorCode::Ownership));
            }
        } else {
            let parent = crate::export_source::Root::open(&self.binding.vm_root)?;
            match open_root(&path) {
                Ok(root) => {
                    if !helper.same_anchor(&root)?
                        || (helper.phase != HelperPhase::Removing
                            && HelperRoot::of(&root)?
                                != *helper.root.as_ref().ok_or(before(ErrorCode::Ownership))?)
                        || HelperRoot::of(&open_root(&path)?)? != HelperRoot::of(&root)?
                    {
                        return Err(before(ErrorCode::Ownership));
                    }
                    if let Some(runtime) = &helper.runtime {
                        runtime.verify(
                            &root,
                            &path,
                            helper.phase == HelperPhase::Removing,
                            budget,
                        )?;
                    } else {
                        helper.verify_files(&path, helper.phase == HelperPhase::Removing)?;
                    }
                    if helper.phase != HelperPhase::Removing {
                        record.helper.as_mut().unwrap().phase = HelperPhase::Removing;
                        let (_, version) = read(&self.path(id))?;
                        self.publish(id, &record, Some(version))
                            .map_err(|e| Error::uncertain(e.code))?;
                        entry.record = record.clone();
                    }
                    budget.check()?;
                    parent.verify()?;
                    if let Some(runtime) = &helper.runtime {
                        runtime.remove_files(&root, &path, budget)?;
                    } else {
                        for file in &helper.files {
                            budget.check()?;
                            let file_path = path.join(&file.name);
                            if absent_path(&file_path) && helper.phase == HelperPhase::Removing {
                                continue;
                            }
                            if Version::of(&plain(&file_path)?)? != file.version {
                                return Err(before(ErrorCode::Ownership));
                            }
                            let name = std::ffi::CString::new(file.name.as_str())
                                .map_err(|_| before(ErrorCode::Ownership))?;
                            if unsafe { libc::unlinkat(root.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                                return Err(Error::uncertain(ErrorCode::Io));
                            }
                        }
                    }
                    root.sync_all()
                        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    if HelperRoot::of(&open_root(&path)?)? != HelperRoot::of(&root)? {
                        return Err(before(ErrorCode::Ownership));
                    }
                    let directory = OpenOptions::new()
                        .read(true)
                        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
                        .open(&self.binding.vm_root)
                        .map_err(|_| before(ErrorCode::Io))?;
                    let name = std::ffi::CString::new(smolvm::agent::vm_dir_hash(&helper.name))
                        .map_err(|_| before(ErrorCode::Ownership))?;
                    if unsafe {
                        libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR)
                    } != 0
                    {
                        return Err(Error::uncertain(ErrorCode::Io));
                    }
                    directory
                        .sync_all()
                        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    if !absent_path(&path) {
                        return Err(Error::uncertain(ErrorCode::Ownership));
                    }
                }
                Err(_) if helper.phase == HelperPhase::Removing && absent_path(&path) => {
                    if let Some(runtime) = &helper.runtime {
                        runtime.verify_removed_marker()?;
                    }
                }
                Err(error) => return Err(error),
            }
        }
        record.helper.as_mut().unwrap().phase = HelperPhase::Removed;
        let (_, version) = read(&self.path(id))?;
        self.publish(id, &record, Some(version))
            .map_err(|e| Error::uncertain(e.code))?;
        entry.record = record;
        Ok(())
    }
}
impl Stage {
    /// Journal observation only; does not attest filesystem/VM absence. The
    /// original in-memory manager must separately retain opaque collection.
    fn cleanup_record(&self) -> Result<Record> {
        self.registry.verify()?;
        let entries = self
            .registry
            .entries
            .lock()
            .map_err(|_| before(ErrorCode::Native))?;
        let entry = entries.get(&self.key).ok_or(before(ErrorCode::Ownership))?;
        let (record, _) = read(&self.registry.path(&self.key))?;
        record.valid(&self.registry.binding)?;
        if entry.record != record || !entry.live.ptr_eq(&Arc::downgrade(&self.live)) {
            return Err(before(ErrorCode::Ownership));
        }
        Ok(record)
    }
    pub(crate) fn runtime_custody_recorded(&self) -> Result<bool> {
        Ok(self.cleanup_record()?.helper.as_ref().is_some_and(|h| {
            h.runtime.is_some()
                && matches!(
                    h.phase,
                    HelperPhase::RuntimePrepared | HelperPhase::Removing | HelperPhase::Removed
                )
        }))
    }
    pub(crate) fn unlaunched_helper_recorded(&self) -> Result<bool> {
        let record = self.cleanup_record()?;
        Ok(record.schema == 7
            && record.helper.as_ref().is_some_and(|h| {
                h.phase == HelperPhase::SdkPrepared && h.launch.is_none() && h.runtime.is_none()
            }))
    }
    pub(crate) fn runtime_prepared(&self) -> Result<bool> {
        let record = self.record()?;
        Ok(matches!(record.schema, 9 | 10)
            && record
                .helper
                .as_ref()
                .is_some_and(|h| h.phase == HelperPhase::RuntimePrepared))
    }
    pub(crate) fn verify_helper_runtime(
        &self,
        root: &File,
        epoch: &crate::epoch::ActorEpoch,
        collected: &crate::epoch::BootCollection,
        rootfs: &crate::export_source::Root,
        budget: &ReadBudget,
    ) -> Result<()> {
        if !self.runtime_prepared()? {
            return Err(before(ErrorCode::Ownership));
        }
        self.verify()?;
        let record = self.record()?;
        let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
        if !epoch.bound_to(&self.registry.binding)
            || !collected.intent().matches_epoch(&helper.name, epoch)
            || helper.launch.as_ref().is_none_or(|l| {
                &l.intent != collected.intent() || l.child != Some(collected.child())
            })
            || !helper.same_anchor(root)?
        {
            return Err(before(ErrorCode::Ownership));
        }
        let runtime = helper
            .runtime
            .as_ref()
            .ok_or(before(ErrorCode::Ownership))?;
        runtime.bound_rootfs(rootfs)?;
        runtime.verify(root, &helper.path(&self.registry.binding), false, budget)
    }
    pub(crate) fn prepare_helper_runtime(
        &mut self,
        root: &File,
        epoch: &crate::epoch::ActorEpoch,
        collected: &crate::epoch::BootCollection,
        rootfs: &crate::export_source::Root,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        let (name, path, child) = self.enrolled_helper_identity(root, epoch)?;
        let mut record = self.record()?;
        let helper = record.helper.as_mut().ok_or(before(ErrorCode::Ownership))?;
        if helper.phase != HelperPhase::LaunchCollected
            || child != collected.child()
            || helper
                .launch
                .as_ref()
                .is_none_or(|l| &l.intent != collected.intent())
        {
            return Err(before(ErrorCode::Ownership));
        }
        let runtime = crate::export_runtime::Snapshot::capture(
            root,
            &path,
            rootfs,
            &name,
            &helper.budget,
            budget,
        )?;
        helper.root = Some(HelperRoot::of(root)?);
        helper.runtime = Some(runtime);
        helper.phase = HelperPhase::RuntimePrepared;
        if record.schema != 10 {
            record.schema = 9;
        }
        budget.check()?;
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))
    }
    /// Persist an entered launch before SDK entry. Only the original domain's
    /// opaque pending dispatch can provide the boot intent. No child is minted.
    pub(crate) fn begin_helper_launch(
        &mut self,
        root: &File,
        dispatch: &crate::epoch::BootDispatch,
        epoch: &crate::epoch::ActorEpoch,
    ) -> Result<()> {
        self.verify()?;
        self.prepared_helper_budget(root)?;
        let mut record = self.record()?;
        let helper = record.helper.as_mut().ok_or(before(ErrorCode::Ownership))?;
        if !epoch.bound_to(&self.registry.binding) || !dispatch.matches_epoch(&helper.name, epoch) {
            return Err(before(ErrorCode::Ownership));
        }
        record.schema = 8;
        helper.phase = HelperPhase::LaunchEntering;
        helper.launch = Some(HelperLaunch {
            intent: dispatch.intent(),
            child: None,
        });
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))
    }
    /// SDK entry returned and the exact pre-exec actor was enrolled. This is
    /// dispatch evidence only, never successful launch or child collection.
    pub(crate) fn helper_launch_returned(
        &mut self,
        root: &File,
        enrolled: &crate::epoch::BootEnrollment,
    ) -> Result<()> {
        self.verify()?;
        let mut record = self.record()?;
        let helper = record.helper.as_mut().ok_or(before(ErrorCode::Ownership))?;
        let launch = helper.launch.as_mut().ok_or(before(ErrorCode::Ownership))?;
        if !matches!(record.schema, 8 | 10)
            || helper.phase != HelperPhase::LaunchEntering
            || &launch.intent != enrolled.intent()
            || launch.child.is_some()
            || !helper.same_anchor(root)?
            || !helper.same_anchor(&open_root(&helper.path(&self.registry.binding))?)?
        {
            return Err(before(ErrorCode::Ownership));
        }
        helper.launch.as_mut().unwrap().child = Some(enrolled.child());
        helper.phase = HelperPhase::LaunchReturned;
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn returned_helper_identity(
        &self,
        root: &File,
        epoch: &crate::epoch::ActorEpoch,
    ) -> Result<(String, PathBuf, crate::OwnerIdentity)> {
        if self
            .record()?
            .helper
            .as_ref()
            .is_none_or(|h| h.phase != HelperPhase::LaunchReturned)
        {
            return Err(before(ErrorCode::Ownership));
        }
        self.enrolled_helper_identity(root, epoch)
    }
    pub(crate) fn enrolled_helper_identity(
        &self,
        root: &File,
        epoch: &crate::epoch::ActorEpoch,
    ) -> Result<(String, PathBuf, crate::OwnerIdentity)> {
        self.verify()?;
        let record = self.record()?;
        let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
        let launch = helper.launch.as_ref().ok_or(before(ErrorCode::Ownership))?;
        let path = helper.path(&self.registry.binding);
        if !matches!(record.schema, 8 | 10)
            || !matches!(
                helper.phase,
                HelperPhase::LaunchReturned
                    | HelperPhase::LaunchCollecting
                    | HelperPhase::LaunchCollected
            )
            || !epoch.bound_to(&self.registry.binding)
            || !launch.intent.matches_epoch(&helper.name, epoch)
            || !helper.same_anchor(root)?
            || !helper.same_anchor(&open_root(&path)?)?
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok((
            helper.name.clone(),
            path,
            launch.child.ok_or(Error::uncertain(ErrorCode::Ownership))?,
        ))
    }
    pub(crate) fn begin_helper_collection(
        &mut self,
        root: &File,
        epoch: &crate::epoch::ActorEpoch,
        enrolled: &crate::epoch::BootEnrollment,
    ) -> Result<()> {
        let (_, _, child) = self.returned_helper_identity(root, epoch)?;
        let mut record = self.record()?;
        let helper = record.helper.as_mut().ok_or(before(ErrorCode::Ownership))?;
        if child != enrolled.child()
            || helper
                .launch
                .as_ref()
                .is_none_or(|l| &l.intent != enrolled.intent())
        {
            return Err(before(ErrorCode::Ownership));
        }
        helper.phase = HelperPhase::LaunchCollecting;
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn helper_collection_entered(&self) -> Result<bool> {
        let record = self.record()?;
        Ok(matches!(record.schema, 8 | 10)
            && record.helper.as_ref().is_some_and(|h| {
                matches!(
                    h.phase,
                    HelperPhase::LaunchCollecting | HelperPhase::LaunchCollected
                )
            }))
    }
    pub(crate) fn helper_launch_pending(&self) -> Result<bool> {
        let record = self.record()?;
        Ok(matches!(record.schema, 8 | 10)
            && record
                .helper
                .as_ref()
                .is_some_and(|h| h.phase == HelperPhase::LaunchEntering))
    }
    pub(crate) fn helper_child_collected(
        &mut self,
        root: &File,
        epoch: &crate::epoch::ActorEpoch,
        collected: &crate::epoch::BootCollection,
    ) -> Result<()> {
        let (_, _, child) = self.enrolled_helper_identity(root, epoch)?;
        let mut record = self.record()?;
        let helper = record.helper.as_mut().ok_or(before(ErrorCode::Ownership))?;
        if !matches!(
            helper.phase,
            HelperPhase::LaunchCollecting | HelperPhase::LaunchCollected
        ) || child != collected.child()
            || helper
                .launch
                .as_ref()
                .is_none_or(|l| &l.intent != collected.intent())
        {
            return Err(before(ErrorCode::Ownership));
        }
        if helper.phase == HelperPhase::LaunchCollected {
            return Ok(());
        }
        helper.phase = HelperPhase::LaunchCollected;
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn retained_identity(&self) -> Result<(CreationReceipt, String, String)> {
        let record = self.record()?;
        if record.schema != 7
            || record
                .helper
                .as_ref()
                .is_none_or(|h| h.phase != HelperPhase::SdkPrepared)
        {
            return Err(before(ErrorCode::Ownership));
        }
        Ok((record.source, record.operation_id, record.request_sha256))
    }
    pub(crate) fn cleanup_retained(&self, budget: &ReadBudget) -> Result<ExportStageCleanup> {
        self.registry.remove(&self.key, Some(&self.live), budget)
    }
    pub(crate) fn begin_helper_sdk(&mut self, root: &File) -> Result<(String, PathBuf)> {
        let identity = self.helper_identity(root)?;
        let mut record = self.record()?;
        if record.schema != 6 {
            return Err(before(ErrorCode::Conflict));
        }
        record.schema = 7;
        record.helper.as_mut().unwrap().phase = HelperPhase::SdkPreparing;
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))?;
        Ok(identity)
    }
    /// Called only after the synchronous storage-only SDK batch returned. It
    /// attests collection of that batch, never initialization success or a VMM.
    pub(crate) fn collect_helper_sdk(&mut self, root: &File) -> Result<()> {
        let mut record = self.record()?;
        let helper = record.helper.as_mut().ok_or(before(ErrorCode::Ownership))?;
        if record.schema != 7
            || helper.phase != HelperPhase::SdkPreparing
            || !helper.same_anchor(root)?
        {
            return Err(before(ErrorCode::Ownership));
        }
        let path = helper.path(&self.registry.binding);
        if !helper.same_anchor(&open_root(&path)?)? {
            return Err(before(ErrorCode::Ownership));
        }
        let mut files = Vec::new();
        for entry in std::fs::read_dir(&path).map_err(|_| before(ErrorCode::Io))? {
            if files.len() == 6 {
                return Err(before(ErrorCode::Ownership));
            }
            let entry = entry.map_err(|_| before(ErrorCode::Io))?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| before(ErrorCode::Ownership))?;
            if !matches!(
                name.as_str(),
                "name"
                    | "storage.raw"
                    | "overlay.raw"
                    | "export-source.qcow2"
                    | "storage.formatted"
                    | "overlay.formatted"
            ) {
                return Err(before(ErrorCode::Ownership));
            }
            let file = plain(&entry.path())?;
            let metadata = file.metadata().map_err(|_| before(ErrorCode::Io))?;
            if !metadata.is_file()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.nlink() != 1
            {
                return Err(before(ErrorCode::Ownership));
            }
            file.set_permissions(std::fs::Permissions::from_mode(0o600))
                .map_err(|_| before(ErrorCode::Io))?;
            file.sync_all().map_err(|_| before(ErrorCode::Io))?;
            let version = Version::of(&file)?;
            let maximum = match name.as_str() {
                "name" => 128,
                "storage.formatted" | "overlay.formatted" => 1,
                "storage.raw" => helper.budget.storage_gib * (1 << 30),
                "overlay.raw" => helper.budget.overlay_gib * (1 << 30),
                "export-source.qcow2" => helper.budget.source_storage_bytes * 2,
                _ => return Err(before(ErrorCode::Ownership)),
            };
            if version.2 > maximum {
                return Err(before(ErrorCode::Ownership));
            }
            if name == "name"
                && !helper
                    .name
                    .as_bytes()
                    .starts_with(&std::fs::read(entry.path()).map_err(|_| before(ErrorCode::Io))?)
            {
                return Err(before(ErrorCode::Ownership));
            }
            files.push(HelperFile { name, version });
        }
        files.sort_by(|a, b| a.name.cmp(&b.name));
        root.sync_all().map_err(|_| before(ErrorCode::Io))?;
        helper.root = Some(HelperRoot::of(root)?);
        helper.files = files;
        helper.phase = HelperPhase::SdkPrepared;
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn prepared_helper_identity(&self, root: &File) -> Result<(String, PathBuf)> {
        let record = self.record()?;
        let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
        let path = helper.path(&self.registry.binding);
        if helper.phase != HelperPhase::SdkPrepared
            || HelperRoot::of(root)? != *helper.root.as_ref().ok_or(before(ErrorCode::Ownership))?
            || HelperRoot::of(&open_root(&path)?)? != HelperRoot::of(root)?
        {
            return Err(before(ErrorCode::Ownership));
        }
        helper.verify_files(&path, false)?;
        Ok((helper.name.clone(), path))
    }
    pub(crate) fn prepared_helper_budget(
        &self,
        root: &File,
    ) -> Result<crate::ExportConversionBudget> {
        let (_, path) = self.prepared_helper_identity(root)?;
        let record = self.record()?;
        let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
        // Partial storage-only batches remain cleanable but cannot supply launch
        // inputs. Exact file versions are checked by prepared_helper_identity.
        if !matches!(helper.files.len(), 4 | 6)
            || helper.files.iter().any(|file| match file.name.as_str() {
                "name" | "export-source.qcow2" => file.version.2 == 0,
                "storage.raw" => file.version.2 != helper.budget.storage_gib * (1 << 30),
                "overlay.raw" => file.version.2 != helper.budget.overlay_gib * (1 << 30),
                "storage.formatted" | "overlay.formatted" => file.version.2 > 1,
                _ => true,
            })
        {
            return Err(before(ErrorCode::Ownership));
        }
        let mut name = Vec::new();
        plain(&path.join("name"))?
            .take(129)
            .read_to_end(&mut name)
            .map_err(|_| before(ErrorCode::Io))?;
        if name != helper.name.as_bytes() {
            return Err(before(ErrorCode::Ownership));
        }
        self.prepared_helper_identity(root)?;
        Ok(helper.budget.clone())
    }
    pub(crate) fn formatted_helper_budget(
        &self,
        root: &File,
    ) -> Result<crate::ExportConversionBudget> {
        let plan = self.prepared_helper_budget(root)?;
        let record = self.record()?;
        let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
        if helper.files.len() != 6 {
            return Err(before(ErrorCode::Ownership));
        }
        let path = helper.path(&self.registry.binding);
        for marker in ["storage.formatted", "overlay.formatted"] {
            let mut bytes = Vec::new();
            plain(&path.join(marker))?
                .take(2)
                .read_to_end(&mut bytes)
                .map_err(|_| before(ErrorCode::Io))?;
            if bytes != b"1" {
                return Err(before(ErrorCode::Ownership));
            }
        }
        self.prepared_helper_identity(root)?;
        Ok(plan)
    }
    pub(crate) fn prepare_helper(
        &mut self,
        resources: &crate::ExportConversionResources,
        planned: &crate::ExportConversionBudget,
        budget: &ReadBudget,
    ) -> Result<File> {
        budget.check()?;
        let mut record = self.record()?;
        if record.schema != 5
            || record.phase != Phase::Preparing
            || record.helper.is_some()
            || planned.max_staging_bytes != record.max_bytes
            || *planned != resources.rebuild(planned)?
        {
            return Err(before(ErrorCode::Ownership));
        }
        let parent = crate::export_source::Root::open(&self.registry.binding.vm_root)?;
        let helper = Helper {
            name: format!("smolbox-export-{}", self.key),
            resources: resources.clone(),
            budget: planned.clone(),
            phase: HelperPhase::Reserved,
            root: None,
            files: vec![],
            launch: None,
            runtime: None,
        };
        let path = helper.path(&self.registry.binding);
        if !absent_path(&path) {
            return Err(before(ErrorCode::Ownership));
        }
        record.schema = 6;
        record.helper = Some(helper);
        self.publish_record(record.clone())
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check()?;
        parent.verify()?;
        std::fs::create_dir(&path).map_err(|_| Error::uncertain(ErrorCode::Conflict))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        let root = open_root(&path)?;
        if std::fs::read_dir(&path)
            .map_err(|_| before(ErrorCode::Io))?
            .next()
            .is_some()
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let helper = record.helper.as_mut().unwrap();
        helper.root = Some(HelperRoot::of(&root)?);
        helper.phase = HelperPhase::Owned;
        File::open(&self.registry.binding.vm_root)
            .and_then(|f| f.sync_all())
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        parent.verify()?;
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))?;
        Ok(root)
    }
    pub(crate) fn helper_identity(&self, root: &File) -> Result<(String, PathBuf)> {
        let record = self.record()?;
        let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
        let path = helper.path(&self.registry.binding);
        if helper.phase != HelperPhase::Owned
            || HelperRoot::of(root)? != *helper.root.as_ref().ok_or(before(ErrorCode::Ownership))?
            || HelperRoot::of(&open_root(&path)?)? != HelperRoot::of(root)?
            || std::fs::read_dir(&path)
                .map_err(|_| before(ErrorCode::Io))?
                .next()
                .is_some()
        {
            return Err(before(ErrorCode::Ownership));
        }
        Ok((helper.name.clone(), path))
    }
    fn record(&self) -> Result<Record> {
        self.registry.verify()?;
        let entries = self
            .registry
            .entries
            .lock()
            .map_err(|_| before(ErrorCode::Native))?;
        let entry = entries.get(&self.key).ok_or(before(ErrorCode::Ownership))?;
        let (record, _) = read(&self.registry.path(&self.key))?;
        if record != entry.record || !entry.live.ptr_eq(&Arc::downgrade(&self.live)) {
            return Err(before(ErrorCode::Ownership));
        }
        verify_root(&self.root, &record)?;
        verify_root(&open_root(&self.registry.root_path(&record))?, &record)?;
        Ok(record)
    }
    pub(crate) fn file<'a>(
        &'a self,
        name: &str,
        max_bytes: u64,
        budget: &ReadBudget,
    ) -> Result<StageWriter<'a>> {
        budget.check()?;
        let record = self.record()?;
        if record.helper.is_some() && record.schema != 11 {
            return Err(before(ErrorCode::Admission));
        }
        if record.schema == 11 {
            self.enter_container_writer(name, max_bytes)?;
        }
        let allowed = match record.phase {
            Phase::Preparing => matches!(name, "storage.raw" | "overlay.raw"),
            Phase::Packing => name == "artifact.smolmachine",
            _ => false,
        };
        if !allowed || max_bytes == 0 {
            return Err(before(ErrorCode::Admission));
        }
        let mut used = self.reserved.load(Ordering::SeqCst);
        loop {
            let next = used
                .checked_add(max_bytes)
                .filter(|next| *next <= record.max_bytes)
                .ok_or(before(ErrorCode::Admission))?;
            match self
                .reserved
                .compare_exchange(used, next, Ordering::SeqCst, Ordering::SeqCst)
            {
                Ok(_) => break,
                Err(current) => used = current,
            }
        }
        // A failed/partial writer retains its declared allowance. It may only be
        // disposed, never retried under this operation's authority.
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(self.registry.root_path(&record).join(name))
            .map_err(|_| before(ErrorCode::Io))?;
        if record.schema == 11 {
            self.note_container_writer(&file)?;
        }
        Ok(StageWriter {
            stage: self,
            file,
            name: name.into(),
            max_bytes,
            bytes: 0,
            budget: budget.clone(),
        })
    }
    pub(crate) fn ready(&mut self, files: Vec<ExportStagedFile>) -> Result<()> {
        let old = self.record()?;
        if old.phase != Phase::Preparing {
            return Err(before(ErrorCode::State));
        }
        let (_, version) = read(&self.registry.path(&self.key))?;
        if files
            .iter()
            .map(|file| file.size_bytes)
            .try_fold(0u64, |sum, bytes| sum.checked_add(bytes))
            != Some(self.written.load(Ordering::SeqCst))
        {
            return Err(before(ErrorCode::Ownership));
        }
        self.root.sync_all().map_err(|_| before(ErrorCode::Io))?;
        let mut next = old.clone();
        next.phase = Phase::Ready;
        next.files = files;
        self.registry.publish(&self.key, &next, Some(version))?;
        let mut entries = self
            .registry
            .entries
            .lock()
            .map_err(|_| before(ErrorCode::Native))?;
        let entry = entries
            .get_mut(&self.key)
            .ok_or(before(ErrorCode::Ownership))?;
        if entry.record != old {
            return Err(before(ErrorCode::Ownership));
        }
        entry.record = next;
        Ok(())
    }
    pub(crate) fn prepare_publication(
        &mut self,
        identity: crate::ExportPublicationIdentity,
    ) -> Result<()> {
        self.verify()?;
        let mut record = self.record()?;
        if !matches!(record.schema, 3 | 5 | 11)
            || record.phase != Phase::Packed
            || record.publication.is_some()
        {
            return Err(before(ErrorCode::State));
        }
        record.publication = Some(Publication {
            identity,
            phase: PublicationPhase::Prepared,
            proof_sha256: None,
        });
        self.publish_record(record)
    }
    pub(crate) fn enter_publication(&mut self) -> Result<()> {
        self.verify()?;
        let mut record = self.record()?;
        let publication = record
            .publication
            .as_mut()
            .ok_or(before(ErrorCode::State))?;
        if publication.phase != PublicationPhase::Prepared {
            return Err(before(ErrorCode::State));
        }
        publication.phase = PublicationPhase::Entered;
        self.publish_record(record)
    }
    pub(crate) fn complete_publication(&mut self) -> Result<crate::ExportPublication> {
        self.verify()?;
        let mut record = self.record()?;
        let publication = record
            .publication
            .as_ref()
            .ok_or(before(ErrorCode::State))?;
        if publication.phase != PublicationPhase::Entered {
            return Err(before(ErrorCode::State));
        }
        let proof = record.publication_receipt(publication)?;
        let publication = record
            .publication
            .as_mut()
            .ok_or(before(ErrorCode::State))?;
        publication.phase = PublicationPhase::Completed;
        publication.proof_sha256 = Some(proof.proof_sha256.clone());
        self.publish_record(record)?;
        Ok(proof)
    }
    fn publish_record(&mut self, next: Record) -> Result<()> {
        let old = self.record()?;
        let (_, version) = read(&self.registry.path(&self.key))?;
        self.registry.publish(&self.key, &next, Some(version))?;
        let mut entries = self
            .registry
            .entries
            .lock()
            .map_err(|_| before(ErrorCode::Native))?;
        let entry = entries
            .get_mut(&self.key)
            .ok_or(before(ErrorCode::Ownership))?;
        if entry.record != old {
            return Err(before(ErrorCode::Ownership));
        }
        entry.record = next;
        Ok(())
    }
    pub(crate) fn begin_pack(&mut self) -> Result<()> {
        self.verify()?;
        if !matches!(self.record()?.schema, 2 | 3 | 5) {
            return Err(before(ErrorCode::State));
        }
        self.transition(Phase::Ready, Phase::Packing, None)
    }
    pub(crate) fn packed(&mut self, file: ExportStagedFile) -> Result<()> {
        self.transition(Phase::Packing, Phase::Packed, Some(file))?;
        self.verify()
    }
    fn transition(&mut self, from: Phase, to: Phase, file: Option<ExportStagedFile>) -> Result<()> {
        let old = self.record()?;
        if old.phase != from {
            return Err(before(ErrorCode::State));
        }
        let (_, version) = read(&self.registry.path(&self.key))?;
        let mut next = old.clone();
        next.phase = to;
        if let Some(file) = file {
            if file.name != "artifact.smolmachine" {
                return Err(before(ErrorCode::Ownership));
            }
            next.files.push(file);
            if next.files.iter().map(|f| f.size_bytes).sum::<u64>()
                != self.written.load(Ordering::SeqCst)
            {
                return Err(before(ErrorCode::Ownership));
            }
        }
        self.root.sync_all().map_err(|_| before(ErrorCode::Io))?;
        self.registry.publish(&self.key, &next, Some(version))?;
        let mut entries = self
            .registry
            .entries
            .lock()
            .map_err(|_| before(ErrorCode::Native))?;
        let entry = entries
            .get_mut(&self.key)
            .ok_or(before(ErrorCode::Ownership))?;
        if entry.record != old {
            return Err(before(ErrorCode::Ownership));
        }
        entry.record = next;
        Ok(())
    }
    pub(crate) fn verify(&self) -> Result<()> {
        let record = self.record()?;
        for proof in &record.files {
            let file = plain(&self.registry.root_path(&record).join(&proof.name))?;
            if file.metadata().map_err(|_| before(ErrorCode::Io))?.mode() & 0o777 != 0o400
                || Version::of(&file)? != proof.version
            {
                return Err(before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
    pub(crate) fn read_at(
        &self,
        name: &str,
        offset: u64,
        bytes: &mut [u8],
        budget: &ReadBudget,
    ) -> Result<()> {
        use std::os::unix::fs::FileExt;
        budget.check()?;
        self.verify()?;
        let record = self.record()?;
        if !matches!(record.phase, Phase::Ready | Phase::Packing | Phase::Packed)
            || bytes.is_empty()
            || bytes.len() > 256 * 1024
        {
            return Err(before(ErrorCode::Validation));
        }
        let proof = record
            .files
            .iter()
            .find(|file| file.name == name)
            .ok_or(before(ErrorCode::Ownership))?;
        if offset
            .checked_add(bytes.len() as u64)
            .is_none_or(|end| end > proof.size_bytes)
        {
            return Err(before(ErrorCode::Validation));
        }
        let file = plain(&self.registry.root_path(&record).join(name))?;
        if Version::of(&file)? != proof.version {
            return Err(before(ErrorCode::Ownership));
        }
        file.read_exact_at(bytes, offset)
            .map_err(|_| before(ErrorCode::Io))?;
        if Version::of(&file)? != proof.version {
            return Err(before(ErrorCode::Ownership));
        }
        self.verify()?;
        budget.check()
    }
    pub(crate) fn close(self, budget: &ReadBudget) -> Result<ExportStageCleanup> {
        self.registry.remove(&self.key, Some(&self.live), budget)
    }
}
pub(crate) struct StageWriter<'a> {
    stage: &'a Stage,
    file: File,
    name: String,
    max_bytes: u64,
    bytes: u64,
    budget: ReadBudget,
}
impl Write for StageWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.budget
            .check()
            .map_err(|_| std::io::Error::other("export budget"))?;
        if self
            .bytes
            .checked_add(bytes.len() as u64)
            .is_none_or(|next| next > self.max_bytes)
        {
            return Err(std::io::Error::other("export size"));
        }
        let count = if bytes.iter().all(|byte| *byte == 0) {
            self.file.seek(SeekFrom::Current(bytes.len() as i64))?;
            bytes.len()
        } else {
            self.file.write(bytes)?
        };
        self.bytes += count as u64;
        Ok(count)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}
impl StageWriter<'_> {
    pub(crate) fn finish(mut self, expected: &crate::ExportDiskDigest) -> Result<ExportStagedFile> {
        self.budget.check()?;
        if self.bytes != expected.size_bytes {
            return Err(before(ErrorCode::Ownership));
        }
        self.file
            .set_len(self.bytes)
            .and_then(|_| self.file.sync_all())
            .map_err(|_| before(ErrorCode::Io))?;
        self.file
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .and_then(|_| self.file.sync_all())
            .map_err(|_| before(ErrorCode::Io))?;
        self.stage
            .root
            .sync_all()
            .map_err(|_| before(ErrorCode::Io))?;
        let original = Version::of(&self.file)?;
        self.file
            .seek(SeekFrom::Start(0))
            .map_err(|_| before(ErrorCode::Io))?;
        let mut hash = Sha256::new();
        let mut buffer = [0; 64 * 1024];
        let mut total = 0;
        loop {
            self.budget.check()?;
            let count = self
                .file
                .read(&mut buffer)
                .map_err(|_| before(ErrorCode::Io))?;
            if count == 0 {
                break;
            }
            total += count as u64;
            if total > self.max_bytes {
                return Err(before(ErrorCode::OutputLimit));
            }
            hash.update(&buffer[..count]);
        }
        let digest = format!("{:x}", hash.finalize());
        self.stage.record()?;
        let path = self
            .stage
            .registry
            .root_path(&self.stage.record()?)
            .join(&self.name);
        if total != self.bytes
            || digest != expected.sha256
            || Version::of(&self.file)? != original
            || Version::of(&plain(&path)?)? != original
        {
            return Err(before(ErrorCode::Ownership));
        }
        self.budget.check()?;
        self.stage.written.fetch_add(self.bytes, Ordering::SeqCst);
        Ok(ExportStagedFile {
            name: self.name,
            size_bytes: self.bytes,
            sha256: digest,
            version: original,
        })
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
struct Version(u64, u64, u64, i64, i64, i64, i64);
impl Version {
    fn of(file: &File) -> Result<Self> {
        let m = file.metadata().map_err(|_| before(ErrorCode::Io))?;
        if !m.is_file()
            || m.uid() != unsafe { libc::geteuid() }
            || m.nlink() != 1
            || m.mode() & 0o077 != 0
        {
            return Err(before(ErrorCode::Ownership));
        }
        Ok(Self(
            m.dev(),
            m.ino(),
            m.len(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
        ))
    }
}
fn plain(path: &Path) -> Result<File> {
    crate::host::unredirected(path)?;
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| before(ErrorCode::Io))
}
fn read(path: &Path) -> Result<(Record, Version)> {
    let mut file = plain(path)?;
    let version = Version::of(&file)?;
    if version.2 > RECORD_BYTES {
        return Err(before(ErrorCode::OutputLimit));
    }
    let mut data = Vec::new();
    Read::by_ref(&mut file)
        .take(RECORD_BYTES + 1)
        .read_to_end(&mut data)
        .map_err(|_| before(ErrorCode::Io))?;
    if data.len() as u64 != version.2 || Version::of(&file)? != version {
        return Err(before(ErrorCode::Ownership));
    }
    Ok((
        serde_json::from_slice(&data).map_err(|_| before(ErrorCode::Ownership))?,
        version,
    ))
}
fn open_root(path: &Path) -> Result<File> {
    crate::host::unredirected(path)?;
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| before(ErrorCode::Io))
}
fn verify_root(file: &File, record: &Record) -> Result<()> {
    let m = file.metadata().map_err(|_| before(ErrorCode::Io))?;
    if !m.is_dir()
        || m.dev() != record.device
        || m.ino() != record.inode
        || m.uid() != unsafe { libc::geteuid() }
        || m.mode() & 0o777 != 0o700
    {
        return Err(before(ErrorCode::Ownership));
    }
    Ok(())
}
impl crate::Engine {
    pub fn admit_export_intent(
        &self,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        maximum: u64,
        identity: &str,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        source.validate(self.binding())?;
        if source.material.is_none()
            || !crate::domain::valid_id(operation)
            || !crate::domain::valid_hex(request, 64)
            || !crate::domain::valid_hex(identity, 64)
            || maximum == 0
            || maximum > crate::JOB_EXPORT_STAGING_BYTES
        {
            return Err(before(ErrorCode::Validation));
        }
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::export_retirement())?;
        let gate = self.observation_gate(&source.name)?;
        let _guard = gate.try_lock().map_err(|_| before(ErrorCode::Conflict))?;
        let directory = self.vm_directory(&source.name);
        let root = crate::export_source::Root::open(&directory)?;
        if !crate::machine::marker_matches(source, &directory)? {
            return Err(before(ErrorCode::Ownership));
        }
        crate::material::MaterialJournal::at(&directory).verify(source)?;
        root.verify()?;
        self.export_staging
            .admit(source, operation, request, maximum, identity, budget)
    }
    pub fn check_export_intent(
        &self,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        maximum: u64,
        identity: &str,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        source.validate(self.binding())?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::export_observation())?;
        self.export_staging
            .check_admission(source, operation, request, maximum, identity, budget)
    }
    /// Exact recorded acknowledgement only. None supplies no absence/replay or
    /// source adoption authority, including after a possibly effective upload.
    pub fn inspect_export_publication(
        &self,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        budget: &ReadBudget,
    ) -> Result<Option<crate::ExportPublication>> {
        self.export_staging
            .inspect_publication(source, operation, request, budget)
    }
    pub fn cleanup_export_staging(
        &self,
        source: &CreationReceipt,
        id: &str,
        request: &str,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<ExportStageCleanup> {
        budget.check()?;
        source.validate(self.binding())?;
        if !quiesced
            || source.material.is_none()
            || !crate::domain::valid_id(id)
            || !crate::domain::valid_hex(request, 64)
        {
            return Err(before(ErrorCode::Validation));
        }
        if let Some(result) = self
            .export_retention
            .collect_for_cleanup(self, source, id, request, budget)
        {
            result?;
        }
        if let Some(result) = self.export_retention.cleanup(source, id, request, budget) {
            return result;
        }
        let gate = self.observation_gate(&source.name)?;
        let _guard = gate.try_lock().map_err(|_| before(ErrorCode::Conflict))?;
        if !self.export_staging.registered(source, id, request)? {
            let _control = self
                .jobs
                .acquire(crate::jobs::Demand::export_retirement())?;
            let directory = self.vm_directory(&source.name);
            let root = crate::export_source::Root::open(&directory)?;
            if !crate::machine::marker_matches(source, &directory)? {
                return Err(before(ErrorCode::Ownership));
            }
            crate::material::MaterialJournal::at(&directory).verify(source)?;
            root.verify()?;
            budget.check()?;
            return self
                .export_staging
                .retire_unstaged(source, id, request, budget);
        }
        self.export_staging
            .cleanup(source, id, request, quiesced, budget)
    }
}

fn cleanup_proof(record: &Record) -> Result<ExportStageCleanup> {
    if record.schema == 8
        || (record.schema == 10 && record.helper.as_ref().is_none_or(|h| h.runtime.is_none()))
    {
        return Err(before(ErrorCode::Conflict));
    }
    let domain = if record.phase == Phase::NoStage {
        "smolbox-export-no-stage-cleanup-v1"
    } else {
        "smolbox-export-stage-cleanup-v1"
    };
    Ok(ExportStageCleanup {
        schema: 1,
        source: record.source.clone(),
        operation_id: record.operation_id.clone(),
        request_sha256: record.request_sha256.clone(),
        stage_sha256: if record.schema == 11 {
            let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
            hash(&(
                "smolbox-export-container-pack-cleanup-v1",
                &record.source,
                &record.operation_id,
                &record.request_sha256,
                record.max_bytes,
                record.device,
                record.inode,
                (
                    &helper.name,
                    &helper.resources,
                    &helper.budget,
                    &helper.root,
                    &helper.files,
                    &helper.launch,
                    &helper.runtime,
                ),
                &record.layer,
                &record.files,
                record.publication.as_ref().map(|p| &p.identity),
            ))?
        } else if record.schema == 10 {
            let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
            hash(&(
                "smolbox-export-container-layer-cleanup-v1",
                &record.source,
                &record.operation_id,
                &record.request_sha256,
                record.max_bytes,
                record.device,
                record.inode,
                (
                    &helper.name,
                    &helper.resources,
                    &helper.budget,
                    &helper.root,
                    &helper.files,
                    &helper.launch,
                    &helper.runtime,
                ),
                &record.layer,
                &record.files,
            ))?
        } else if record.schema == 9 {
            let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
            hash(&(
                "smolbox-export-conversion-runtime-cleanup-v1",
                &record.source,
                &record.operation_id,
                &record.request_sha256,
                record.max_bytes,
                record.device,
                record.inode,
                &helper.name,
                &helper.resources,
                &helper.budget,
                &helper.root,
                &helper.files,
                &helper.launch,
                &helper.runtime,
            ))?
        } else if record.schema == 7 {
            let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
            hash(&(
                "smolbox-export-sdk-storage-cleanup-v1",
                &record.source,
                &record.operation_id,
                &record.request_sha256,
                record.max_bytes,
                record.device,
                record.inode,
                &helper.name,
                &helper.resources,
                &helper.budget,
                &helper.root,
                &helper.files,
            ))?
        } else if let Some(helper) = &record.helper {
            hash(&(
                "smolbox-export-prelaunch-helper-cleanup-v1",
                &record.source,
                &record.operation_id,
                &record.request_sha256,
                record.max_bytes,
                record.device,
                record.inode,
                &helper.name,
                &helper.resources,
                &helper.budget,
                &helper.root,
            ))?
        } else {
            hash(&(
                domain,
                &record.source,
                &record.operation_id,
                &record.request_sha256,
                record.max_bytes,
                record.device,
                record.inode,
            ))?
        },
    })
}
fn absent_path(path: &Path) -> bool {
    matches!(std::fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Cancellation, Engine};
    use std::time::Duration;
    fn fixture() -> (tempfile::TempDir, Engine, CreationReceipt) {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(temp.path(), false);
        (temp, engine, receipt)
    }
    #[test]
    fn collected_storage_only_sdk_files_are_owned_private_and_explicitly_cleaned_after_replacement()
    {
        for partial in [false, true] {
            let (temp, engine, source) = fixture();
            let request = "d".repeat(64);
            let maximum = 128 << 30;
            engine
                .admit_export_intent(
                    &source,
                    "sdk-model",
                    &request,
                    maximum,
                    &"e".repeat(64),
                    &budget(),
                )
                .unwrap();
            let mut stage = engine
                .export_staging
                .create(&source, "sdk-model", &request, maximum, &budget())
                .unwrap();
            let resources = crate::ExportConversionResources {
                slots: 1,
                cpus: 4,
                memory_mb: 4608,
                disk_gb: 128,
            };
            let plan = resources.plan(1 << 30, 1 << 30, maximum).unwrap();
            let root = stage.prepare_helper(&resources, &plan, &budget()).unwrap();
            let (name, path) = stage.begin_helper_sdk(&root).unwrap();
            // Private explicit-path SDK disk APIs only. No manager, global SDK
            // namespace, library overlay operation, process or VM is entered.
            std::fs::write(
                path.join("name"),
                if partial {
                    &name.as_bytes()[..3]
                } else {
                    name.as_bytes()
                },
            )
            .unwrap();
            if partial {
                File::create(path.join("storage.raw")).unwrap();
            } else {
                let storage =
                    smolvm::storage::StorageDisk::open_or_create_at(&path.join("storage.raw"), 1)
                        .unwrap();
                let overlay =
                    smolvm::storage::OverlayDisk::open_or_create_at(&path.join("overlay.raw"), 1)
                        .unwrap();
                assert_eq!(storage.path(), path.join("storage.raw"));
                assert_eq!(overlay.path(), path.join("overlay.raw"));
            }
            assert!(stage
                .record()
                .unwrap()
                .helper
                .as_ref()
                .unwrap()
                .files
                .is_empty());
            stage.collect_helper_sdk(&root).unwrap();
            stage.prepared_helper_identity(&root).unwrap();
            let record = stage.record().unwrap();
            assert_eq!(record.schema, 7);
            let expected = cleanup_proof(&record).unwrap();
            drop((stage, root));
            drop(engine);
            let reopened = crate::machine::tests::test_engine(temp.path());
            let proof = reopened
                .cleanup_export_staging(&source, "sdk-model", &request, true, &budget())
                .unwrap();
            assert_eq!(proof, expected);
            assert!(!path.exists());
            assert_eq!(reopened.jobs.counts().export_staging, 0);
            assert!(!reopened.available());
        }
    }
    #[test]
    fn uncollected_sdk_storage_and_changed_collected_file_never_release_or_resume() {
        for collected in [false, true] {
            let (_temp, engine, source) = fixture();
            let request = "d".repeat(64);
            let maximum = 128 << 30;
            engine
                .admit_export_intent(
                    &source,
                    "sdk-model",
                    &request,
                    maximum,
                    &"e".repeat(64),
                    &budget(),
                )
                .unwrap();
            let mut stage = engine
                .export_staging
                .create(&source, "sdk-model", &request, maximum, &budget())
                .unwrap();
            let resources = crate::ExportConversionResources {
                slots: 1,
                cpus: 4,
                memory_mb: 4608,
                disk_gb: 128,
            };
            let root = stage
                .prepare_helper(
                    &resources,
                    &resources.plan(1 << 30, 1 << 30, maximum).unwrap(),
                    &budget(),
                )
                .unwrap();
            let (name, path) = stage.begin_helper_sdk(&root).unwrap();
            std::fs::write(path.join("name"), name).unwrap();
            if collected {
                stage.collect_helper_sdk(&root).unwrap();
                std::fs::write(path.join("name"), b"foreign").unwrap();
            }
            assert!(stage.begin_helper_sdk(&root).is_err());
            drop((stage, root));
            assert!(engine
                .cleanup_export_staging(&source, "sdk-model", &request, true, &budget())
                .is_err());
            assert!(path.join("name").exists());
            assert_eq!(engine.jobs.counts().export_staging, maximum);
        }
    }
    #[test]
    fn protected_sdk_completion_cache_lag_and_removal_prefix_recover_cleanup_only() {
        for prefix in [false, true] {
            let (_temp, engine, source) = fixture();
            let request = "d".repeat(64);
            let maximum = 128 << 30;
            engine
                .admit_export_intent(
                    &source,
                    "sdk-model",
                    &request,
                    maximum,
                    &"e".repeat(64),
                    &budget(),
                )
                .unwrap();
            let mut stage = engine
                .export_staging
                .create(&source, "sdk-model", &request, maximum, &budget())
                .unwrap();
            let resources = crate::ExportConversionResources {
                slots: 1,
                cpus: 4,
                memory_mb: 4608,
                disk_gb: 128,
            };
            let root = stage
                .prepare_helper(
                    &resources,
                    &resources.plan(1 << 30, 1 << 30, maximum).unwrap(),
                    &budget(),
                )
                .unwrap();
            let (name, path) = stage.begin_helper_sdk(&root).unwrap();
            let prior = stage.record().unwrap();
            std::fs::write(path.join("name"), name).unwrap();
            std::fs::write(path.join("storage.raw"), b"private-prefix").unwrap();
            stage.collect_helper_sdk(&root).unwrap();
            let key = stage.key.clone();
            if prefix {
                let (mut stored, version) = read(&engine.export_staging.path(&key)).unwrap();
                stored.helper.as_mut().unwrap().phase = HelperPhase::Removing;
                engine
                    .export_staging
                    .publish(&key, &stored, Some(version))
                    .unwrap();
                // Deterministic private deletion-prefix model; no live writer.
                std::fs::remove_file(path.join("storage.raw")).unwrap();
            } else {
                engine
                    .export_staging
                    .entries
                    .lock()
                    .unwrap()
                    .get_mut(&key)
                    .unwrap()
                    .record = prior;
            }
            drop((stage, root));
            let proof = engine
                .cleanup_export_staging(&source, "sdk-model", &request, true, &budget())
                .unwrap();
            assert!(!path.exists());
            assert_eq!(engine.jobs.counts().export_staging, 0);
            assert_eq!(
                proof,
                engine
                    .cleanup_export_staging(&source, "sdk-model", &request, true, &budget())
                    .unwrap()
            );
            assert!(engine
                .inspect_export_publication(&source, "sdk-model", &request, &budget())
                .unwrap()
                .is_none());
            assert!(engine
                .check_export_intent(
                    &source,
                    "sdk-model",
                    &request,
                    maximum,
                    &"e".repeat(64),
                    &budget()
                )
                .is_err());
        }
    }
    #[test]
    fn helper_removal_models_require_protected_intent_and_recover_only_forward_cleanup() {
        for removing in [false, true] {
            let (temp, engine, source) = fixture();
            let request = "d".repeat(64);
            let identity = "e".repeat(64);
            let maximum = 128 << 30;
            engine
                .admit_export_intent(
                    &source,
                    "helper-model",
                    &request,
                    maximum,
                    &identity,
                    &budget(),
                )
                .unwrap();
            let mut stage = engine
                .export_staging
                .create(&source, "helper-model", &request, maximum, &budget())
                .unwrap();
            let resources = crate::ExportConversionResources {
                slots: 1,
                cpus: 4,
                memory_mb: 4608,
                disk_gb: 128,
            };
            let plan = resources.plan(1 << 30, 1 << 30, maximum).unwrap();
            let root = stage.prepare_helper(&resources, &plan, &budget()).unwrap();
            let (_, path) = stage.helper_identity(&root).unwrap();
            let id = stage.key.clone();
            if removing {
                let (mut stored, version) = read(&engine.export_staging.path(&id)).unwrap();
                stored.helper.as_mut().unwrap().phase = HelperPhase::Removing;
                // Deterministic protected cache-lag/removal-prefix model only.
                engine
                    .export_staging
                    .publish(&id, &stored, Some(version))
                    .unwrap();
            }
            std::fs::remove_dir(&path).unwrap();
            drop((stage, root));
            if removing {
                let proof = engine
                    .cleanup_export_staging(&source, "helper-model", &request, true, &budget())
                    .unwrap();
                assert_eq!(engine.jobs.counts().export_staging, 0);
                assert_eq!(
                    proof,
                    engine
                        .cleanup_export_staging(&source, "helper-model", &request, true, &budget())
                        .unwrap()
                );
            } else {
                assert!(engine
                    .cleanup_export_staging(&source, "helper-model", &request, true, &budget())
                    .is_err());
                assert_eq!(engine.jobs.counts().export_staging, maximum);
                drop(engine);
                let reopened = crate::machine::tests::test_engine(temp.path());
                assert!(reopened
                    .cleanup_export_staging(&source, "helper-model", &request, true, &budget())
                    .is_err());
                assert_eq!(reopened.jobs.counts().export_staging, maximum);
            }
        }
    }
    #[test]
    fn helper_authority_never_comes_from_unindexed_namespace_or_changed_grant() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let maximum = 128 << 30;
        engine
            .admit_export_intent(
                &source,
                "helper-model",
                &request,
                maximum,
                &"e".repeat(64),
                &budget(),
            )
            .unwrap();
        let mut stage = engine
            .export_staging
            .create(&source, "helper-model", &request, maximum, &budget())
            .unwrap();
        let resources = crate::ExportConversionResources {
            slots: 1,
            cpus: 4,
            memory_mb: 4608,
            disk_gb: 128,
        };
        let mut plan = resources.plan(1 << 30, 1 << 30, maximum).unwrap();
        plan.memory_mib = 8192;
        assert!(stage.prepare_helper(&resources, &plan, &budget()).is_err());
        assert!(stage.record().unwrap().helper.is_none());
        let path = engine
            .binding()
            .vm_root
            .join(smolvm::agent::vm_dir_hash(&format!(
                "smolbox-export-{}",
                stage.key
            )));
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("foreign"), b"keep").unwrap();
        let plan = resources.plan(1 << 30, 1 << 30, maximum).unwrap();
        assert!(stage.prepare_helper(&resources, &plan, &budget()).is_err());
        assert!(stage.record().unwrap().helper.is_none());
        assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"keep");
        stage.close(&budget()).unwrap();
        assert!(path.join("foreign").exists());
    }
    pub(super) fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(60), Cancellation::default()).unwrap()
    }
    pub(super) fn launch_fixture() -> (
        tempfile::TempDir,
        crate::Engine,
        CreationReceipt,
        Stage,
        File,
        crate::epoch::ActorEpoch,
    ) {
        launch_fixture_budget(false)
    }
    pub(super) fn shared_launch_fixture() -> (
        tempfile::TempDir,
        crate::Engine,
        CreationReceipt,
        Stage,
        File,
        crate::epoch::ActorEpoch,
    ) {
        launch_fixture_budget(true)
    }
    fn launch_fixture_budget(
        shared: bool,
    ) -> (
        tempfile::TempDir,
        crate::Engine,
        CreationReceipt,
        Stage,
        File,
        crate::epoch::ActorEpoch,
    ) {
        let (temp, engine, source) = fixture();
        let maximum = 128 << 30;
        let request = "d".repeat(64);
        engine
            .admit_export_intent(
                &source,
                "launch-model",
                &request,
                maximum,
                &"e".repeat(64),
                &budget(),
            )
            .unwrap();
        let mut stage = engine
            .export_staging
            .create(&source, "launch-model", &request, maximum, &budget())
            .unwrap();
        let resources = crate::ExportConversionResources {
            slots: 1,
            cpus: 4,
            memory_mb: 4608,
            disk_gb: 128,
        };
        let root = stage
            .prepare_helper(
                &resources,
                &if shared {
                    resources.shared_plan(1 << 30, 127 << 30, maximum).unwrap()
                } else {
                    resources.plan(1 << 30, 1 << 30, maximum).unwrap()
                },
                &budget(),
            )
            .unwrap();
        let (name, path) = stage.begin_helper_sdk(&root).unwrap();
        std::fs::write(path.join("name"), name).unwrap();
        smolvm::storage::StorageDisk::open_or_create_at(&path.join("storage.raw"), 1).unwrap();
        smolvm::storage::OverlayDisk::open_or_create_at(&path.join("overlay.raw"), 1).unwrap();
        // Stage-only model: a complete bounded private file set, not a qualified
        // COW or SDK manager. Manager preparation separately checks actual COWs.
        std::fs::write(path.join("export-source.qcow2"), b"private stage model").unwrap();
        stage.collect_helper_sdk(&root).unwrap();
        let epoch_root = temp.path().canonicalize().unwrap().join("model-epoch");
        std::fs::create_dir(&epoch_root).unwrap();
        let (_, _, epoch) =
            crate::epoch::tests::fixture_for_binding(&epoch_root, None, engine.binding().clone());
        (temp, engine, source, stage, root, epoch)
    }
    #[test]
    fn cleanup_observation_distinguishes_unentered_launch_from_runtime_custody_without_adoption() {
        let (temp, _engine, _source, mut stage, root, epoch) = launch_fixture();
        assert!(stage.unlaunched_helper_recorded().unwrap());
        assert!(!stage.runtime_custody_recorded().unwrap());
        let (name, _) = stage.prepared_helper_identity(&root).unwrap();
        let dispatch = epoch.begin_boot(&name).unwrap();
        stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
        assert!(!stage.unlaunched_helper_recorded().unwrap());
        assert!(!stage.runtime_custody_recorded().unwrap());
        let enrolled = crate::epoch::tests::complete_model(dispatch);
        stage.helper_launch_returned(&root, &enrolled).unwrap();
        stage
            .begin_helper_collection(&root, &epoch, &enrolled)
            .unwrap();
        let collected = epoch.collect_enrolled(&name, &enrolled).unwrap();
        stage
            .helper_child_collected(&root, &epoch, &collected)
            .unwrap();
        assert!(!stage.runtime_custody_recorded().unwrap());
        let path = temp
            .path()
            .canonicalize()
            .unwrap()
            .join("cleanup-observation-rootfs");
        std::fs::create_dir(&path).unwrap();
        let rootfs = crate::export_source::Root::open(&path).unwrap();
        stage
            .prepare_helper_runtime(&root, &epoch, &collected, &rootfs, &budget())
            .unwrap();
        assert!(stage.runtime_custody_recorded().unwrap());
        assert!(!stage.unlaunched_helper_recorded().unwrap());
        stage.close(&budget()).unwrap();
    }
    #[test]
    fn runtime_retirement_is_exact_marker_scoped_and_preserves_other_rootfs_files() {
        for marker in [false, true] {
            let (temp, engine, source, mut stage, root, epoch) = launch_fixture();
            let (name, path) = stage.prepared_helper_identity(&root).unwrap();
            let dispatch = epoch.begin_boot(&name).unwrap();
            stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
            let enrolled = crate::epoch::tests::complete_model(dispatch);
            stage.helper_launch_returned(&root, &enrolled).unwrap();
            stage
                .begin_helper_collection(&root, &epoch, &enrolled)
                .unwrap();
            let collected = epoch.collect_enrolled(&name, &enrolled).unwrap();
            stage
                .helper_child_collected(&root, &epoch, &collected)
                .unwrap();
            let rootfs_path = temp.path().canonicalize().unwrap().join("rootfs-model");
            std::fs::create_dir(&rootfs_path).unwrap();
            let marker_name = format!(
                "{}.{}",
                smolvm_protocol::AGENT_READY_MARKER,
                smolvm::agent::vm_dir_hash(&name)
            );
            if marker {
                std::fs::write(rootfs_path.join(&marker_name), b"ready").unwrap();
            }
            std::fs::write(rootfs_path.join("other-marker"), b"preserve").unwrap();
            std::fs::write(path.join("vm.lock"), b"").unwrap();
            std::fs::write(path.join("boot-config.json"), b"{}").unwrap();
            let socket = std::os::unix::net::UnixListener::bind(path.join("agent.sock")).unwrap();
            drop(socket); // Stale private socket model, no connection or SDK entry.
            if marker {
                // The current SDK can leave its separate libkrun control socket
                // beside agent.ready after collection. Older boots may omit it.
                let control =
                    std::os::unix::net::UnixListener::bind(path.join("control.sock")).unwrap();
                drop(control);
            }
            let rootfs = crate::export_source::Root::open(&rootfs_path).unwrap();
            stage
                .prepare_helper_runtime(&root, &epoch, &collected, &rootfs, &budget())
                .unwrap();
            stage
                .verify_helper_runtime(&root, &epoch, &collected, &rootfs, &budget())
                .unwrap();
            assert_eq!(stage.record().unwrap().schema, 9);
            let expected = cleanup_proof(&stage.record().unwrap()).unwrap();
            drop((root, rootfs));
            let proof = stage.close(&budget()).unwrap();
            assert_eq!(proof, expected);
            assert!(!path.exists());
            assert!(!rootfs_path.join(marker_name).exists());
            assert_eq!(
                std::fs::read(rootfs_path.join("other-marker")).unwrap(),
                b"preserve"
            );
            assert_eq!(engine.jobs.counts().export_staging, 0);
            assert!(engine.db.get_vm(&source.name).unwrap().is_some());
        }
    }

    #[test]
    fn collected_failed_boot_custody_bounds_short_raw_disks_and_sdk_format_ready_files_without_success(
    ) {
        let (temp, engine, source, mut stage, root, epoch) = launch_fixture();
        let (name, path) = stage.prepared_helper_identity(&root).unwrap();
        let dispatch = epoch.begin_boot(&name).unwrap();
        stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
        let enrolled = crate::epoch::tests::complete_model(dispatch);
        stage.helper_launch_returned(&root, &enrolled).unwrap();
        stage
            .begin_helper_collection(&root, &epoch, &enrolled)
            .unwrap();
        let collected = epoch.collect_enrolled(&name, &enrolled).unwrap();
        stage
            .helper_child_collected(&root, &epoch, &collected)
            .unwrap();
        let rootfs_path = temp
            .path()
            .canonicalize()
            .unwrap()
            .join("failed-boot-rootfs-model");
        std::fs::create_dir(&rootfs_path).unwrap();
        let rootfs = crate::export_source::Root::open(&rootfs_path).unwrap();
        OpenOptions::new()
            .write(true)
            .open(path.join("storage.raw"))
            .unwrap()
            .set_len(512 << 20)
            .unwrap();
        std::fs::write(path.join("storage.formatted"), b"1").unwrap();
        std::fs::write(path.join("overlay.formatted"), b"too large").unwrap();
        let ready = std::os::unix::net::UnixListener::bind(path.join("agent.ready")).unwrap();
        drop(ready);
        assert!(stage
            .prepare_helper_runtime(&root, &epoch, &collected, &rootfs, &budget())
            .is_err());
        assert!(stage.record().unwrap().helper.unwrap().phase == HelperPhase::LaunchCollected);
        std::fs::write(path.join("overlay.formatted"), b"1").unwrap();
        stage
            .prepare_helper_runtime(&root, &epoch, &collected, &rootfs, &budget())
            .unwrap();
        assert!(stage.container_layer().is_err()); // Custody grants cleanup, not conversion/export success.
        stage.close(&budget()).unwrap();
        assert!(!path.exists());
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert!(engine.db.get_vm(&source.name).unwrap().is_some());
    }

    #[test]
    fn recorded_runtime_removal_resumes_only_its_remaining_files_after_normal_reopen() {
        let (temp, engine, source, mut stage, root, epoch) = launch_fixture();
        let (name, path) = stage.prepared_helper_identity(&root).unwrap();
        let dispatch = epoch.begin_boot(&name).unwrap();
        stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
        let enrolled = crate::epoch::tests::complete_model(dispatch);
        stage.helper_launch_returned(&root, &enrolled).unwrap();
        stage
            .begin_helper_collection(&root, &epoch, &enrolled)
            .unwrap();
        let collected = epoch.collect_enrolled(&name, &enrolled).unwrap();
        stage
            .helper_child_collected(&root, &epoch, &collected)
            .unwrap();
        let rootfs_path = temp.path().canonicalize().unwrap().join("rootfs-model");
        std::fs::create_dir(&rootfs_path).unwrap();
        let marker_name = format!(
            "{}.{}",
            smolvm_protocol::AGENT_READY_MARKER,
            smolvm::agent::vm_dir_hash(&name)
        );
        std::fs::write(rootfs_path.join(&marker_name), b"ready").unwrap();
        std::fs::write(path.join("boot-config.json"), b"{}").unwrap();
        let rootfs = crate::export_source::Root::open(&rootfs_path).unwrap();
        stage
            .prepare_helper_runtime(&root, &epoch, &collected, &rootfs, &budget())
            .unwrap();
        let expected = cleanup_proof(&stage.record().unwrap()).unwrap();
        let mut removing = stage.record().unwrap();
        removing.helper.as_mut().unwrap().phase = HelperPhase::Removing;
        stage.publish_record(removing).unwrap();
        // Private deterministic partial-removal model, no live interruption.
        std::fs::remove_file(rootfs_path.join(&marker_name)).unwrap();
        std::fs::remove_file(path.join("boot-config.json")).unwrap();
        drop((stage, root, rootfs, engine));
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert!(!reopened.available());
        assert_eq!(reopened.jobs.counts().export_staging, 128 << 30);
        let proof = reopened
            .cleanup_export_staging(&source, "launch-model", &"d".repeat(64), true, &budget())
            .unwrap();
        assert_eq!(proof, expected);
        assert!(!path.exists());
        assert!(!rootfs_path.join(marker_name).exists());
        assert_eq!(reopened.jobs.counts().export_staging, 0);
    }

    #[test]
    fn changed_runtime_files_markers_and_foreign_inventory_keep_the_full_allowance() {
        for variant in 0..9 {
            let (temp, engine, _source, mut stage, root, epoch) = launch_fixture();
            let (name, path) = stage.prepared_helper_identity(&root).unwrap();
            let dispatch = epoch.begin_boot(&name).unwrap();
            stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
            let enrolled = crate::epoch::tests::complete_model(dispatch);
            stage.helper_launch_returned(&root, &enrolled).unwrap();
            stage
                .begin_helper_collection(&root, &epoch, &enrolled)
                .unwrap();
            let collected = epoch.collect_enrolled(&name, &enrolled).unwrap();
            stage
                .helper_child_collected(&root, &epoch, &collected)
                .unwrap();
            let rootfs_path = temp.path().canonicalize().unwrap().join("rootfs-model");
            std::fs::create_dir(&rootfs_path).unwrap();
            let marker_name = format!(
                "{}.{}",
                smolvm_protocol::AGENT_READY_MARKER,
                smolvm::agent::vm_dir_hash(&name)
            );
            if variant != 2 {
                std::fs::write(rootfs_path.join(&marker_name), b"ready").unwrap();
            }
            let rootfs = crate::export_source::Root::open(&rootfs_path).unwrap();
            if variant >= 4 {
                match variant {
                    4 => std::fs::create_dir(path.join("unknown-directory")).unwrap(),
                    5 => std::os::unix::fs::symlink(
                        rootfs_path.join(&marker_name),
                        path.join("agent.sock"),
                    )
                    .unwrap(),
                    6 => {
                        let file = std::fs::File::create(path.join("agent-console.log")).unwrap();
                        file.set_len((64 << 20) + 1).unwrap();
                    }
                    7 => std::fs::hard_link(
                        path.join("export-source.qcow2"),
                        path.join("agent.config.json"),
                    )
                    .unwrap(),
                    _ => std::fs::write(path.join("control.sock"), b"not a socket").unwrap(),
                }
                assert!(stage
                    .prepare_helper_runtime(&root, &epoch, &collected, &rootfs, &budget())
                    .is_err());
                assert_eq!(stage.record().unwrap().schema, 8);
                assert!(stage.cleanup_retained(&budget()).is_err());
                assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
                assert!(path.join("storage.raw").exists());
                continue;
            }
            stage
                .prepare_helper_runtime(&root, &epoch, &collected, &rootfs, &budget())
                .unwrap();
            match variant {
                0 => std::fs::write(path.join("export-source.qcow2"), b"changed").unwrap(),
                1 | 2 => std::fs::write(rootfs_path.join(&marker_name), b"changed").unwrap(),
                _ => std::fs::write(path.join("foreign"), b"preserve").unwrap(),
            }
            assert!(stage.cleanup_retained(&budget()).is_err());
            assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
            assert!(path.join("storage.raw").exists());
            assert!(rootfs_path.join(&marker_name).exists());
        }
    }

    #[test]
    fn collected_child_requires_exact_entered_intent_and_does_not_release_files() {
        let (temp, engine, _source, mut stage, root, epoch) = launch_fixture();
        let (name, path) = stage.prepared_helper_identity(&root).unwrap();
        let dispatch = epoch.begin_boot(&name).unwrap();
        stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
        let enrolled = crate::epoch::tests::complete_model(dispatch);
        stage.helper_launch_returned(&root, &enrolled).unwrap();
        let collected = epoch.collect_enrolled(&name, &enrolled).unwrap();
        assert!(stage
            .helper_child_collected(&root, &epoch, &collected)
            .is_err());
        stage
            .begin_helper_collection(&root, &epoch, &enrolled)
            .unwrap();
        assert!(stage
            .begin_helper_collection(&root, &epoch, &enrolled)
            .is_err());
        let foreign_root = temp.path().canonicalize().unwrap().join("foreign-epoch");
        std::fs::create_dir(&foreign_root).unwrap();
        let (_, _, foreign) =
            crate::epoch::tests::fixture_for_binding(&foreign_root, None, engine.binding().clone());
        let foreign_enrolled =
            crate::epoch::tests::complete_model(foreign.begin_boot(&name).unwrap());
        let crossed = foreign.collect_enrolled(&name, &foreign_enrolled).unwrap();
        let before = serde_json::to_vec(&stage.record().unwrap()).unwrap();
        assert!(stage
            .helper_child_collected(&root, &epoch, &crossed)
            .is_err());
        assert_eq!(
            before,
            serde_json::to_vec(&stage.record().unwrap()).unwrap()
        );
        stage
            .helper_child_collected(&root, &epoch, &collected)
            .unwrap();
        let before = serde_json::to_vec(&stage.record().unwrap()).unwrap();
        stage
            .helper_child_collected(&root, &epoch, &collected)
            .unwrap();
        assert_eq!(
            before,
            serde_json::to_vec(&stage.record().unwrap()).unwrap()
        );
        assert!(stage.returned_helper_identity(&root, &epoch).is_err());
        assert!(cleanup_proof(&stage.record().unwrap()).is_err());
        assert!(stage.cleanup_retained(&budget()).is_err());
        assert!(path.join("storage.raw").exists());
        assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
    }
    #[test]
    fn helper_launch_intent_and_returned_enrollment_never_grant_cleanup_or_replay() {
        let (_temp, engine, _source, mut stage, root, epoch) = launch_fixture();
        let (name, path) = stage.prepared_helper_identity(&root).unwrap();
        let dispatch = epoch.begin_boot(&name).unwrap();
        stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
        assert_eq!(stage.record().unwrap().schema, 8);
        assert!(stage.prepared_helper_identity(&root).is_err());
        assert!(stage.begin_helper_launch(&root, &dispatch, &epoch).is_err());
        assert!(cleanup_proof(&stage.record().unwrap()).is_err());
        assert!(stage.cleanup_retained(&budget()).is_err());
        // Model SDK disk/namespace changes after entered launch. The original
        // snapshots remain dispatch evidence, never post-launch file authority.
        std::fs::write(path.join("export-source.qcow2"), b"modeled journal replay").unwrap();
        let enrolled = crate::epoch::tests::complete_model(dispatch);
        stage.helper_launch_returned(&root, &enrolled).unwrap();
        let (_, _, child) = stage.returned_helper_identity(&root, &epoch).unwrap();
        assert!(child == enrolled.child());
        assert!(stage.helper_launch_returned(&root, &enrolled).is_err());
        assert!(stage.cleanup_retained(&budget()).is_err());
        assert!(cleanup_proof(&stage.record().unwrap()).is_err());
        assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
        assert!(path.join("export-source.qcow2").exists());
    }
    #[test]
    fn helper_launch_rejects_foreign_name_domain_and_epoch_before_changing_authority() {
        for variant in 0..3 {
            let (temp, engine, _source, mut stage, root, epoch) = launch_fixture();
            let (name, _) = stage.prepared_helper_identity(&root).unwrap();
            let before = serde_json::to_vec(&stage.record().unwrap()).unwrap();
            let foreign_root = temp.path().canonicalize().unwrap().join("foreign-epoch");
            std::fs::create_dir(&foreign_root).unwrap();
            let mut binding = engine.binding().clone();
            if variant == 1 {
                binding.target_id = "foreign".into();
            }
            let (_, _, foreign) =
                crate::epoch::tests::fixture_for_binding(&foreign_root, None, binding);
            let dispatch = if variant == 0 {
                epoch.begin_boot("foreign-helper").unwrap()
            } else {
                foreign.begin_boot(&name).unwrap()
            };
            let selected_epoch = if variant == 1 { &foreign } else { &epoch };
            assert!(stage
                .begin_helper_launch(&root, &dispatch, selected_epoch)
                .is_err());
            assert_eq!(
                before,
                serde_json::to_vec(&stage.record().unwrap()).unwrap()
            );
            stage.prepared_helper_identity(&root).unwrap();
            drop(dispatch); // Pure unresolved-dispatch model; no child or SDK entry.
            stage.cleanup_retained(&budget()).unwrap();
            assert_eq!(engine.jobs.counts().export_staging, 0);
        }
    }
    #[test]
    fn helper_launch_enrollment_from_another_epoch_cannot_complete_original_intent() {
        let (temp, engine, _source, mut stage, root, epoch) = launch_fixture();
        let (name, _) = stage.prepared_helper_identity(&root).unwrap();
        let dispatch = epoch.begin_boot(&name).unwrap();
        stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
        let foreign_root = temp.path().canonicalize().unwrap().join("foreign-epoch");
        std::fs::create_dir(&foreign_root).unwrap();
        let (_, _, foreign) =
            crate::epoch::tests::fixture_for_binding(&foreign_root, None, engine.binding().clone());
        let crossed = crate::epoch::tests::complete_model(foreign.begin_boot(&name).unwrap());
        let before = serde_json::to_vec(&stage.record().unwrap()).unwrap();
        assert!(stage.helper_launch_returned(&root, &crossed).is_err());
        assert_eq!(
            before,
            serde_json::to_vec(&stage.record().unwrap()).unwrap()
        );
        let enrolled = crate::epoch::tests::complete_model(dispatch);
        stage.helper_launch_returned(&root, &enrolled).unwrap();
        assert!(stage.returned_helper_identity(&root, &foreign).is_err());
        stage.returned_helper_identity(&root, &epoch).unwrap();
    }
    #[test]
    fn normal_reopen_preserves_entered_and_returned_helper_capacity_without_adoption() {
        for phase in 0..4 {
            let (temp, engine, source, mut stage, root, epoch) = launch_fixture();
            let (name, path) = stage.prepared_helper_identity(&root).unwrap();
            let dispatch = epoch.begin_boot(&name).unwrap();
            stage.begin_helper_launch(&root, &dispatch, &epoch).unwrap();
            if phase > 0 {
                let enrolled = crate::epoch::tests::complete_model(dispatch);
                stage.helper_launch_returned(&root, &enrolled).unwrap();
                if phase > 1 {
                    stage
                        .begin_helper_collection(&root, &epoch, &enrolled)
                        .unwrap();
                }
                if phase > 2 {
                    let collected = epoch.collect_enrolled(&name, &enrolled).unwrap();
                    stage
                        .helper_child_collected(&root, &epoch, &collected)
                        .unwrap();
                }
            } else {
                drop(dispatch);
            }
            let before = serde_json::to_vec(&stage.record().unwrap()).unwrap();
            drop((stage, root, engine));
            let reopened = crate::machine::tests::test_engine(temp.path());
            assert_eq!(reopened.jobs.counts().export_staging, 128 << 30);
            assert!(!reopened.available());
            assert!(reopened
                .cleanup_export_staging(&source, "launch-model", &"d".repeat(64), true, &budget())
                .is_err());
            let id = key(&source, "launch-model", &"d".repeat(64)).unwrap();
            let (record, _) = read(&reopened.export_staging.path(&id)).unwrap();
            assert_eq!(before, serde_json::to_vec(&record).unwrap());
            assert!(path.join("storage.raw").exists());
            assert_eq!(reopened.jobs.counts().export_staging, 128 << 30);
        }
    }
    fn file(stage: &mut Stage, name: &str, bytes: &[u8]) -> ExportStagedFile {
        let mut writer = stage.file(name, bytes.len() as u64, &budget()).unwrap();
        writer.write_all(bytes).unwrap();
        writer
            .finish(&crate::ExportDiskDigest {
                size_bytes: bytes.len() as u64,
                sha256: format!("{:x}", Sha256::digest(bytes)),
            })
            .unwrap()
    }
    #[test]
    fn ready_stage_is_private_charged_immutable_and_live_cleanup_cannot_override_the_handle() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        assert!(!engine.export_staging.ledger_path().exists());
        let mut stage = engine
            .export_staging
            .create(&source, "export", &request, 64, &budget())
            .unwrap();
        let one = file(&mut stage, "storage.raw", b"one\0\0\0\0\0");
        let two = file(&mut stage, "overlay.raw", b"two");
        stage.ready(vec![one, two]).unwrap();
        stage.verify().unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 64);
        assert!(engine
            .cleanup_export_staging(&source, "export", &request, true, &budget())
            .is_err());
        assert!(engine
            .export_staging
            .create(&source, "export", &"e".repeat(64), 64, &budget())
            .is_err());
        let proof = stage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        let repeated = engine
            .cleanup_export_staging(&source, "export", &request, true, &budget())
            .unwrap();
        assert!(proof == repeated);
        assert!(engine
            .export_staging
            .create(&source, "export", &request, 64, &budget())
            .is_err());
    }
    #[test]
    fn incomplete_or_missing_stage_keeps_capacity_and_missing_files_are_not_cleanup_proof() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let stage = engine
            .export_staging
            .create(&source, "export", &request, 64, &budget())
            .unwrap();
        {
            let mut writer = stage.file("storage.raw", 8, &budget()).unwrap();
            writer.write_all(b"partial").unwrap();
        }
        let record = stage.record().unwrap();
        drop(stage);
        assert_eq!(engine.jobs.counts().export_staging, 64);
        assert!(engine
            .cleanup_export_staging(&source, "export", &request, false, &budget())
            .is_err());
        let mut foreign = source.clone();
        foreign.owner_token = "f".repeat(64);
        assert!(engine
            .cleanup_export_staging(&foreign, "export", &request, true, &budget())
            .is_err());
        assert!(engine
            .cleanup_export_staging(&source, "export", &"f".repeat(64), true, &budget())
            .is_err());
        std::fs::remove_file(engine.export_staging.root_path(&record).join("storage.raw")).unwrap();
        std::fs::remove_dir(engine.export_staging.root_path(&record)).unwrap();
        assert!(engine
            .cleanup_export_staging(&source, "export", &request, true, &budget())
            .is_err());
        assert_eq!(engine.jobs.counts().export_staging, 64);
    }
    #[test]
    fn changed_payload_or_substituted_root_never_becomes_ready_authority_and_foreign_data_is_preserved(
    ) {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let mut stage = engine
            .export_staging
            .create(&source, "export", &request, 64, &budget())
            .unwrap();
        let one = file(&mut stage, "storage.raw", b"one");
        let two = file(&mut stage, "overlay.raw", b"two");
        stage.ready(vec![one, two]).unwrap();
        let record = stage.record().unwrap();
        let root = engine.export_staging.root_path(&record);
        let path = root.join("storage.raw");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(&path, b"changed").unwrap();
        assert!(stage.verify().is_err());
        std::fs::rename(&root, root.with_extension("retained")).unwrap();
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("foreign"), b"keep").unwrap();
        drop(stage);
        assert!(engine
            .cleanup_export_staging(&source, "export", &request, true, &budget())
            .is_err());
        assert_eq!(std::fs::read(root.join("foreign")).unwrap(), b"keep");
        assert_eq!(engine.jobs.counts().export_staging, 64);
    }
    #[test]
    fn modeled_reopen_restores_only_recorded_allowances_and_never_replays_or_adopts_output() {
        // Ordinary in-process registry replacement, no helper/VM process or loss.
        let (temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let stage = engine
            .export_staging
            .create(&source, "export", &request, 64, &budget())
            .unwrap();
        drop(stage);
        let binding = engine.binding().clone();
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert_eq!(reopened.binding(), &binding);
        assert_eq!(reopened.jobs.counts().export_staging, 64);
        assert!(!reopened.available());
        let proof = reopened
            .cleanup_export_staging(&source, "export", &request, true, &budget())
            .unwrap();
        assert_eq!(proof.operation_id, "export");
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        assert!(!reopened.available());
        drop(reopened);
        let clean = crate::machine::tests::test_engine(temp.path());
        assert_eq!(clean.jobs.counts().export_staging, 0);
        assert!(clean.available());
    }
    #[test]
    fn budget_duplicate_requests_and_output_limits_reject_without_claiming_success() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        assert!(engine
            .export_staging
            .create(&source, "export", &request, 0, &budget())
            .is_err());
        assert!(!engine.export_staging.ledger_path().exists());
        let stage = engine
            .export_staging
            .create(&source, "export", &request, 8, &budget())
            .unwrap();
        assert!(stage.file("storage.raw", 9, &budget()).is_err());
        {
            let mut writer = stage.file("storage.raw", 8, &budget()).unwrap();
            assert!(writer.write_all(b"too-large").is_err());
        }
        assert!(stage.file("../outside", 1, &budget()).is_err());
        let cancel = Cancellation::default();
        cancel.cancel();
        let stopped = ReadBudget::for_export_work(Duration::from_secs(1), cancel).unwrap();
        assert!(stage.file("overlay.raw", 1, &stopped).is_err());
        let proof = stage.close(&budget()).unwrap();
        assert_eq!(proof.operation_id, "export");
        assert_eq!(engine.jobs.counts().export_staging, 0);
    }
    #[test]
    fn modeled_published_cleanup_completes_retained_accounting_without_reopening_a_writer() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let stage = engine
            .export_staging
            .create(&source, "export", &request, 64, &budget())
            .unwrap();
        let mut record = stage.record().unwrap();
        let id = stage.key.clone();
        drop(stage);
        let (_, version) = read(&engine.export_staging.path(&id)).unwrap();
        record.phase = Phase::Cleaning;
        engine
            .export_staging
            .publish(&id, &record, Some(version))
            .unwrap();
        // Deterministic empty-root/control publication model, no live writer.
        std::fs::remove_dir(engine.export_staging.root_path(&record)).unwrap();
        let (_, version) = read(&engine.export_staging.path(&id)).unwrap();
        record.phase = Phase::Cleaned;
        engine
            .export_staging
            .publish(&id, &record, Some(version))
            .unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 64);
        let proof = engine
            .cleanup_export_staging(&source, "export", &request, true, &budget())
            .unwrap();
        assert_eq!(proof.operation_id, "export");
        assert_eq!(engine.jobs.counts().export_staging, 0);
    }

    #[test]
    fn unstaged_cleanup_is_explicit_source_bound_zero_byte_retirement_without_publication_or_replay(
    ) {
        let (temp, engine, source) = fixture();
        let request = "d".repeat(64);
        assert!(engine
            .cleanup_export_staging(&source, "unused", &request, false, &budget())
            .is_err());
        assert!(!engine.export_staging.ledger_path().exists());
        let before_row = serde_json::to_vec(&engine.db.get_vm(&source.name).unwrap()).unwrap();
        let proof = engine
            .cleanup_export_staging(&source, "unused", &request, true, &budget())
            .unwrap();
        assert_eq!(proof.operation_id, "unused");
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert!(engine
            .inspect_export_publication(&source, "unused", &request, &budget())
            .unwrap()
            .is_none());
        let id = key(&source, "unused", &request).unwrap();
        let (record, _) = read(&engine.export_staging.path(&id)).unwrap();
        assert_eq!(record.schema, 4);
        assert_eq!(record.max_bytes, 0);
        assert!(
            record.phase == Phase::NoStage
                && record.files.is_empty()
                && record.publication.is_none()
        );
        assert!(!engine.export_staging.root_path(&record).exists());
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&source.name).unwrap()).unwrap(),
            before_row
        );
        assert!(engine
            .export_staging
            .create(&source, "unused", &request, 64, &budget())
            .is_err());
        assert!(engine
            .export_staging
            .create(&source, "unused", &"e".repeat(64), 64, &budget())
            .is_err());
        assert!(
            engine
                .cleanup_export_staging(&source, "unused", &request, true, &budget())
                .unwrap()
                == proof
        );
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert!(reopened.available());
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        assert!(
            reopened
                .cleanup_export_staging(&source, "unused", &request, true, &budget())
                .unwrap()
                == proof
        );
    }

    #[test]
    fn unstaged_retirement_requires_owned_source_and_preserves_unknown_root_and_live_source_gate() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let mut foreign = source.clone();
        foreign.incarnation = "f".repeat(32);
        assert!(engine
            .cleanup_export_staging(&foreign, "unused", &request, true, &budget())
            .is_err());
        assert!(!engine.export_staging.ledger_path().exists());
        let gate = engine.observation_gate(&source.name).unwrap();
        let held = gate.try_lock().unwrap();
        assert_eq!(
            engine
                .cleanup_export_staging(&source, "unused", &request, true, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(held);
        let path = engine.domain.directory.join(format!(
            ".export-{}",
            key(&source, "unused", &request).unwrap()
        ));
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("foreign"), b"keep").unwrap();
        assert!(engine
            .cleanup_export_staging(&source, "unused", &request, true, &budget())
            .is_err());
        assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"keep");
        assert!(!engine.export_staging.ledger_path().exists());
    }

    #[test]
    fn unstaged_cleanup_uses_reserved_control_under_full_work_and_quarantine_without_clearing_it() {
        let (_temp, engine, source) = fixture();
        let mut source_work = engine
            .jobs
            .acquire(crate::jobs::Demand::export_source())
            .unwrap();
        source_work.promote_export_disks().unwrap();
        let mut held = vec![source_work];
        for _ in 0..3 {
            held.push(
                engine
                    .jobs
                    .acquire(crate::jobs::Demand::streaming())
                    .unwrap(),
            );
        }
        assert_eq!(engine.jobs.counts().work_descriptors, 24);
        assert_eq!(
            engine.jobs.counts().work_metadata,
            crate::jobs::JOB_METADATA_BYTES
        );
        engine.jobs.quarantine();
        let cancel = Cancellation::default();
        cancel.cancel();
        let cancelled = ReadBudget::new(Duration::from_secs(1), cancel).unwrap();
        assert!(engine
            .cleanup_export_staging(&source, "unused", &"d".repeat(64), true, &cancelled)
            .is_err());
        assert!(!engine.export_staging.ledger_path().exists());
        let proof = engine
            .cleanup_export_staging(&source, "unused", &"d".repeat(64), true, &budget())
            .unwrap();
        assert_eq!(proof.operation_id, "unused");
        assert_eq!(engine.jobs.counts().work, 4);
        assert_eq!(engine.jobs.counts().control, 0);
        assert_eq!(engine.jobs.counts().material_control_metadata, 0);
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert!(!engine.available());
        drop(held);
        assert!(!engine.available());
    }

    #[test]
    fn protected_no_stage_cache_lag_model_recovers_only_exact_retirement_and_never_a_writer() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let proof = engine
            .cleanup_export_staging(&source, "unused", &request, true, &budget())
            .unwrap();
        let id = key(&source, "unused", &request).unwrap();
        engine.export_staging.entries.lock().unwrap().remove(&id);
        assert!(
            engine
                .cleanup_export_staging(&source, "unused", &request, true, &budget())
                .unwrap()
                == proof
        );
        let (mut invalid, _) = read(&engine.export_staging.path(&id)).unwrap();
        invalid.max_bytes = 1;
        assert!(invalid.valid(engine.binding()).is_err());
        invalid.max_bytes = 0;
        invalid.schema = 3;
        assert!(invalid.valid(engine.binding()).is_err());
    }

    #[test]
    fn collected_export_stage_remains_owned_in_the_private_deleted_source_model() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let stage = engine
            .export_staging
            .create(&source, "dispose", &request, 64, &budget())
            .unwrap();
        drop(stage);
        // This synthetic engine does not install SDK process-path overrides.
        // Only model removal of its own row/fixture directory, never invoke
        // SDK lifecycle cleanup against the host's ordinary cache paths.
        engine.db.remove_vm(&source.name).unwrap();
        std::fs::remove_dir_all(engine.vm_directory(&source.name)).unwrap();
        let observation = engine.inspect(&source).unwrap();
        assert_eq!(observation.state, crate::ObservedState::Missing);
        assert_eq!(engine.jobs.counts().export_staging, 64);
        let proof = engine
            .cleanup_export_staging(&source, "dispose", &request, true, &budget())
            .unwrap();
        assert_eq!(proof.operation_id, "dispose");
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert!(
            engine
                .cleanup_export_staging(&source, "dispose", &request, true, &budget())
                .unwrap()
                == proof
        );
        assert!(engine
            .cleanup_export_staging(&source, "unregistered", &request, true, &budget())
            .is_err());
    }

    #[test]
    fn db_only_fixture_cannot_enter_sdk_deletion_against_an_unbound_process_cache_root() {
        let (_temp, engine, source) = fixture();
        assert_ne!(
            smolvm::agent::vm_data_dir(&source.name),
            engine.vm_directory(&source.name)
        );
        let before_row = serde_json::to_vec(&engine.db.get_vm(&source.name).unwrap()).unwrap();
        let error = engine
            .delete_with_budget(
                &source,
                &ReadBudget::new(Duration::from_secs(30), Cancellation::default()).unwrap(),
            )
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&source.name).unwrap()).unwrap(),
            before_row
        );
        assert!(engine.vm_directory(&source.name).exists());
    }

    #[test]
    fn admitted_unstaged_intent_survives_private_source_disposal_without_adoption_or_replay() {
        let (temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let identity = "e".repeat(64);
        engine
            .admit_export_intent(&source, "admitted", &request, 64, &identity, &budget())
            .unwrap();
        engine
            .admit_export_intent(&source, "admitted", &request, 64, &identity, &budget())
            .unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        engine
            .check_export_intent(&source, "admitted", &request, 64, &identity, &budget())
            .unwrap();
        assert!(engine
            .check_export_intent(&source, "admitted", &request, 65, &identity, &budget())
            .is_err());
        assert!(engine
            .check_export_intent(
                &source,
                "admitted",
                &request,
                64,
                &"f".repeat(64),
                &budget()
            )
            .is_err());
        engine.db.remove_vm(&source.name).unwrap();
        std::fs::remove_dir_all(engine.vm_directory(&source.name)).unwrap();
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert!(reopened.available());
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        let proof = reopened
            .cleanup_export_staging(&source, "admitted", &request, true, &budget())
            .unwrap();
        assert_eq!(proof.operation_id, "admitted");
        assert!(reopened
            .inspect_export_publication(&source, "admitted", &request, &budget())
            .unwrap()
            .is_none());
        assert!(reopened
            .check_export_intent(&source, "admitted", &request, 64, &identity, &budget())
            .is_err());
        assert!(reopened
            .export_staging
            .create(&source, "admitted", &request, 64, &budget())
            .is_err());
        assert!(
            reopened
                .cleanup_export_staging(&source, "admitted", &request, true, &budget())
                .unwrap()
                == proof
        );
    }

    #[test]
    fn admission_rejects_cancelled_changed_and_crossed_intents_without_scratch_or_row_mutation() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        let identity = "e".repeat(64);
        let original = serde_json::to_vec(&engine.db.get_vm(&source.name).unwrap()).unwrap();
        let cancellation = Cancellation::default();
        cancellation.cancel();
        let cancelled = ReadBudget::new(Duration::from_secs(1), cancellation).unwrap();
        assert!(engine
            .admit_export_intent(&source, "admitted", &request, 64, &identity, &cancelled)
            .is_err());
        assert!(!engine.export_staging.ledger_path().exists());
        engine
            .admit_export_intent(&source, "admitted", &request, 64, &identity, &budget())
            .unwrap();
        for (digest, maximum, fingerprint) in [
            (request.clone(), 65, identity.clone()),
            (request.clone(), 64, "f".repeat(64)),
            ("f".repeat(64), 64, identity.clone()),
        ] {
            assert!(engine
                .admit_export_intent(
                    &source,
                    "admitted",
                    &digest,
                    maximum,
                    &fingerprint,
                    &budget()
                )
                .is_err());
        }
        engine
            .check_export_intent(&source, "admitted", &request, 64, &identity, &budget())
            .unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert_eq!(
            original,
            serde_json::to_vec(&engine.db.get_vm(&source.name).unwrap()).unwrap()
        );
        assert_eq!(engine.export_staging.entries.lock().unwrap().len(), 1);
    }

    #[test]
    fn uncertain_entering_model_retains_ceiling_until_exact_explicit_retirement() {
        for ledger_advanced in [false, true] {
            let (_temp, engine, source) = fixture();
            let request = "d".repeat(64);
            engine
                .admit_export_intent(
                    &source,
                    "admitted",
                    &request,
                    64,
                    &"e".repeat(64),
                    &budget(),
                )
                .unwrap();
            let key = key(&source, "admitted", &request).unwrap();
            // Deterministic state model only; no interrupted live I/O.
            if ledger_advanced {
                let (mut stored, version) = read(&engine.export_staging.path(&key)).unwrap();
                stored.phase = Phase::Entering;
                engine
                    .export_staging
                    .publish(&key, &stored, Some(version))
                    .unwrap();
            }
            engine
                .export_staging
                .entries
                .lock()
                .unwrap()
                .get_mut(&key)
                .unwrap()
                .allowance = Some(engine.jobs.export_staging(64, false).unwrap());
            engine.jobs.quarantine();
            assert_eq!(engine.jobs.counts().export_staging, 64);
            assert!(engine
                .check_export_intent(
                    &source,
                    "admitted",
                    &request,
                    64,
                    &"e".repeat(64),
                    &budget()
                )
                .is_err());
            let proof = engine
                .cleanup_export_staging(&source, "admitted", &request, true, &budget())
                .unwrap();
            assert_eq!(engine.jobs.counts().export_staging, 0);
            assert!(!engine.available());
            assert_eq!(
                proof,
                engine
                    .cleanup_export_staging(&source, "admitted", &request, true, &budget())
                    .unwrap()
            );
        }
    }

    #[test]
    fn admission_promotes_once_to_owned_stage_and_retains_exact_identity_through_cleanup() {
        let (_temp, engine, source) = fixture();
        let request = "d".repeat(64);
        engine
            .admit_export_intent(
                &source,
                "admitted",
                &request,
                64,
                &"e".repeat(64),
                &budget(),
            )
            .unwrap();
        assert!(engine
            .export_staging
            .create(&source, "admitted", &request, 65, &budget())
            .is_err());
        let mut stage = engine
            .export_staging
            .create(&source, "admitted", &request, 64, &budget())
            .unwrap();
        let record = stage.record().unwrap();
        assert_eq!(record.schema, 5);
        assert_eq!(record.admission.unwrap().maximum, 64);
        assert_eq!(engine.jobs.counts().export_staging, 64);
        let storage = file(&mut stage, "storage.raw", b"storage");
        let overlay = file(&mut stage, "overlay.raw", b"overlay");
        stage.ready(vec![storage, overlay]).unwrap();
        assert!(engine
            .check_export_intent(
                &source,
                "admitted",
                &request,
                64,
                &"e".repeat(64),
                &budget()
            )
            .is_err());
        assert!(engine
            .export_staging
            .create(&source, "admitted", &request, 64, &budget())
            .is_err());
        stage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
    }

    #[test]
    fn entering_without_directory_is_explicitly_retired_but_unproved_directory_is_preserved() {
        for root_present in [false, true] {
            let (temp, engine, source) = fixture();
            let request = "d".repeat(64);
            engine
                .admit_export_intent(
                    &source,
                    "admitted",
                    &request,
                    64,
                    &"e".repeat(64),
                    &budget(),
                )
                .unwrap();
            let id = key(&source, "admitted", &request).unwrap();
            let (mut record, version) = read(&engine.export_staging.path(&id)).unwrap();
            record.phase = Phase::Entering;
            engine
                .export_staging
                .publish(&id, &record, Some(version))
                .unwrap();
            if root_present {
                std::fs::create_dir(engine.export_staging.root_path(&record)).unwrap();
                std::fs::write(
                    engine.export_staging.root_path(&record).join("foreign"),
                    b"keep",
                )
                .unwrap();
            }
            drop(engine);
            let reopened = crate::machine::tests::test_engine(temp.path());
            assert_eq!(reopened.jobs.counts().export_staging, 64);
            assert!(!reopened.available());
            let result =
                reopened.cleanup_export_staging(&source, "admitted", &request, true, &budget());
            if root_present {
                assert!(result.is_err());
                assert_eq!(
                    std::fs::read(reopened.export_staging.root_path(&record).join("foreign"))
                        .unwrap(),
                    b"keep"
                );
                assert_eq!(reopened.jobs.counts().export_staging, 64);
            } else {
                result.unwrap();
                assert_eq!(reopened.jobs.counts().export_staging, 0);
            }
            assert!(!reopened.available());
        }
    }
    #[test]
    fn legacy_ready_records_remain_readable_and_cleanable_without_pack_adoption() {
        let (_temp, engine, source) = fixture();
        let mut stage = engine
            .export_staging
            .create(&source, "legacy", &"a".repeat(64), 64, &budget())
            .unwrap();
        let one = file(&mut stage, "storage.raw", b"one");
        let two = file(&mut stage, "overlay.raw", b"two");
        stage.ready(vec![one, two]).unwrap();
        // Exact earlier schema, installed as a deterministic protected-row model.
        let (mut record, version) = read(&engine.export_staging.path(&stage.key)).unwrap();
        record.schema = 1;
        engine
            .export_staging
            .publish(&stage.key, &record, Some(version))
            .unwrap();
        engine
            .export_staging
            .entries
            .lock()
            .unwrap()
            .get_mut(&stage.key)
            .unwrap()
            .record = record.clone();
        stage.verify().unwrap();
        let mut bytes = [0; 3];
        stage
            .read_at("storage.raw", 0, &mut bytes, &budget())
            .unwrap();
        assert_eq!(&bytes, b"one");
        assert!(stage.begin_pack().is_err());
        assert!(read(&engine.export_staging.path(&stage.key)).unwrap().0 == record);
        stage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
    }
    #[test]
    fn partial_packing_remains_reserved_after_normal_registry_replacement_and_cannot_restart() {
        let (temp, engine, source) = fixture();
        let mut stage = engine
            .export_staging
            .create(&source, "partial-pack", &"a".repeat(64), 128, &budget())
            .unwrap();
        let one = file(&mut stage, "storage.raw", b"one");
        let two = file(&mut stage, "overlay.raw", b"two");
        stage.ready(vec![one, two]).unwrap();
        stage.begin_pack().unwrap();
        assert!(stage.begin_pack().is_err());
        assert!(stage.file("storage.raw", 1, &budget()).is_err());
        {
            let mut writer = stage.file("artifact.smolmachine", 122, &budget()).unwrap();
            writer.write_all(b"partial output").unwrap();
            assert!(stage.file("artifact.smolmachine", 1, &budget()).is_err());
            assert!(stage
                .read_at("artifact.smolmachine", 0, &mut [0; 1], &budget())
                .is_err());
        }
        let root = engine.export_staging.root_path(&stage.record().unwrap());
        drop(stage);
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert!(!reopened.available());
        assert_eq!(reopened.jobs.counts().export_staging, 128);
        assert!(reopened
            .export_staging
            .create(&source, "partial-pack", &"a".repeat(64), 128, &budget())
            .is_err());
        reopened
            .cleanup_export_staging(&source, "partial-pack", &"a".repeat(64), true, &budget())
            .unwrap();
        assert!(!root.exists());
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        assert!(!reopened.available());
    }
    fn packed_fixture() -> (
        tempfile::TempDir,
        Engine,
        CreationReceipt,
        Stage,
        crate::ExportPublicationIdentity,
    ) {
        let (temp, engine, source) = fixture();
        let mut stage = engine
            .export_staging
            .create(&source, "publish", &"a".repeat(64), 128, &budget())
            .unwrap();
        let one = file(&mut stage, "storage.raw", b"one");
        let two = file(&mut stage, "overlay.raw", b"two");
        stage.ready(vec![one, two]).unwrap();
        stage.begin_pack().unwrap();
        let artifact = file(&mut stage, "artifact.smolmachine", b"owned artifact");
        stage.packed(artifact.clone()).unwrap();
        let platform = crate::oci::native_oci_platform();
        let identity = crate::ExportPublicationIdentity {
            destination_id: "registry".into(),
            destination_sha256: "b".repeat(64),
            registry: "registry.example".into(),
            repository: "team/artifact".into(),
            tag: "release".into(),
            platform_tag: format!("release-{}", platform.replace('/', "-")),
            platform: platform.into(),
            content_sha256: artifact.sha256,
            size_bytes: artifact.size_bytes,
            config_sha256: "c".repeat(64),
            manifest_sha256: "d".repeat(64),
            index_sha256: "e".repeat(64),
        };
        (temp, engine, source, stage, identity)
    }
    #[test]
    fn earlier_packed_schema_is_read_cleanup_compatible_without_publication_resume() {
        let (_temp, engine, _source, mut stage, identity) = packed_fixture();
        let (mut record, version) = read(&engine.export_staging.path(&stage.key)).unwrap();
        record.schema = 2;
        engine
            .export_staging
            .publish(&stage.key, &record, Some(version))
            .unwrap();
        engine
            .export_staging
            .entries
            .lock()
            .unwrap()
            .get_mut(&stage.key)
            .unwrap()
            .record = record.clone();
        assert!(serde_json::to_value(&record)
            .unwrap()
            .get("publication")
            .is_none());
        stage.verify().unwrap();
        assert!(stage.prepare_publication(identity).is_err());
        stage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
    }
    #[test]
    fn entered_publication_reopen_retains_quarantine_capacity_and_only_recorded_result_can_be_observed(
    ) {
        let (temp, engine, source, mut stage, identity) = packed_fixture();
        stage.prepare_publication(identity).unwrap();
        stage.enter_publication().unwrap();
        assert!(engine
            .inspect_export_publication(&source, "publish", &"a".repeat(64), &budget())
            .unwrap()
            .is_none());
        let mut work = engine
            .jobs
            .acquire(crate::jobs::Demand::export_source())
            .unwrap();
        work.promote_export_disks().unwrap();
        work.promote_export_stage().unwrap();
        let other_control = engine
            .jobs
            .acquire(crate::jobs::Demand::export_observation())
            .unwrap();
        engine.jobs.quarantine();
        assert!(engine
            .inspect_export_publication(&source, "publish", &"a".repeat(64), &budget())
            .unwrap()
            .is_none());
        drop(other_control);
        drop(work);
        drop(stage);
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert!(!reopened.available());
        assert_eq!(reopened.jobs.counts().export_staging, 128);
        assert!(reopened
            .inspect_export_publication(&source, "publish", &"a".repeat(64), &budget())
            .unwrap()
            .is_none());
        reopened
            .cleanup_export_staging(&source, "publish", &"a".repeat(64), true, &budget())
            .unwrap();
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        assert!(!reopened.available());
    }
    #[test]
    fn protected_completion_model_can_finish_cleanup_accounting_without_minting_a_missing_acknowledgement(
    ) {
        let (_temp, engine, source, mut stage, identity) = packed_fixture();
        stage.prepare_publication(identity).unwrap();
        stage.enter_publication().unwrap();
        let entered = stage.record().unwrap();
        let proof = stage.complete_publication().unwrap();
        let completed = stage.record().unwrap();
        let mut corrupted = completed.clone();
        corrupted.publication.as_mut().unwrap().proof_sha256 = Some("f".repeat(64));
        assert!(corrupted.valid(engine.binding()).is_err());
        let key = stage.key.clone();
        drop(stage);
        // Deterministic protected-publication/cache-lag model, no process loss.
        engine
            .export_staging
            .entries
            .lock()
            .unwrap()
            .get_mut(&key)
            .unwrap()
            .record = entered;
        assert!(engine
            .inspect_export_publication(&source, "publish", &"a".repeat(64), &budget())
            .is_err());
        engine
            .cleanup_export_staging(&source, "publish", &"a".repeat(64), true, &budget())
            .unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert!(
            engine
                .inspect_export_publication(&source, "publish", &"a".repeat(64), &budget())
                .unwrap()
                == Some(proof)
        );
    }
}
