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
    _permit: Option<crate::jobs::JobLease>,
    _metadata: Option<Spool>,
    _conversion: Option<Spool>,
}
impl Prepared {
    pub(crate) fn with_registry(
        mut self,
        selected: Option<crate::guest_registry::Plan>,
    ) -> Result<Self> {
        match &mut self.request.kind {
            Kind::Pull { registry, .. } | Kind::Bootstrap { registry, .. } => *registry = selected,
            _ => return Err(Error::before(ErrorCode::Validation)),
        }
        // Validate the full private frame before spawning; no secret spool is
        // created and no public worker event/frame limit is widened.
        ipc::encode_request(&self.request)?;
        Ok(self)
    }
    pub(crate) fn verify_unentered_branch(&self) -> Result<()> {
        let Kind::BranchPrepare { metadata, expected } = &self.request.kind else {
            return Err(Error::before(ErrorCode::Validation));
        };
        self.request.validate()?;
        self.spool.verify()?;
        if self
            .spool
            .file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?
            .len()
            != 0
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let selected: crate::branch_worker::Metadata =
            metadata.read(self.request.owner, crate::branch_worker::METADATA_BYTES)?;
        crate::branch_worker::verify_request(&selected, &self.request, expected)
    }
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
    pub converted: Option<crate::export_bootstrap::Proof>,
    pub captured: Option<crate::capture_worker::Proof>,
    pub branch_prepared: Option<crate::branch_worker::Proof>,
    pub bootstrapped: Option<crate::bootstrap::Proof>,
    pub pulled: Option<crate::ImageObservation>,
    pub installed: Option<crate::checkpoint_install::Proof>,
    pub materialized: Option<crate::checkpoint_materialize::Proof>,
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
impl Collected {
    /// Inert private row/file projection. It runs no worker and is unavailable
    /// in production; callers must not attribute SDK collection to this model.
    #[cfg(test)]
    pub(crate) fn model_branch_projection(prepared: Prepared) -> Self {
        Self::model_branch_projection_with_leases(prepared, Box::new(()))
    }
    #[cfg(test)]
    pub(crate) fn model_branch_projection_with_leases(
        prepared: Prepared,
        leases: Box<dyn Send>,
    ) -> Self {
        Self {
            converted: None,
            captured: None,
            branch_prepared: None,
            bootstrapped: None,
            pulled: None,
            installed: None,
            materialized: None,
            grown: None,
            stream: None,
            command: None,
            launched: None,
            outcome: FileOutcome {
                completion: crate::FileCompletion::Completed,
                dispatch: crate::Dispatch::MayHaveDispatched,
                observed_bytes: 0,
                native_acknowledged: true,
            },
            prepared,
            _leases: leases,
            worker_ready: false,
            termination_requested: false,
        }
    }
    pub(crate) fn verify_conversion(
        &mut self,
        budget: &crate::ReadBudget,
    ) -> Result<(
        crate::ContainerExportPlan,
        crate::ContainerLayerIo,
        crate::checkpoint_materialize::FileVersion,
    )> {
        use sha2::{Digest, Sha256};
        budget.check()?;
        let Kind::Conversion { expected, .. } = &self.prepared.request.kind else {
            return Err(Error::before(ErrorCode::Validation));
        };
        let proof = self
            .converted
            .as_ref()
            .filter(|p| p.matches(expected))
            .ok_or(Error::uncertain(ErrorCode::Native))?;
        let plan = self
            .prepared
            ._conversion
            .as_mut()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        fn verify(
            spool: &mut Spool,
            length: u64,
            hash: &str,
            budget: &crate::ReadBudget,
        ) -> Result<crate::checkpoint_materialize::FileVersion> {
            spool.verify()?;
            let before = spool
                .file
                .metadata()
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
            let version = crate::checkpoint_materialize::FileVersion::of(&before);
            if !before.is_file()
                || before.uid() != unsafe { libc::geteuid() }
                || before.mode() & 0o777 != 0o600
                || before.nlink() != 1
                || before.len() != length
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            spool
                .file
                .seek(SeekFrom::Start(0))
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
            let mut remaining = length;
            let mut hash_state = Sha256::new();
            let mut buffer = [0; ipc::CHUNK as usize];
            while remaining > 0 {
                budget.check().map_err(|e| Error::uncertain(e.code))?;
                let n = spool
                    .file
                    .read(&mut buffer[..remaining.min(ipc::CHUNK) as usize])
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                if n == 0 {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                hash_state.update(&buffer[..n]);
                remaining -= n as u64;
            }
            spool.verify()?;
            let after = spool
                .file
                .metadata()
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
            if crate::checkpoint_materialize::FileVersion::of(&after) != version
                || hex::encode(hash_state.finalize()) != hash
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            budget.check().map_err(|e| Error::uncertain(e.code))?;
            Ok(version)
        }
        let version = verify(&mut self.prepared.spool, proof.bytes, &proof.sha256, budget)?;
        verify(plan, proof.plan_bytes, &proof.plan_sha256, budget)?;
        plan.file
            .seek(SeekFrom::Start(0))
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        let mut bytes = Vec::with_capacity(proof.plan_bytes as usize);
        (&mut plan.file)
            .take(proof.plan_bytes + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        if bytes.len() as u64 != proof.plan_bytes
            || hex::encode(Sha256::digest(&bytes)) != proof.plan_sha256
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let metadata =
            serde_json::from_slice(&bytes).map_err(|_| Error::uncertain(ErrorCode::Validation))?;
        Ok((
            metadata,
            crate::ContainerLayerIo {
                bytes: proof.bytes,
                sha256: proof.sha256.clone(),
            },
            version,
        ))
    }
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
    pub(crate) fn prepare_branch_owned(
        &self,
        directory: &Path,
        bytes: &[u8],
        expected: crate::branch_worker::Expected,
    ) -> Result<Prepared> {
        expected.validate()?;
        if bytes.is_empty() || bytes.len() as u64 > crate::branch_worker::METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        let selected: crate::branch_worker::Metadata =
            serde_json::from_slice(bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
        if selected.grant.directory != directory || selected.grant.owner != self.owner {
            return Err(Error::before(ErrorCode::Ownership));
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
        let request = Request {
            schema: 1,
            file_activation: None,
            operation: selected.grant.worker_operation,
            owner: self.owner,
            socket: selected.source_directory.join("agent.sock"),
            staging: spool.path.clone(),
            staging_device: spool.identity.0,
            staging_inode: spool.identity.1,
            guest_path: "/workspace/.smolbox-branch-prepare".into(),
            max_bytes: crate::branch_worker::OUTPUT_BYTES,
            kind: Kind::BranchPrepare {
                metadata: blob,
                expected,
            },
        };
        let prepared = Prepared {
            request,
            spool,
            _permit: None,
            _metadata: Some(metadata),
            _conversion: None,
        };
        prepared.verify_unentered_branch()?;
        Ok(prepared)
    }
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
        self.prepare_file(directory, socket, options, kind, None)
    }

    pub(crate) fn prepare_file(
        &self,
        directory: &Path,
        socket: PathBuf,
        options: &FileOptions,
        kind: Kind,
        activation: Option<&crate::buffered::Metadata>,
    ) -> Result<Prepared> {
        let permit = self
            .pool
            .acquire(Self::file_demand(options, &kind, activation)?)?;
        self.prepare_file_reserved(permit, directory, socket, options, kind, activation)
    }

    pub(crate) fn file_demand(
        options: &FileOptions,
        kind: &Kind,
        activation: Option<&crate::buffered::Metadata>,
    ) -> Result<crate::jobs::Demand> {
        Ok(Self::file_plan(options, kind, activation)?.0)
    }

    fn file_plan(
        options: &FileOptions,
        kind: &Kind,
        activation: Option<&crate::buffered::Metadata>,
    ) -> Result<(crate::jobs::Demand, Option<Vec<u8>>)> {
        options.validate(matches!(kind, Kind::Write { .. }))?;
        let activation_bytes = activation
            .map(|metadata| {
                metadata.file_activation_deadline()?;
                if !matches!(kind, Kind::Read | Kind::Write { .. }) {
                    return Err(Error::before(ErrorCode::Validation));
                }
                serde_json::to_vec(metadata).map_err(|_| Error::before(ErrorCode::Validation))
            })
            .transpose()?;
        let demand = if let Some(bytes) = &activation_bytes {
            crate::jobs::Demand::image_transfer(options.max_bytes, bytes.len() as u64)?
        } else if matches!(kind, Kind::Pull { .. } | Kind::Bootstrap { .. }) {
            crate::jobs::Demand::image_pull()
        } else if matches!(kind, Kind::Images { .. }) {
            crate::jobs::Demand::images()
        } else {
            crate::jobs::Demand::transfer(options.max_bytes)?
        };
        Ok((demand, activation_bytes))
    }

    pub(crate) fn prepare_file_reserved(
        &self,
        permit: crate::jobs::JobLease,
        directory: &Path,
        socket: PathBuf,
        options: &FileOptions,
        kind: Kind,
        activation: Option<&crate::buffered::Metadata>,
    ) -> Result<Prepared> {
        let (_, activation_bytes) = Self::file_plan(options, &kind, activation)?;
        let metadata = activation_bytes
            .as_ref()
            .map(|bytes| {
                let mut spool = Spool::new(directory)?;
                spool
                    .file
                    .write_all(bytes)
                    .map_err(|_| Error::before(ErrorCode::Io))?;
                spool
                    .file
                    .set_permissions(std::fs::Permissions::from_mode(0o400))
                    .and_then(|()| spool.file.sync_all())
                    .map_err(|_| Error::before(ErrorCode::Io))?;
                Ok::<_, Error>(spool)
            })
            .transpose()?;
        let spool = Spool::new(directory)?;
        let mut nonce = [0; 16];
        getrandom::fill(&mut nonce).map_err(|_| Error::before(ErrorCode::Native))?;
        let request = Request {
            schema: 1,
            file_activation: metadata.as_ref().zip(activation_bytes.as_ref()).map(
                |(spool, bytes)| ipc::Blob {
                    path: spool.path.clone(),
                    device: spool.identity.0,
                    inode: spool.identity.1,
                    bytes: bytes.len() as u64,
                },
            ),
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
            _permit: Some(permit),
            _metadata: metadata,
            _conversion: None,
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
            file_activation: None,
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
                registry: None,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: Some(permit),
            _metadata: Some(plan),
            _conversion: None,
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
            file_activation: None,
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
                registry: None,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: Some(permit),
            _metadata: Some(metadata),
            _conversion: None,
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
            file_activation: None,
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
            _permit: Some(permit),
            _metadata: Some(metadata),
            _conversion: None,
        })
    }

    /// Admission lives in the checkpoint source held by the collection lease
    /// box. No second work slot or prematurely dropped temporary-file lease.
    pub(crate) fn prepare_checkpoint_owned(
        &self,
        directory: &Path,
        bytes: &[u8],
        expected: crate::checkpoint_materialize::Expected,
    ) -> Result<Prepared> {
        expected.validate()?;
        if bytes.is_empty() || bytes.len() as u64 > crate::checkpoint_materialize::METADATA_BYTES {
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
            file_activation: None,
            operation: hex::encode(nonce),
            owner: self.owner,
            socket: directory.join("agent.sock"),
            staging: spool.path.clone(),
            staging_device: spool.identity.0,
            staging_inode: spool.identity.1,
            guest_path: "/workspace/.smolbox-checkpoint-material".into(),
            max_bytes: 1,
            kind: Kind::CheckpointMaterialize {
                metadata: blob,
                expected,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: None,
            _metadata: Some(metadata),
            _conversion: None,
        })
    }

    pub(crate) fn prepare_capture_owned(
        &self,
        directory: &Path,
        source: &Path,
        bytes: &[u8],
        expected: crate::capture_worker::Expected,
    ) -> Result<Prepared> {
        expected.validate()?;
        if bytes.is_empty() || bytes.len() as u64 > crate::capture_worker::METADATA_BYTES {
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
            file_activation: None,
            operation: hex::encode(nonce),
            owner: self.owner,
            socket: source.join("agent.sock"),
            staging: spool.path.clone(),
            staging_device: spool.identity.0,
            staging_inode: spool.identity.1,
            guest_path: "/workspace/.smolbox-capture".into(),
            max_bytes: 1,
            kind: Kind::Capture {
                metadata: blob,
                expected,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: None,
            _metadata: Some(metadata),
            _conversion: None,
        })
    }

    /// Uses the source's existing conversion reservation, retained by run's leases.
    pub(crate) fn prepare_conversion_owned(
        &self,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        expected: crate::export_bootstrap::Expected,
    ) -> Result<Prepared> {
        expected.validate()?;
        if bytes.is_empty() || bytes.len() > crate::export_bootstrap::METADATA_BYTES {
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
        let plan = Spool::new(directory)?;
        let plan_blob = ipc::Blob {
            path: plan.path.clone(),
            device: plan.identity.0,
            inode: plan.identity.1,
            bytes: crate::export_bootstrap::PLAN_BYTES,
        };
        let mut nonce = [0; 16];
        getrandom::fill(&mut nonce).map_err(|_| Error::before(ErrorCode::Native))?;
        let request = Request {
            schema: 1,
            file_activation: None,
            operation: hex::encode(nonce),
            owner: self.owner,
            socket,
            staging: spool.path.clone(),
            staging_device: spool.identity.0,
            staging_inode: spool.identity.1,
            guest_path: "/workspace/.smolbox-conversion".into(),
            max_bytes: expected.maximum,
            kind: Kind::Conversion {
                metadata: blob,
                plan: plan_blob,
                expected,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: None,
            _metadata: Some(metadata),
            _conversion: Some(plan),
        })
    }

    pub(crate) fn prepare_checkpoint_install_owned(
        &self,
        directory: &Path,
        target: &Path,
        bytes: &[u8],
        expected: crate::checkpoint_install::Expected,
    ) -> Result<Prepared> {
        expected.validate()?;
        if bytes.is_empty() || bytes.len() as u64 > crate::checkpoint_install::METADATA_BYTES {
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
            file_activation: None,
            operation: hex::encode(nonce),
            owner: self.owner,
            socket: target.join("agent.sock"),
            staging: spool.path.clone(),
            staging_device: spool.identity.0,
            staging_inode: spool.identity.1,
            guest_path: "/workspace/.smolbox-checkpoint-install".into(),
            max_bytes: 1,
            kind: Kind::CheckpointInstall {
                metadata: blob,
                expected,
            },
        };
        request.validate()?;
        Ok(Prepared {
            request,
            spool,
            _permit: None,
            _metadata: Some(metadata),
            _conversion: None,
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
            file_activation: None,
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
            _permit: Some(permit),
            _metadata: Some(metadata),
            _conversion: None,
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
        let request_bytes = ipc::encode_request(&prepared.request)?;
        let mut command = Command::new(&self.executable.path);
        command
            .arg(
                if matches!(
                    prepared.request.kind,
                    Kind::Conversion { .. }
                        | Kind::Bootstrap { .. }
                        | Kind::Pull { .. }
                        | Kind::Images { .. }
                        | Kind::Buffered { .. }
                        | Kind::Background { .. }
                        | Kind::Streaming { .. }
                        | Kind::Capture { .. }
                        | Kind::BranchPrepare { .. }
                        | Kind::CheckpointInstall { .. }
                        | Kind::CheckpointMaterialize { .. }
                        | Kind::Grow { .. }
                ) {
                    "--job-worker"
                } else {
                    "--file-worker"
                },
            )
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("SMOLVM_RESTORE_COW_DISK", "0")
            .env("SMOLVM_RESTORE_TMPFS", "0")
            .env(
                "SMOLVM_CHECKPOINT_THREADS",
                crate::checkpoint_materialize::THREADS,
            )
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
            .stderr(Stdio::null());
        if let Kind::BranchPrepare { .. } = &prepared.request.kind {
            command.env("SMOLVM_BRANCH_RAM_MODE", "shared");
        }
        let namespace = match &prepared.request.kind {
            Kind::BranchPrepare { metadata, .. } => {
                let selected: crate::branch_worker::Metadata =
                    metadata.read(self.owner, crate::branch_worker::METADATA_BYTES)?;
                Some((selected.database, selected.source_directory))
            }
            Kind::Capture { metadata, .. } => {
                let selected: crate::capture_worker::Metadata =
                    metadata.read(self.owner, crate::capture_worker::METADATA_BYTES)?;
                Some((selected.database, selected.source_directory))
            }
            _ => None,
        };
        if let Some((database, source_directory)) = namespace {
            let data = database
                .parent()
                .and_then(Path::parent)
                .and_then(Path::parent)
                .ok_or(Error::before(ErrorCode::Ownership))?;
            let cache = source_directory
                .parent()
                .and_then(Path::parent)
                .and_then(Path::parent)
                .ok_or(Error::before(ErrorCode::Ownership))?;
            command
                .env("XDG_DATA_HOME", data)
                .env("XDG_CACHE_HOME", cache);
        }
        let mut child = command
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
            no_signals: matches!(
                owned.prepared.request.kind,
                Kind::Conversion { .. }
                    | Kind::Grow { .. }
                    | Kind::Capture { .. }
                    | Kind::BranchPrepare { .. }
                    | Kind::CheckpointInstall { .. }
                    | Kind::CheckpointMaterialize { .. }
            ),
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
                let child = OwnerIdentity {
                    pid: owned.child.id() as i32,
                    birth,
                    uid: self.owner.uid,
                };
                if matches!(
                    owned.prepared.request.kind,
                    Kind::CheckpointMaterialize { .. }
                ) {
                    return owned
                        .prepared
                        .request
                        .staging
                        .parent()
                        .is_some_and(|stage| {
                            epoch
                                .register_checkpoint_materialize(
                                    child,
                                    &owned.prepared.request.operation,
                                    stage,
                                )
                                .is_ok()
                        });
                }
                epoch
                    .register_transfer(
                        child,
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
                    converted: if status.success() && decoder.complete() && reason.is_none() {
                        evidence.converted.clone()
                    } else {
                        None
                    },
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
                    branch_prepared: if status.success() && decoder.complete() && reason.is_none() {
                        evidence.branch_prepared.clone()
                    } else {
                        None
                    },
                    captured: if status.success() && decoder.complete() && reason.is_none() {
                        evidence.captured.clone()
                    } else {
                        None
                    },
                    installed: if status.success() && decoder.complete() && reason.is_none() {
                        evidence.installed.clone()
                    } else {
                        None
                    },
                    materialized: if status.success() && decoder.complete() && reason.is_none() {
                        evidence.materialized.clone()
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

    fn registry_plan(
        source: &crate::ImagePullRequest,
        secret: &str,
    ) -> crate::guest_registry::Plan {
        serde_json::from_value(serde_json::json!({"source":source,"effective_reference":source.reference,"auth":{"username":"<token>","password":secret}})).unwrap()
    }

    #[test]
    fn guest_registry_credentials_never_enter_pull_or_bootstrap_spools() {
        let temp = tempfile::tempdir().unwrap();
        let root = root(&temp);
        let supervisor = supervisor(&root, std::env::current_exe().unwrap());
        let bootstrap = crate::bootstrap::tests::plan(false);
        let expected = bootstrap.expected().unwrap();
        for startup in [false, true] {
            let prepared = if startup {
                supervisor
                    .prepare_bootstrap(&root, root.join("agent.sock"), &bootstrap)
                    .unwrap()
            } else {
                supervisor
                    .prepare_pull(&root, root.join("agent.sock"), expected.source.clone(), 1)
                    .unwrap()
            }
            .with_registry(Some(registry_plan(
                &expected.source,
                "PRIVATE-GUEST-CREDENTIAL",
            )))
            .unwrap();
            let bytes = ipc::encode_request(&prepared.request).unwrap();
            assert!(String::from_utf8_lossy(&bytes).contains("PRIVATE-GUEST-CREDENTIAL"));
            for entry in std::fs::read_dir(&root).unwrap() {
                let path = entry.unwrap().path();
                if path.is_file() {
                    assert!(!String::from_utf8_lossy(&std::fs::read(path).unwrap())
                        .contains("PRIVATE-GUEST-CREDENTIAL"));
                }
            }
            assert_eq!(supervisor.pool.counts().children, 1);
            drop(prepared);
        }
        assert_eq!(
            bootstrap.expected().unwrap().metadata_sha256,
            expected.metadata_sha256
        );
        assert_eq!(supervisor.pool.counts(), crate::jobs::Counts::default());
    }
    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM branch namespace rejection"]
    fn ordinary_branch_worker_rejects_unentered_fixture_and_collects_original_leases() {
        let (temp, metadata, expected) = crate::branch_worker::tests::fixture();
        let root = root(&temp);
        // This private DB cannot resolve to the SDK's default smolvm/server DB,
        // even under the worker's inherited namespace projection. No SDK open,
        // snapshot, manager or VM is permitted in this ordinary negative test.
        assert_eq!(metadata.database.file_name().unwrap(), "db");
        let original_db = std::fs::read(&metadata.database).unwrap();
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER")
            .expect("set the explicit rebuilt helper path");
        let supervisor = supervisor(&root, executable.into());
        let mut permit = supervisor
            .pool
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        permit.promote_branch_preparation().unwrap();
        permit
            .promote_branch_backing(metadata.grant.intent.plan.preparation_disk_bytes().unwrap())
            .unwrap();
        let admitted = supervisor.pool.counts();
        let (bytes, _) = metadata.encode().unwrap();
        let prepared = supervisor
            .prepare_branch_owned(&metadata.grant.directory, &bytes, expected)
            .unwrap();
        prepared.verify_unentered_branch().unwrap();
        let paths = (
            prepared.spool.path.clone(),
            prepared._metadata.as_ref().unwrap().path.clone(),
        );
        assert_eq!(supervisor.pool.counts(), admitted);
        let marker = std::sync::Arc::new(());
        let retained = std::sync::Arc::downgrade(&marker);
        let result = supervisor
            .run(
                prepared,
                Box::new((permit, marker)),
                Instant::now() + Duration::from_secs(60),
                &Cancellation::new(),
            )
            .unwrap();
        let RunResult::Collected(collected) = result else {
            panic!("ordinary branch rejection worker was not collected")
        };
        assert!(collected.worker_ready && !collected.termination_requested);
        assert!(!collected.outcome.native_acknowledged);
        assert_eq!(collected.outcome.observed_bytes, 0);
        assert!(collected.branch_prepared.is_none());
        collected.prepared.verify_unentered_branch().unwrap();
        assert!(retained.upgrade().is_some());
        assert_eq!(supervisor.pool.counts(), admitted);
        assert_eq!(std::fs::read(&metadata.database).unwrap(), original_db);
        assert!(!metadata.source_directory.join("agent.sock").exists());
        drop(collected);
        assert!(retained.upgrade().is_none());
        assert_eq!(supervisor.pool.counts(), crate::jobs::Counts::default());
        assert!(!paths.0.exists() && !paths.1.exists());
    }

    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM imported conversion peer"]
    fn ordinary_imported_conversion_worker_preserves_source_gate_and_spools() {
        use std::os::unix::net::UnixListener;
        let budget =
            crate::ReadBudget::for_export_work(Duration::from_secs(60), Cancellation::default())
                .unwrap();
        let (temp, engine, source, input, files) =
            crate::export_bootstrap::tests::imported_fixture(&budget);
        let root = root(&temp);
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let mut supervisor = supervisor(&root, executable.into());
        supervisor.pool = engine.jobs.clone();
        let before = engine.jobs.counts();
        let snapshot: crate::export_import::Snapshot =
            serde_json::from_value(serde_json::to_value(&input).unwrap()["imported"].clone())
                .unwrap();
        let record = engine.db.get_vm("export-source").unwrap().unwrap();
        let expected_plan = crate::ContainerExportPlan::from_imported(&record, &snapshot).unwrap();
        let socket = root.join("agent.sock");
        let peer = crate::export_bootstrap::tests::imported_peer_until(
            UnixListener::bind(&socket).unwrap(),
            files,
            false,
            budget.deadline,
        );
        let prepared = supervisor
            .prepare_conversion_owned(
                &root,
                socket,
                &serde_json::to_vec(&input).unwrap(),
                input.expected().unwrap(),
            )
            .unwrap();
        assert_eq!(engine.jobs.counts(), before);
        let marker = std::sync::Arc::new(());
        let retained = std::sync::Arc::downgrade(&marker);
        let result = supervisor
            .run(
                prepared,
                Box::new((source, marker)),
                budget.deadline,
                &budget.cancel,
            )
            .unwrap();
        let RunResult::Collected(mut collected) = result else {
            panic!("imported worker not collected")
        };
        assert!(collected.worker_ready && !collected.termination_requested);
        assert!(retained.upgrade().is_some());
        assert!(engine.gate("export-source").unwrap().try_lock().is_err());
        let (plan, layer, _) = collected.verify_conversion(&budget).unwrap();
        assert_eq!(
            crate::material::hash(&plan).unwrap(),
            crate::material::hash(&expected_plan).unwrap()
        );
        assert!(layer.bytes > 256 * 1024);
        assert_eq!(engine.jobs.counts(), before);
        assert!(
            peer.join()
                .unwrap()
                .iter()
                .filter(|r| matches!(r, smolvm_protocol::AgentRequest::FileWriteChunk { .. }))
                .count()
                > 2
        );
        drop(collected);
        assert!(retained.upgrade().is_none());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.gate("export-source").unwrap().try_lock().is_ok());
    }
    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM conversion peer"]
    fn ordinary_conversion_worker_collects_and_rehashes_both_spools_with_original_leases() {
        use smolvm_protocol::{encode_message, AgentResponse};
        use std::os::unix::net::UnixListener;
        let temp = tempfile::tempdir_in("/tmp").unwrap();
        let root = root(&temp);
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let supervisor = supervisor(&root, executable.into());
        let budget =
            crate::ReadBudget::for_export_work(Duration::from_secs(60), Cancellation::default())
                .unwrap();
        let original = crate::export_bootstrap::tests::record();
        let input =
            crate::ContainerConversionInput::from_record(original.clone(), 1024, &budget).unwrap();
        let mut permit = supervisor
            .pool
            .acquire(crate::jobs::Demand::export_source())
            .unwrap();
        permit.promote_export_disks().unwrap();
        permit.promote_export_conversion().unwrap();
        let before = supervisor.pool.counts();
        let socket = root.join("agent.sock");
        let wire = |event| vec![encode_message(&event).unwrap()];
        let completed = || {
            wire(AgentResponse::Completed {
                exit_code: 0,
                stdout: vec![],
                stderr: vec![],
            })
        };
        let peer = crate::export_bootstrap::tests::peer_until(
            UnixListener::bind(&socket).unwrap(),
            vec![
                completed(),
                completed(),
                crate::export_bootstrap::tests::cached_blobs()[0].clone(),
                crate::export_bootstrap::tests::cached_blobs()[1].clone(),
                wire(AgentResponse::Ok {
                    data: Some(
                        serde_json::to_value(crate::export_bootstrap::tests::cached()).unwrap(),
                    ),
                }),
                wire(AgentResponse::DataChunk {
                    data: b"owned layer".to_vec(),
                    done: true,
                }),
            ],
            budget.deadline,
        );
        let prepared = supervisor
            .prepare_conversion_owned(
                &root,
                socket,
                &serde_json::to_vec(&input).unwrap(),
                input.expected().unwrap(),
            )
            .unwrap();
        assert_eq!(supervisor.pool.counts(), before); // No double work admission.
        let paths = (
            prepared.spool.path.clone(),
            prepared._conversion.as_ref().unwrap().path.clone(),
        );
        let marker = std::sync::Arc::new(());
        let retained = std::sync::Arc::downgrade(&marker);
        let result = supervisor
            .run(
                prepared,
                Box::new((permit, marker)),
                budget.deadline,
                &budget.cancel,
            )
            .unwrap();
        let RunResult::Collected(mut collected) = result else {
            panic!("worker not collected")
        };
        let requests = peer.join().unwrap_or_else(|_| {
            panic!(
                "conversion peer failed after worker outcome {:?}",
                collected.outcome
            )
        });
        assert_eq!(requests.len(), 6);
        assert!(collected.worker_ready && !collected.termination_requested);
        assert!(retained.upgrade().is_some());
        let (plan, layer, _) = collected.verify_conversion(&budget).unwrap();
        plan.validate(&original).unwrap();
        assert_eq!(layer.bytes, 11);
        assert_eq!(supervisor.pool.counts(), before);
        let proof = collected.converted.clone().unwrap();
        collected.converted.as_mut().unwrap().input_sha256 = "e".repeat(64);
        assert!(collected.verify_conversion(&budget).is_err());
        collected.converted = Some(proof.clone());
        std::fs::write(&paths.0, b"other layer").unwrap();
        assert!(collected.verify_conversion(&budget).is_err());
        std::fs::write(&paths.0, b"owned layer").unwrap();
        std::fs::write(&paths.1, b"changed plan").unwrap();
        assert!(collected.verify_conversion(&budget).is_err());
        drop(collected);
        assert!(retained.upgrade().is_none());
        assert_eq!(supervisor.pool.counts().work, 0);
        assert!(!paths.0.exists() && !paths.1.exists());
    }

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
        for (packed, empty, failed, credentials) in [
            (false, false, false, false),
            (false, false, true, false),
            (false, true, false, false),
            (true, false, false, false),
            (true, false, true, false),
            (true, true, false, false),
            (false, false, false, true),
            (false, true, false, true),
        ] {
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let plan = if packed {
                crate::bootstrap::tests::packed_plan(empty)
            } else {
                crate::bootstrap::tests::plan(empty)
            };
            let expected = plan.expected().unwrap();
            let secret = format!("PRIVATE-GUEST-{}", "\n".repeat(16000));
            let prepared = supervisor
                .prepare_bootstrap(&root, socket.clone(), &plan)
                .unwrap()
                .with_registry(credentials.then(|| registry_plan(&expected.source, &secret)))
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(30);
            std::thread::scope(|scope| {
                let peer = scope.spawn(|| {
                    for stage in (if packed { 1 } else { 0 })..(if empty { 1 } else { 2 }) {
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
                            let AgentRequest::Pull { image, oci_platform, auth, proxy, no_proxy, cache_as: None } = request.body else { panic!() };
                            assert_eq!(image, expected.source.reference);
                            assert_eq!(oci_platform.as_deref(), Some(expected.source.platform.as_str()));
                            assert!(proxy.is_none() && no_proxy.is_none());
                            if credentials {
                                let auth=auth.expect("parent-supplied guest credentials");
                                assert!(auth.username=="<token>" && auth.password==secret);
                            } else { assert!(auth.is_none()); }
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
                                stop_signal: None, stop_timeout_secs: None,
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
                assert_eq!(collected.outcome.success(), packed || !failed);
                if failed && !packed {
                    assert!(collected.bootstrapped.is_none());
                } else {
                    let proof = collected.bootstrapped.as_ref().unwrap();
                    assert!(proof.matches(&expected));
                    assert_eq!(proof.container_id.is_none(), empty || failed);
                    assert_eq!(proof.launch_rejected, packed && failed);
                    assert_eq!(proof.image.is_none(), packed);
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
        for (reply, credentials) in [
            ("valid", false),
            ("packed", false),
            ("different", false),
            ("error", false),
            ("valid", true),
            ("packed", true),
            ("different", true),
            ("error", true),
            ("mirror", true),
        ] {
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + Duration::from_secs(30);
            let deadline_ns = crate::buffered::monotonic_ns().unwrap() + 30_000_000_000;
            let secret = format!("PRIVATE-GUEST-{}", "\n".repeat(16000));
            let mut registry = serde_json::to_value(registry_plan(&expected, &secret)).unwrap();
            let effective = if reply == "mirror" {
                expected
                    .reference
                    .replace("registry.example", "mirror.example/prefix")
            } else {
                expected.reference.clone()
            };
            registry["effective_reference"] = effective.clone().into();
            let registry = serde_json::from_value(registry).unwrap();
            let prepared = supervisor
                .prepare_pull(&root, socket.clone(), expected.clone(), deadline_ns)
                .unwrap()
                .with_registry(credentials.then_some(registry))
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
                    let AgentRequest::Pull { image, oci_platform, auth, proxy, no_proxy, cache_as: None } = request.body else { panic!() };
                    assert_eq!(image, effective);
                    assert_eq!(oci_platform.as_deref(), Some("linux/arm64"));
                    assert!(proxy.is_none() && no_proxy.is_none());
                    if credentials {
                        let auth=auth.expect("parent-supplied guest credentials");
                        assert!(auth.username=="<token>" && auth.password==secret);
                    } else { assert!(auth.is_none()); }
                    let progress = serde_json::json!({"status":"progress","message":"PRIVATE=discard"});
                    let result = if reply == "error" {
                        serde_json::json!({"status":"error","message":"PRIVATE=discard"})
                    } else {
                        serde_json::json!({"status":"ok","data":{
                            "reference":if reply == "different" {"registry.example/other"} else if reply=="mirror" {&effective} else {&expected.reference},
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
        // Plain files, activated image files, rejected activation, malformed
        // acknowledgement and an ordinary observation deadline (no signals).
        for (write, activation_case) in [
            (true, "bare"),
            (false, "bare"),
            (true, "ok"),
            (false, "ok"),
            (true, "mounted"),
            (false, "mounted"),
            (false, "nonzero"),
            (false, "verbose"),
            (true, "rejected"),
            (false, "malformed"),
            (false, "deadline"),
            (false, "transfer-deadline"),
            (false, "output-limit"),
        ] {
            let expires = Instant::now()
                + if matches!(activation_case, "deadline" | "transfer-deadline") {
                    Duration::from_secs(2)
                } else {
                    Duration::from_secs(30)
                };
            let successful = matches!(
                activation_case,
                "bare" | "ok" | "nonzero" | "verbose" | "mounted"
            );
            let mut record =
                smolvm::config::VmRecord::new("original".into(), 1, 512, vec![], vec![], false);
            record.image = Some("local-dir:/fixture".into());
            record.fork_overlay_owner = Some("original-overlay".into());
            let mounted = activation_case == "mounted";
            if mounted {
                record.mounts = vec![(
                    "/approved/backing".into(),
                    "/mnt/volumes/data".into(),
                    !write,
                )];
            }
            let expected_mounts = smolvm::workload::record_mounts_to_bindings(&record);
            let volume_gate = std::sync::Arc::new(crate::gate::MachineGate::default());
            let volume_guard = mounted.then(|| volume_gate.try_lock().unwrap());
            let expected_path = if mounted {
                "/mnt/volumes/data/value"
            } else {
                "/workspace/data"
            };
            let mut file_options = options();
            file_options.guest_path = expected_path.into();
            let activation = if activation_case == "bare" {
                None
            } else {
                crate::buffered::Metadata::file_activation(&record, expires).unwrap()
            };
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
            let controls = mounted.then(|| {
                [
                    supervisor
                        .pool
                        .acquire(crate::jobs::Demand::volume_observation())
                        .unwrap(),
                    supervisor
                        .pool
                        .acquire(crate::jobs::Demand::volume_observation())
                        .unwrap(),
                ]
            });
            let mut prepared = if mounted {
                let mut permit = supervisor
                    .pool
                    .acquire(crate::jobs::Demand::volume_mounts(1).unwrap())
                    .unwrap();
                permit
                    .promote_mount_worker(
                        TransferSupervisor::file_demand(&file_options, &kind, activation.as_ref())
                            .unwrap(),
                    )
                    .unwrap();
                supervisor
                    .prepare_file_reserved(
                        permit,
                        &root,
                        socket.clone(),
                        &file_options,
                        kind,
                        activation.as_ref(),
                    )
                    .unwrap()
            } else {
                supervisor
                    .prepare_file(
                        &root,
                        socket.clone(),
                        &file_options,
                        kind,
                        activation.as_ref(),
                    )
                    .unwrap()
            };
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
                    if activation_case != "bare" {
                        match message(&mut stream) {
                            AgentRequest::Run { image, command, env, workdir, user, mounts,
                                timeout_ms, interactive, tty, detached, persistent_overlay_id,
                                stdin_data, background, stop_vm_on_exit, .. } => {
                                assert_eq!(image, "local-dir:/fixture");
                                assert_eq!(command, ["/bin/true"]);
                                assert!(env.is_empty());
                                assert_eq!(mounts, expected_mounts);
                                if mounted {
                                    assert!(volume_gate.try_lock().is_err());
                                    assert_eq!(supervisor.pool.counts().work, 1);
                                    assert_eq!(supervisor.pool.counts().children, 1);
                                }
                                assert!(workdir.is_none() && user.is_none() && stdin_data.is_none());
                                assert_eq!(persistent_overlay_id.as_deref(), Some("original-overlay"));
                                assert!(timeout_ms.is_some() && interactive && !tty && !detached && !background && !stop_vm_on_exit);
                            }
                            _ => panic!("expected only fixed activation, never pull or lifecycle"),
                        }
                        if activation_case == "malformed" {
                            stream.write_all(&encode_message(&AgentResponse::Ok { data: None }).unwrap()).unwrap();
                            return;
                        }
                        if activation_case == "rejected" {
                            stream.write_all(&encode_message(&AgentResponse::Error { message: "activation rejected".into(), code: None }).unwrap()).unwrap();
                            return;
                        }
                        stream.write_all(&encode_message(&AgentResponse::Started).unwrap()).unwrap();
                        if activation_case == "deadline" {
                            // The deadline closes observation; the fake peer exits normally.
                            assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
                            return;
                        }
                        if activation_case == "output-limit" {
                            let frame = encode_message(&AgentResponse::Stdout { data: vec![0; 64 * 1024] }).unwrap();
                            for _ in 0..=crate::buffered::FILE_ACTIVATION_OUTPUT_BYTES / (64 * 1024) {
                                stream.write_all(&frame).unwrap();
                            }
                            assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
                            return;
                        }
                        if activation_case == "verbose" {
                            stream.write_all(&encode_message(&AgentResponse::Stderr { data: vec![0; 8193] }).unwrap()).unwrap();
                        }
                        stream.write_all(&encode_message(&AgentResponse::Exited { exit_code: if matches!(activation_case, "nonzero" | "verbose") { 7 } else { 0 }, oom: false }).unwrap()).unwrap();
                        drop(stream);
                        if activation_case == "rejected" { return; }
                        stream = loop {
                            match listener.accept() {
                                Ok((stream, _)) => break stream,
                                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                                    assert!(Instant::now() < until, "file worker did not reconnect");
                                    std::thread::sleep(POLL);
                                }
                                Err(error) => panic!("file fixture accept failed: {error}"),
                            }
                        };
                        stream.set_nonblocking(false).unwrap();
                        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
                        stream.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
                    }
                    if write {
                        match message(&mut stream) {
                            AgentRequest::FileWriteBegin { path, mode, total_size, .. } => {
                                assert_eq!(path, expected_path); assert_eq!(mode, Some(0o600));
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
                        assert!(matches!(message(&mut stream), AgentRequest::FileRead { path, .. } if path == expected_path));
                        if activation_case == "transfer-deadline" {
                            assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
                            return;
                        }
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
                        Box::new(volume_guard),
                        Instant::now() + Duration::from_secs(30),
                        &Cancellation::new(),
                    )
                    .unwrap();
                let RunResult::Collected(mut collected) = result else {
                    panic!("normal transfer was not collected");
                };
                assert_eq!(collected.outcome.success(), successful);
                assert_eq!(collected.outcome.native_acknowledged, successful);
                assert_eq!(
                    collected.outcome.observed_bytes,
                    if successful { binary.len() as u64 } else { 0 }
                );
                assert!(!collected.termination_requested);
                if successful && !write {
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
                if mounted {
                    assert!(volume_gate.try_lock().is_err());
                }
                peer.join().unwrap();
                assert!(
                    matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
                    "unexpected guest request after collection"
                );
            });
            assert!(volume_gate.try_lock().is_ok());
            drop(controls);
            assert_eq!(supervisor.pool.counts().work, 0);
            std::fs::remove_file(socket).unwrap();
        }
        assert_eq!(supervisor.pool.counts().work, 0);
    }
}
