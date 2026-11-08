//! Explicit owned-volume removal. Immutable private intent precedes unlink;
//! uncertain attempts retain records and cannot replay or infer completion from
//! missing backing. No CLI/server, guest boot, signals or permission widening.
use super::super::{
    cstring, existing_ledger, open_directory, publish, read_record, require_absent,
};
use super::{
    inspect, VolumeAccount, VolumeDeletionPermit, VolumeProvisionPresence, VolumeProvisionReceipt,
};
use crate::{
    DomainBinding, Engine, Error, ErrorCode, LocalVolumeIntent, LocalVolumePolicy,
    QualifiedVolumeRoot, ReadBudget, Result,
};
use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString};
use std::fs::File;
use std::os::fd::{AsRawFd, IntoRawFd};
use std::os::unix::fs::MetadataExt;

const MAX_ENTRIES: usize = crate::VOLUME_DELETE_ENTRIES;
const MAX_PATH_BYTES: usize = crate::VOLUME_ANCESTOR_BYTES;

#[path = "volume_abort.rs"]
mod abort;
pub use abort::{VolumeStagingAbortPresence, VolumeStagingAbortReceipt};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeDeletionReceipt {
    pub schema: u8,
    pub operation_id: String,
    pub provision: VolumeProvisionReceipt,
}
impl std::fmt::Debug for VolumeDeletionReceipt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VolumeDeletionReceipt")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl VolumeDeletionReceipt {
    pub fn validate(&self) -> Result<()> {
        self.provision.validate()?;
        if self.schema != 1 || !crate::domain::valid_hex(&self.operation_id, 32) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VolumeDeletionPresence {
    Unverified,
    Deleted(Box<VolumeDeletionReceipt>),
}

impl Engine {
    /// Resolve only after the host fences every prior writer/request. The
    /// declaration cannot override native work quarantine, gates, missing proof
    /// or a retained SDK attachment. Never called by observation or startup.
    pub fn resolve_volume_deletion(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<VolumeDeletionReceipt> {
        if !quiesced {
            return Err(Error::before(ErrorCode::Validation));
        }
        budget.check()?;
        policy.validate()?;
        intent.validate()?;
        if !cfg!(target_os = "linux") {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let job = self.jobs.acquire(crate::jobs::Demand::volume_delete())?;
        self.domain.verify()?;
        let mut root =
            QualifiedVolumeRoot::open(policy, &LocalVolumePolicy::canonical_sdk_root()?, budget)?;
        root._lease = Some(job);
        let gate = self.gate(&format!("volume:{}", intent.worker_volume_id))?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let result = resolve(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            budget,
            Resolution {
                quiesced,
                max_entries: MAX_ENTRIES,
            },
            || {
                self.domain.verify()?;
                if !crate::sdk_compat::volume_unattached(
                    &self.binding().database,
                    self.database_identity,
                    &policy.root.join(&intent.worker_volume_id),
                    budget,
                )? {
                    return Err(Error::before(ErrorCode::Conflict));
                }
                Ok(())
            },
        )?;
        self.domain
            .verify()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(result)
    }

    /// One explicit deletion attempt. Duplicate/uncertain attempts cannot replay;
    /// completed evidence is observed separately. Durable attachment exclusion
    /// and ordinary guest qualification still gate public feature activation.
    pub fn delete_volume(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        budget: &ReadBudget,
    ) -> Result<VolumeDeletionReceipt> {
        let permit = self.qualify_volume_deletion(policy, intent, budget)?;
        self.delete_prepared_volume(permit, budget)
    }

    pub fn delete_prepared_volume(
        &self,
        permit: VolumeDeletionPermit,
        budget: &ReadBudget,
    ) -> Result<VolumeDeletionReceipt> {
        budget.check()?;
        self.domain.verify()?;
        if permit.receipt.backing.target_id != self.binding().target_id
            || permit.receipt.backing.domain_generation != self.binding().generation
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let receipt = remove(
            &permit.root,
            self.binding(),
            &self.domain.directory,
            &permit.receipt,
            budget,
            MAX_ENTRIES,
            || {
                self.domain.verify()?;
                if !crate::sdk_compat::volume_unattached(
                    &self.binding().database,
                    self.database_identity,
                    &permit.receipt.node_path(),
                    budget,
                )? {
                    return Err(Error::before(ErrorCode::Conflict));
                }
                Ok(())
            },
        )?;
        self.domain
            .verify()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(receipt)
    }

    /// Protected completed deletion evidence plus present root/current absence.
    /// Missing backing or an entered intent alone cannot become completion.
    pub fn inspect_volume_deletion(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        budget: &ReadBudget,
    ) -> Result<VolumeDeletionPresence> {
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
        let mut root =
            QualifiedVolumeRoot::open(policy, &LocalVolumePolicy::canonical_sdk_root()?, budget)?;
        root._lease = Some(job);
        let gate = self.observation_gate(&format!("volume:{}", intent.worker_volume_id))?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let result = observe_deleted(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            budget,
        )?;
        self.domain.verify()?;
        Ok(result)
    }
}

pub(super) fn remove(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    provision: &VolumeProvisionReceipt,
    budget: &ReadBudget,
    max_entries: usize,
    attachment_guard: impl FnOnce() -> Result<()>,
) -> Result<VolumeDeletionReceipt> {
    budget.check()?;
    provision.validate()?;
    let intent = &provision.backing.intent;
    match inspect(root, binding, domain, intent, budget)? {
        VolumeProvisionPresence::Provisioned(current) if *current == *provision => {}
        _ => return Err(Error::before(ErrorCode::Ownership)),
    }
    let ledger = existing_ledger(domain)?.ok_or(Error::before(ErrorCode::Ownership))?;
    let entered = cstring(&format!("{}.delete-intent.json", intent.worker_volume_id))?;
    let completed = cstring(&format!("{}.deleted.json", intent.worker_volume_id))?;
    require_absent(&ledger.directory, &entered)?;
    require_absent(&ledger.directory, &completed)?;
    attachment_guard()?;
    root.verify(budget)?;
    let mut id = [0; 16];
    getrandom::fill(&mut id).map_err(|_| Error::before(ErrorCode::Native))?;
    let receipt = VolumeDeletionReceipt {
        schema: 1,
        operation_id: hex::encode(id),
        provision: provision.clone(),
    };
    receipt.validate()?;
    publish(&ledger, &entered, &receipt)?;
    finish_removal(root, &ledger, &receipt, budget, max_entries, false)
        .map_err(|error| Error::uncertain(error.code))?;
    Ok(receipt)
}

struct Resolution {
    quiesced: bool,
    max_entries: usize,
}

fn resolve(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    intent: &LocalVolumeIntent,
    budget: &ReadBudget,
    resolution: Resolution,
    attachment_guard: impl FnOnce() -> Result<()>,
) -> Result<VolumeDeletionReceipt> {
    if !resolution.quiesced {
        return Err(Error::before(ErrorCode::Validation));
    }
    budget.check()?;
    intent.validate()?;
    root.verify(budget)?;
    let ledger = existing_ledger(domain)?.ok_or(Error::before(ErrorCode::Ownership))?;
    let entered: Option<VolumeDeletionReceipt> = read_record(
        &ledger,
        &cstring(&format!("{}.delete-intent.json", intent.worker_volume_id))?,
        budget,
    )?;
    let Some(entered) = entered else {
        // A lost provisioning acknowledgment may still have protected completed
        // provisioning. Explicit fenced cleanup can start its first deletion;
        // staging/absence alone cannot supply that missing authority.
        return match inspect(root, binding, domain, intent, budget)? {
            VolumeProvisionPresence::Provisioned(provision) => remove(
                root,
                binding,
                domain,
                &provision,
                budget,
                resolution.max_entries,
                attachment_guard,
            ),
            _ => Err(Error::before(ErrorCode::Ownership)),
        };
    };
    verify_origin(root, binding, intent, &entered)?;
    let original: Option<VolumeProvisionReceipt> = read_record(
        &ledger,
        &cstring(&format!("{}.provisioned.json", intent.worker_volume_id))?,
        budget,
    )?;
    if original.as_ref() != Some(&entered.provision) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    attachment_guard()?;
    // A completed matching attempt needs no mutation or new evidence. Missing
    // completion remains unknown until this explicit fenced resolution finishes.
    if let VolumeDeletionPresence::Deleted(receipt) =
        observe_deleted(root, binding, domain, intent, budget)?
    {
        return Ok(*receipt);
    }
    let name = cstring(&intent.worker_volume_id)?;
    match require_absent(&root.directory, &name) {
        Ok(()) => {}
        Err(error) if error.code == ErrorCode::Conflict => {
            let child = open_directory(&root.directory, &name)?;
            verify_backing(&child, &entered.provision)?;
        }
        Err(error) => return Err(error),
    }
    let resolution_name = cstring(&format!(
        "{}.delete-resolution.json",
        intent.worker_volume_id
    ))?;
    let previous: Option<VolumeDeletionReceipt> = read_record(&ledger, &resolution_name, budget)?;
    if let Some(previous) = previous {
        if previous != entered {
            return Err(Error::before(ErrorCode::Ownership));
        }
    } else {
        // Immutable audit of explicit resolution entry, not an automatic retry
        // instruction. Every repeated resolution still requires fresh fencing.
        publish(&ledger, &resolution_name, &entered)?;
    }
    finish_removal(
        root,
        &ledger,
        &entered,
        budget,
        resolution.max_entries,
        true,
    )
    .map_err(|error| Error::uncertain(error.code))?;
    Ok(entered)
}

fn verify_origin(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    intent: &LocalVolumeIntent,
    receipt: &VolumeDeletionReceipt,
) -> Result<()> {
    receipt.validate()?;
    let backing = &receipt.provision.backing;
    if backing.target_id != binding.target_id
        || backing.domain_generation != binding.generation
        || backing.policy != root.policy
        || backing.intent != *intent
        || (backing.root_device, backing.root_inode) != root.identity
        || receipt.provision.account != VolumeAccount::current()?
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

fn finish_removal(
    root: &QualifiedVolumeRoot,
    ledger: &super::super::PrivateLedger,
    receipt: &VolumeDeletionReceipt,
    budget: &ReadBudget,
    max_entries: usize,
    allow_absent: bool,
) -> Result<()> {
    let provision = &receipt.provision;
    let intent = &provision.backing.intent;
    let completed = cstring(&format!("{}.deleted.json", intent.worker_volume_id))?;
    root.verify(budget)?;
    if provision.account != VolumeAccount::current()? {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let name = cstring(&intent.worker_volume_id)?;
    match require_absent(&root.directory, &name) {
        Ok(()) if allow_absent => {
            root.directory
                .sync_all()
                .map_err(|_| Error::before(ErrorCode::Io))?;
            root.verify(budget)?;
            publish(ledger, &completed, receipt)?;
            root.verify(budget)?;
            require_absent(&root.directory, &name)?;
            return Ok(());
        }
        Ok(()) => return Err(Error::before(ErrorCode::Ownership)),
        Err(error) if error.code == ErrorCode::Conflict => {}
        Err(error) => return Err(error),
    }
    let volume = open_directory(&root.directory, &name)?;
    let metadata = volume
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    verify_backing(&volume, provision)?;
    remove_tree(&volume, budget, max_entries)?;
    root.verify(budget)?;
    let current = node(&root.directory, &name)?;
    if current.identity != (metadata.dev(), metadata.ino()) || !current.directory {
        return Err(Error::before(ErrorCode::Ownership));
    }
    unlink(&root.directory, &name, true)?;
    root.directory
        .sync_all()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    require_absent(&root.directory, &name)?;
    ledger.verify()?;
    root.verify(budget)?;
    publish(ledger, &completed, receipt)?;
    root.verify(budget)?;
    require_absent(&root.directory, &name)?;
    Ok(())
}

fn verify_backing(volume: &File, provision: &VolumeProvisionReceipt) -> Result<()> {
    super::verify_completed_backing(volume, provision)
}

pub(super) fn observe_deleted(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    intent: &LocalVolumeIntent,
    budget: &ReadBudget,
) -> Result<VolumeDeletionPresence> {
    budget.check()?;
    intent.validate()?;
    root.verify(budget)?;
    let Some(ledger) = existing_ledger(domain)? else {
        return Ok(VolumeDeletionPresence::Unverified);
    };
    let entered: Option<VolumeDeletionReceipt> = read_record(
        &ledger,
        &cstring(&format!("{}.delete-intent.json", intent.worker_volume_id))?,
        budget,
    )?;
    let complete: Option<VolumeDeletionReceipt> = read_record(
        &ledger,
        &cstring(&format!("{}.deleted.json", intent.worker_volume_id))?,
        budget,
    )?;
    let result = match (entered, complete) {
        (Some(entered), Some(complete)) => {
            complete.validate()?;
            if entered != complete
                || complete.provision.backing.target_id != binding.target_id
                || complete.provision.backing.domain_generation != binding.generation
                || complete.provision.backing.policy != root.policy
                || complete.provision.backing.intent != *intent
                || (
                    complete.provision.backing.root_device,
                    complete.provision.backing.root_inode,
                ) != root.identity
                || complete.provision.account != VolumeAccount::current()?
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let original: Option<VolumeProvisionReceipt> = read_record(
                &ledger,
                &cstring(&format!("{}.provisioned.json", intent.worker_volume_id))?,
                budget,
            )?;
            if original.as_ref() != Some(&complete.provision) {
                return Err(Error::before(ErrorCode::Ownership));
            }
            require_absent(&root.directory, &cstring(&intent.worker_volume_id)?)
                .map_err(|_| Error::before(ErrorCode::Ownership))?;
            VolumeDeletionPresence::Deleted(Box::new(complete))
        }
        _ => VolumeDeletionPresence::Unverified,
    };
    ledger.verify()?;
    root.verify(budget)?;
    Ok(result)
}

struct Frame {
    name: CString,
    identity: (u64, u64),
}
struct Node {
    identity: (u64, u64),
    directory: bool,
}

// libc dev_t/mode_t differ between Linux and Darwin; normalize only identity.
#[allow(clippy::unnecessary_cast)]
fn node(parent: &File, name: &CString) -> Result<Node> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(Error::before(ErrorCode::Io));
    }
    let stat = unsafe { stat.assume_init() };
    Ok(Node {
        identity: (stat.st_dev as u64, stat.st_ino as u64),
        directory: stat.st_mode & libc::S_IFMT == libc::S_IFDIR,
    })
}

fn unlink(parent: &File, name: &CString, directory: bool) -> Result<()> {
    if unsafe {
        libc::unlinkat(
            parent.as_raw_fd(),
            name.as_ptr(),
            if directory { libc::AT_REMOVEDIR } else { 0 },
        )
    } != 0
    {
        return Err(Error::before(ErrorCode::Io));
    }
    parent.sync_all().map_err(|_| Error::before(ErrorCode::Io))
}

fn reopen(volume: &File, frames: &[Frame], budget: &ReadBudget) -> Result<File> {
    budget.check()?;
    let mut directory = open_directory(volume, &cstring(".")?)?;
    for frame in frames {
        budget.check()?;
        let child = open_directory(&directory, &frame.name)?;
        let metadata = child
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if (metadata.dev(), metadata.ino()) != frame.identity {
            return Err(Error::before(ErrorCode::Ownership));
        }
        directory = child;
    }
    Ok(directory)
}

struct Directory(*mut libc::DIR);
impl Drop for Directory {
    fn drop(&mut self) {
        unsafe {
            libc::closedir(self.0);
        }
    }
}

fn next_entry(directory: &File) -> Result<Option<CString>> {
    // Open a new file description: dup would share the directory offset and
    // skip entries when libc buffers multiple names but only one is consumed.
    let scan = open_directory(directory, &cstring(".")?)?;
    let fd = scan.into_raw_fd();
    let pointer = unsafe { libc::fdopendir(fd) };
    if pointer.is_null() {
        unsafe {
            libc::close(fd);
        }
        return Err(Error::before(ErrorCode::Io));
    }
    let stream = Directory(pointer);
    loop {
        // Distinguish readdir EOF from an error using the platform errno slot.
        set_errno_zero();
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            if std::io::Error::last_os_error().raw_os_error() != Some(0) {
                return Err(Error::before(ErrorCode::Io));
            }
            return Ok(None);
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if !matches!(name.to_bytes(), b"." | b"..") {
            return Ok(Some(name.to_owned()));
        }
    }
}

#[cfg(target_os = "linux")]
fn set_errno_zero() {
    unsafe {
        *libc::__errno_location() = 0;
    }
}
#[cfg(target_os = "macos")]
fn set_errno_zero() {
    unsafe {
        *libc::__error() = 0;
    }
}

pub(crate) fn remove_tree(volume: &File, budget: &ReadBudget, max_entries: usize) -> Result<()> {
    let device = volume
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?
        .dev();
    let mut frames: Vec<Frame> = Vec::new();
    let mut path_bytes = 0;
    let mut entries = 0;
    loop {
        budget.check()?;
        let directory = reopen(volume, &frames, budget)?;
        if let Some(name) = next_entry(&directory)? {
            entries += 1;
            if entries > max_entries {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            let original = node(&directory, &name)?;
            if original.identity.0 != device {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if original.directory {
                let length = name.as_bytes().len() + 1;
                if length > MAX_PATH_BYTES - path_bytes {
                    return Err(Error::before(ErrorCode::OutputLimit));
                }
                path_bytes += length;
                frames.push(Frame {
                    name,
                    identity: original.identity,
                });
            } else {
                let current = node(&directory, &name)?;
                if current.identity != original.identity || current.directory {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                budget.check()?;
                unlink(&directory, &name, false)?;
            }
        } else if let Some(frame) = frames.pop() {
            drop(directory);
            let parent = reopen(volume, &frames, budget)?;
            let current = node(&parent, &frame.name)?;
            if current.identity != frame.identity || !current.directory {
                return Err(Error::before(ErrorCode::Ownership));
            }
            budget.check()?;
            unlink(&parent, &frame.name, true)?;
            path_bytes -= frame.name.as_bytes().len() + 1;
        } else {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "linux")]
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn budget() -> ReadBudget {
        crate::volumes::tests::budget()
    }
    struct Fixture {
        _directory: tempfile::TempDir,
        root: QualifiedVolumeRoot,
        domain: std::path::PathBuf,
        binding: DomainBinding,
        provision: VolumeProvisionReceipt,
    }
    fn fixture() -> Option<Fixture> {
        let account = match VolumeAccount::current() {
            Ok(account) => account,
            Err(error) => {
                assert_eq!(error.code, ErrorCode::Unsupported);
                return None;
            }
        };
        let (directory, policy) = crate::volumes::tests::fixture();
        let domain = std::fs::canonicalize(directory.path())
            .unwrap()
            .join("private");
        std::fs::create_dir(&domain).unwrap();
        std::fs::set_permissions(&domain, std::fs::Permissions::from_mode(0o700)).unwrap();
        let root = QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).unwrap();
        let binding = DomainBinding {
            target_id: "worker".into(),
            generation: "a".repeat(32),
            database: domain.join("db"),
            vm_root: domain.join("vms"),
        };
        let intent = LocalVolumeIntent {
            worker_volume_id: format!("sbv-{}", "b".repeat(32)),
            size_gb: 2,
        };
        let provision =
            super::super::provision(&root, &binding, &domain, &intent, account, &budget()).unwrap();
        Some(Fixture {
            _directory: directory,
            root,
            domain,
            binding,
            provision,
        })
    }
    fn run(f: &Fixture) -> Result<VolumeDeletionReceipt> {
        remove(
            &f.root,
            &f.binding,
            &f.domain,
            &f.provision,
            &budget(),
            MAX_ENTRIES,
            || Ok(()),
        )
    }
    fn inspect_deleted(f: &Fixture) -> Result<VolumeDeletionPresence> {
        observe_deleted(
            &f.root,
            &f.binding,
            &f.domain,
            &f.provision.backing.intent,
            &budget(),
        )
    }
    fn record_path(f: &Fixture, kind: &str) -> std::path::PathBuf {
        f.domain.join("volume-staging").join(format!(
            "{}.{kind}.json",
            f.provision.backing.intent.worker_volume_id
        ))
    }

    #[test]
    fn completed_safe_mode_evolution_still_allows_original_owned_deletion() {
        let Some(f) = fixture() else {
            return;
        };
        let path = f.provision.node_path();
        std::fs::write(path.join("owned"), b"data").unwrap();
        let foreign = f.root.policy.root.join("unrelated");
        std::fs::create_dir(&foreign).unwrap();
        std::fs::write(foreign.join("keep"), b"foreign").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        let result = run(&f).unwrap();
        assert_eq!(result.provision, f.provision);
        assert_eq!(result.provision.backing.mode, 0o700);
        assert!(!path.exists());
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Deleted(Box::new(result))
        );
        assert_eq!(std::fs::read(foreign.join("keep")).unwrap(), b"foreign");
    }

    #[test]
    fn descriptor_tree_removes_nested_contents_without_following_links_or_touching_hardlink_targets(
    ) {
        let temporary = tempfile::tempdir().unwrap();
        let volume = temporary.path().join("volume");
        let outside = temporary.path().join("outside");
        std::fs::create_dir_all(volume.join("nested/deeper")).unwrap();
        std::fs::create_dir(&outside).unwrap();
        std::fs::write(outside.join("keep"), b"outside").unwrap();
        for i in 0..80 {
            std::fs::write(volume.join(format!("file-{i}")), b"inside").unwrap();
        }
        std::fs::write(volume.join("nested/deeper/file"), b"nested").unwrap();
        #[cfg(target_os = "linux")]
        std::fs::write(
            volume.join(std::ffi::OsString::from_vec(vec![0xff])),
            b"raw name",
        )
        .unwrap();
        symlink(&outside, volume.join("directory-link")).unwrap();
        symlink(outside.join("keep"), volume.join("file-link")).unwrap();
        std::fs::hard_link(outside.join("keep"), volume.join("hard-link")).unwrap();
        let fifo = cstring(volume.join("fifo").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        // This is a traversal/containment contract, not a two-second storage
        // latency assertion. Preserve the ordinary budget ceiling while allowing
        // nested Linux filesystems to finish alongside other journal models.
        let traversal_budget = ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        remove_tree(
            &File::open(&volume).unwrap(),
            &traversal_budget,
            MAX_ENTRIES,
        )
        .unwrap();
        assert_eq!(std::fs::read_dir(&volume).unwrap().count(), 0);
        assert_eq!(std::fs::read(outside.join("keep")).unwrap(), b"outside");
        assert_eq!(std::fs::metadata(outside.join("keep")).unwrap().nlink(), 1);
    }

    #[test]
    fn tree_entry_budget_retains_partial_data_and_never_reports_success() {
        let temporary = tempfile::tempdir().unwrap();
        for i in 0..2 {
            std::fs::write(temporary.path().join(format!("file-{i}")), b"inside").unwrap();
        }
        let error = remove_tree(&File::open(temporary.path()).unwrap(), &budget(), 1).unwrap_err();
        assert_eq!(error.code, ErrorCode::OutputLimit);
        assert_eq!(std::fs::read_dir(temporary.path()).unwrap().count(), 1);
    }

    #[test]
    fn entered_removal_budget_failure_retains_uncertainty_and_refuses_automatic_replay() {
        let Some(f) = fixture() else { return };
        for i in 0..2 {
            std::fs::write(f.provision.node_path().join(format!("file-{i}")), b"inside").unwrap();
        }
        let error = remove(
            &f.root,
            &f.binding,
            &f.domain,
            &f.provision,
            &budget(),
            1,
            || Ok(()),
        )
        .unwrap_err();
        assert_eq!(error.code, ErrorCode::OutputLimit);
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        assert_eq!(
            std::fs::read_dir(f.provision.node_path()).unwrap().count(),
            1
        );
        assert!(record_path(&f, "delete-intent").exists());
        assert!(!record_path(&f, "deleted").exists());
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Unverified
        );
        let retry = run(&f).unwrap_err();
        assert_eq!(retry.code, ErrorCode::Conflict);
        assert_eq!(retry.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(
            std::fs::read_dir(f.provision.node_path()).unwrap().count(),
            1
        );
    }

    #[test]
    fn tree_cancellation_before_entry_preserves_all_contents() {
        let temporary = tempfile::tempdir().unwrap();
        std::fs::write(temporary.path().join("keep"), b"inside").unwrap();
        let cancel = crate::Cancellation::default();
        cancel.cancel();
        let budget = ReadBudget::new(std::time::Duration::from_secs(2), cancel).unwrap();
        assert_eq!(
            remove_tree(&File::open(temporary.path()).unwrap(), &budget, MAX_ENTRIES)
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        assert_eq!(
            std::fs::read(temporary.path().join("keep")).unwrap(),
            b"inside"
        );
    }

    #[test]
    fn owned_removal_publishes_intent_completion_and_verified_absence() {
        let Some(f) = fixture() else { return };
        let path = f.provision.node_path();
        std::fs::create_dir_all(path.join("one/two")).unwrap();
        std::fs::write(path.join("one/two/file"), b"owned").unwrap();
        let receipt = run(&f).unwrap();
        receipt.validate().unwrap();
        assert!(!path.exists());
        assert_eq!(receipt.provision, f.provision);
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Deleted(Box::new(receipt.clone()))
        );
        for kind in ["delete-intent", "deleted"] {
            let path = record_path(&f, kind);
            let metadata = std::fs::metadata(&path).unwrap();
            assert_eq!(metadata.mode() & 0o7777, 0o600);
            let stored: VolumeDeletionReceipt =
                serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
            assert_eq!(stored, receipt);
        }
        assert_eq!(
            std::fs::read_dir(f.domain.join("volume-staging"))
                .unwrap()
                .count(),
            6
        );
        assert!(!format!("{receipt:?}").contains(&receipt.provision.backing.owner_token));
    }

    #[test]
    fn attachment_guard_rejection_precedes_intent_and_any_removal() {
        let Some(f) = fixture() else { return };
        std::fs::write(f.provision.node_path().join("keep"), b"attached").unwrap();
        let error = remove(
            &f.root,
            &f.binding,
            &f.domain,
            &f.provision,
            &budget(),
            MAX_ENTRIES,
            || Err(Error::before(ErrorCode::Conflict)),
        )
        .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(
            std::fs::read(f.provision.node_path().join("keep")).unwrap(),
            b"attached"
        );
        assert!(!record_path(&f, "delete-intent").exists());
    }

    #[test]
    fn static_entered_intent_model_refuses_replay_and_cannot_be_completed_by_inspection() {
        let Some(f) = fixture() else { return };
        let ledger = existing_ledger(&f.domain).unwrap().unwrap();
        let entry = VolumeDeletionReceipt {
            schema: 1,
            operation_id: "c".repeat(32),
            provision: f.provision.clone(),
        };
        publish(
            &ledger,
            &cstring(&format!(
                "{}.delete-intent.json",
                f.provision.backing.intent.worker_volume_id
            ))
            .unwrap(),
            &entry,
        )
        .unwrap();
        std::fs::write(f.provision.node_path().join("keep"), b"unknown").unwrap();
        assert_eq!(run(&f).unwrap_err().code, ErrorCode::Conflict);
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Unverified
        );
        assert!(!record_path(&f, "deleted").exists());
        assert_eq!(
            std::fs::read(f.provision.node_path().join("keep")).unwrap(),
            b"unknown"
        );
    }

    #[test]
    fn missing_completion_model_cannot_mint_deleted_evidence_from_absent_backing() {
        let Some(f) = fixture() else { return };
        run(&f).unwrap();
        // Static non-VM evidence model, no live writer/persistence interruption.
        std::fs::remove_file(record_path(&f, "deleted")).unwrap();
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Unverified
        );
        assert!(!record_path(&f, "deleted").exists());
        assert!(run(&f).is_err());
    }

    #[test]
    fn substituted_backing_is_preserved_without_deletion_intent() {
        let Some(f) = fixture() else { return };
        let path = f.provision.node_path();
        std::fs::rename(&path, path.with_extension("original")).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(path.join("keep"), b"foreign").unwrap();
        assert_eq!(run(&f).unwrap_err().code, ErrorCode::Ownership);
        assert!(!record_path(&f, "delete-intent").exists());
        assert_eq!(std::fs::read(path.join("keep")).unwrap(), b"foreign");
    }

    #[test]
    fn deleted_observer_rejects_crossed_operation_and_replacement_inventory() {
        let Some(f) = fixture() else { return };
        let receipt = run(&f).unwrap();
        let changed = VolumeDeletionReceipt {
            operation_id: "d".repeat(32),
            ..receipt.clone()
        };
        std::fs::write(
            record_path(&f, "deleted"),
            serde_json::to_vec(&changed).unwrap(),
        )
        .unwrap();
        assert_eq!(inspect_deleted(&f).unwrap_err().code, ErrorCode::Ownership);
        std::fs::write(
            record_path(&f, "deleted"),
            serde_json::to_vec(&receipt).unwrap(),
        )
        .unwrap();
        std::fs::create_dir(f.provision.node_path()).unwrap();
        std::fs::write(f.provision.node_path().join("keep"), b"foreign").unwrap();
        assert_eq!(inspect_deleted(&f).unwrap_err().code, ErrorCode::Ownership);
        assert_eq!(
            std::fs::read(f.provision.node_path().join("keep")).unwrap(),
            b"foreign"
        );
    }

    fn resolve_fixture(
        f: &Fixture,
        quiesced: bool,
        max_entries: usize,
    ) -> Result<VolumeDeletionReceipt> {
        resolve(
            &f.root,
            &f.binding,
            &f.domain,
            &f.provision.backing.intent,
            &budget(),
            Resolution {
                quiesced,
                max_entries,
            },
            || Ok(()),
        )
    }

    fn partial(f: &Fixture, count: usize) -> VolumeDeletionReceipt {
        for i in 0..count {
            std::fs::write(f.provision.node_path().join(format!("file-{i}")), b"inside").unwrap();
        }
        let error = remove(
            &f.root,
            &f.binding,
            &f.domain,
            &f.provision,
            &budget(),
            1,
            || Ok(()),
        )
        .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        serde_json::from_slice(&std::fs::read(record_path(f, "delete-intent")).unwrap()).unwrap()
    }

    #[test]
    fn resolver_requires_positive_quiescence_before_read_or_mutation() {
        let Some(f) = fixture() else { return };
        partial(&f, 2);
        let before = std::fs::read(record_path(&f, "delete-intent")).unwrap();
        let error = resolve_fixture(&f, false, MAX_ENTRIES).unwrap_err();
        assert_eq!(error.code, ErrorCode::Validation);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(
            std::fs::read_dir(f.provision.node_path()).unwrap().count(),
            1
        );
        assert_eq!(
            std::fs::read(record_path(&f, "delete-intent")).unwrap(),
            before
        );
        assert!(!record_path(&f, "delete-resolution").exists());
    }

    #[test]
    fn repeated_explicit_resolution_preserves_original_operation_and_finishes_partial_data() {
        let Some(f) = fixture() else { return };
        let original = partial(&f, 3);
        let error = resolve_fixture(&f, true, 1).unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        assert!(record_path(&f, "delete-resolution").exists());
        assert_eq!(
            std::fs::read_dir(f.provision.node_path()).unwrap().count(),
            1
        );
        assert_eq!(resolve_fixture(&f, true, 1).unwrap(), original);
        assert!(!f.provision.node_path().exists());
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Deleted(Box::new(original.clone()))
        );
        let before = std::fs::read(record_path(&f, "deleted")).unwrap();
        assert_eq!(resolve_fixture(&f, true, 1).unwrap(), original);
        assert_eq!(std::fs::read(record_path(&f, "deleted")).unwrap(), before);
        assert_eq!(
            std::fs::read_dir(f.domain.join("volume-staging"))
                .unwrap()
                .count(),
            7
        );
    }

    #[test]
    fn explicit_fenced_resolution_completes_known_removed_backing_without_absence_adoption() {
        let Some(f) = fixture() else { return };
        let original = run(&f).unwrap();
        // Static non-VM model of an absent completion record after removal.
        std::fs::remove_file(record_path(&f, "deleted")).unwrap();
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Unverified
        );
        assert_eq!(resolve_fixture(&f, true, MAX_ENTRIES).unwrap(), original);
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Deleted(Box::new(original))
        );
    }

    #[test]
    fn explicit_fenced_cleanup_can_start_first_deletion_from_completed_provisioning() {
        let Some(f) = fixture() else { return };
        assert!(!record_path(&f, "delete-intent").exists());
        let result = resolve_fixture(&f, true, MAX_ENTRIES).unwrap();
        assert_eq!(result.provision, f.provision);
        assert!(!f.provision.node_path().exists());
        assert_eq!(
            inspect_deleted(&f).unwrap(),
            VolumeDeletionPresence::Deleted(Box::new(result))
        );
    }

    #[test]
    fn resolver_rejects_substituted_backing_and_crossed_entered_evidence() {
        let Some(f) = fixture() else { return };
        let original = partial(&f, 2);
        let changed = VolumeDeletionReceipt {
            operation_id: "e".repeat(32),
            provision: VolumeProvisionReceipt {
                backing: super::super::super::VolumeStagingReceipt {
                    owner_token: "f".repeat(64),
                    ..original.provision.backing.clone()
                },
                ..original.provision.clone()
            },
            ..original.clone()
        };
        std::fs::write(
            record_path(&f, "delete-intent"),
            serde_json::to_vec(&changed).unwrap(),
        )
        .unwrap();
        assert_eq!(
            resolve_fixture(&f, true, MAX_ENTRIES).unwrap_err().code,
            ErrorCode::Ownership
        );
        assert!(!record_path(&f, "delete-resolution").exists());
        std::fs::write(
            record_path(&f, "delete-intent"),
            serde_json::to_vec(&original).unwrap(),
        )
        .unwrap();
        let path = f.provision.node_path();
        std::fs::rename(&path, path.with_extension("original")).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(path.join("keep"), b"foreign").unwrap();
        assert_eq!(
            resolve_fixture(&f, true, MAX_ENTRIES).unwrap_err().code,
            ErrorCode::Ownership
        );
        assert!(!record_path(&f, "delete-resolution").exists());
        assert_eq!(std::fs::read(path.join("keep")).unwrap(), b"foreign");
    }

    #[test]
    fn retained_attachment_and_cancellation_cannot_be_overridden_by_quiescence() {
        let Some(f) = fixture() else { return };
        partial(&f, 2);
        let error = resolve(
            &f.root,
            &f.binding,
            &f.domain,
            &f.provision.backing.intent,
            &budget(),
            Resolution {
                quiesced: true,
                max_entries: MAX_ENTRIES,
            },
            || Err(Error::before(ErrorCode::Conflict)),
        )
        .unwrap_err();
        assert_eq!(error.code, ErrorCode::Conflict);
        assert!(!record_path(&f, "delete-resolution").exists());
        let cancel = crate::Cancellation::default();
        cancel.cancel();
        let budget = ReadBudget::new(std::time::Duration::from_secs(2), cancel).unwrap();
        assert_eq!(
            resolve(
                &f.root,
                &f.binding,
                &f.domain,
                &f.provision.backing.intent,
                &budget,
                Resolution {
                    quiesced: true,
                    max_entries: MAX_ENTRIES
                },
                || Ok(())
            )
            .unwrap_err()
            .code,
            ErrorCode::State
        );
        assert_eq!(
            std::fs::read_dir(f.provision.node_path()).unwrap().count(),
            1
        );
    }

    #[test]
    fn quiescence_cannot_supply_missing_provision_or_mismatched_resolution_authority() {
        let Some(f) = fixture() else { return };
        let original = partial(&f, 2);
        let ledger = existing_ledger(&f.domain).unwrap().unwrap();
        let changed = VolumeDeletionReceipt {
            operation_id: "f".repeat(32),
            ..original
        };
        publish(
            &ledger,
            &cstring(&format!(
                "{}.delete-resolution.json",
                f.provision.backing.intent.worker_volume_id
            ))
            .unwrap(),
            &changed,
        )
        .unwrap();
        assert_eq!(
            resolve_fixture(&f, true, MAX_ENTRIES).unwrap_err().code,
            ErrorCode::Ownership
        );
        std::fs::remove_file(record_path(&f, "provisioned")).unwrap();
        assert_eq!(
            resolve_fixture(&f, true, MAX_ENTRIES).unwrap_err().code,
            ErrorCode::Ownership
        );
        assert_eq!(
            std::fs::read_dir(f.provision.node_path()).unwrap().count(),
            1
        );
    }
}
