//! Transport-independent ownership and immutable boot context.
//!
//! Port captures the helper identity; a future direct Rustler engine captures
//! BEAM's identity. Only the separately executed boot launcher arms the watcher.
use crate::domain::{valid_hex, valid_id};
use crate::{DomainBinding, Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

const CONTEXT_BYTES: u64 = 8192;
const EXECUTABLE_BYTES: u64 = 256 * 1024 * 1024;
const LAUNCHER_NAME: &str = "smolbox-boot";

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OwnerIdentity {
    pub pid: i32,
    pub birth: u64,
    pub uid: u32,
}

impl OwnerIdentity {
    pub fn capture() -> Result<Self> {
        let pid = std::process::id() as i32;
        let birth = smolvm::process::process_start_time(pid)
            .filter(|birth| *birth != 0)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        Ok(Self {
            pid,
            birth,
            uid: unsafe { libc::geteuid() },
        })
    }

    pub(crate) fn is_current_parent(&self) -> bool {
        self.matches(
            unsafe { libc::getppid() },
            smolvm::process::process_start_time(self.pid),
            unsafe { libc::geteuid() },
        )
    }

    /// Only for a separately executed owned subprocess, never the controller.
    pub(crate) fn arm_subprocess_watch(&self) -> Result<()> {
        if !self.is_current_parent() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let owner_pid = self.pid;
        let (ready, started) = std::sync::mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("smolbox-owner-watch".into())
            .spawn(move || {
                if unsafe { libc::getppid() } != owner_pid || ready.send(()).is_err() {
                    return;
                }
                loop {
                    if unsafe { libc::getppid() } != owner_pid {
                        unsafe { libc::_exit(0) };
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            })
            .map_err(|_| Error::before(ErrorCode::Native))?;
        started
            .recv_timeout(std::time::Duration::from_secs(1))
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if !self.is_current_parent() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }

    fn matches(&self, parent: i32, birth: Option<u64>, uid: u32) -> bool {
        self.pid > 0
            && self.birth != 0
            && parent == self.pid
            && birth == Some(self.birth)
            && uid == self.uid
    }
}

/// Approved executable bytes, supplied by the bridge's verified package.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Executable {
    pub path: PathBuf,
    pub sha256: String,
}

#[derive(Clone)]
pub struct ExecutableLocator {
    pub boot: Executable,
    pub file_worker: Executable,
    /// Verified package libraries, passed only to subprocess loader environment.
    pub library_directory: PathBuf,
}

#[derive(Clone)]
pub struct HostContext {
    pub owner: OwnerIdentity,
    pub domain: DomainBinding,
    pub epoch: String,
    pub package_sha256: String,
    pub executables: ExecutableLocator,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct BootContext {
    schema: u32,
    pub(crate) owner: OwnerIdentity,
    pub(crate) domain: DomainBinding,
    pub(crate) epoch: String,
    package_sha256: String,
    executable_sha256: String,
}

/// Context is retained after drop: only the engine can establish that all epoch
/// children were collected before retiring the launcher directory.
pub struct BootLauncher {
    executable: PathBuf,
}

impl HostContext {
    pub fn capture(
        domain: DomainBinding,
        epoch: String,
        package_sha256: String,
        executables: ExecutableLocator,
    ) -> Result<Self> {
        let context = Self {
            owner: OwnerIdentity::capture()?,
            domain,
            epoch,
            package_sha256,
            executables,
        };
        context.validate()?;
        Ok(context)
    }

    pub(crate) fn validate(&self) -> Result<()> {
        if !valid_id(&self.domain.target_id)
            || !valid_hex(&self.domain.generation, 32)
            || !self.domain.database.is_absolute()
            || !self.domain.vm_root.is_absolute()
            || !valid_hex(&self.epoch, 32)
            || !valid_hex(&self.package_sha256, 64)
            || self.owner != OwnerIdentity::capture()?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        verified_executable(&self.executables.boot)?;
        verified_executable(&self.executables.file_worker)?;
        unredirected(&self.executables.library_directory)?;
        if !self.executables.library_directory.is_dir() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }

    /// Copy the approved executable unchanged, then publish bounded immutable
    /// owner context. No global owner file, inherited secret or env mutation.
    pub fn prepare_boot_launcher(&self, owned_directory: &Path) -> Result<BootLauncher> {
        self.validate()?;
        private_directory(owned_directory)?;
        let epochs = owned_directory.join("epochs");
        if let Err(error) = private_create_directory(&epochs) {
            if error.kind() != std::io::ErrorKind::AlreadyExists {
                return Err(Error::before(ErrorCode::Io));
            }
        }
        private_directory(&epochs)?;
        let directory = epochs.join(&self.epoch);
        private_create_directory(&directory).map_err(|_| Error::before(ErrorCode::Conflict))?;
        let executable = directory.join(LAUNCHER_NAME);
        let mut source = verified_executable(&self.executables.boot)?;
        let mut destination = private_new(&executable)?;
        std::io::copy(&mut source, &mut destination).map_err(|_| Error::before(ErrorCode::Io))?;
        destination
            .set_permissions(std::fs::Permissions::from_mode(0o500))
            .and_then(|()| destination.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        verified_executable(&Executable {
            path: executable.clone(),
            sha256: self.executables.boot.sha256.clone(),
        })?;
        let context = BootContext {
            schema: 1,
            owner: self.owner,
            domain: self.domain.clone(),
            epoch: self.epoch.clone(),
            package_sha256: self.package_sha256.clone(),
            executable_sha256: self.executables.boot.sha256.clone(),
        };
        let bytes =
            serde_json::to_vec(&context).map_err(|_| Error::before(ErrorCode::Validation))?;
        if bytes.len() as u64 > CONTEXT_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        let mut context_file = private_new(&directory.join("owner.json"))?;
        context_file
            .write_all(&bytes)
            .and_then(|()| context_file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        context_file
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .and_then(|()| context_file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        File::open(&directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        File::open(&epochs)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        Ok(BootLauncher { executable })
    }
}

impl BootLauncher {
    pub fn executable(&self) -> &Path {
        &self.executable
    }

    /// Invoke only inside a boot subprocess, before calling the SDK boot entry.
    /// Not an engine/NIF initialization operation. Reads no arbitrary argv path.
    pub fn arm_current(config: &Path) -> Result<()> {
        let executable = std::env::current_exe().map_err(|_| Error::before(ErrorCode::Io))?;
        let context = Self::read_context(&executable)?;
        // The SDK's boot config must be a machine-local file within this domain.
        if !config.is_absolute()
            || config.file_name() != Some("boot-config.json".as_ref())
            || !config.starts_with(&context.domain.vm_root)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        unredirected(config)?;
        let metadata =
            std::fs::symlink_metadata(config).map_err(|_| Error::before(ErrorCode::Io))?;
        if !metadata.is_file()
            || metadata.uid() != context.owner.uid
            || metadata.mode() & 0o022 != 0
            || metadata.len() > 1024 * 1024
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if !context.owner.is_current_parent() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // The synchronous birth check establishes authority. After sandboxing,
        // only getppid/nanosleep/_exit are needed; no /proc reads or inherited FD.
        context.owner.arm_subprocess_watch()?;
        crate::epoch::register_boot(
            executable.parent().unwrap(),
            context.owner,
            &context.epoch,
            &context.domain,
            config,
        )
    }

    pub(crate) fn read_context(executable: &Path) -> Result<BootContext> {
        if executable.file_name() != Some(LAUNCHER_NAME.as_ref()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let directory = executable
            .parent()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        private_directory(directory)?;
        let path = directory.join("owner.json");
        unredirected(&path)?;
        let file = private_read(&path)?;
        let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if metadata.len() > CONTEXT_BYTES || metadata.mode() & 0o777 != 0o400 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let context: BootContext = serde_json::from_reader(file.take(CONTEXT_BYTES + 1))
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if context.schema != 1
            || !valid_hex(&context.epoch, 32)
            || directory.file_name() != Some(context.epoch.as_ref())
            || !valid_hex(&context.package_sha256, 64)
            || !valid_hex(&context.domain.generation, 32)
            || !valid_id(&context.domain.target_id)
            || !context.domain.vm_root.is_absolute()
            || !context.domain.database.is_absolute()
            || context.owner.pid <= 0
            || context.owner.birth == 0
            || context.owner.uid != unsafe { libc::geteuid() }
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if std::fs::symlink_metadata(executable)
            .map_err(|_| Error::before(ErrorCode::Io))?
            .mode()
            & 0o777
            != 0o500
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        verified_executable(&Executable {
            path: executable.to_path_buf(),
            sha256: context.executable_sha256.clone(),
        })?;
        Ok(context)
    }
}

fn private_create_directory(path: &Path) -> std::io::Result<()> {
    std::fs::DirBuilder::new().mode(0o700).create(path)
}

pub(crate) fn private_directory(path: &Path) -> Result<()> {
    unredirected(path)?;
    let metadata = std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

pub(crate) fn unredirected(path: &Path) -> Result<()> {
    if !path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir | std::path::Component::CurDir
            )
        })
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    for ancestor in path.ancestors() {
        let metadata =
            std::fs::symlink_metadata(ancestor).map_err(|_| Error::before(ErrorCode::Io))?;
        if metadata.file_type().is_symlink() {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    Ok(())
}

fn private_new(path: &Path) -> Result<File> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))
}

fn private_read(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(file)
}

pub(crate) fn verified_executable(executable: &Executable) -> Result<File> {
    if !valid_hex(&executable.sha256, 64) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    unredirected(&executable.path)?;
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(&executable.path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_file()
        || (metadata.uid() != 0 && metadata.uid() != unsafe { libc::geteuid() })
        || metadata.len() > EXECUTABLE_BYTES
        || metadata.mode() & 0o022 != 0
        || metadata.mode() & 0o100 == 0
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut hash = Sha256::new();
    let count = std::io::copy(
        &mut Read::by_ref(&mut file).take(EXECUTABLE_BYTES + 1),
        &mut hash,
    )
    .map_err(|_| Error::before(ErrorCode::Io))?;
    if count != metadata.len() || hex::encode(hash.finalize()) != executable.sha256 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    use std::io::Seek;
    file.rewind().map_err(|_| Error::before(ErrorCode::Io))?;
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(root: &Path) -> HostContext {
        std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = root.join("approved-executable");
        std::fs::write(&path, b"approved native executable bytes").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o500)).unwrap();
        let executable = Executable {
            path,
            sha256: hex::encode(Sha256::digest(b"approved native executable bytes")),
        };
        HostContext::capture(
            DomainBinding {
                target_id: "owned".into(),
                generation: "a".repeat(32),
                database: root.join("db"),
                vm_root: root.join("vms"),
            },
            "b".repeat(32),
            "c".repeat(64),
            ExecutableLocator {
                boot: executable.clone(),
                file_worker: executable,
                library_directory: root.to_path_buf(),
            },
        )
        .unwrap()
    }

    #[test]
    fn captured_owner_requires_exact_parent_birth_and_uid() {
        let owner = OwnerIdentity::capture().unwrap();
        assert!(owner.matches(owner.pid, Some(owner.birth), owner.uid));
        assert!(!owner.matches(owner.pid + 1, Some(owner.birth), owner.uid));
        assert!(!owner.matches(owner.pid, Some(owner.birth + 1), owner.uid));
        assert!(!owner.matches(owner.pid, None, owner.uid));
        assert!(!owner.matches(owner.pid, Some(owner.birth), owner.uid + 1));
    }

    #[test]
    fn launcher_preserves_bytes_and_immutable_epoch_context() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let mut host = fixture(&root);
        let first = host.prepare_boot_launcher(&root).unwrap();
        let context = BootLauncher::read_context(first.executable()).unwrap();
        assert!(context.owner == host.owner);
        assert_eq!(context.epoch, host.epoch);
        assert_eq!(context.package_sha256, host.package_sha256);
        assert_eq!(
            std::fs::read(first.executable()).unwrap(),
            std::fs::read(&host.executables.boot.path).unwrap()
        );
        assert!(host.prepare_boot_launcher(&root).is_err());
        host.epoch = "d".repeat(32);
        let second = host.prepare_boot_launcher(&root).unwrap();
        assert_eq!(
            BootLauncher::read_context(first.executable())
                .unwrap()
                .epoch,
            "b".repeat(32)
        );
        assert_eq!(
            BootLauncher::read_context(second.executable())
                .unwrap()
                .epoch,
            "d".repeat(32)
        );
        drop(first);
        assert!(root
            .join("epochs")
            .join("b".repeat(32))
            .join("owner.json")
            .exists());
    }

    #[test]
    fn redirected_mutable_malformed_or_relabelled_context_is_refused() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let host = fixture(&root);
        let launcher = host.prepare_boot_launcher(&root).unwrap();
        let path = launcher.executable().parent().unwrap().join("owner.json");
        let original = std::fs::read(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(BootLauncher::read_context(launcher.executable()).is_err());
        std::fs::write(&path, b"{}").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert!(BootLauncher::read_context(launcher.executable()).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
        value["epoch"] = "e".repeat(32).into();
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert!(BootLauncher::read_context(launcher.executable()).is_err());
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&host.executables.boot.path, &path).unwrap();
        assert!(BootLauncher::read_context(launcher.executable()).is_err());
    }

    #[test]
    fn changed_executable_and_redirected_epoch_roots_are_refused() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let mut host = fixture(&root);
        host.executables.boot.sha256 = "0".repeat(64);
        assert!(host.prepare_boot_launcher(&root).is_err());
        host.executables.boot = host.executables.file_worker.clone();
        let outside = root.join("outside");
        private_create_directory(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("epochs")).unwrap();
        assert!(host.prepare_boot_launcher(&root).is_err());
        assert!(std::fs::read_dir(&outside).unwrap().next().is_none());
    }

    #[test]
    fn oversized_executable_is_refused_before_hashing_its_sparse_contents() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("oversized-test-model");
        let file = File::create(&path).unwrap();
        file.set_len(EXECUTABLE_BYTES + 1).unwrap();
        file.set_permissions(std::fs::Permissions::from_mode(0o500))
            .unwrap();
        let error = verified_executable(&Executable {
            path,
            sha256: "0".repeat(64),
        })
        .unwrap_err();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
    }

    #[test]
    fn copied_test_executable_loads_and_exits_normally_without_vm_dispatch() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let mut host = fixture(&root);
        let original = std::env::current_exe().unwrap();
        let executable = Executable {
            sha256: hex::encode(Sha256::digest(std::fs::read(&original).unwrap())),
            path: original,
        };
        host.executables = ExecutableLocator {
            boot: executable.clone(),
            file_worker: executable,
            library_directory: root.to_path_buf(),
        };
        let launcher = host.prepare_boot_launcher(&root).unwrap();
        // --list invokes only Rust's test listing, never any test or VM entry.
        let status = std::process::Command::new(launcher.executable())
            .arg("--list")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success());
        #[cfg(target_os = "macos")]
        assert!(std::process::Command::new("/usr/bin/codesign")
            .args(["--verify", "--strict"])
            .arg(launcher.executable())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success());
    }
}
