//! Fresh private volume backing, prior to isolated guest access qualification.
//! Immutable intent precedes temporary mkdir; protected backing identity precedes
//! no-replacement public rename and distinct final staging evidence. Incomplete
//! attempts are never replayed or adopted from directory inventory.
use super::{LocalVolumeIntent, LocalVolumePolicy, QualifiedVolumeRoot};
use crate::{DomainBinding, Engine, Error, ErrorCode, ReadBudget, Result};
use serde::{Deserialize, Serialize};
use std::ffi::CString;
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::OpenOptionsExt;

const MAX_RECORD_BYTES: usize = super::VOLUME_RECORD_BYTES;

#[path = "volume_access.rs"]
mod access;
pub(crate) use access::remove_tree;
#[cfg(test)]
pub(crate) use access::{foreign_handle, owned_handle};
pub use access::{
    QualifiedVolumeMounts, VolumeAccount, VolumeDeletionPermit, VolumeDeletionPresence,
    VolumeDeletionReceipt, VolumeMountRequest, VolumeMountSelection, VolumeProvisionPresence,
    VolumeProvisionReceipt, VolumeStagingAbortPresence, VolumeStagingAbortReceipt, VOLUME_MOUNTS,
};

/// Read-only staging result. Absence is an observation, not quiescence or
/// permission to release a reservation. Staged evidence comes only from matching
/// protected intent/completion records and descriptor-verified current backing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VolumeStagingPresence {
    Absent,
    Unverified,
    Staged(Box<VolumeStagingReceipt>),
}

/// Evidence for fresh 0700 backing only, not public volume readiness. Future
/// operations must match protected native records; supplied fields alone cannot
/// authorize an existing directory. Never infer isolated guest write access.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeStagingReceipt {
    pub schema: u8,
    pub target_id: String,
    pub domain_generation: String,
    pub policy: LocalVolumePolicy,
    pub intent: LocalVolumeIntent,
    pub owner_token: String,
    pub root_device: u64,
    pub root_inode: u64,
    pub device: u64,
    pub inode: u64,
    pub mode: u32,
}
impl std::fmt::Debug for VolumeStagingReceipt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VolumeStagingReceipt")
            .field("schema", &self.schema)
            .field("mode", &self.mode)
            .finish_non_exhaustive()
    }
}
impl VolumeStagingReceipt {
    pub fn validate(&self) -> Result<()> {
        self.policy.validate()?;
        self.intent.validate()?;
        if self.schema != 1
            || !crate::domain::valid_id(&self.target_id)
            || !crate::domain::valid_hex(&self.domain_generation, 32)
            || !crate::domain::valid_hex(&self.owner_token, 64)
            || self.root_inode == 0
            || self.inode == 0
            || self.device != self.root_device
            || self.mode != 0o700
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    schema: u8,
    target_id: String,
    domain_generation: String,
    policy: LocalVolumePolicy,
    intent: LocalVolumeIntent,
    owner_token: String,
    root_device: u64,
    root_inode: u64,
}

impl Engine {
    /// Observe protected staging evidence without repair, replay, adoption,
    /// initialization or synchronization writes. Available under work quarantine.
    pub fn inspect_volume_staging(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        budget: &ReadBudget,
    ) -> Result<VolumeStagingPresence> {
        budget.check()?;
        policy.validate()?;
        intent.validate()?;
        if !cfg!(target_os = "linux") {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let job = self
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())?;
        self.domain.verify()?;
        let expected = LocalVolumePolicy::canonical_sdk_root()?;
        let mut root = QualifiedVolumeRoot::open(policy, &expected, budget)?;
        root._lease = Some(job);
        let gate = self.observation_gate(&format!("volume:{}", intent.worker_volume_id))?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let result = observe(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            budget,
        )?;
        self.domain.verify()?;
        root.verify(budget)?;
        Ok(result)
    }

