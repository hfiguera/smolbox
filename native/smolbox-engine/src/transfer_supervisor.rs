//! File workers share engine-wide job admission. Owned leases survive uncertain
//! collection; no waitpid sweep or transport request ID is used as authority.
use crate::host::{private_directory, verified_executable};
#[cfg(test)]
use crate::transfer_worker::MAX_TRANSFER;
use crate::transfer_worker::{self as ipc, Decoder, Evidence, Kind, Request};
use crate::{
    Cancellation, Dispatch, Error, ErrorCode, Executable, FileCompletion, FileOptions, FileOutcome,
    HostContext, OwnerIdentity, Result,
};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

#[cfg(test)]
const WORKERS: usize = crate::JOB_WORK_SLOTS;
#[cfg(test)]
const SPOOL_BYTES: u64 = crate::JOB_STAGING_BYTES;
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

/// Deletes only the original inode, including when the SDK already removed a
/// failed read spool. A replacement or redirected path is never cleanup authority.
pub(crate) struct Spool {
    pub file: File,
    pub path: PathBuf,
    identity: (u64, u64),
}
impl Spool {
    pub(crate) fn new(directory: &Path) -> Result<Self> {
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
    _permit: crate::jobs::JobLease,
    _metadata: Option<Spool>,
}
impl Prepared {
    pub(crate) fn into_streaming(mut self) -> Result<Self> {
        let Kind::Buffered { metadata } = &self.request.kind else {
            return Err(Error::before(ErrorCode::Validation));
        };
        self.request.kind = Kind::Streaming {
            metadata: metadata.clone(),
        };
        self.request.validate()?;
        Ok(self)
    }
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
    pub bootstrapped: Option<crate::bootstrap::Proof>,
    pub pulled: Option<crate::ImageObservation>,
    pub grown: Option<crate::growth::GrowthProof>,
    pub stream: Option<crate::CommandOutcome>,
    pub command: Option<ipc::CommandProof>,
    pub launched: Option<u32>,
    pub outcome: FileOutcome,
    pub prepared: Prepared,
    // Includes domain, machine and SDK source leases; retained through forwarding.
    _leases: Box<dyn Send>,
    #[cfg(test)]
    worker_ready: bool,
    #[cfg(test)]
    termination_requested: bool,
}
fn forward_stream(
    prepared: &mut Prepared,
    stderr: bool,
    offset: u64,
    bytes: u64,
    consumer: &mut dyn FnMut(crate::Output) -> std::result::Result<(), ()>,
) -> std::result::Result<(), FileCompletion> {
    prepared
        .spool
        .verify()
        .map_err(|_| FileCompletion::NativeError)?;
    let size = prepared
        .spool
        .file
        .metadata()
        .map_err(|_| FileCompletion::NativeError)?
        .len();
    if size < offset + bytes
        || size > prepared.request.max_bytes
        || bytes == 0
        || bytes > ipc::CHUNK
    {
        return Err(FileCompletion::NativeError);
    }
    prepared
        .spool
        .file
        .seek(SeekFrom::Start(offset))
        .map_err(|_| FileCompletion::NativeError)?;
    let mut buffer = vec![0; bytes as usize];
    prepared
        .spool
        .file
        .read_exact(&mut buffer)
        .map_err(|_| FileCompletion::NativeError)?;
    consumer(crate::Output {
        stream: if stderr {
            crate::Stream::Stderr
        } else {
            crate::Stream::Stdout
        },
        bytes: buffer,
    })
    .map_err(|_| FileCompletion::ConsumerLost)
}

pub(crate) enum RunResult {
    Collected(Box<Collected>),
    Retained(FileOutcome),
}

#[derive(Clone)]
pub(crate) struct TransferSupervisor {
    pub(crate) pool: crate::jobs::JobPool,
    pub(crate) executable: Executable,
    pub(crate) libraries: PathBuf,
    pub(crate) owner: OwnerIdentity,
    pub(crate) epoch: Option<crate::epoch::ActorEpoch>,
}
impl TransferSupervisor {
    pub(crate) fn new(host: &HostContext, pool: crate::jobs::JobPool) -> Result<Self> {
        host.validate()?;
        Ok(Self {
            pool,
            executable: host.executables.file_worker.clone(),
            libraries: host.executables.library_directory.clone(),
            owner: host.owner,
            epoch: None,
        })
    }

    pub(crate) fn available(&self) -> bool {
        self.pool.available()
    }
    pub(crate) fn set_epoch(&mut self, epoch: crate::epoch::ActorEpoch) {
        self.epoch = Some(epoch);
    }

