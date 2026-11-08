//! Persistent child/dispatch evidence. Unknown attempts fence epoch replacement.
use crate::domain::valid_hex;
use crate::host::{private_directory, unredirected};
use crate::{BootLauncher, DomainBinding, Error, ErrorCode, HostContext, OwnerIdentity, Result};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

const MAX_RECORDS: usize = 4096;
const MAX_BYTES: u64 = 4096;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
enum Role {
    Boot { machine: String, operation: String },
    Transfer { machine: String, operation: String },
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Actor {
    schema: u32,
    owner: OwnerIdentity,
    epoch: String,
    child: OwnerIdentity,
    role: Role,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Pending {
    schema: u32,
    owner: OwnerIdentity,
    epoch: String,
    machine: String,
    operation: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Closed {
    schema: u32,
    owner: OwnerIdentity,
    epoch: String,
}
struct Shared {
    directory: PathBuf,
    owner: OwnerIdentity,
    epoch: String,
    domain: DomainBinding,
    directory_identity: (u64, u64),
    executable: PathBuf,
    unavailable: AtomicBool,
    mutation: Mutex<()>,
}
#[derive(Clone)]
pub(crate) struct ActorEpoch(Arc<Shared>);
pub(crate) struct BootDispatch {
    epoch: ActorEpoch,
    path: PathBuf,
    pending: Pending,
    finished: bool,
}
pub(crate) struct CollectionDispatch(BootDispatch);
impl CollectionDispatch {
    /// The owned SDK stop call actually returned, including an error. Only then
    /// may another actor sweep reap this boot child. This proves no collection.
    pub(crate) fn sdk_returned(self) -> Result<()> {
        self.clear()
    }
    /// Recheck the caller budget after publishing pending collection. A request
    /// that expires before entry removes only its own unentered fence; it makes
    /// no SDK-return or process-collection claim.
    pub(crate) fn run(
        self,
        budget: &crate::ReadBudget,
        call: impl FnOnce() -> Result<()>,
    ) -> Result<()> {
        if let Err(error) = budget.check() {
            self.clear().map_err(|e| Error::uncertain(e.code))?;
            return Err(error);
        }
        let result = call();
        self.sdk_returned().map_err(|e| Error::uncertain(e.code))?;
        result.map_err(|e| Error::uncertain(e.code))
    }
    fn clear(mut self) -> Result<()> {
        let _guard = self
            .0
            .epoch
            .0
            .mutation
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        let actual: Pending = read(&self.0.path)?;
        if actual != self.0.pending {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        remove_record(&self.0.path)?;
        self.0.finished = true;
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct BootIntent {
    owner: OwnerIdentity,
    directory_identity: (u64, u64),
    epoch: String,
    machine: String,
    operation: String,
}
pub(crate) struct BootEnrollment {
    intent: BootIntent,
    child: OwnerIdentity,
}
/// Positive collection of an originally enrolled boot child. Persisted process
/// fields alone cannot construct this authority or adopt another manager.
pub(crate) struct BootCollection {
    intent: BootIntent,
    child: OwnerIdentity,
}
impl BootCollection {
    pub(crate) fn intent(&self) -> &BootIntent {
        &self.intent
    }
    pub(crate) fn child(&self) -> OwnerIdentity {
        self.child
    }
}
impl BootIntent {
    pub(crate) fn valid_for(&self, name: &str) -> bool {
        self.owner.pid > 0
            && self.owner.birth > 0
            && self.owner.uid == unsafe { libc::geteuid() }
            && valid_hex(&self.epoch, 32)
            && self.machine == smolvm::agent::vm_dir_hash(name)
            && valid_hex(&self.operation, 32)
            && self.directory_identity.0 > 0
            && self.directory_identity.1 > 0
    }
    pub(crate) fn owner(&self) -> OwnerIdentity {
        self.owner
    }
    pub(crate) fn matches_epoch(&self, name: &str, epoch: &ActorEpoch) -> bool {
        self.matches(name, &epoch.0.epoch)
            && self.owner == epoch.0.owner
            && self.directory_identity == epoch.0.directory_identity
            && private_directory(&epoch.0.directory).is_ok()
            && std::fs::symlink_metadata(&epoch.0.directory)
                .is_ok_and(|m| (m.dev(), m.ino()) == self.directory_identity)
    }
    pub(crate) fn matches(&self, name: &str, epoch: &str) -> bool {
        self.epoch == epoch && self.valid_for(name)
    }
}
impl BootEnrollment {
    pub(crate) fn intent(&self) -> &BootIntent {
        &self.intent
    }
    pub(crate) fn child(&self) -> OwnerIdentity {
        self.child
    }
}
impl Drop for BootDispatch {
    fn drop(&mut self) {
        if !self.finished {
            self.epoch.0.unavailable.store(true, Ordering::Release);
        }
    }
}
impl BootDispatch {
    pub(crate) fn matches_epoch(&self, name: &str, epoch: &ActorEpoch) -> bool {
        Arc::ptr_eq(&self.epoch.0, &epoch.0)
            && self.pending.owner == epoch.0.owner
            && self.intent().matches_epoch(name, epoch)
            && epoch.available()
    }
    pub(crate) fn intent(&self) -> BootIntent {
        BootIntent {
            owner: self.pending.owner,
            directory_identity: self.epoch.0.directory_identity,
            epoch: self.pending.epoch.clone(),
            machine: self.pending.machine.clone(),
            operation: self.pending.operation.clone(),
        }
    }
    /// Return the identity enrolled before SDK execution, including when the
    /// child has already exited. Current inventory cannot reconstruct birth.
    pub(crate) fn finish_enrollment(mut self, sdk_pid: Option<i32>) -> Result<BootEnrollment> {
        let _guard = self
            .epoch
            .0
            .mutation
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        let matching = actors(
            &self.epoch.0.directory,
            self.epoch.0.owner,
            &self.epoch.0.epoch,
        )?
        .into_iter()
        .filter(|(_, actor)| {
            actor.role
                == Role::Boot {
                    machine: self.pending.machine.clone(),
                    operation: self.pending.operation.clone(),
                }
        })
        .collect::<Vec<_>>();
        if matching.len() != 1 || sdk_pid.is_some_and(|pid| matching[0].1.child.pid != pid) {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let actual: Pending = read(&self.path)?;
        if actual != self.pending {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        remove_record(&self.path)?;
        self.finished = true;
        Ok(BootEnrollment {
            intent: self.intent(),
            child: matching[0].1.child,
        })
    }
}
impl ActorEpoch {
    pub(crate) fn begin_collection(
        &self,
        name: &str,
        enrolled: &BootEnrollment,
    ) -> Result<CollectionDispatch> {
        if !enrolled.intent.matches_epoch(name, self) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let _guard = self
            .0
            .mutation
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        admission(&self.0.directory)?;
        let pending = Pending {
            schema: 1,
            owner: self.0.owner,
            epoch: self.0.epoch.clone(),
            machine: enrolled.intent.machine.clone(),
            operation: enrolled.intent.operation.clone(),
        };
        let path = self
            .0
            .directory
            .join(format!("pending-{}.json", pending.machine));
        publish(&path, &pending)?;
        Ok(CollectionDispatch(BootDispatch {
            epoch: self.clone(),
            path,
            pending,
            finished: false,
        }))
    }
    pub(crate) fn collect_enrolled(
        &self,
        name: &str,
        enrolled: &BootEnrollment,
    ) -> Result<BootCollection> {
        if !enrolled.intent.matches_epoch(name, self) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // This bounded actor sweep may reap our exact exited boot child. A
        // foreign/reused PID is only observed; no signal or SDK stop is sent.
        if !self.quiescent_for(name)? || !gone(enrolled.child)? {
            return Err(Error::before(ErrorCode::Conflict));
        }
        Ok(BootCollection {
            intent: enrolled.intent.clone(),
            child: enrolled.child,
        })
    }
    pub(crate) fn launcher_selected(&self) -> bool {
        std::env::var_os("SMOLVM_BOOT_BINARY").as_deref() == Some(self.0.executable.as_os_str())
    }
    pub(crate) fn bound_to(&self, binding: &DomainBinding) -> bool {
        &self.0.domain == binding
    }
    pub(crate) fn identity(&self) -> String {
        self.0.epoch.clone()
    }
    pub(crate) fn new(launcher: &BootLauncher, host: &HostContext) -> Result<Self> {
        let directory = launcher
            .executable()
            .parent()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .to_path_buf();
        private_directory(&directory)?;
        let metadata = std::fs::symlink_metadata(&directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        Ok(Self(Arc::new(Shared {
            directory,
            owner: host.owner,
            epoch: host.epoch.clone(),
            domain: host.domain.clone(),
            directory_identity: (metadata.dev(), metadata.ino()),
            executable: launcher.executable().into(),
            unavailable: AtomicBool::new(false),
            mutation: Mutex::new(()),
        })))
    }
    pub(crate) fn available(&self) -> bool {
        !self.0.unavailable.load(Ordering::Acquire)
    }
    pub(crate) fn begin_boot(&self, name: &str) -> Result<BootDispatch> {
        if !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
        let _guard = self
            .0
            .mutation
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        self.collect_locked()?;
        admission(&self.0.directory)?;
        let mut nonce = [0; 16];
        getrandom::fill(&mut nonce).map_err(|_| Error::before(ErrorCode::Native))?;
        let pending = Pending {
            schema: 1,
            owner: self.0.owner,
            epoch: self.0.epoch.clone(),
            machine: smolvm::agent::vm_dir_hash(name),
            operation: hex::encode(nonce),
        };
        let path = self
            .0
            .directory
            .join(format!("pending-{}.json", pending.machine));
        publish(&path, &pending)?;
        Ok(BootDispatch {
            epoch: self.clone(),
            path,
            pending,
            finished: false,
        })
    }
    /// Persist identity before sending transfer authority through private stdin.
    pub(crate) fn register_transfer(
        &self,
        child: OwnerIdentity,
        operation: &str,
        machine: &str,
    ) -> Result<()> {
        if !self.available()
            || !valid_hex(operation, 32)
            || !valid_hex(machine, 16)
            || child.pid <= 0
            || child.birth == 0
            || child.uid != self.0.owner.uid
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let _guard = self
            .0
            .mutation
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        self.collect_locked()?;
        admission(&self.0.directory)?;
        let actor = Actor {
            schema: 1,
            owner: self.0.owner,
            epoch: self.0.epoch.clone(),
            child,
            role: Role::Transfer {
                machine: machine.into(),
                operation: operation.into(),
            },
        };
        publish(&actor_path(&self.0.directory, child), &actor)
    }
    pub(crate) fn quiescent_for(&self, name: &str) -> Result<bool> {
        let _guard = self
            .0
            .mutation
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        self.collect_locked()?;
        let machine = smolvm::agent::vm_dir_hash(name);
        if self
            .0
            .directory
            .join(format!("pending-{machine}.json"))
            .exists()
        {
            return Ok(false);
        }
        Ok(!actors(&self.0.directory, self.0.owner, &self.0.epoch)?
            .iter()
            .any(|(_, actor)| match &actor.role {
                Role::Boot {
                    machine: actor_machine,
                    ..
                }
                | Role::Transfer {
                    machine: actor_machine,
                    ..
                } => actor_machine == &machine,
            }))
    }
    fn collect_locked(&self) -> Result<bool> {
        let mut quiescent = true;
        for (path, actor) in actors(&self.0.directory, self.0.owner, &self.0.epoch)? {
            // Enrollment must remain visible until its SDK entry has returned
            // and the matching pending dispatch has been finalized.
            if let Role::Boot { machine, .. } = &actor.role {
                if self
                    .0
                    .directory
                    .join(format!("pending-{machine}.json"))
                    .exists()
                {
                    quiescent = false;
                    continue;
                }
            }
            if collect_exact(&actor)? {
                remove_record(&path)?;
            } else {
                quiescent = false;
            }
        }
        Ok(quiescent)
    }
    pub(crate) fn close(&self) -> Result<()> {
        let _guard = self
            .0
            .mutation
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let path = self.0.directory.join("closed.json");
        if path.exists() {
            let marker: Closed = read(&path)?;
            if marker.schema != 1 || marker.owner != self.0.owner || marker.epoch != self.0.epoch {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            self.0.unavailable.store(true, Ordering::Release);
            return Ok(());
        }
        if !self.collect_locked()? || has_pending(&self.0.directory)? {
            self.0.unavailable.store(true, Ordering::Release);
            return Err(Error::uncertain(ErrorCode::State));
        }
        publish(
            &path,
            &Closed {
                schema: 1,
                owner: self.0.owner,
                epoch: self.0.epoch.clone(),
            },
        )?;
        self.0.unavailable.store(true, Ordering::Release);
        Ok(())
    }
}
/// Launcher enrollment happens after synchronous owner validation, before SDK.
pub(crate) fn register_boot(
    directory: &Path,
    owner: OwnerIdentity,
    epoch: &str,
    domain: &DomainBinding,
    config: &Path,
) -> Result<()> {
    let parent = config.parent().ok_or(Error::before(ErrorCode::Ownership))?;
    let machine = parent
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or(Error::before(ErrorCode::Ownership))?;
    if !valid_hex(machine, 16) || parent.parent() != Some(domain.vm_root.as_path()) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let pending: Pending = read(&directory.join(format!("pending-{machine}.json")))?;
    if pending.schema != 1
        || pending.owner != owner
        || pending.epoch != epoch
        || pending.machine != machine
        || !valid_hex(&pending.operation, 32)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    admission(directory)?;
    let actor = Actor {
        schema: 1,
        owner,
        epoch: epoch.into(),
        child: OwnerIdentity::capture()?,
        role: Role::Boot {
            machine: machine.into(),
            operation: pending.operation,
        },
    };
    publish(&actor_path(directory, actor.child), &actor)
}
/// Domain ownership excludes cooperating writers. Unknown entries are preserved.
pub(crate) fn fence_previous(owned: &Path, domain: &DomainBinding) -> Result<()> {
    let epochs = owned.join("epochs");
    match std::fs::symlink_metadata(&epochs) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(Error::before(ErrorCode::Io)),
        Ok(_) => private_directory(&epochs)?,
    }
    for directory in entries(&epochs)? {
        private_directory(&directory)?;
        let context = BootLauncher::read_context(&directory.join("smolbox-boot"))?;
        if &context.domain != domain || has_pending(&directory)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let closed = directory.join("closed.json");
        if closed.exists() {
            let marker: Closed = read(&closed)?;
            if marker.schema != 1 || marker.owner != context.owner || marker.epoch != context.epoch
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        } else if !gone(context.owner)? {
            return Err(Error::before(ErrorCode::Conflict));
        }
        for (_, actor) in actors(&directory, context.owner, &context.epoch)? {
            if !gone(actor.child)? {
                return Err(Error::before(ErrorCode::Conflict));
            }
        }
        let files = entries(&directory)?;
        for file in &files {
            let name = file
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or(Error::before(ErrorCode::Ownership))?;
            if !matches!(name, "owner.json" | "smolbox-boot" | "closed.json")
                && !name.starts_with("actor-")
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            unredirected(file)?;
            if !std::fs::symlink_metadata(file)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .is_file()
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        for file in files {
            std::fs::remove_file(file).map_err(|_| Error::before(ErrorCode::Io))?;
        }
        std::fs::remove_dir(directory).map_err(|_| Error::before(ErrorCode::Io))?;
    }
    File::open(epochs)
        .and_then(|file| file.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    Ok(())
}
fn actor_path(directory: &Path, child: OwnerIdentity) -> PathBuf {
    directory.join(format!("actor-{}-{}.json", child.pid, child.birth))
}
fn actors(directory: &Path, owner: OwnerIdentity, epoch: &str) -> Result<Vec<(PathBuf, Actor)>> {
    let mut result = Vec::new();
    for path in entries(directory)? {
        if path
            .file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with("actor-"))
        {
            let actor: Actor = read(&path)?;
            let role_valid = match &actor.role {
                Role::Boot { machine, operation } => {
                    valid_hex(machine, 16) && valid_hex(operation, 32)
                }
                Role::Transfer { machine, operation } => {
                    valid_hex(machine, 16) && valid_hex(operation, 32)
                }
            };
            if actor.schema != 1
                || actor.owner != owner
                || actor.epoch != epoch
                || actor.child.pid <= 0
                || actor.child.birth == 0
                || actor.child.uid != owner.uid
                || path != actor_path(directory, actor.child)
                || !role_valid
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            result.push((path, actor));
        }
    }
    Ok(result)
}
fn entries(directory: &Path) -> Result<Vec<PathBuf>> {
    private_directory(directory)?;
    let mut files = Vec::new();
    for entry in std::fs::read_dir(directory).map_err(|_| Error::before(ErrorCode::Io))? {
        if files.len() >= MAX_RECORDS {
            return Err(Error::before(ErrorCode::Conflict));
        }
        files.push(entry.map_err(|_| Error::before(ErrorCode::Io))?.path());
    }
    Ok(files)
}
fn has_pending(directory: &Path) -> Result<bool> {
    Ok(entries(directory)?.iter().any(|path| {
        path.file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with("pending-"))
    }))
}
fn admission(directory: &Path) -> Result<()> {
    if entries(directory)?.len() >= MAX_RECORDS - 16 {
        return Err(Error::before(ErrorCode::Conflict));
    }
    Ok(())
}
fn collect_exact(actor: &Actor) -> Result<bool> {
    if gone(actor.child)? {
        return Ok(true);
    }
    // TransferSupervisor owns its Child; never consume that exit status here.
    if matches!(actor.role, Role::Transfer { .. }) || actor.owner != OwnerIdentity::capture()? {
        return Ok(false);
    }
    if smolvm::process::process_start_time(actor.child.pid) != Some(actor.child.birth) {
        return Ok(false);
    }
    let result = unsafe { libc::waitpid(actor.child.pid, std::ptr::null_mut(), libc::WNOHANG) };
    if result == actor.child.pid {
        return Ok(true);
    }
    gone(actor.child)
}
pub(crate) fn gone(identity: OwnerIdentity) -> Result<bool> {
    let result = unsafe { libc::kill(identity.pid, 0) };
    if result == -1 {
        return if std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
            Ok(true)
        } else {
            Err(Error::before(ErrorCode::Ownership))
        };
    }
    Ok(smolvm::process::process_start_time(identity.pid)
        .is_some_and(|birth| birth != identity.birth && birth != 0))
}
fn read<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    unredirected(path)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > MAX_BYTES
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    serde_json::from_reader(file.take(MAX_BYTES + 1))
        .map_err(|_| Error::before(ErrorCode::Ownership))
}
fn publish(path: &Path, value: &impl Serialize) -> Result<()> {
    private_directory(path.parent().ok_or(Error::before(ErrorCode::Ownership))?)?;
    let bytes = serde_json::to_vec(value).map_err(|_| Error::before(ErrorCode::Validation))?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut staged = tempfile::NamedTempFile::new_in(path.parent().unwrap())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    staged
        .write_all(&bytes)
        .and_then(|_| staged.as_file().sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    staged
        .persist_noclobber(path)
        .map_err(|_| Error::before(ErrorCode::Conflict))?;
    File::open(path.parent().unwrap())
        .and_then(|file| file.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    Ok(())
}
fn remove_record(path: &Path) -> Result<()> {
    std::fs::remove_file(path).map_err(|_| Error::before(ErrorCode::Io))?;
    File::open(path.parent().unwrap())
        .and_then(|file| file.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{Dispatch, Executable, ExecutableLocator};
    use sha2::{Digest, Sha256};
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};

    fn fixture(
        root: &Path,
        executable: Option<PathBuf>,
    ) -> (HostContext, BootLauncher, ActorEpoch) {
        fixture_for_binding(
            root,
            executable,
            DomainBinding {
                target_id: "owned".into(),
                generation: "a".repeat(32),
                database: root.join("db"),
                vm_root: root.join("vms"),
            },
        )
    }
    pub(crate) fn fixture_for_binding(
        root: &Path,
        executable: Option<PathBuf>,
        binding: DomainBinding,
    ) -> (HostContext, BootLauncher, ActorEpoch) {
        fixture_for_binding_and_epoch(root, executable, binding, "b".repeat(32))
    }
    pub(crate) fn fixture_for_binding_and_epoch(
        root: &Path,
        executable: Option<PathBuf>,
        binding: DomainBinding,
        epoch: String,
    ) -> (HostContext, BootLauncher, ActorEpoch) {
        std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = executable.unwrap_or_else(|| {
            let path = root.join("approved");
            std::fs::write(&path, b"fixture executable bytes").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o500)).unwrap();
            path
        });
        let executable = Executable {
            sha256: hex::encode(Sha256::digest(std::fs::read(&path).unwrap())),
            path,
        };
        let host = HostContext::capture(
            binding,
            epoch,
            "c".repeat(64),
            ExecutableLocator {
                boot: executable.clone(),
                file_worker: executable,
                library_directory: root.to_path_buf(),
            },
        )
        .unwrap();
        let launcher = host.prepare_boot_launcher(root).unwrap();
        let actors = ActorEpoch::new(&launcher, &host).unwrap();
        (host, launcher, actors)
    }
    /// Private record model, never process enrollment or guest qualification.
    pub(crate) fn complete_model(dispatch: BootDispatch) -> BootEnrollment {
        let identity = OwnerIdentity {
            pid: dispatch.pending.owner.pid + 1_000_000,
            birth: 1,
            uid: dispatch.pending.owner.uid,
        };
        complete_model_with_child(dispatch, identity)
    }
    pub(crate) fn complete_model_with_child(
        dispatch: BootDispatch,
        identity: OwnerIdentity,
    ) -> BootEnrollment {
        let actor = Actor {
            schema: 1,
            owner: dispatch.pending.owner,
            epoch: dispatch.pending.epoch.clone(),
            child: identity,
            role: Role::Boot {
                machine: dispatch.pending.machine.clone(),
                operation: dispatch.pending.operation.clone(),
            },
        };
        publish(&actor_path(&dispatch.epoch.0.directory, identity), &actor).unwrap();
        dispatch.finish_enrollment(Some(identity.pid)).unwrap()
    }

    fn waiting_child() -> (Child, OwnerIdentity) {
        // A private pipe release makes the shell exit normally. No signals.
        let mut child = Command::new("/bin/sh")
            .args(["-c", "read value"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        let deadline = Instant::now() + Duration::from_secs(1);
        let birth = loop {
            if let Some(birth) = smolvm::process::process_start_time(pid).filter(|v| *v != 0) {
                break birth;
            }
            if Instant::now() >= deadline {
                drop(child.stdin.take());
                child.wait().unwrap();
                panic!("normal child birth unavailable");
            }
            std::thread::yield_now();
        };
        (
            child,
            OwnerIdentity {
                pid,
                birth,
                uid: unsafe { libc::geteuid() },
            },
        )
    }

    #[test]
    fn collection_requires_original_enrollment_and_normal_exit_without_signalling() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let (host, _, actors) = fixture(&root, None);
        let dispatch = actors.begin_boot("owned").unwrap();
        let (mut child, identity) = waiting_child();
        let actor = Actor {
            schema: 1,
            owner: host.owner,
            epoch: host.epoch.clone(),
            child: identity,
            role: Role::Boot {
                machine: dispatch.pending.machine.clone(),
                operation: dispatch.pending.operation.clone(),
            },
        };
        publish(&actor_path(&actors.0.directory, identity), &actor).unwrap();
        let enrolled = dispatch.finish_enrollment(Some(identity.pid)).unwrap();
        assert_eq!(
            actors
                .collect_enrolled("owned", &enrolled)
                .err()
                .unwrap()
                .code,
            crate::ErrorCode::Conflict
        );
        assert!(actors.collect_enrolled("foreign", &enrolled).is_err());
        let pending_collection = actors.begin_collection("owned", &enrolled).unwrap();
        drop(child.stdin.take());
        child.wait().unwrap();
        assert!(!actors.quiescent_for("owned").unwrap());
        assert!(actors.quiescent_for("sibling").unwrap());
        assert!(actors.collect_enrolled("owned", &enrolled).is_err());
        pending_collection.sdk_returned().unwrap();
        let collected = actors.collect_enrolled("owned", &enrolled).unwrap();
        assert!(collected.child() == identity);
        assert!(collected.intent() == enrolled.intent());
        assert!(actors.quiescent_for("owned").unwrap());
        let foreign_root = root.join("foreign-epoch");
        std::fs::create_dir(&foreign_root).unwrap();
        let (_, _, foreign) = fixture_for_binding(&foreign_root, None, host.domain.clone());
        assert!(foreign.collect_enrolled("owned", &enrolled).is_err());
        actors.close().unwrap();
    }

    #[test]
    fn unresolved_dispatch_fences_replacement_and_preserves_context() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let (host, launcher, actors) = fixture(&root, None);
        let pending = actors.begin_boot("owned").unwrap();
        assert!(!actors.quiescent_for("owned").unwrap());
        assert!(actors.quiescent_for("sibling").unwrap());
        drop(pending); // Models lost SDK result; no live fault injection.
        assert!(!actors.available());
        assert_eq!(
            actors.begin_boot("sibling").err().unwrap().dispatch,
            Dispatch::NotDispatched
        );
        assert!(actors.close().is_err());
        assert!(fence_previous(&root, &host.domain).is_err());
        assert!(launcher.executable().exists());
    }

    #[test]
    fn live_owner_requires_closed_epoch_and_unknown_files_are_preserved() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let (host, launcher, actors) = fixture(&root, None);
        assert!(fence_previous(&root, &host.domain).is_err());
        actors.close().unwrap();
        actors.close().unwrap(); // A normal repeated drain is idempotent.
        assert!(!actors.available());
        let unknown = launcher.executable().parent().unwrap().join("unrecognized");
        std::fs::write(&unknown, b"preserve").unwrap();
        assert!(fence_previous(&root, &host.domain).is_err());
        assert!(unknown.exists());
        std::fs::remove_file(unknown).unwrap();
        fence_previous(&root, &host.domain).unwrap();
        assert!(!launcher.executable().exists());
    }

    #[test]
    fn transfer_status_belongs_to_supervisor_and_siblings_do_not_block_absence() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let (_, _, actors) = fixture(&root, None);
        let (mut child, identity) = waiting_child();
        actors
            .register_transfer(
                identity,
                &"d".repeat(32),
                &smolvm::agent::vm_dir_hash("owned"),
            )
            .unwrap();
        assert!(!actors.quiescent_for("owned").unwrap());
        assert!(actors.quiescent_for("sibling").unwrap());
        child.stdin.take().unwrap().write_all(b"done\n").unwrap();
        // Even if the exit races observation, it cannot be stolen by the ledger.
        actors.quiescent_for("owned").unwrap();
        assert!(child.wait().unwrap().success());
        assert!(actors.quiescent_for("owned").unwrap());
        actors.close().unwrap();
    }

    #[test]
    fn completed_enrollment_survives_until_sdk_result_and_collects_exact_boot_child() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let (host, _, actors) = fixture(&root, None);
        let dispatch = actors.begin_boot("owned").unwrap();
        let (mut child, identity) = waiting_child();
        let actor = Actor {
            schema: 1,
            owner: host.owner,
            epoch: host.epoch.clone(),
            child: identity,
            role: Role::Boot {
                machine: dispatch.pending.machine.clone(),
                operation: dispatch.pending.operation.clone(),
            },
        };
        let path = actor_path(&actors.0.directory, identity);
        publish(&path, &actor).unwrap();
        drop(child.stdin.take());
        child.wait().unwrap();
        assert!(!actors.quiescent_for("owned").unwrap());
        assert!(path.exists()); // SDK result has not been resolved yet.
        let enrolled = dispatch.finish_enrollment(Some(identity.pid)).unwrap();
        assert!(enrolled.child() == identity);
        assert!(enrolled.intent().matches("owned", &host.epoch));
        assert!(!enrolled.intent().matches("foreign", &host.epoch));
        assert!(!enrolled.intent().matches("owned", &"f".repeat(32)));
        assert!(actors.quiescent_for("owned").unwrap());
        assert!(!path.exists());
        actors.close().unwrap();
        fence_previous(&root, &host.domain).unwrap();
    }
    #[test]
    fn sdk_pid_substitution_cannot_finalize_or_release_original_boot_intent() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let (host, _, actors) = fixture(&root, None);
        let dispatch = actors.begin_boot("owned").unwrap();
        let (mut child, identity) = waiting_child();
        let actor = Actor {
            schema: 1,
            owner: host.owner,
            epoch: host.epoch.clone(),
            child: identity,
            role: Role::Boot {
                machine: dispatch.pending.machine.clone(),
                operation: dispatch.pending.operation.clone(),
            },
        };
        let path = actor_path(&actors.0.directory, identity);
        publish(&path, &actor).unwrap();
        assert!(dispatch.finish_enrollment(Some(identity.pid + 1)).is_err());
        assert!(!actors.available());
        drop(child.stdin.take());
        child.wait().unwrap();
        assert!(!actors.quiescent_for("owned").unwrap());
        assert!(path.exists());
        assert!(fence_previous(&root, &host.domain).is_err());
    }

    #[test]
    #[ignore = "requires built helper; ordinary non-VM boot entry and normal config rejection"]
    fn ordinary_boot_guard_enrolls_before_sdk_and_collects_normal_exit() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let executable =
            PathBuf::from(std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper"));
        let (host, launcher, actors) = fixture(&root, Some(executable));
        let dispatch = actors.begin_boot("owned").unwrap();
        let directory = host
            .domain
            .vm_root
            .join(smolvm::agent::vm_dir_hash("owned"));
        std::fs::create_dir_all(&directory).unwrap();
        let config = directory.join("boot-config.json");
        std::fs::write(&config, b"{}").unwrap();
        std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mut command = Command::new(launcher.executable());
        command
            .args(["_boot-vm"])
            .arg(&config)
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        for variable in ["DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH"] {
            if let Some(value) = std::env::var_os(variable) {
                command.env(variable, value);
            }
        }
        let mut child = command.spawn().unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            assert!(
                Instant::now() < deadline,
                "normal boot-config rejection did not exit; no forced fallback"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(status.code(), Some(2));
        // Guard rejection cannot pass: it would leave no enrolled actor.
        dispatch.finish_enrollment(Some(child.id() as i32)).unwrap();
        assert!(actors.quiescent_for("owned").unwrap());
        actors.close().unwrap();
        fence_previous(&root, &host.domain).unwrap();
    }
}