    /// Prepare fresh private backing with durable intent/completion evidence.
    /// This is not Backend.provision_volume and does not enable local volumes.
    /// A later qualified access transition must make backing guest-writable.
    pub fn stage_volume(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        budget: &ReadBudget,
    ) -> Result<VolumeStagingReceipt> {
        budget.check()?;
        intent.validate()?;
        let root = self.qualify_volume_root(policy, budget)?;
        let gate = self.gate(&format!("volume:{}", intent.worker_volume_id))?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.domain.verify()?;
        let receipt = stage(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            budget,
        )?;
        self.domain
            .verify()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(receipt)
    }
}

fn observe(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    intent: &LocalVolumeIntent,
    budget: &ReadBudget,
) -> Result<VolumeStagingPresence> {
    intent.validate()?;
    root.verify(budget)?;
    let id = cstring(&intent.worker_volume_id)?;
    let Some(ledger) = existing_ledger(domain)? else {
        let result = absence(&root.directory, &id)?;
        root.verify(budget)?;
        return Ok(result);
    };
    let entry: Option<Entry> = read_record(
        &ledger,
        &cstring(&format!("{}.intent.json", intent.worker_volume_id))?,
        budget,
    )?;
    let receipt: Option<VolumeStagingReceipt> = read_record(
        &ledger,
        &cstring(&format!("{}.staged.json", intent.worker_volume_id))?,
        budget,
    )?;
    let result = match (entry, receipt) {
        (None, None) => absence(&root.directory, &id)?,
        (Some(entry), Some(receipt)) => {
            receipt.validate()?;
            if !matches!(entry.schema, 1 | 2)
                || entry.target_id != binding.target_id
                || entry.domain_generation != binding.generation
                || entry.policy != root.policy
                || entry.intent != *intent
                || (entry.root_device, entry.root_inode) != root.identity
                || receipt.target_id != entry.target_id
                || receipt.domain_generation != entry.domain_generation
                || receipt.policy != entry.policy
                || receipt.intent != entry.intent
                || receipt.owner_token != entry.owner_token
                || (receipt.root_device, receipt.root_inode) != root.identity
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if entry.schema == 2 {
                let prepared: Option<VolumeStagingReceipt> = read_record(
                    &ledger,
                    &cstring(&format!("{}.backing.json", intent.worker_volume_id))?,
                    budget,
                )?;
                if prepared.as_ref() != Some(&receipt) {
                    return Err(Error::before(ErrorCode::Ownership));
                }
            }
            if absence(&root.directory, &id)? == VolumeStagingPresence::Absent {
                VolumeStagingPresence::Unverified
            } else {
                let child = open_directory(&root.directory, &id)?;
                let metadata = child
                    .metadata()
                    .map_err(|_| Error::before(ErrorCode::Ownership))?;
                if (metadata.dev(), metadata.ino()) != (receipt.device, receipt.inode)
                    || metadata.uid() != unsafe { libc::geteuid() }
                    || metadata.mode() & 0o7777 != receipt.mode
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                VolumeStagingPresence::Staged(Box::new(receipt))
            }
        }
        _ => VolumeStagingPresence::Unverified,
    };
    ledger.verify()?;
    root.verify(budget)?;
    Ok(result)
}

fn absence(parent: &File, name: &CString) -> Result<VolumeStagingPresence> {
    match require_absent(parent, name) {
        Ok(()) => Ok(VolumeStagingPresence::Absent),
        Err(error) if error.code == ErrorCode::Conflict => Ok(VolumeStagingPresence::Unverified),
        Err(error) => Err(error),
    }
}

fn existing_ledger(domain: &std::path::Path) -> Result<Option<PrivateLedger>> {
    crate::host::unredirected(domain)?;
    let parent =
        std::fs::symlink_metadata(domain).map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !parent.is_dir()
        || parent.uid() != unsafe { libc::geteuid() }
        || parent.mode() & 0o7777 != 0o700
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let path = domain.join("volume-staging");
    let directory = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(&path)
    {
        Ok(directory) => directory,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Error::before(ErrorCode::Ownership)),
    };
    let metadata = directory
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    let ledger = PrivateLedger {
        directory,
        path,
        identity: (metadata.dev(), metadata.ino()),
    };
    ledger.verify()?;
    Ok(Some(ledger))
}

fn read_record<T: serde::de::DeserializeOwned>(
    ledger: &PrivateLedger,
    name: &CString,
    budget: &ReadBudget,
) -> Result<Option<T>> {
    budget.check()?;
    ledger.verify()?;
    let Some(mut file) = open_record(ledger, name)? else {
        return Ok(None);
    };
    let metadata = file
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    validate_record(&metadata)?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    Read::by_ref(&mut file)
        .take(MAX_RECORD_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    budget.check()?;
    let after = file
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if bytes.len() as u64 != metadata.len() || !same_record(&metadata, &after) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    drop(file);
    let current = open_record(ledger, name)?.ok_or(Error::before(ErrorCode::Ownership))?;
    let current = current
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !same_record(&metadata, &current) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    ledger.verify()?;
    budget.check()?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| Error::before(ErrorCode::Ownership))
}