    pub(crate) fn prepare(
        &self,
        directory: &Path,
        socket: PathBuf,
        options: &FileOptions,
        kind: Kind,
    ) -> Result<Prepared> {
        options.validate(matches!(kind, Kind::Write { .. }))?;
        let permit = self.pool.acquire(
            if matches!(kind, Kind::Pull { .. } | Kind::Bootstrap { .. }) {
                crate::jobs::Demand::image_pull()
            } else if matches!(kind, Kind::Images { .. }) {
                crate::jobs::Demand::images()
            } else {
                crate::jobs::Demand::transfer(options.max_bytes)?
            },
        )?;
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
            _metadata: None,
        })
    }

    #[cfg(test)]
    fn prepare_bootstrap(
        &self,
        directory: &Path,
        socket: PathBuf,
        metadata: &crate::bootstrap::Metadata,
    ) -> Result<Prepared> {
        self.prepare_bootstrap_reserved(
            self.pool.acquire(crate::jobs::Demand::image_pull())?,
            directory,
            socket,
            metadata,
        )
    }

    pub(crate) fn prepare_bootstrap_reserved(
        &self,
        permit: crate::jobs::JobLease,
        directory: &Path,
        socket: PathBuf,
        metadata: &crate::bootstrap::Metadata,
    ) -> Result<Prepared> {
        let expected = metadata.expected()?;
        let bytes =
            serde_json::to_vec(metadata).map_err(|_| Error::before(ErrorCode::Validation))?;
        let mut plan = Spool::new(directory)?;
        plan.file
            .write_all(&bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        plan.file
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let blob = ipc::Blob {
            path: plan.path.clone(),
            device: plan.identity.0,
            inode: plan.identity.1,
            bytes: bytes.len() as u64,
        };
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
            guest_path: "/bootstrap".into(),
            max_bytes: 1,
            kind: Kind::Bootstrap {
                metadata: blob,
                expected,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: permit,
            _metadata: Some(plan),
        })
    }

    pub(crate) fn reserve_pull(&self) -> Result<crate::jobs::JobLease> {
        self.pool.acquire(crate::jobs::Demand::image_pull())
    }

    #[cfg(test)]
    fn prepare_pull(
        &self,
        directory: &Path,
        socket: PathBuf,
        request: crate::ImagePullRequest,
        deadline_ns: u64,
    ) -> Result<Prepared> {
        self.prepare_pull_reserved(
            self.reserve_pull()?,
            directory,
            socket,
            request,
            deadline_ns,
        )
    }

    pub(crate) fn prepare_pull_reserved(
        &self,
        permit: crate::jobs::JobLease,
        directory: &Path,
        socket: PathBuf,
        request: crate::ImagePullRequest,
        deadline_ns: u64,
    ) -> Result<Prepared> {
        request.validate()?;
        let bytes = serde_json::to_vec(&crate::image_pull::Metadata {
            schema: 1,
            request: request.clone(),
            deadline_ns,
        })
        .map_err(|_| Error::before(ErrorCode::Validation))?;
        if bytes.len() as u64 > crate::image_pull::METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        let mut metadata = Spool::new(directory)?;
        metadata
            .file
            .write_all(&bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        metadata
            .file
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let blob = ipc::Blob {
            path: metadata.path.clone(),
            device: metadata.identity.0,
            inode: metadata.identity.1,
            bytes: bytes.len() as u64,
        };
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
            guest_path: "/images".into(),
            max_bytes: 1,
            kind: Kind::Pull {
                metadata: blob,
                expected: request,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: permit,
            _metadata: Some(metadata),
        })
    }

    #[cfg(test)]
    pub(crate) fn prepare_command(
        &self,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        output: u64,
    ) -> Result<Prepared> {
        self.prepare_job(directory, socket, bytes, output, false)
    }

    #[cfg(test)]
    pub(crate) fn prepare_background(
        &self,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        output: u64,
    ) -> Result<Prepared> {
        self.prepare_job(directory, socket, bytes, output, true)
    }

    #[cfg(test)]
    pub(crate) fn prepare_streaming(
        &self,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        output: u64,
    ) -> Result<Prepared> {
        self.prepare_command(directory, socket, bytes, output)?
            .into_streaming()
    }

    #[cfg(test)]
    pub(crate) fn prepare_growth(
        &self,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        expected: crate::growth::GrowthProof,
    ) -> Result<Prepared> {
        self.prepare_growth_reserved(self.reserve_growth()?, directory, socket, bytes, expected)
    }

    pub(crate) fn reserve_growth(&self) -> Result<crate::jobs::JobLease> {
        self.pool
            .acquire(crate::jobs::Demand::growth(crate::growth::METADATA_BYTES)?)
    }

    pub(crate) fn prepare_growth_reserved(
        &self,
        permit: crate::jobs::JobLease,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        expected: crate::growth::GrowthProof,
    ) -> Result<Prepared> {
        if bytes.is_empty() || bytes.len() as u64 > crate::growth::METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        let mut metadata = Spool::new(directory)?;
        metadata
            .file
            .write_all(bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        metadata
            .file
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .and_then(|()| metadata.file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let blob = ipc::Blob {
            path: metadata.path.clone(),
            device: metadata.identity.0,
            inode: metadata.identity.1,
            bytes: bytes.len() as u64,
        };
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
            guest_path: "/workspace/.smolbox-growth".into(),
            max_bytes: 1,
            kind: Kind::Grow {
                metadata: blob,
                expected,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: permit,
            _metadata: Some(metadata),
        })
    }

    #[cfg(test)]
    fn prepare_job(
        &self,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        output: u64,
        background: bool,
    ) -> Result<Prepared> {
        let permit = self
            .pool
            .acquire(crate::jobs::Demand::command(output, bytes.len() as u64)?)?;
        self.prepare_job_reserved(permit, directory, socket, bytes, output, background)
    }

    pub(crate) fn prepare_job_reserved(
        &self,
        permit: crate::jobs::JobLease,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        output: u64,
        background: bool,
    ) -> Result<Prepared> {
        crate::jobs::Demand::command(output, bytes.len() as u64)?;
        let mut metadata = Spool::new(directory)?;
        metadata
            .file
            .write_all(bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        metadata
            .file
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let blob = ipc::Blob {
            path: metadata.path.clone(),
            device: metadata.identity.0,
            inode: metadata.identity.1,
            bytes: bytes.len() as u64,
        };
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
            guest_path: "/workspace/.smolbox-command".into(),
            max_bytes: output,
            kind: if background {
                Kind::Background { metadata: blob }
            } else {
                Kind::Buffered { metadata: blob }
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: permit,
            _metadata: Some(metadata),
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
        self.run_inner(prepared, leases, deadline, cancel, None)
    }

    pub(crate) fn run_streaming(
        &self,
        prepared: Prepared,
        leases: Box<dyn Send>,
        deadline: Instant,
        cancel: &Cancellation,
        consumer: &mut dyn FnMut(crate::Output) -> std::result::Result<(), ()>,
    ) -> Result<RunResult> {
        self.run_inner(prepared, leases, deadline, cancel, Some(consumer))
    }

    fn run_inner(
        &self,
        prepared: Prepared,
        leases: Box<dyn Send>,
        deadline: Instant,
        cancel: &Cancellation,
        mut consumer: Option<&mut dyn FnMut(crate::Output) -> std::result::Result<(), ()>>,
    ) -> Result<RunResult> {
        check_budget(deadline, cancel)?;
        verified_executable(&self.executable)?;
        check_budget(deadline, cancel)?;
        let request_bytes = ipc::encode(&prepared.request)?;
        let mut child = Command::new(&self.executable.path)
            .arg(
                if matches!(
                    prepared.request.kind,
                    Kind::Bootstrap { .. }
                        | Kind::Pull { .. }
                        | Kind::Images { .. }
                        | Kind::Buffered { .. }
                        | Kind::Background { .. }
                        | Kind::Streaming { .. }
                        | Kind::Grow { .. }
                ) {
                    "--job-worker"
                } else {
                    "--file-worker"
                },
            )
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
        let mut decoder = Decoder::for_request(&owned.prepared.request);
        let mut sent = 0;
        let mut pipe_eof = false;
        let mut reason = None;
        let mut policy = CollectionPolicy {
            no_signals: matches!(owned.prepared.request.kind, Kind::Grow { .. }),
            ..CollectionPolicy::default()
        };
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
                                    let output = match event.event {
                                        ipc::Event::StreamOutput {
                                            stderr,
                                            offset,
                                            bytes,
                                        } => Some((stderr, offset, bytes)),
                                        _ => None,
                                    };
                                    evidence.event(event)?;
                                    if let Some((stderr, offset, bytes)) = output {
                                        let failure = match consumer.as_mut() {
                                            Some(consumer) => forward_stream(
                                                &mut owned.prepared,
                                                stderr,
                                                offset,
                                                bytes,
                                                *consumer,
                                            )
                                            .err(),
                                            None => Some(FileCompletion::NativeError),
                                        };
                                        if let Some(failure) = failure {
                                            reason = Some(failure);
                                            policy.retire(origin.elapsed());
                                            evidence.retire();
                                            break;
                                        }
                                    }
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
                    if status.success() && evidence.limited && decoder.complete() {
                        FileCompletion::OutputLimit
                    } else if status.success() && evidence.acknowledged && decoder.complete() {
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
                    bootstrapped: if status.success() && decoder.complete() && reason.is_none() {
                        evidence.bootstrapped.clone()
                    } else {
                        None
                    },
                    pulled: if status.success() && decoder.complete() && reason.is_none() {
                        evidence.pulled.clone()
                    } else {
                        None
                    },
                    grown: if status.success() && decoder.complete() && reason.is_none() {
                        evidence.grown
                    } else {
                        None
                    },
                    stream: if status.success() && decoder.complete() {
                        evidence.stream.clone()
                    } else {
                        None
                    },
                    launched: if status.success() && decoder.complete() {
                        evidence.launched
                    } else {
                        None
                    },
                    command: if status.success() && decoder.complete() {
                        evidence.command
                    } else {
                        None
                    },
                    outcome,
                    prepared: owned.prepared,
                    _leases: owned._leases,
                    #[cfg(test)]
                    worker_ready: evidence.ready(),
                    #[cfg(test)]
                    termination_requested: !policy.no_signals && policy.next > 1,
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
                    self.pool.quarantine();
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
    no_signals: bool,
}
impl CollectionPolicy {
    fn retire(&mut self, now: Duration) {
        if self.retired.is_none() {
            self.retired = Some(now);
        }
    }
    fn step(&mut self, now: Duration) -> Option<Action> {
        let elapsed = now.checked_sub(self.retired?)?;
        // Filesystem growth/fsync may have crossed the mutation boundary.
        // Cancellation closes input and retains the exact child; signals cannot
        // establish rollback, quiescence or safe admission release.
        let (after, action) = match (self.no_signals, self.next) {
            (true, 0) => (Duration::ZERO, Action::Close),
            (true, 1) => (Duration::from_millis(2200), Action::Retain),
            (true, _) => return None,
            (false, 0) => (Duration::ZERO, Action::Close),
            (false, 1) => (Duration::from_millis(100), Action::Terminate),
            (false, 2) => (Duration::from_millis(200), Action::Kill),
            (false, 3) => (Duration::from_millis(2200), Action::Retain),
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
        TransferSupervisor::new(&host, crate::jobs::JobPool::default()).unwrap()
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
        assert_eq!(supervisor.pool.counts().staging, SPOOL_BYTES);
        assert_eq!(
            supervisor
                .prepare(&root, root.join("agent.sock"), &options(), Kind::Read)
                .err()
                .unwrap()
                .code,
            ErrorCode::Admission
        );
        drop(prepared.pop());
        supervisor
            .prepare(&root, root.join("agent.sock"), &options(), Kind::Read)
            .unwrap();
        supervisor.pool.quarantine();
        assert!(supervisor
            .prepare(&root, root.join("agent.sock"), &options(), Kind::Read)
            .is_err());
        assert_eq!(supervisor.pool.counts().work, 3);
        drop(prepared);
        assert_eq!(supervisor.pool.counts().work, 0);
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

    #[test]
    fn modeled_growth_retirement_closes_then_retains_without_signals() {
        let mut policy = CollectionPolicy {
            no_signals: true,
            ..CollectionPolicy::default()
        };
        policy.retire(Duration::from_secs(20));
        assert_eq!(policy.step(Duration::from_secs(20)), Some(Action::Close));
        assert_eq!(policy.step(Duration::from_millis(20100)), None);
        assert_eq!(policy.step(Duration::from_millis(20200)), None);
        policy.retire(Duration::from_secs(99));
        assert_eq!(
            policy.step(Duration::from_millis(22200)),
            Some(Action::Retain)
        );
        assert_eq!(policy.step(Duration::from_secs(100)), None);
    }

    #[test]
    fn growth_geometry_and_prepared_worker_share_one_reserved_job_with_control_headroom() {
        let temporary = tempfile::tempdir().unwrap();
        let root = root(&temporary);
        let supervisor = supervisor(&root, std::env::current_exe().unwrap());
        let permit = supervisor.reserve_growth().unwrap();
        assert_eq!(supervisor.pool.counts().work, 1);
        assert_eq!(supervisor.pool.counts().children, 1);
        assert!(supervisor.reserve_growth().is_err());
        let control = supervisor
            .pool
            .acquire(crate::jobs::Demand::observation())
            .unwrap();
        let other_control = supervisor
            .pool
            .acquire(crate::jobs::Demand::observation())
            .unwrap();
        assert_eq!(supervisor.pool.counts().control, 2);
        drop((control, other_control));

        let storage_path = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(storage_path, root.join("overlay.raw")).unwrap();
        crate::disk_geometry::tests::raw(&root);
        let storage = crate::disk_geometry::DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        let overlay = crate::disk_geometry::DiskGeometry::capture(&root, "overlay.raw", 1).unwrap();
        let metadata = serde_json::to_vec(&crate::growth::Metadata::new(
            &storage,
            &overlay,
            crate::GrowDisks {
                storage_gib: Some(2),
                overlay_gib: None,
            },
        ))
        .unwrap();
        let prepared = supervisor
            .prepare_growth_reserved(
                permit,
                &root,
                root.join("agent.sock"),
                &metadata,
                crate::growth::GrowthProof {
                    storage_gib: 2,
                    overlay_gib: 1,
                },
            )
            .unwrap();
        assert_eq!(supervisor.pool.counts().work, 1);
        assert_eq!(supervisor.pool.counts().children, 1);
        drop(prepared);
        assert_eq!(supervisor.pool.counts(), crate::jobs::Counts::default());

        let permit = supervisor.reserve_growth().unwrap();
        assert!(supervisor
            .prepare_growth_reserved(
                permit,
                &root,
                root.join("agent.sock"),
                &[],
                crate::growth::GrowthProof {
                    storage_gib: 2,
                    overlay_gib: 1
                },
            )
            .is_err());
        assert_eq!(supervisor.pool.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn pull_preflight_and_protected_worker_share_one_reservation_with_control_headroom() {
        let temporary = tempfile::tempdir().unwrap();
        let root = root(&temporary);
        let supervisor = supervisor(&root, std::env::current_exe().unwrap());
        let permit = supervisor.reserve_pull().unwrap();
        assert_eq!(supervisor.pool.counts().work, 1);
        assert!(supervisor.reserve_pull().is_err());
        let controls = [
            supervisor
                .pool
                .acquire(crate::jobs::Demand::observation())
                .unwrap(),
            supervisor
                .pool
                .acquire(crate::jobs::Demand::observation())
                .unwrap(),
        ];
        let expected = crate::ImagePullRequest {
            reference: format!("registry.example/app@sha256:{}", "a".repeat(64)),
            platform: crate::oci::native_oci_platform().into(),
        };
        let prepared = supervisor
            .prepare_pull_reserved(
                permit,
                &root,
                root.join("agent.sock"),
                expected,
                crate::buffered::monotonic_ns().unwrap() + 1_000_000_000,
            )
            .unwrap();
        assert_eq!(supervisor.pool.counts().work, 1);
        assert_eq!(supervisor.pool.counts().children, 1);
        assert_eq!(supervisor.pool.counts().control, 2);
        drop(prepared);
        drop(controls);
        assert_eq!(supervisor.pool.counts(), crate::jobs::Counts::default());
        assert!(!root.join("agent.sock").exists());
    }

    fn ordinary_growth_worker(qcow: bool, replace_companion: bool) {
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER")
            .expect("set the explicit rebuilt helper path")
            .into();
        let temporary = tempfile::tempdir().unwrap();
        let root = root(&temporary);
        let supervisor = supervisor(&root, executable);
        let storage_path = if qcow {
            crate::disk_geometry::tests::backed_qcow(&root, 3)
        } else {
            crate::disk_geometry::tests::raw(&root)
        };
        let saved = root.join("saved-storage");
        std::fs::rename(&storage_path, &saved).unwrap();
        let companion = if qcow {
            crate::disk_geometry::tests::backed_qcow(&root, 2)
        } else {
            crate::disk_geometry::tests::raw(&root)
        };
        let overlay_path = root.join(if qcow { "overlay.qcow2" } else { "overlay.raw" });
        std::fs::rename(companion, &overlay_path).unwrap();
        std::fs::rename(saved, &storage_path).unwrap();
        let storage = std::sync::Arc::new(
            crate::disk_geometry::DiskGeometry::capture(&root, "storage.raw", 1).unwrap(),
        );
        let overlay = std::sync::Arc::new(
            crate::disk_geometry::DiskGeometry::capture(&root, "overlay.raw", 1).unwrap(),
        );
        let growth = crate::GrowDisks {
            storage_gib: Some(2),
            overlay_gib: Some(3),
        };
        let expected = crate::growth::GrowthProof {
            storage_gib: 2,
            overlay_gib: 3,
        };
        let metadata =
            serde_json::to_vec(&crate::growth::Metadata::new(&storage, &overlay, growth)).unwrap();
        let prepared = supervisor
            .prepare_growth(&root, root.join("agent.sock"), &metadata, expected)
            .unwrap();
        if replace_companion {
            // Deterministic pre-dispatch substitution; no live persistence race.
            std::fs::rename(&overlay_path, root.join("original-overlay")).unwrap();
            let replacement_directory = root.join("replacement");
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&replacement_directory)
                .unwrap();
            let replacement = crate::disk_geometry::tests::raw(&replacement_directory);
            std::fs::rename(replacement, &overlay_path).unwrap();
        }
        let source = crate::sdk_compat::source_lease(&root, "owned").unwrap();
        let gate = std::sync::Arc::new(crate::gate::MachineGate::default());
        let machine = gate.try_lock().unwrap();
        let result = supervisor
            .run(
                prepared,
                Box::new((source, machine, storage.clone(), overlay.clone())),
                Instant::now() + Duration::from_secs(10),
                &Cancellation::new(),
            )
            .unwrap();
        let RunResult::Collected(collected) = result else {
            panic!("ordinary growth worker was not collected")
        };
        assert!(collected.worker_ready);
        assert!(!collected.termination_requested);
        assert!(gate.try_lock().is_err());
        assert!(crate::sdk_compat::source_lease(&root, "owned").is_err());
        assert_eq!(supervisor.pool.counts().work, 1);
        assert_eq!(supervisor.pool.counts().children, 1);
        assert_eq!(collected.prepared.spool.file.metadata().unwrap().len(), 0);
        if replace_companion {
            assert_eq!(collected.outcome.completion, FileCompletion::NativeError);
            assert!(!collected.outcome.native_acknowledged);
            assert_eq!(collected.grown, None);
            storage.verify_after(1).unwrap();
        } else {
            assert_eq!(collected.outcome.completion, FileCompletion::Completed);
            assert!(collected.outcome.native_acknowledged);
            assert_eq!(collected.grown, Some(expected));
            storage.verify_after(2).unwrap();
            overlay.verify_after(3).unwrap();
        }
        drop(collected);
        assert_eq!(supervisor.pool.counts().work, 0);
        assert!(gate.try_lock().is_ok());
        assert!(crate::sdk_compat::source_lease(&root, "owned").is_ok());
        assert!(!root.join("db").exists());
        assert!(!root.join("agent.sock").exists());
    }

    #[test]
    #[ignore = "requires built helper; explicit ordinary sparse-file growth, no VM or fault campaign"]
    fn ordinary_growth_worker_collects_raw_and_qcow_sdk_geometry_with_owned_leases() {
        ordinary_growth_worker(false, false);
        ordinary_growth_worker(true, false);
    }

    #[test]
    #[ignore = "requires built helper; deterministic companion substitution before worker dispatch"]
    fn ordinary_growth_worker_rejects_changed_companion_before_any_sdk_mutation() {
        ordinary_growth_worker(false, true);
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
        assert_eq!(supervisor.pool.counts().work, 1);
        assert!(crate::sdk_compat::source_lease(&root, "owned").is_err());
        drop(collected);
        assert_eq!(supervisor.pool.counts().work, 0);
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
    fn ordinary_streaming_worker_forwards_large_command_output_before_sdk_exit() {
        use smolvm_protocol::{encode_message, AgentRequest, AgentResponse, Envelope};
        use std::os::unix::net::UnixListener;
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = root(&directory);
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let supervisor = supervisor(&root, executable.into());
        for image in [false, true] {
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let mut record = smolvm::config::VmRecord::new(
                "0123456789abcdef".into(),
                1,
                512,
                vec![],
                vec![],
                false,
            );
            if image {
                record.image = Some("local-dir:/fixture".into());
            }
            let command = crate::BufferedCommand {
                argv: vec!["/bin/cat".into()],
                env: (0..64)
                    .map(|n| (format!("K{n}"), "\u{1}".repeat(8192)))
                    .collect(),
                workdir: Some("/workspace".into()),
                user: if image {
                    Some("1234:2345".into())
                } else {
                    None
                },
                stdin: None,
                timeout: Duration::from_secs(20),
                max_output_bytes: if image { 16 * 1024 * 1024 } else { 1024 },
            };
            let until = Instant::now() + Duration::from_secs(20);
            let metadata = crate::buffered::Metadata::new(&record, command, until).unwrap();
            let bytes = serde_json::to_vec(&metadata).unwrap();
            let prepared = supervisor
                .prepare_streaming(
                    &root,
                    socket.clone(),
                    &bytes,
                    if image { 16 * 1024 * 1024 } else { 1024 },
                )
                .unwrap();
            let (delivered, output_seen) = std::sync::mpsc::channel();
            std::thread::scope(|scope| {
                let peer = scope.spawn(move || {
                    let mut socket = loop {
                        match listener.accept() {
                            Ok((socket, _)) => break socket,
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                                assert!(Instant::now() < until);
                                std::thread::sleep(POLL);
                            }
                            Err(error) => panic!("{error}"),
                        }
                    };
                    socket.set_nonblocking(false).unwrap();
                    socket
                        .set_read_timeout(Some(Duration::from_secs(10)))
                        .unwrap();
                    let mut header = [0; 4];
                    socket.read_exact(&mut header).unwrap();
                    let size = u32::from_be_bytes(header) as usize;
                    assert!(size < crate::AGENT_REQUEST_BYTES);
                    let mut data = vec![0; size];
                    socket.read_exact(&mut data).unwrap();
                    let request = serde_json::from_slice::<Envelope<AgentRequest>>(&data)
                        .unwrap()
                        .body;
                    match request {
                        AgentRequest::Run {
                            env,
                            stdin_data,
                            background,
                            interactive,
                            user,
                            persistent_overlay_id,
                            ..
                        } if image => {
                            assert_eq!(env.len(), 64);
                            assert!(env.iter().all(|(_, v)| v.len() == 8192));
                            assert!(interactive && !background && stdin_data.is_none());
                            assert_eq!(user.as_deref(), Some("1234:2345"));
                            assert_eq!(persistent_overlay_id.as_deref(), Some("0123456789abcdef"));
                        }
                        AgentRequest::VmExec {
                            env,
                            stdin_data,
                            background,
                            interactive,
                            ..
                        } if !image => {
                            assert_eq!(env.len(), 64);
                            assert!(interactive && !background && stdin_data.is_none());
                        }
                        _ => panic!("unexpected SDK command"),
                    }
                    socket
                        .write_all(&encode_message(&AgentResponse::Started).unwrap())
                        .unwrap();
                    socket
                        .write_all(
                            &encode_message(&AgentResponse::Stdout {
                                data: vec![0, 255, 7],
                            })
                            .unwrap(),
                        )
                        .unwrap();
                    // A buffered implementation deadlocks here: no Exit is sent
                    // until the controller's consumer observes stdout.
                    output_seen.recv_timeout(Duration::from_secs(5)).unwrap();
                    if image {
                        for _ in 0..192 {
                            socket
                                .write_all(
                                    &encode_message(&AgentResponse::Stdout {
                                        data: vec![42; 65536],
                                    })
                                    .unwrap(),
                                )
                                .unwrap();
                        }
                    }
                    socket
                        .write_all(
                            &encode_message(&AgentResponse::Stderr { data: vec![0, 254] }).unwrap(),
                        )
                        .unwrap();
                    socket
                        .write_all(
                            &encode_message(&AgentResponse::Exited {
                                exit_code: 7,
                                oom: false,
                            })
                            .unwrap(),
                        )
                        .unwrap();
                });
                let mut output = Vec::new();
                let mut notified = false;
                let result = supervisor
                    .run_streaming(
                        prepared,
                        Box::new(()),
                        until,
                        &Cancellation::new(),
                        &mut |event| {
                            if event.stream == crate::Stream::Stdout && !notified {
                                delivered.send(()).unwrap();
                                notified = true;
                            }
                            output.push((event.stream, event.bytes));
                            Ok(())
                        },
                    )
                    .unwrap();
                let RunResult::Collected(collected) = result else {
                    panic!("worker not collected")
                };
                let proof = collected.stream.as_ref().unwrap();
                assert_eq!(proof.observed_exit, Some(7));
                assert_eq!(
                    proof.output_bytes,
                    if image { 12 * 1024 * 1024 + 5 } else { 5 }
                );
                assert_eq!(proof.completion, crate::Completion::Exited);
                assert!(!proof.success()); // the observed guest code is nonzero
                assert!(collected.outcome.success());
                assert!(!collected.termination_requested);
                assert_eq!(
                    output.first().unwrap(),
                    &(crate::Stream::Stdout, vec![0, 255, 7])
                );
                assert_eq!(
                    output.last().unwrap(),
                    &(crate::Stream::Stderr, vec![0, 254])
                );
                assert_eq!(output.len(), if image { 194 } else { 2 });
                peer.join().unwrap();
            });
            std::fs::remove_file(socket).unwrap();
        }
        assert_eq!(supervisor.pool.counts().work, 0);
        assert_eq!(supervisor.pool.counts().metadata, 0);
    }

    #[test]
    #[ignore = "requires a built helper; ordinary non-VM SDK peer only"]
    fn ordinary_bootstrap_worker_pulls_once_then_launches_exact_workload_without_vm_entry() {
        use smolvm_protocol::{AgentRequest, AgentResponse, Envelope};
        use std::os::unix::net::UnixListener;
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = root(&directory);
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let supervisor = supervisor(&root, executable.into());
        for (empty, failed) in [(false, false), (false, true), (true, false)] {
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let plan = crate::bootstrap::tests::plan(empty);
            let expected = plan.expected().unwrap();
            let prepared = supervisor
                .prepare_bootstrap(&root, socket.clone(), &plan)
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(30);
            std::thread::scope(|scope| {
                let peer = scope.spawn(|| {
                    for stage in 0..if empty { 1 } else { 2 } {
                        let mut stream = loop {
                            match listener.accept() {
                                Ok((stream, _)) => break stream,
                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                    assert!(Instant::now() < deadline);
                                    std::thread::sleep(POLL);
                                }
                                Err(e) => panic!("{e}"),
                            }
                        };
                        stream.set_nonblocking(false).unwrap();
                        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                        let mut header = [0; 4];
                        stream.read_exact(&mut header).unwrap();
                        let size = u32::from_be_bytes(header) as usize;
                        assert!(size <= crate::AGENT_REQUEST_BYTES);
                        let mut body = vec![0; size];
                        stream.read_exact(&mut body).unwrap();
                        let request: Envelope<AgentRequest> = serde_json::from_slice(&body).unwrap();
                        let response = if stage == 0 {
                            let AgentRequest::Pull { image, oci_platform, auth, proxy, no_proxy } = request.body else { panic!() };
                            assert_eq!(image, expected.source.reference);
                            assert_eq!(oci_platform.as_deref(), Some(expected.source.platform.as_str()));
                            assert!(auth.is_none() && proxy.is_none() && no_proxy.is_none());
                            let info = serde_json::json!({
                                "reference": expected.source.reference,
                                "digest": format!("sha256:{}", "b".repeat(64)), "size": 123,
                                "architecture": expected.source.platform.trim_start_matches("linux/"),
                                "os": "linux", "layer_count": 2
                            });
                            AgentResponse::Ok { data: Some(info) }
                        } else {
                            let AgentRequest::Run {
                                image, command, env, user, workdir, persistent_overlay_id,
                                detached, background, interactive, tty, stdin_data, timeout_ms,
                                stop_vm_on_exit, s3_volumes, mounts, unprivileged,
                            } = request.body else { panic!() };
                            assert_eq!(image, expected.source.reference);
                            assert_eq!(command, vec!["/app", "serve"]);
                            assert_eq!(env, vec![("A".into(), "override".into()), ("B".into(), "base".into())]);
                            assert_eq!(user.as_deref(), Some("1234:2345"));
                            assert_eq!(workdir.as_deref(), Some("/workspace"));
                            assert_eq!(persistent_overlay_id.as_deref(), Some("owned"));
                            assert!(detached && !background && !interactive && !tty && !stop_vm_on_exit && !unprivileged);
                            assert!(stdin_data.is_none() && timeout_ms.is_none() && s3_volumes.is_empty() && mounts.is_empty());
                            if failed {
                                AgentResponse::Error { message: "PRIVATE=discard".into(), code: None }
                            } else {
                                AgentResponse::Completed { exit_code: 0, stdout: b"smolvm-fixture".to_vec(), stderr: b"PRIVATE=discard".to_vec() }
                            }
                        };
                        let progress = serde_json::json!({ "status": "progress", "message": "PRIVATE=discard" });
                        for body in [serde_json::to_vec(&progress).unwrap(), serde_json::to_vec(&response).unwrap()] {
                            stream.write_all(&(body.len() as u32).to_be_bytes()).unwrap();
                            stream.write_all(&body).unwrap();
                        }
                    }
                });
                let RunResult::Collected(collected) = supervisor
                    .run(prepared, Box::new(()), deadline, &Cancellation::default())
                    .unwrap()
                else {
                    panic!("ordinary worker must be collected")
                };
                assert!(!collected.termination_requested);
                assert_eq!(collected.outcome.success(), !failed);
                if failed {
                    assert!(collected.bootstrapped.is_none());
                } else {
                    let proof = collected.bootstrapped.as_ref().unwrap();
                    assert!(proof.matches(&expected));
                    assert_eq!(proof.container_id.is_none(), empty);
                }
                peer.join().unwrap();
            });
            std::fs::remove_file(socket).unwrap();
            assert!(supervisor.pool.available());
            assert!(!root.join("db").exists());
        }
    }

    #[test]
    #[ignore = "requires a built helper; ordinary non-VM SDK peer only"]
    fn ordinary_pull_worker_uses_exact_request_and_collects_only_matching_image_evidence() {
        use smolvm_protocol::{AgentRequest, Envelope};
        use std::os::unix::net::UnixListener;
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = root(&directory);
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let supervisor = supervisor(&root, executable.into());
        let expected = crate::ImagePullRequest {
            reference: format!("registry.example/app@sha256:{}", "a".repeat(64)),
            platform: "linux/arm64".into(),
        };
        for reply in ["valid", "packed", "different", "error"] {
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + Duration::from_secs(30);
            let deadline_ns = crate::buffered::monotonic_ns().unwrap() + 30_000_000_000;
            let prepared = supervisor
                .prepare_pull(&root, socket.clone(), expected.clone(), deadline_ns)
                .unwrap();
            std::thread::scope(|scope| {
                let peer = scope.spawn(|| {
                    let mut stream = loop {
                        match listener.accept() {
                            Ok((s, _)) => break s,
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                assert!(Instant::now() < deadline);
                                std::thread::sleep(POLL);
                            }
                            Err(e) => panic!("{e}"),
                        }
                    };
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                    let mut header = [0; 4];
                    stream.read_exact(&mut header).unwrap();
                    let mut body = vec![0; u32::from_be_bytes(header) as usize];
                    stream.read_exact(&mut body).unwrap();
                    let request: Envelope<AgentRequest> = serde_json::from_slice(&body).unwrap();
                    let AgentRequest::Pull { image, oci_platform, auth, proxy, no_proxy } = request.body else { panic!() };
                    assert_eq!(image, expected.reference);
                    assert_eq!(oci_platform.as_deref(), Some("linux/arm64"));
                    assert!(auth.is_none() && proxy.is_none() && no_proxy.is_none());
                    let progress = serde_json::json!({"status":"progress","message":"PRIVATE=discard"});
                    let result = if reply == "error" {
                        serde_json::json!({"status":"error","message":"PRIVATE=discard"})
                    } else {
                        serde_json::json!({"status":"ok","data":{
                            "reference":if reply == "different" {"registry.example/other"} else {&expected.reference},
                            "digest":if reply == "packed" {"packed".to_string()} else {format!("sha256:{}", "b".repeat(64))},
                            "size":123,"architecture":"arm64","os":"linux","layer_count":2,
                            "env":["PRIVATE=discard"],"layers":["discard"]}})
                    };
                    for value in [progress, result] {
                        let bytes = serde_json::to_vec(&value).unwrap();
                        stream.write_all(&(bytes.len() as u32).to_be_bytes()).unwrap();
                        stream.write_all(&bytes).unwrap();
                    }
                });
                let RunResult::Collected(collected) = supervisor
                    .run(prepared, Box::new(()), deadline, &Cancellation::default())
                    .unwrap()
                else {
                    panic!("ordinary worker must be collected")
                };
                assert_eq!(collected.outcome.success(), reply == "valid");
                assert_eq!(collected.outcome.native_acknowledged, reply == "valid");
                assert!(!collected.termination_requested);
                if reply == "valid" {
                    let image = collected.pulled.as_ref().unwrap();
                    assert!(expected.matches(image));
                    assert_ne!(image.digest, format!("sha256:{}", "a".repeat(64)));
                } else {
                    assert!(collected.pulled.is_none());
                }
                assert_eq!(collected.outcome.observed_bytes, 0);
                peer.join().unwrap();
            });
            std::fs::remove_file(socket).unwrap();
            assert!(supervisor.pool.available());
            assert!(!root.join("db").exists());
        }
    }

    #[test]
    #[ignore = "requires a built helper; ordinary non-VM SDK peer only"]
    fn ordinary_image_worker_lists_without_boot_and_collects_invalid_replies() {
        use smolvm_protocol::{AgentRequest, Envelope};
        use std::os::unix::net::UnixListener;
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = root(&directory);
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let supervisor = supervisor(&root, executable.into());
        for valid in [true, false] {
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + Duration::from_secs(10);
            let deadline_ns = crate::buffered::monotonic_ns().unwrap() + 10_000_000_000;
            let prepared = supervisor
                .prepare(
                    &root,
                    socket.clone(),
                    &FileOptions {
                        guest_path: "/images".into(),
                        max_bytes: crate::images::IMAGE_OUTPUT_BYTES,
                        timeout: Duration::from_secs(10),
                        mode: None,
                    },
                    Kind::Images { deadline_ns },
                )
                .unwrap();
            std::thread::scope(|scope| {
                let peer = scope.spawn(|| {
                    let mut stream = loop {
                        match listener.accept() {
                            Ok((s, _)) => break s,
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                assert!(Instant::now() < deadline);
                                std::thread::sleep(POLL);
                            }
                            Err(e) => panic!("{e}"),
                        }
                    };
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                    let mut header = [0; 4];
                    stream.read_exact(&mut header).unwrap();
                    let mut body = vec![0; u32::from_be_bytes(header) as usize];
                    stream.read_exact(&mut body).unwrap();
                    let request: Envelope<AgentRequest> = serde_json::from_slice(&body).unwrap();
                    assert!(matches!(request.body, AgentRequest::ListImages));
                    let image = serde_json::json!({"reference":"fixture", "digest":if valid {"packed"} else {"invalid"},
                        "size":123,"architecture":"arm64","os":"linux","layer_count":2,
                        "env":["TOKEN=discard"],"layers":["discard"]});
                    let bytes = serde_json::to_vec(&serde_json::json!({"status":"ok","data":[image]})).unwrap();
                    stream.write_all(&(bytes.len() as u32).to_be_bytes()).unwrap();
                    stream.write_all(&bytes).unwrap();
                });
                let RunResult::Collected(mut collected) = supervisor
                    .run(prepared, Box::new(()), deadline, &Cancellation::default())
                    .unwrap()
                else {
                    panic!("ordinary worker must be collected")
                };
                assert_eq!(collected.outcome.success(), valid);
                assert_eq!(collected.outcome.native_acknowledged, valid);
                assert!(!collected.termination_requested);
                if valid {
                    collected
                        .prepared
                        .spool
                        .file
                        .seek(SeekFrom::Start(0))
                        .unwrap();
                    let images: Vec<crate::ImageObservation> =
                        serde_json::from_reader(&collected.prepared.spool.file).unwrap();
                    assert_eq!(images.len(), 1);
                    assert_eq!(images[0].digest, "packed");
                    assert_eq!(images[0].layer_count, 2);
                }
                peer.join().unwrap();
            });
            std::fs::remove_file(socket).unwrap();
            assert!(supervisor.pool.available());
            assert!(!root.join("db").exists());
        }
    }

    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM agent fixture"]
    fn ordinary_command_worker_preserves_stdin_exit_and_background_launch_evidence() {
        use smolvm_protocol::{encode_message, AgentRequest, AgentResponse, Envelope};
        use std::io::{Seek, SeekFrom};
        use std::os::unix::net::UnixListener;
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = root(&directory);
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let supervisor = supervisor(&root, executable.into());
        for (image, launch, reply, max_output) in [
            (false, false, "", 1024),
            (true, false, "", 1024),
            (true, true, "4242", 1024),
            (true, true, "0", 1024),
            (true, true, "malformed", 1024),
            (true, true, "lost", 1024),
            (true, true, "4242", 1),
        ] {
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let mut record = smolvm::config::VmRecord::new(
                "0123456789abcdef".into(),
                1,
                512,
                vec![],
                vec![],
                false,
            );
            if image {
                record.image = Some("local-dir:/fixture".into());
            }
            let command = crate::BufferedCommand {
                argv: vec!["/bin/cat".into()],
                env: vec![("PRIVATE".into(), "value".into())],
                workdir: Some("/workspace".into()),
                user: if image {
                    Some("1234:2345".into())
                } else {
                    None
                },
                stdin: if launch {
                    None
                } else {
                    Some("hé\0stdin".into())
                },
                timeout: Duration::from_secs(20),
                max_output_bytes: max_output,
            };
            let expires = Instant::now() + Duration::from_secs(20);
            let metadata = if launch {
                crate::buffered::Metadata::background(&record, command, expires)
            } else {
                crate::buffered::Metadata::new(&record, command, expires)
            }
            .unwrap();
            let bytes = serde_json::to_vec(&metadata).unwrap();
            let prepared = if launch {
                supervisor.prepare_background(&root, socket.clone(), &bytes, max_output.min(64))
            } else {
                supervisor.prepare_command(&root, socket.clone(), &bytes, max_output)
            }
            .unwrap();
            std::thread::scope(|scope| {
                let peer = scope.spawn(|| {
                    let until = Instant::now() + Duration::from_secs(10);
                    let mut stream = loop {
                        match listener.accept() {
                            Ok((s, _)) => break s,
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                assert!(Instant::now() < until);
                                std::thread::sleep(POLL)
                            }
                            Err(e) => panic!("{e}"),
                        }
                    };
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(10)))
                        .unwrap();
                    let mut header = [0; 4];
                    stream.read_exact(&mut header).unwrap();
                    let mut body = vec![0; u32::from_be_bytes(header) as usize];
                    stream.read_exact(&mut body).unwrap();
                    let request = serde_json::from_slice::<Envelope<AgentRequest>>(&body)
                        .unwrap()
                        .body;
                    match request {
                        AgentRequest::VmExec {
                            command,
                            stdin_data,
                            background,
                            interactive,
                            ..
                        } if !image => {
                            assert_eq!(command, vec!["/bin/cat"]);
                            assert_eq!(stdin_data.as_deref(), Some("hé\0stdin"));
                            assert!(!background && !interactive);
                        }
                        AgentRequest::Run {
                            stdin_data,
                            user,
                            persistent_overlay_id,
                            background,
                            interactive,
                            timeout_ms,
                            ..
                        } if image => {
                            assert_eq!(
                                stdin_data.as_deref(),
                                if launch { None } else { Some("hé\0stdin") }
                            );
                            assert_eq!(user.as_deref(), Some("1234:2345"));
                            assert_eq!(persistent_overlay_id.as_deref(), Some("0123456789abcdef"));
                            assert_eq!(background, launch);
                            assert!(!interactive);
                            assert_eq!(timeout_ms.is_none(), launch);
                        }
                        _ => panic!("unexpected operation"),
                    }
                    if reply != "lost" {
                        stream
                            .write_all(
                                &encode_message(&AgentResponse::Completed {
                                    exit_code: if launch { 0 } else { 7 },
                                    stdout: if launch {
                                        reply.as_bytes().to_vec()
                                    } else {
                                        vec![0, 255, 7]
                                    },
                                    stderr: if launch { vec![] } else { vec![0, 254] },
                                })
                                .unwrap(),
                            )
                            .unwrap();
                    }
                });
                let result = supervisor
                    .run(
                        prepared,
                        Box::new(()),
                        Instant::now() + Duration::from_secs(20),
                        &Cancellation::new(),
                    )
                    .unwrap();
                let RunResult::Collected(mut collected) = result else {
                    panic!("ordinary worker was not collected")
                };
                assert_eq!(
                    collected.outcome.success(),
                    !launch || (reply == "4242" && max_output > 1)
                );
                assert!(!collected.termination_requested);
                if launch {
                    assert!(collected.command.is_none());
                    assert_eq!(
                        collected.launched,
                        if reply == "4242" && max_output > 1 {
                            Some(4242)
                        } else {
                            None
                        }
                    );
                    assert_eq!(collected.outcome.observed_bytes, 0);
                } else {
                    let proof = collected.command.as_ref().unwrap();
                    assert_eq!(proof.exit_code, 7);
                    assert_eq!((proof.stdout, proof.stderr), (3, 2));
                    assert!(collected.launched.is_none());
                }
                collected
                    .prepared
                    .spool
                    .file
                    .seek(SeekFrom::Start(0))
                    .unwrap();
                let mut output = Vec::new();
                collected
                    .prepared
                    .spool
                    .file
                    .read_to_end(&mut output)
                    .unwrap();
                assert_eq!(
                    output,
                    if launch {
                        vec![]
                    } else {
                        vec![0, 255, 7, 0, 254]
                    }
                );
                peer.join().unwrap();
            });
            std::fs::remove_file(socket).unwrap();
        }
        assert_eq!(supervisor.pool.counts().work, 0);
        assert_eq!(supervisor.pool.counts().metadata, 0);
    }

    #[test]
    #[ignore = "requires built helper; explicit ordinary non-VM agent fixture"]
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
        assert_eq!(supervisor.pool.counts().work, 0);
    }
}
