//! Four bounded file workers. Owned leases and spool admission survive uncertain
//! collection; no waitpid sweep or transport request ID is used as authority.
use crate::host::{private_directory, verified_executable};
use crate::transfer_worker::{self as ipc, Decoder, Evidence, Kind, Request, MAX_TRANSFER};
use crate::{
    Cancellation, Dispatch, Error, ErrorCode, Executable, FileCompletion, FileOptions, FileOutcome,
    HostContext, OwnerIdentity, Result,
};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const WORKERS: usize = 4;
const SPOOL_BYTES: u64 = WORKERS as u64 * MAX_TRANSFER;
const POLL: Duration = Duration::from_millis(5);

/// Only used beneath the verified, exclusively owned domain directory. An older
/// helper could create this child with mode 0755; tighten its permissions without
/// touching spool contents. Never accept a redirected, foreign or writable alias.
pub(crate) fn prepare_directory(path: &Path) -> Result<()> {
    private_directory(path.parent().ok_or(Error::before(ErrorCode::Ownership))?)?;
    match std::fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err(Error::before(ErrorCode::Io)),
    }
    let directory = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    let before = directory
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    if !before.is_dir() || before.uid() != unsafe { libc::geteuid() } || before.mode() & 0o022 != 0
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    directory
        .set_permissions(std::fs::Permissions::from_mode(0o700))
        .and_then(|()| directory.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    private_directory(path)?;
    let after = std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Io))?;
    if (before.dev(), before.ino()) != (after.dev(), after.ino()) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

#[derive(Default)]
struct Budget {
    workers: usize,
    bytes: u64,
}
#[derive(Default)]
struct Shared {
    budget: Mutex<Budget>,
    unavailable: AtomicBool,
}
struct Permit {
    shared: Arc<Shared>,
    bytes: u64,
}
impl Drop for Permit {
    fn drop(&mut self) {
        let mut budget = self
            .shared
            .budget
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        budget.workers -= 1;
        budget.bytes -= self.bytes;
    }
}