fn open_record(ledger: &PrivateLedger, name: &CString) -> Result<Option<File>> {
    let fd = unsafe {
        libc::openat(
            ledger.directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        if std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(Some(unsafe { File::from_raw_fd(fd) }))
}

fn validate_record(metadata: &std::fs::Metadata) -> Result<()> {
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
        || metadata.mode() & 0o7777 != 0o600
        || metadata.len() == 0
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    if metadata.len() > MAX_RECORD_BYTES as u64 {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    Ok(())
}

fn same_record(before: &std::fs::Metadata, after: &std::fs::Metadata) -> bool {
    after.is_file()
        && before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.uid() == after.uid()
        && before.nlink() == after.nlink()
        && before.mode() == after.mode()
        && before.len() == after.len()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}

fn stage(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    intent: &LocalVolumeIntent,
    budget: &ReadBudget,
) -> Result<VolumeStagingReceipt> {
    intent.validate()?;
    if !crate::domain::valid_id(&binding.target_id)
        || !crate::domain::valid_hex(&binding.generation, 32)
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    root.verify(budget)?;
    let id = cstring(&intent.worker_volume_id)?;
    let temporary = temporary_name(intent)?;
    require_absent(&root.directory, &id)?;
    require_absent(&root.directory, &temporary)?;
    let ledger = ledger(domain)?;
    let intent_name = cstring(&format!("{}.intent.json", intent.worker_volume_id))?;
    let completion_name = cstring(&format!("{}.staged.json", intent.worker_volume_id))?;
    let backing_name = cstring(&format!("{}.backing.json", intent.worker_volume_id))?;
    require_absent(&ledger.directory, &intent_name)?;
    require_absent(&ledger.directory, &completion_name)?;
    require_absent(&ledger.directory, &backing_name)?;
    let mut token = [0; 32];
    getrandom::fill(&mut token).map_err(|_| Error::before(ErrorCode::Native))?;
    let entry = Entry {
        schema: 2,
        target_id: binding.target_id.clone(),
        domain_generation: binding.generation.clone(),
        policy: root.policy.clone(),
        intent: intent.clone(),
        owner_token: hex::encode(token),
        root_device: root.identity.0,
        root_inode: root.identity.1,
    };
    // No child mutation before this publication. If publication is uncertain,
    // retain it and refuse replay; never delete evidence on timeout/error.
    root.verify(budget)?;
    publish(&ledger, &intent_name, &entry)?;
    let mutate = || -> Result<VolumeStagingReceipt> {
        ledger.verify()?;
        root.verify(budget)?;
        if unsafe { libc::mkdirat(root.directory.as_raw_fd(), temporary.as_ptr(), 0o700) } != 0 {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let child = open_directory(&root.directory, &temporary)?;
        let original = child.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if original.uid() != unsafe { libc::geteuid() }
            || original.dev() != root.identity.0
            || !original.is_dir()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // mkdir respects the process umask. Correct only the newly created,
        // descriptor-bound directory; existing directories are never chmodded.
        if unsafe { libc::fchmod(child.as_raw_fd(), 0o700) } != 0 {
            return Err(Error::before(ErrorCode::Io));
        }
        child.sync_all().map_err(|_| Error::before(ErrorCode::Io))?;
        root.directory
            .sync_all()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        root.verify(budget)?;
        let observed = open_directory(&root.directory, &temporary)?;
        let metadata = observed
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if (metadata.dev(), metadata.ino()) != (original.dev(), original.ino())
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o7777 != 0o700
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        drop(observed);
        let receipt = VolumeStagingReceipt {
            schema: 1,
            target_id: entry.target_id.clone(),
            domain_generation: entry.domain_generation.clone(),
            policy: entry.policy.clone(),
            intent: entry.intent.clone(),
            owner_token: entry.owner_token.clone(),
            root_device: entry.root_device,
            root_inode: entry.root_inode,
            device: metadata.dev(),
            inode: metadata.ino(),
            mode: 0o700,
        };
        receipt.validate()?;
        root.verify(budget)?;
        // Capture exact backing identity before publishing the SDK-visible
        // name. No successful public rename can lack this protected evidence.
        publish(&ledger, &backing_name, &receipt)?;
        root.verify(budget)?;
        publish_directory(&root.directory, &temporary, &id)?;
        root.directory
            .sync_all()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        root.verify(budget)?;
        let current = open_directory(&root.directory, &id)?;
        let metadata = current
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if (metadata.dev(), metadata.ino()) != (receipt.device, receipt.inode)
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o7777 != receipt.mode
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        drop(current);
        publish(&ledger, &completion_name, &receipt)?;
        root.verify(budget)?;
        require_absent(&root.directory, &temporary)?;
        ledger.verify()?;
        Ok(receipt)
    };
    mutate().map_err(|error| Error::uncertain(error.code))
}

fn temporary_name(intent: &LocalVolumeIntent) -> Result<CString> {
    intent.validate()?;
    cstring(&format!(".stage-{}", intent.worker_volume_id))
}

fn publish_directory(parent: &File, source: &CString, target: &CString) -> Result<()> {
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            parent.as_raw_fd(),
            source.as_ptr(),
            parent.as_raw_fd(),
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let result = unsafe {
        libc::renameatx_np(
            parent.as_raw_fd(),
            source.as_ptr(),
            parent.as_raw_fd(),
            target.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        let code = if error.kind() == std::io::ErrorKind::AlreadyExists {
            ErrorCode::Conflict
        } else if matches!(
            error.raw_os_error(),
            Some(libc::ENOSYS | libc::EINVAL | libc::ENOTSUP)
        ) {
            ErrorCode::Unsupported
        } else {
            ErrorCode::Io
        };
        return Err(Error::before(code));
    }
    Ok(())
}

fn cstring(value: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error::before(ErrorCode::Validation))
}

fn require_absent(parent: &File, name: &CString) -> Result<()> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } == 0
    {
        return Err(Error::before(ErrorCode::Conflict));
    }
    if std::io::Error::last_os_error().kind() != std::io::ErrorKind::NotFound {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

fn open_directory(parent: &File, name: &CString) -> Result<File> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY
                | libc::O_DIRECTORY
                | libc::O_NOFOLLOW
                | libc::O_CLOEXEC
                | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

struct PrivateLedger {
    directory: File,
    path: std::path::PathBuf,
    identity: (u64, u64),
}
impl PrivateLedger {
    fn verify(&self) -> Result<()> {
        crate::host::unredirected(&self.path)?;
        let path = std::fs::symlink_metadata(&self.path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let descriptor = self
            .directory
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        for metadata in [path, descriptor] {
            if !metadata.is_dir()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.mode() & 0o7777 != 0o700
                || (metadata.dev(), metadata.ino()) != self.identity
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
}

fn ledger(domain: &std::path::Path) -> Result<PrivateLedger> {
    crate::host::unredirected(domain)?;
    let parent = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(domain)
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    let metadata = parent
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o7777 != 0o700 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let name = cstring("volume-staging")?;
    let created = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } == 0;
    if !created && std::io::Error::last_os_error().kind() != std::io::ErrorKind::AlreadyExists {
        return Err(Error::before(ErrorCode::Io));
    }
    let directory = open_directory(&parent, &name)?;
    if created && unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) } != 0 {
        return Err(Error::uncertain(ErrorCode::Io));
    }
    let metadata = directory
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o7777 != 0o700 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    directory
        .sync_all()
        .and_then(|()| parent.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let ledger = PrivateLedger {
        directory,
        path: domain.join("volume-staging"),
        identity: (metadata.dev(), metadata.ino()),
    };
    ledger.verify()?;
    Ok(ledger)
}

fn publish(parent: &PrivateLedger, name: &CString, value: &impl Serialize) -> Result<()> {
    parent.verify()?;
    let bytes = serde_json::to_vec(value).map_err(|_| Error::before(ErrorCode::Native))?;
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    let fd = unsafe {
        libc::openat(
            parent.directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(Error::before(ErrorCode::Conflict));
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    if unsafe { libc::fchmod(file.as_raw_fd(), 0o600) } != 0 {
        return Err(Error::uncertain(ErrorCode::Io));
    }
    file.write_all(&bytes)
        .and_then(|()| file.sync_all())
        .and_then(|()| parent.directory.sync_all())
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let metadata = file
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
        || metadata.mode() & 0o7777 != 0o600
        || metadata.len() != bytes.len() as u64
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    drop(file);
    // Reopen the published name after closing the writer so the descriptor
    // budget remains bounded. A replaced path cannot become completion evidence.
    let fd = unsafe {
        libc::openat(
            parent.directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    let published = unsafe { File::from_raw_fd(fd) };
    let current = published
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
    if !current.is_file()
        || (current.dev(), current.ino()) != (metadata.dev(), metadata.ino())
        || current.uid() != metadata.uid()
        || current.nlink() != 1
        || current.mode() & 0o7777 != 0o600
        || current.len() != metadata.len()
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    parent
        .verify()
        .map_err(|error| Error::uncertain(error.code))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    struct Fixture {
        _directory: tempfile::TempDir,
        root: QualifiedVolumeRoot,
        binding: DomainBinding,
        domain: std::path::PathBuf,
        intent: LocalVolumeIntent,
    }
    fn fixture() -> Fixture {
        let (directory, policy) = super::super::tests::fixture();
        let domain = std::fs::canonicalize(directory.path())
            .unwrap()
            .join("private");
        std::fs::create_dir(&domain).unwrap();
        std::fs::set_permissions(&domain, std::fs::Permissions::from_mode(0o700)).unwrap();
        let root = QualifiedVolumeRoot::open(&policy, &policy.root, &super::super::tests::budget())
            .unwrap();
        Fixture {
            _directory: directory,
            root,
            binding: DomainBinding {
                target_id: "worker".into(),
                generation: "a".repeat(32),
                database: domain.join("db"),
                vm_root: domain.join("vms"),
            },
            domain,
            intent: LocalVolumeIntent {
                worker_volume_id: format!("sbv-{}", "b".repeat(32)),
                size_gb: 2,
            },
        }
    }
    fn run(f: &Fixture) -> Result<VolumeStagingReceipt> {
        stage(
            &f.root,
            &f.binding,
            &f.domain,
            &f.intent,
            &super::super::tests::budget(),
        )
    }

    #[test]
    fn fresh_backing_publishes_bound_private_intent_and_completion_before_return() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        receipt.validate().unwrap();
        let path = f.root.policy.root.join(&f.intent.worker_volume_id);
        let metadata = std::fs::metadata(path).unwrap();
        assert_eq!(
            (receipt.device, receipt.inode),
            (metadata.dev(), metadata.ino())
        );
        assert_eq!(metadata.mode() & 0o7777, 0o700);
        assert_eq!(receipt.intent, f.intent);
        assert_eq!(receipt.policy, f.root.policy);
        assert_eq!(receipt.target_id, f.binding.target_id);
        assert_eq!(receipt.domain_generation, f.binding.generation);
        let ledger = f.domain.join("volume-staging");
        assert_eq!(std::fs::metadata(&ledger).unwrap().mode() & 0o7777, 0o700);
        let intent_path = ledger.join(format!("{}.intent.json", f.intent.worker_volume_id));
        let completion_path = ledger.join(format!("{}.staged.json", f.intent.worker_volume_id));
        for path in [&intent_path, &completion_path] {
            let metadata = std::fs::metadata(path).unwrap();
            assert_eq!(metadata.mode() & 0o7777, 0o600);
            assert_eq!(metadata.nlink(), 1);
        }
        let entry: Entry = serde_json::from_slice(&std::fs::read(intent_path).unwrap()).unwrap();
        let stored: VolumeStagingReceipt =
            serde_json::from_slice(&std::fs::read(completion_path).unwrap()).unwrap();
        assert_eq!(stored, receipt);
        let prepared: VolumeStagingReceipt = serde_json::from_slice(
            &std::fs::read(ledger.join(format!("{}.backing.json", f.intent.worker_volume_id)))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(prepared, receipt);
        assert_eq!(entry.schema, 2);
        assert!(!f
            .root
            .policy
            .root
            .join(temporary_name(&f.intent).unwrap().to_str().unwrap())
            .exists());
        assert_eq!(entry.owner_token, receipt.owner_token);
        assert_eq!(entry.intent, receipt.intent);
        assert_eq!((entry.root_device, entry.root_inode), f.root.identity);
        let debug = format!("{receipt:?}");
        assert!(!debug.contains(&receipt.owner_token));
        assert!(!debug.contains(&f.intent.worker_volume_id));
        assert!(!debug.contains(f.root.policy.root.to_str().unwrap()));
    }

    #[test]
    fn duplicate_attempt_cannot_replay_or_change_existing_files() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        let file = f
            .root
            .policy
            .root
            .join(&f.intent.worker_volume_id)
            .join("keep");
        std::fs::write(&file, b"retained").unwrap();
        let error = run(&f).unwrap_err();
        assert_eq!(error.code, ErrorCode::Conflict);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(std::fs::read(file).unwrap(), b"retained");
        assert_eq!(
            std::fs::read_dir(f.domain.join("volume-staging"))
                .unwrap()
                .count(),
            3
        );
        receipt.validate().unwrap();
    }

    #[test]
    fn foreign_directory_file_or_link_is_not_adopted_or_chmodded() {
        for kind in ["directory", "file", "symlink"] {
            let f = fixture();
            let path = f.root.policy.root.join(&f.intent.worker_volume_id);
            match kind {
                "directory" => {
                    std::fs::create_dir(&path).unwrap();
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
                        .unwrap();
                }
                "file" => std::fs::write(&path, b"foreign").unwrap(),
                _ => symlink(&f.domain, &path).unwrap(),
            }
            let before = std::fs::symlink_metadata(&path).unwrap();
            assert_eq!(run(&f).unwrap_err().code, ErrorCode::Conflict);
            let after = std::fs::symlink_metadata(&path).unwrap();
            assert_eq!(
                (before.dev(), before.ino(), before.mode()),
                (after.dev(), after.ino(), after.mode())
            );
            assert!(!f.domain.join("volume-staging").exists());
        }
    }

    #[test]
    fn incomplete_intent_model_blocks_dispatch_without_inventing_completion() {
        let f = fixture();
        let private = ledger(&f.domain).unwrap();
        let name = cstring(&format!("{}.intent.json", f.intent.worker_volume_id)).unwrap();
        publish(&private, &name, &serde_json::json!({"incomplete": true})).unwrap();
        assert_eq!(run(&f).unwrap_err().code, ErrorCode::Conflict);
        assert!(!f.root.policy.root.join(&f.intent.worker_volume_id).exists());
        assert_eq!(
            std::fs::read_dir(f.domain.join("volume-staging"))
                .unwrap()
                .count(),
            1
        );
    }

    #[test]
    fn unsafe_or_linked_private_ledger_cannot_authorize_mutation() {
        let f = fixture();
        let path = f.domain.join("volume-staging");
        symlink(&f.root.policy.root, &path).unwrap();
        assert_eq!(run(&f).unwrap_err().code, ErrorCode::Ownership);
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert_eq!(run(&f).unwrap_err().code, ErrorCode::Ownership);
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o7777, 0o777);
        assert!(!f.root.policy.root.join(&f.intent.worker_volume_id).exists());
    }

    #[test]
    fn cancellation_before_intent_has_no_volume_or_journal_effect() {
        let f = fixture();
        let cancel = crate::Cancellation::default();
        cancel.cancel();
        let budget = ReadBudget::new(std::time::Duration::from_secs(2), cancel).unwrap();
        assert_eq!(
            stage(&f.root, &f.binding, &f.domain, &f.intent, &budget)
                .unwrap_err()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        assert!(!f.domain.join("volume-staging").exists());
        assert!(!f.root.policy.root.join(&f.intent.worker_volume_id).exists());
    }

    #[test]
    fn receipt_validation_rejects_unqualified_permissions_and_cross_device_material() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        let mut changed = receipt.clone();
        changed.mode = 0o777;
        assert!(changed.validate().is_err());
        changed = receipt.clone();
        changed.device = changed.root_device.wrapping_add(1);
        assert!(changed.validate().is_err());
        changed = receipt;
        changed.owner_token = "not-evidence".into();
        assert!(changed.validate().is_err());
    }

    #[test]
    fn replaced_ledger_model_cannot_publish_to_either_directory() {
        let f = fixture();
        let private = ledger(&f.domain).unwrap();
        let original = private.path.with_extension("original");
        std::fs::rename(&private.path, &original).unwrap();
        std::fs::create_dir(&private.path).unwrap();
        std::fs::set_permissions(&private.path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let name = cstring("proof.json").unwrap();
        assert_eq!(
            publish(&private, &name, &serde_json::json!({"value": 1}))
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(std::fs::read_dir(&original).unwrap().count(), 0);
        assert_eq!(std::fs::read_dir(&private.path).unwrap().count(), 0);
    }

    fn inspect(f: &Fixture) -> Result<VolumeStagingPresence> {
        observe(
            &f.root,
            &f.binding,
            &f.domain,
            &f.intent,
            &super::super::tests::budget(),
        )
    }
    fn record_path(f: &Fixture, kind: &str) -> std::path::PathBuf {
        f.domain
            .join("volume-staging")
            .join(format!("{}.{kind}.json", f.intent.worker_volume_id))
    }
    fn rewrite_completion(f: &Fixture, receipt: &VolumeStagingReceipt) {
        std::fs::write(
            record_path(f, "staged"),
            serde_json::to_vec(receipt).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn staging_observation_proves_absence_without_initializing_or_adopting_inventory() {
        let f = fixture();
        assert_eq!(inspect(&f).unwrap(), VolumeStagingPresence::Absent);
        assert!(!f.domain.join("volume-staging").exists());
        let foreign = f.root.policy.root.join(&f.intent.worker_volume_id);
        std::fs::create_dir(&foreign).unwrap();
        std::fs::write(foreign.join("keep"), b"unrelated").unwrap();
        let before = std::fs::metadata(&foreign).unwrap();
        assert_eq!(inspect(&f).unwrap(), VolumeStagingPresence::Unverified);
        let after = std::fs::metadata(&foreign).unwrap();
        assert_eq!(
            (before.dev(), before.ino(), before.mode()),
            (after.dev(), after.ino(), after.mode())
        );
        assert_eq!(std::fs::read(foreign.join("keep")).unwrap(), b"unrelated");
        assert!(!f.domain.join("volume-staging").exists());
    }

    #[test]
    fn staging_observation_matches_protected_completion_without_rewriting_records() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        let paths = [record_path(&f, "intent"), record_path(&f, "staged")];
        let before = paths
            .iter()
            .map(|path| {
                (
                    std::fs::read(path).unwrap(),
                    std::fs::metadata(path).unwrap(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            inspect(&f).unwrap(),
            VolumeStagingPresence::Staged(Box::new(receipt))
        );
        for (path, (bytes, metadata)) in paths.iter().zip(before) {
            assert_eq!(std::fs::read(path).unwrap(), bytes);
            assert!(same_record(&metadata, &std::fs::metadata(path).unwrap()));
        }
        assert_eq!(
            std::fs::read_dir(f.domain.join("volume-staging"))
                .unwrap()
                .count(),
            3
        );
    }

    #[test]
    fn missing_proof_models_stay_unverified_without_repair_or_absence() {
        // Static non-VM fixtures model missing evidence; no live writer or
        // persistence interruption is involved.
        for missing in ["intent", "staged", "child"] {
            let f = fixture();
            run(&f).unwrap();
            if missing == "child" {
                std::fs::remove_dir(f.root.policy.root.join(&f.intent.worker_volume_id)).unwrap();
            } else {
                std::fs::remove_file(record_path(&f, missing)).unwrap();
            }
            assert_eq!(inspect(&f).unwrap(), VolumeStagingPresence::Unverified);
            assert_eq!(
                std::fs::read_dir(f.domain.join("volume-staging"))
                    .unwrap()
                    .count(),
                if missing == "child" { 3 } else { 2 }
            );
        }
    }

    #[test]
    fn mismatched_completion_cannot_supply_ownership_from_current_backing() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        let variants = [
            VolumeStagingReceipt {
                target_id: "other".into(),
                ..receipt.clone()
            },
            VolumeStagingReceipt {
                domain_generation: "c".repeat(32),
                ..receipt.clone()
            },
            VolumeStagingReceipt {
                owner_token: "d".repeat(64),
                ..receipt.clone()
            },
            VolumeStagingReceipt {
                root_inode: receipt.root_inode + 1,
                ..receipt.clone()
            },
            VolumeStagingReceipt {
                inode: receipt.inode + 1,
                ..receipt.clone()
            },
            VolumeStagingReceipt {
                intent: LocalVolumeIntent {
                    size_gb: 3,
                    ..receipt.intent.clone()
                },
                ..receipt.clone()
            },
            VolumeStagingReceipt {
                policy: LocalVolumePolicy {
                    id: "other".into(),
                    ..receipt.policy.clone()
                },
                ..receipt.clone()
            },
        ];
        for changed in variants {
            rewrite_completion(&f, &changed);
            assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
            assert_eq!(
                std::fs::read(record_path(&f, "staged")).unwrap(),
                serde_json::to_vec(&changed).unwrap()
            );
        }
        rewrite_completion(&f, &receipt);
        let mut changed_intent = f.intent.clone();
        changed_intent.size_gb += 1;
        assert_eq!(
            observe(
                &f.root,
                &f.binding,
                &f.domain,
                &changed_intent,
                &super::super::tests::budget()
            )
            .unwrap_err()
            .code,
            ErrorCode::Ownership
        );
    }

    #[test]
    fn substituted_backing_and_changed_permissions_do_not_rebind_receipt() {
        let f = fixture();
        run(&f).unwrap();
        let child = f.root.policy.root.join(&f.intent.worker_volume_id);
        std::fs::set_permissions(&child, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
        assert_eq!(std::fs::metadata(&child).unwrap().mode() & 0o7777, 0o777);
        std::fs::set_permissions(&child, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::rename(&child, child.with_extension("original")).unwrap();
        std::fs::create_dir(&child).unwrap();
        std::fs::set_permissions(&child, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(child.join("foreign"), b"preserve").unwrap();
        assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
        assert_eq!(std::fs::read(child.join("foreign")).unwrap(), b"preserve");
    }

    #[test]
    fn protected_record_reader_rejects_links_extra_links_and_unsafe_modes() {
        for invalid in ["symlink", "hardlink", "mode", "directory", "fifo"] {
            let f = fixture();
            run(&f).unwrap();
            let path = record_path(&f, "staged");
            match invalid {
                "symlink" => {
                    std::fs::remove_file(&path).unwrap();
                    symlink(record_path(&f, "intent"), &path).unwrap();
                }
                "hardlink" => std::fs::hard_link(&path, path.with_extension("linked")).unwrap(),
                "fifo" => {
                    std::fs::remove_file(&path).unwrap();
                    let name = cstring(path.to_str().unwrap()).unwrap();
                    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
                }
                "mode" => {
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap()
                }
                _ => {
                    std::fs::remove_file(&path).unwrap();
                    std::fs::create_dir(&path).unwrap();
                }
            }
            assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
        }
    }

    #[test]
    fn protected_record_reader_bounds_input_and_rejects_malformed_or_extra_fields() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        let path = record_path(&f, "staged");
        for bytes in [Vec::new(), b"not-json".to_vec(), b"{}".to_vec()] {
            std::fs::write(&path, bytes).unwrap();
            assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
        }
        std::fs::write(&path, vec![b' '; MAX_RECORD_BYTES + 1]).unwrap();
        assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::OutputLimit);
        let mut extra = serde_json::to_value(receipt).unwrap();
        extra["adopt"] = serde_json::Value::Bool(true);
        std::fs::write(&path, serde_json::to_vec(&extra).unwrap()).unwrap();
        assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
    }

    #[test]
    fn observation_cancellation_keeps_records_and_backing_unchanged() {
        let f = fixture();
        run(&f).unwrap();
        let cancel = crate::Cancellation::default();
        cancel.cancel();
        let budget = ReadBudget::new(std::time::Duration::from_secs(2), cancel).unwrap();
        let error = observe(&f.root, &f.binding, &f.domain, &f.intent, &budget).unwrap_err();
        assert_eq!(error.code, ErrorCode::State);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(f.root.policy.root.join(&f.intent.worker_volume_id).is_dir());
        assert_eq!(
            std::fs::read_dir(f.domain.join("volume-staging"))
                .unwrap()
                .count(),
            3
        );
    }

    #[test]
    fn volume_observation_admission_survives_work_quarantine_and_charges_metadata() {
        let pool = crate::jobs::JobPool::default();
        pool.quarantine();
        assert!(pool.acquire(crate::jobs::Demand::volume_root()).is_err());
        let observation = pool
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        assert_eq!(pool.counts().work, 0);
        assert_eq!(pool.counts().control, 1);
        assert_eq!(pool.counts().descriptors, 4);
        assert_eq!(pool.counts().metadata, 128 * 1024);
        drop(observation);
        assert_eq!(pool.counts().control, 0);
        assert_eq!(pool.counts().metadata, 0);
    }

    fn provision_run(f: &Fixture) -> Option<VolumeProvisionReceipt> {
        match VolumeAccount::current() {
            Ok(account) => Some(
                access::provision(
                    &f.root,
                    &f.binding,
                    &f.domain,
                    &f.intent,
                    account,
                    &super::super::tests::budget(),
                )
                .unwrap(),
            ),
            Err(error) => {
                // Privileged test runners assert rejection before filesystem
                // entry; ordinary same-account fixtures run unprivileged.
                assert_eq!(error.code, ErrorCode::Unsupported);
                assert!(!f.domain.join("volume-staging").exists());
                assert!(!f.root.policy.root.join(&f.intent.worker_volume_id).exists());
                None
            }
        }
    }
    fn inspect_provision(f: &Fixture) -> Result<VolumeProvisionPresence> {
        access::inspect(
            &f.root,
            &f.binding,
            &f.domain,
            &f.intent,
            &super::super::tests::budget(),
        )
    }

    #[test]
    fn provision_binds_same_account_backing_without_permission_widening() {
        let f = fixture();
        let Some(receipt) = provision_run(&f) else {
            return;
        };
        receipt.validate().unwrap();
        assert_eq!(receipt.account, VolumeAccount::current().unwrap());
        assert_eq!(
            receipt.node_path(),
            f.root.policy.root.join(&f.intent.worker_volume_id)
        );
        assert_eq!(
            std::fs::metadata(receipt.node_path()).unwrap().mode() & 0o7777,
            0o700
        );
        std::fs::write(receipt.node_path().join("retained"), b"first").unwrap();
        assert_eq!(
            std::fs::read(receipt.node_path().join("retained")).unwrap(),
            b"first"
        );
        std::fs::write(receipt.node_path().join("retained"), b"second").unwrap();
        assert_eq!(
            inspect_provision(&f).unwrap(),
            VolumeProvisionPresence::Provisioned(Box::new(receipt.clone()))
        );
        let path = record_path(&f, "provisioned");
        let bytes = std::fs::read(&path).unwrap();
        let before = std::fs::metadata(&path).unwrap();
        assert_eq!(before.mode() & 0o7777, 0o600);
        inspect_provision(&f).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        assert!(same_record(&before, &std::fs::metadata(&path).unwrap()));
        assert!(!format!("{receipt:?}").contains(&receipt.backing.owner_token));
    }

    #[test]
    fn staged_backing_without_account_completion_cannot_be_promoted_by_observation() {
        let f = fixture();
        assert_eq!(
            inspect_provision(&f).unwrap(),
            VolumeProvisionPresence::Absent
        );
        assert!(!f.domain.join("volume-staging").exists());
        run(&f).unwrap();
        assert_eq!(
            inspect_provision(&f).unwrap(),
            VolumeProvisionPresence::Unverified
        );
        assert!(!record_path(&f, "provisioned").exists());
        assert_eq!(
            std::fs::metadata(f.root.policy.root.join(&f.intent.worker_volume_id))
                .unwrap()
                .mode()
                & 0o7777,
            0o700
        );
    }

    #[test]
    fn provision_duplicate_retains_original_records_and_data() {
        let f = fixture();
        let Some(receipt) = provision_run(&f) else {
            return;
        };
        std::fs::write(receipt.node_path().join("keep"), b"retained").unwrap();
        let error = access::provision(
            &f.root,
            &f.binding,
            &f.domain,
            &f.intent,
            receipt.account,
            &super::super::tests::budget(),
        )
        .unwrap_err();
        assert_eq!(error.code, ErrorCode::Conflict);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(
            std::fs::read(receipt.node_path().join("keep")).unwrap(),
            b"retained"
        );
        assert_eq!(
            std::fs::read_dir(f.domain.join("volume-staging"))
                .unwrap()
                .count(),
            4
        );
    }

    #[test]
    fn mismatched_account_or_backing_cannot_supply_provision_authority() {
        let f = fixture();
        let Some(receipt) = provision_run(&f) else {
            return;
        };
        for changed in [
            VolumeProvisionReceipt {
                account: VolumeAccount {
                    uid: receipt.account.uid + 1,
                    ..receipt.account
                },
                ..receipt.clone()
            },
            VolumeProvisionReceipt {
                account: VolumeAccount {
                    gid: receipt.account.gid + 1,
                    ..receipt.account
                },
                ..receipt.clone()
            },
            VolumeProvisionReceipt {
                backing: VolumeStagingReceipt {
                    owner_token: "f".repeat(64),
                    ..receipt.backing.clone()
                },
                ..receipt.clone()
            },
        ] {
            std::fs::write(
                record_path(&f, "provisioned"),
                serde_json::to_vec(&changed).unwrap(),
            )
            .unwrap();
            assert_eq!(
                inspect_provision(&f).unwrap_err().code,
                ErrorCode::Ownership
            );
        }
    }

    #[test]
    fn orphan_completion_model_cannot_be_absence_or_adoption_evidence() {
        let f = fixture();
        let Some(receipt) = provision_run(&f) else {
            return;
        };
        // Static non-VM model: only an account completion record remains.
        std::fs::remove_file(record_path(&f, "intent")).unwrap();
        std::fs::remove_file(record_path(&f, "staged")).unwrap();
        std::fs::remove_file(record_path(&f, "backing")).unwrap();
        std::fs::remove_dir(receipt.node_path()).unwrap();
        assert_eq!(
            inspect_provision(&f).unwrap(),
            VolumeProvisionPresence::Unverified
        );
        assert_eq!(
            std::fs::read_dir(f.domain.join("volume-staging"))
                .unwrap()
                .count(),
            1
        );
    }

    #[test]
    fn provision_rejects_foreign_account_before_any_intent_or_child_mutation() {
        let f = fixture();
        let account = VolumeAccount {
            uid: unsafe { libc::geteuid() }.saturating_add(1),
            gid: unsafe { libc::getegid() },
        };
        let error = access::provision(
            &f.root,
            &f.binding,
            &f.domain,
            &f.intent,
            account,
            &super::super::tests::budget(),
        )
        .unwrap_err();
        assert!(matches!(
            error.code,
            ErrorCode::Ownership | ErrorCode::Unsupported
        ));
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(!f.domain.join("volume-staging").exists());
        assert!(!f.root.policy.root.join(&f.intent.worker_volume_id).exists());
    }

    #[test]
    fn directory_publication_never_replaces_even_an_empty_foreign_directory() {
        let (_dir, policy) = super::super::tests::fixture();
        let root = QualifiedVolumeRoot::open(&policy, &policy.root, &super::super::tests::budget())
            .unwrap();
        std::fs::create_dir(policy.root.join("source")).unwrap();
        std::fs::create_dir(policy.root.join("foreign")).unwrap();
        let before = std::fs::metadata(policy.root.join("foreign")).unwrap();
        assert_eq!(
            publish_directory(
                &root.directory,
                &cstring("source").unwrap(),
                &cstring("foreign").unwrap()
            )
            .unwrap_err()
            .code,
            ErrorCode::Conflict
        );
        let after = std::fs::metadata(policy.root.join("foreign")).unwrap();
        assert_eq!((before.dev(), before.ino()), (after.dev(), after.ino()));
        assert!(policy.root.join("source").is_dir());
    }

    #[test]
    fn prepared_publication_model_stays_unverified_and_cannot_replay() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        // Static non-VM model of prepared backing before public rename.
        let temporary = f
            .root
            .policy
            .root
            .join(temporary_name(&f.intent).unwrap().to_str().unwrap());
        std::fs::rename(
            f.root.policy.root.join(&f.intent.worker_volume_id),
            &temporary,
        )
        .unwrap();
        std::fs::remove_file(record_path(&f, "staged")).unwrap();
        assert_eq!(inspect(&f).unwrap(), VolumeStagingPresence::Unverified);
        assert_eq!(run(&f).unwrap_err().code, ErrorCode::Conflict);
        assert!(!f.root.policy.root.join(&f.intent.worker_volume_id).exists());
        let metadata = std::fs::metadata(temporary).unwrap();
        assert_eq!(
            (metadata.dev(), metadata.ino()),
            (receipt.device, receipt.inode)
        );
    }

    #[test]
    fn renamed_backing_without_final_stage_record_is_not_promoted_by_observation() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        std::fs::remove_file(record_path(&f, "staged")).unwrap();
        assert_eq!(inspect(&f).unwrap(), VolumeStagingPresence::Unverified);
        assert!(!record_path(&f, "staged").exists());
        let prepared: VolumeStagingReceipt =
            serde_json::from_slice(&std::fs::read(record_path(&f, "backing")).unwrap()).unwrap();
        assert_eq!(prepared, receipt);
    }

    #[test]
    fn new_publication_schema_requires_exact_prepared_backing_and_preserves_legacy_reader() {
        let f = fixture();
        let receipt = run(&f).unwrap();
        let path = record_path(&f, "backing");
        let changed = VolumeStagingReceipt {
            inode: receipt.inode + 1,
            ..receipt.clone()
        };
        std::fs::write(&path, serde_json::to_vec(&changed).unwrap()).unwrap();
        assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
        std::fs::remove_file(path).unwrap();
        assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
        let mut entry: Entry =
            serde_json::from_slice(&std::fs::read(record_path(&f, "intent")).unwrap()).unwrap();
        entry.schema = 1;
        std::fs::write(
            record_path(&f, "intent"),
            serde_json::to_vec(&entry).unwrap(),
        )
        .unwrap();
        assert_eq!(
            inspect(&f).unwrap(),
            VolumeStagingPresence::Staged(Box::new(receipt))
        );
    }
}