/// Deletes only the original inode, including when the SDK already removed a
/// failed read spool. A replacement or redirected path is never cleanup authority.
pub(crate) struct Spool {
    pub file: File,
    pub path: PathBuf,
    identity: (u64, u64),
}
impl Spool {
    fn new(directory: &Path) -> Result<Self> {
        private_directory(directory)?;
        let temporary =
            tempfile::NamedTempFile::new_in(directory).map_err(|_| Error::before(ErrorCode::Io))?;
        let metadata = temporary
            .as_file()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let (file, path) = temporary.keep().map_err(|_| Error::before(ErrorCode::Io))?;
        Ok(Self {
            file,
            path,
            identity: (metadata.dev(), metadata.ino()),
        })
    }
    pub(crate) fn verify(&self) -> Result<()> {
        let metadata =
            std::fs::symlink_metadata(&self.path).map_err(|_| Error::uncertain(ErrorCode::Io))?;
        if !metadata.is_file() || (metadata.dev(), metadata.ino()) != self.identity {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Drop for Spool {
    fn drop(&mut self) {
        if std::fs::symlink_metadata(&self.path).is_ok_and(|metadata| {
            metadata.is_file() && (metadata.dev(), metadata.ino()) == self.identity
        }) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

pub(crate) struct Prepared {
    pub request: Request,
    pub spool: Spool,
    _permit: Permit,
}
impl Prepared {
    /// Caller adapters supply a bounded local source. Never feed an arbitrary
    /// blocking user reader on a BEAM scheduler. This step precedes guest dispatch.
    pub(crate) fn upload(
        &mut self,
        mut source: impl Read,
        deadline: Instant,
        cancel: &Cancellation,
    ) -> Result<()> {
        let Kind::Write { total, .. } = self.request.kind else {
            return Err(Error::before(ErrorCode::Validation));
        };
        let mut copied = 0;
        let mut buffer = [0; ipc::CHUNK as usize];
        while copied < total {
            check_budget(deadline, cancel)?;
            let count = source
                .read(&mut buffer[..((total - copied) as usize).min(ipc::CHUNK as usize)])
                .map_err(|_| Error::before(ErrorCode::Io))?;
            if count == 0 {
                return Err(Error::before(ErrorCode::Validation));
            }
            self.spool
                .file
                .write_all(&buffer[..count])
                .map_err(|_| Error::before(ErrorCode::Io))?;
            copied += count as u64;
        }
        check_budget(deadline, cancel)?;
        if source
            .read(&mut [0; 1])
            .map_err(|_| Error::before(ErrorCode::Io))?
            != 0
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.spool
            .file
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        Ok(())
    }
}

pub(crate) struct Collected {
    pub outcome: FileOutcome,
    pub prepared: Prepared,
    // Includes domain, machine and SDK source leases; retained through forwarding.
    _leases: Box<dyn Send>,
    #[cfg(test)]
    worker_ready: bool,
    #[cfg(test)]
    termination_requested: bool,
}

pub(crate) enum RunResult {
    Collected(Box<Collected>),
    Retained(FileOutcome),
}

pub(crate) struct TransferSupervisor {
    shared: Arc<Shared>,
    executable: Executable,
    libraries: PathBuf,
    owner: OwnerIdentity,
    epoch: Option<crate::epoch::ActorEpoch>,
}
impl TransferSupervisor {
    pub(crate) fn new(host: &HostContext) -> Result<Self> {
        host.validate()?;
        Ok(Self {
            shared: Arc::new(Shared::default()),
            executable: host.executables.file_worker.clone(),
            libraries: host.executables.library_directory.clone(),
            owner: host.owner,
            epoch: None,
        })
    }

    pub(crate) fn available(&self) -> bool {
        !self.shared.unavailable.load(Ordering::Acquire)
    }
    pub(crate) fn set_epoch(&mut self, epoch: crate::epoch::ActorEpoch) {
        self.epoch = Some(epoch);
    }

    fn admit(&self, bytes: u64) -> Result<Permit> {
        if !self.available() || bytes == 0 || bytes > MAX_TRANSFER {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let mut budget = self
            .shared
            .budget
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if budget.workers >= WORKERS || budget.bytes + bytes > SPOOL_BYTES {
            return Err(Error::before(ErrorCode::Conflict));
        }
        fd_admission(budget.workers + 1)?;
        budget.workers += 1;
        budget.bytes += bytes;
        Ok(Permit {
            shared: self.shared.clone(),
            bytes,
        })
    }

    pub(crate) fn prepare(
        &self,
        directory: &Path,
        socket: PathBuf,
        options: &FileOptions,
        kind: Kind,
    ) -> Result<Prepared> {
        options.validate(matches!(kind, Kind::Write { .. }))?;
        let permit = self.admit(options.max_bytes)?;
        let spool = Spool::new(directory)?;
        let mut nonce = [0; 16];
        getrandom::fill(&mut nonce).map_err(|_| Error::before(ErrorCode::Native))?;
        let request = Request {
            schema: 1,
            operation: hex::encode(nonce),
            owner: self.owner,
            socket,
            staging: spool.path.clone(),
            staging_device: spool.identity.0,
            staging_inode: spool.identity.1,
            guest_path: options.guest_path.clone(),
            max_bytes: options.max_bytes,
            kind,
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: permit,
        })
    }

    /// Leases must be owned, transferable RAII guards. The caller may return on
    /// a finite deadline while a quarantined collector retains all those guards.
    pub(crate) fn run(
        &self,
        prepared: Prepared,
        leases: Box<dyn Send>,
        deadline: Instant,
        cancel: &Cancellation,
    ) -> Result<RunResult> {
        check_budget(deadline, cancel)?;
        verified_executable(&self.executable)?;
        check_budget(deadline, cancel)?;
        let request_bytes = ipc::encode(&prepared.request)?;
        let mut child = Command::new(&self.executable.path)
            .arg("--file-worker")
            .env_clear()
            .env(
                if cfg!(target_os = "macos") {
                    "DYLD_LIBRARY_PATH"
                } else {
                    "LD_LIBRARY_PATH"
                },
                std::env::join_paths([&self.libraries])
                    .map_err(|_| Error::before(ErrorCode::Validation))?,
            )
            .current_dir(
                prepared
                    .spool
                    .path
                    .parent()
                    .ok_or(Error::before(ErrorCode::Validation))?,
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let birth = smolvm::process::process_start_time(child.id() as i32);
        let input = child.stdin.take();
        let output = child.stdout.take();
        let mut owned = Owned {
            child,
            birth,
            input,
            output,
            prepared,
            _leases: leases,
        };
        let mut evidence = Evidence::new(&owned.prepared.request);
        let mut decoder = Decoder::default();
        let mut sent = 0;
        let mut pipe_eof = false;
        let mut reason = None;
        let mut policy = CollectionPolicy::default();
        let origin = Instant::now();
        let nonblocking = owned
            .input
            .as_ref()
            .is_some_and(|pipe| set_nonblocking(pipe.as_raw_fd()).is_ok())
            && owned
                .output
                .as_ref()
                .is_some_and(|pipe| set_nonblocking(pipe.as_raw_fd()).is_ok());
        let enrolled = self.epoch.as_ref().is_none_or(|epoch| {
            birth.is_some_and(|birth| {
                epoch
                    .register_transfer(
                        OwnerIdentity {
                            pid: owned.child.id() as i32,
                            birth,
                            uid: self.owner.uid,
                        },
                        &owned.prepared.request.operation,
                        owned
                            .prepared
                            .request
                            .socket
                            .parent()
                            .and_then(|path| path.file_name())
                            .and_then(|name| name.to_str())
                            .unwrap_or(""),
                    )
                    .is_ok()
            })
        });
        if !nonblocking || !enrolled {
            reason = Some(FileCompletion::NativeError);
            policy.retire(origin.elapsed());
        }
        loop {
            let expired = Instant::now() >= deadline;
            if reason.is_none() && (expired || cancel.is_cancelled()) {
                reason = Some(if expired {
                    FileCompletion::Deadline
                } else {
                    FileCompletion::Cancelled
                });
                policy.retire(origin.elapsed());
            }
            if reason.is_none() && sent < request_bytes.len() {
                match owned.input.as_mut().unwrap().write(&request_bytes[sent..]) {
                    Ok(0) => {
                        reason = Some(FileCompletion::NativeError);
                        policy.retire(origin.elapsed());
                    }
                    Ok(count) => sent += count,
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                        ) => {}
                    Err(_) => {
                        reason = Some(FileCompletion::NativeError);
                        policy.retire(origin.elapsed());
                    }
                }
                if sent == request_bytes.len() {
                    owned.input.take();
                }
            }
            if reason.is_some() {
                evidence.retire();
            }
            if nonblocking && !pipe_eof {
                let mut buffer = [0; 8192];
                // Drain at most a finite batch each tick so cancellation/control
                // work remains responsive even to malformed endless output.
                for _ in 0..4 {
                    match owned.output.as_mut().unwrap().read(&mut buffer) {
                        Ok(0) => {
                            pipe_eof = true;
                            break;
                        }
                        Ok(count) if reason.is_none() => {
                            let valid = decoder.feed(&buffer[..count]).and_then(|events| {
                                for event in events {
                                    evidence.event(event)?;
                                }
                                Ok(())
                            });
                            if valid.is_err() {
                                reason = Some(FileCompletion::NativeError);
                                policy.retire(origin.elapsed());
                            }
                        }
                        Ok(_) => {} // retired acknowledgments are never promoted
                        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(_) => {
                            reason = Some(FileCompletion::NativeError);
                            policy.retire(origin.elapsed());
                            break;
                        }
                    }
                }
            }
            // Only this exact Child handle consumes its exit status.
            if let Ok(Some(status)) = owned.child.try_wait() {
                // A real file worker has no descendants holding its output pipe.
                // Pending output is bounded and is drained before final evidence.
                if nonblocking && !pipe_eof && reason.is_none() {
                    continue;
                }
                let completion = reason.unwrap_or(
                    if status.success() && evidence.acknowledged && decoder.complete() {
                        FileCompletion::Completed
                    } else {
                        FileCompletion::NativeError
                    },
                );
                let outcome = FileOutcome {
                    completion,
                    dispatch: if sent == 0 {
                        Dispatch::NotDispatched
                    } else {
                        Dispatch::MayHaveDispatched
                    },
                    observed_bytes: evidence.observed_bytes,
                    native_acknowledged: evidence.acknowledged,
                };
                return Ok(RunResult::Collected(Box::new(Collected {
                    outcome,
                    prepared: owned.prepared,
                    _leases: owned._leases,
                    #[cfg(test)]
                    worker_ready: evidence.ready(),
                    #[cfg(test)]
                    termination_requested: policy.next > 1,
                })));
            }
            if pipe_eof && reason.is_none() && !evidence.acknowledged {
                reason = Some(FileCompletion::NativeError);
                policy.retire(origin.elapsed());
            }
            match policy.step(origin.elapsed()) {
                Some(Action::Close) => {
                    owned.input.take();
                }
                Some(Action::Terminate) => owned.signal(libc::SIGTERM),
                Some(Action::Kill) => owned.signal(libc::SIGKILL),
                Some(Action::Retain) => {
                    self.shared.unavailable.store(true, Ordering::Release);
                    let outcome = FileOutcome {
                        completion: reason.unwrap_or(FileCompletion::NativeError),
                        dispatch: if sent == 0 {
                            Dispatch::NotDispatched
                        } else {
                            Dispatch::MayHaveDispatched
                        },
                        observed_bytes: evidence.observed_bytes,
                        native_acknowledged: evidence.acknowledged,
                    };
                    retain_until_collected(owned);
                    return Ok(RunResult::Retained(outcome));
                }
                None => {}
            }
            std::thread::sleep(POLL);
        }
    }
}

struct Owned {
    child: Child,
    birth: Option<u64>,
    input: Option<ChildStdin>,
    output: Option<ChildStdout>,
    prepared: Prepared,
    _leases: Box<dyn Send>,
}
impl Owned {
    fn signal(&mut self, signal: i32) {
        // A live, unreaped direct child cannot have its PID reused. Check birth
        // too; an unavailable/mismatched identity never authorizes a signal.
        if matches!(self.child.try_wait(), Ok(None))
            && self.birth.is_some_and(|birth| {
                smolvm::process::process_start_time(self.child.id() as i32) == Some(birth)
            })
        {
            unsafe { libc::kill(self.child.id() as i32, signal) };
        }
    }
}

fn retain_until_collected(owned: Owned) {
    let (send, receive) = std::sync::mpsc::sync_channel::<Owned>(1);
    let collector = std::thread::Builder::new()
        .name("smolbox-transfer-collect".into())
        .spawn(move || {
            if let Ok(mut owned) = receive.recv() {
                let draining = owned
                    .output
                    .as_ref()
                    .is_some_and(|pipe| set_nonblocking(pipe.as_raw_fd()).is_ok());
                // Admission bounds these retained native collectors to four. Never
                // block a BEAM scheduler/destructor or release leases on timeout.
                loop {
                    if draining {
                        let mut buffer = [0; 8192];
                        for _ in 0..4 {
                            match owned.output.as_mut().unwrap().read(&mut buffer) {
                                Ok(0) | Err(_) => break,
                                Ok(_) => {} // late messages cannot revive authority
                            }
                        }
                    }
                    if owned.child.try_wait().ok().flatten().is_some() {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        });
    if collector.is_ok() {
        if let Err(error) = send.send(owned) {
            Box::leak(Box::new(error.0));
        }
    } else {
        // Fail closed if even the bounded native collector cannot start. The
        // process retains the guards until exit; admission remains unavailable.
        Box::leak(Box::new(owned));
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Close,
    Terminate,
    Kill,
    Retain,
}
#[derive(Default)]
struct CollectionPolicy {
    retired: Option<Duration>,
    next: u8,
}
impl CollectionPolicy {
    fn retire(&mut self, now: Duration) {
        if self.retired.is_none() {
            self.retired = Some(now);
        }
    }
    fn step(&mut self, now: Duration) -> Option<Action> {
        let elapsed = now.checked_sub(self.retired?)?;
        let (after, action) = match self.next {
            0 => (Duration::ZERO, Action::Close),
            1 => (Duration::from_millis(100), Action::Terminate),
            2 => (Duration::from_millis(200), Action::Kill),
            3 => (Duration::from_millis(2200), Action::Retain),
            _ => return None,
        };
        if elapsed < after {
            return None;
        }
        self.next += 1;
        Some(action)
    }
}

fn set_nonblocking(fd: i32) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(Error::before(ErrorCode::Io));
    }
    Ok(())
}
fn check_budget(deadline: Instant, cancel: &Cancellation) -> Result<()> {
    if Instant::now() >= deadline || cancel.is_cancelled() {
        return Err(Error::before(ErrorCode::State));
    }
    Ok(())
}
fn fd_admission(reserved_workers: usize) -> Result<()> {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        return Err(Error::before(ErrorCode::Io));
    }
    let directory = if cfg!(target_os = "linux") {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    };
    let used = std::fs::read_dir(directory)
        .map_err(|_| Error::before(ErrorCode::Io))?
        .count() as u64;
    // Four parent-side descriptors for this worker plus eight for control work.
    if used.saturating_add(8 + reserved_workers as u64 * 4) > limit.rlim_cur {
        return Err(Error::before(ErrorCode::Conflict));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    #[test]
    fn spool_directory_is_private_and_old_owned_permissions_tighten_without_content_changes() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().canonicalize().unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.join("transfers");
        prepare_directory(&path).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o700);
        let spool = path.join("retained");
        std::fs::write(&spool, b"owned uncertain contents").unwrap();
        let inode = std::fs::metadata(&path).unwrap().ino();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        prepare_directory(&path).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().ino(), inode);
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o700);
        assert_eq!(std::fs::read(&spool).unwrap(), b"owned uncertain contents");
    }

    #[test]
    fn spool_directory_refuses_shared_write_redirected_and_non_directory_paths() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().canonicalize().unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.join("transfers");
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(prepare_directory(&path).is_err());
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o777);
        let alias = directory.join("alias");
        std::os::unix::fs::symlink(&path, &alias).unwrap();
        assert!(prepare_directory(&alias).is_err());
        let file = directory.join("file");
        std::fs::write(&file, b"foreign").unwrap();
        assert!(prepare_directory(&file).is_err());
        assert_eq!(std::fs::read(file).unwrap(), b"foreign");
    }
    fn supervisor(root: &Path, executable: PathBuf) -> TransferSupervisor {
        std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let identity = Executable {
            sha256: hex::encode(Sha256::digest(std::fs::read(&executable).unwrap())),
            path: executable,
        };
        let libraries = std::env::var_os("LIBKRUN_BUNDLE")
            .map(PathBuf::from)
            .unwrap_or(root.into());
        let host = HostContext::capture(
            crate::DomainBinding {
                target_id: "owned".into(),
                generation: "a".repeat(32),
                database: root.join("db"),
                vm_root: root.into(),
            },
            "b".repeat(32),
            "c".repeat(64),
            crate::ExecutableLocator {
                boot: identity.clone(),
                file_worker: identity,
                library_directory: libraries,
            },
        )
        .unwrap();
        TransferSupervisor::new(&host).unwrap()
    }
    fn options() -> FileOptions {
        FileOptions {
            guest_path: "/workspace/data".into(),
            max_bytes: MAX_TRANSFER,
            timeout: Duration::from_secs(10),
            mode: None,
        }
    }
    fn root(temporary: &tempfile::TempDir) -> PathBuf {
        temporary.path().canonicalize().unwrap()
    }

    #[test]
    fn four_spools_bound_admission_and_retained_permits_remain_charged() {
        let directory = tempfile::tempdir().unwrap();
        let root = root(&directory);
        let supervisor = supervisor(&root, "/usr/bin/true".into());
        let mut prepared = (0..WORKERS)
            .map(|_| {
                supervisor
                    .prepare(&root, root.join("agent.sock"), &options(), Kind::Read)
                    .unwrap()
            })
            .collect::<Vec<_>>();
        assert_eq!(supervisor.shared.budget.lock().unwrap().bytes, SPOOL_BYTES);
        assert_eq!(
            supervisor
                .prepare(&root, root.join("agent.sock"), &options(), Kind::Read)
                .err()
                .unwrap()
                .code,
            ErrorCode::Conflict
        );
        drop(prepared.pop());
        supervisor
            .prepare(&root, root.join("agent.sock"), &options(), Kind::Read)
            .unwrap();
        supervisor.shared.unavailable.store(true, Ordering::Release);
        assert!(supervisor
            .prepare(&root, root.join("agent.sock"), &options(), Kind::Read)
            .is_err());
        assert_eq!(supervisor.shared.budget.lock().unwrap().workers, 3);
        drop(prepared);
        assert_eq!(supervisor.shared.budget.lock().unwrap().workers, 0);
        assert!(!supervisor.available()); // only explicit engine replacement re-enrolls
    }

    #[test]
    fn exact_short_and_overlong_uploads_are_resolved_before_dispatch() {
        let directory = tempfile::tempdir().unwrap();
        let root = root(&directory);
        let supervisor = supervisor(&root, "/usr/bin/true".into());
        for (bytes, valid) in [(b"ab".as_slice(), false), (b"abc", true), (b"abcd", false)] {
            let mut prepared = supervisor
                .prepare(
                    &root,
                    root.join("agent.sock"),
                    &options(),
                    Kind::Write {
                        total: 3,
                        mode: Some(0o600),
                    },
                )
                .unwrap();
            assert_eq!(
                prepared
                    .upload(
                        bytes,
                        Instant::now() + Duration::from_secs(1),
                        &Cancellation::new()
                    )
                    .is_ok(),
                valid
            );
            if valid {
                assert_eq!(prepared.spool.file.metadata().unwrap().len(), 3);
            }
        }
        let cancel = Cancellation::new();
        cancel.cancel();
        let mut prepared = supervisor
            .prepare(
                &root,
                root.join("agent.sock"),
                &options(),
                Kind::Write {
                    total: 3,
                    mode: None,
                },
            )
            .unwrap();
        assert!(prepared
            .upload(
                b"abc".as_slice(),
                Instant::now() + Duration::from_secs(1),
                &cancel
            )
            .is_err());
        assert_eq!(prepared.spool.file.metadata().unwrap().len(), 0);
    }

    #[test]
    fn spool_cleanup_never_unlinks_a_replaced_foreign_inode() {
        let directory = tempfile::tempdir().unwrap();
        let root = root(&directory);
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let spool = Spool::new(&root).unwrap();
        let path = spool.path.clone();
        std::fs::rename(&path, root.join("original")).unwrap();
        std::fs::write(&path, b"foreign replacement").unwrap();
        assert!(spool.verify().is_err());
        drop(spool);
        assert_eq!(std::fs::read(&path).unwrap(), b"foreign replacement");
    }

    #[test]
    fn modeled_cancel_escalation_is_finite_and_cannot_reset_its_deadline() {
        let mut policy = CollectionPolicy::default();
        assert_eq!(policy.step(Duration::from_secs(20)), None);
        policy.retire(Duration::from_secs(20));
        assert_eq!(policy.step(Duration::from_secs(20)), Some(Action::Close));
        assert_eq!(policy.step(Duration::from_millis(20099)), None);
        assert_eq!(
            policy.step(Duration::from_millis(20100)),
            Some(Action::Terminate)
        );
        policy.retire(Duration::from_secs(99));
        assert_eq!(
            policy.step(Duration::from_millis(20200)),
            Some(Action::Kill)
        );
        assert_eq!(policy.step(Duration::from_millis(22199)), None);
        assert_eq!(
            policy.step(Duration::from_millis(22200)),
            Some(Action::Retain)
        );
        assert_eq!(policy.step(Duration::from_secs(100)), None);
    }

    fn normal_child(executable: PathBuf, ready: bool) {
        let directory = tempfile::tempdir().unwrap();
        let root = root(&directory);
        let supervisor = supervisor(&root, executable);
        let prepared = supervisor
            .prepare(&root, root.join("agent.sock"), &options(), Kind::Read)
            .unwrap();
        let source = crate::sdk_compat::source_lease(&root, "owned").unwrap();
        let result = supervisor
            .run(
                prepared,
                Box::new(source),
                Instant::now() + Duration::from_secs(10),
                &Cancellation::new(),
            )
            .unwrap();
        let RunResult::Collected(collected) = result else {
            panic!("normal child was not collected");
        };
        assert_eq!(collected.outcome.completion, FileCompletion::NativeError);
        assert!(!collected.outcome.native_acknowledged);
        assert_eq!(collected.worker_ready, ready);
        assert!(!collected.termination_requested);
        assert_eq!(supervisor.shared.budget.lock().unwrap().workers, 1);
        assert!(crate::sdk_compat::source_lease(&root, "owned").is_err());
        drop(collected);
        assert_eq!(supervisor.shared.budget.lock().unwrap().workers, 0);
        crate::sdk_compat::source_lease(&root, "owned").unwrap();
        assert!(supervisor.available());
    }

    #[test]
    fn normal_child_exit_is_collected_but_is_never_guest_acknowledgment() {
        normal_child("/usr/bin/true".into(), false);
    }

    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM worker check"]
    fn ordinary_worker_process_connects_without_initializing_runtime_ownership() {
        // A valid private request for a nonexistent agent. The real helper runs
        // worker mode and exits normally; no signal, VM or SDK DB is involved.
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        normal_child(PathBuf::from(executable), true);
    }

    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM agent fixture"]
    fn ordinary_worker_binary_transfers_use_public_agent_api() {
        use smolvm_protocol::{encode_message, AgentRequest, AgentResponse, Envelope};
        use std::io::{Seek, SeekFrom};
        use std::os::unix::net::{UnixListener, UnixStream};
        fn message(stream: &mut UnixStream) -> AgentRequest {
            let mut header = [0; 4];
            stream.read_exact(&mut header).unwrap();
            let size = u32::from_be_bytes(header) as usize;
            assert!(size <= smolvm_protocol::MAX_FRAME_SIZE as usize);
            let mut bytes = vec![0; size];
            stream.read_exact(&mut bytes).unwrap();
            serde_json::from_slice::<Envelope<AgentRequest>>(&bytes)
                .unwrap()
                .body
        }
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = root(&directory);
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let supervisor = supervisor(&root, executable.into());
        let binary = (0..smolvm_protocol::FILE_WRITE_SINGLE_SHOT_MAX + 17)
            .map(|index| (index % 256) as u8)
            .collect::<Vec<_>>();
        assert!(binary.len() as u64 <= MAX_TRANSFER);
        for write in [true, false] {
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let kind = if write {
                Kind::Write {
                    total: binary.len() as u64,
                    mode: Some(0o600),
                }
            } else {
                Kind::Read
            };
            let mut prepared = supervisor
                .prepare(&root, socket.clone(), &options(), kind)
                .unwrap();
            if write {
                prepared
                    .upload(
                        binary.as_slice(),
                        Instant::now() + Duration::from_secs(30),
                        &Cancellation::new(),
                    )
                    .unwrap();
            }
            std::thread::scope(|scope| {
                let peer = scope.spawn(|| {
                    let until = Instant::now() + Duration::from_secs(10);
                    let mut stream = loop {
                        match listener.accept() {
                            Ok((stream, _)) => break stream,
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                                assert!(Instant::now() < until, "worker did not connect");
                                std::thread::sleep(POLL);
                            }
                            Err(error) => panic!("agent fixture accept failed: {error}"),
                        }
                    };
                    // macOS can inherit the listener's nonblocking flag. The
                    // peer uses bounded blocking reads after finite admission.
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
                    stream.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
                    if write {
                        match message(&mut stream) {
                            AgentRequest::FileWriteBegin { path, mode, total_size, .. } => {
                                assert_eq!(path, "/workspace/data"); assert_eq!(mode, Some(0o600));
                                assert_eq!(total_size, binary.len() as u64);
                            }
                            _ => panic!("expected SDK streaming upload initialization"),
                        }
                        stream.write_all(&encode_message(&AgentResponse::Ok { data: None }).unwrap()).unwrap();
                        let mut observed = Vec::new();
                        loop {
                            let AgentRequest::FileWriteChunk { data, done } = message(&mut stream) else { panic!("expected SDK chunk"); };
                            observed.extend_from_slice(&data);
                            stream.write_all(&encode_message(&AgentResponse::Ok { data: None }).unwrap()).unwrap();
                            if done { break; }
                        }
                        assert_eq!(observed, binary);
                    } else {
                        assert!(matches!(message(&mut stream), AgentRequest::FileRead { path } if path == "/workspace/data"));
                        let chunks = binary.chunks(ipc::CHUNK as usize).collect::<Vec<_>>();
                        for (index, bytes) in chunks.iter().enumerate() {
                            let frame = encode_message(&AgentResponse::DataChunk {
                                data: bytes.to_vec(), done: index + 1 == chunks.len(),
                            }).unwrap();
                            // Fragment the real SDK stream while keeping each message bounded.
                            for fragment in frame.chunks(257) { stream.write_all(fragment).unwrap(); }
                        }
                    }
                });
                let result = supervisor
                    .run(
                        prepared,
                        Box::new(()),
                        Instant::now() + Duration::from_secs(30),
                        &Cancellation::new(),
                    )
                    .unwrap();
                let RunResult::Collected(mut collected) = result else {
                    panic!("normal transfer was not collected");
                };
                assert!(collected.outcome.success());
                assert!(collected.outcome.native_acknowledged);
                assert_eq!(collected.outcome.observed_bytes, binary.len() as u64);
                assert!(!collected.termination_requested);
                if !write {
                    collected.prepared.spool.verify().unwrap();
                    collected
                        .prepared
                        .spool
                        .file
                        .seek(SeekFrom::Start(0))
                        .unwrap();
                    let mut observed = Vec::new();
                    collected
                        .prepared
                        .spool
                        .file
                        .read_to_end(&mut observed)
                        .unwrap();
                    assert_eq!(observed, binary);
                }
                peer.join().unwrap();
            });
            std::fs::remove_file(socket).unwrap();
        }
        assert_eq!(supervisor.shared.budget.lock().unwrap().workers, 0);
    }
}
