//! Private, bounded transfer IPC. This entry never constructs a runtime, acquires
//! SDK ownership, starts a VM, or accepts a creation receipt.
use crate::domain::valid_hex;
use crate::host::{private_directory, unredirected};
use crate::{Error, ErrorCode, FileOptions, OwnerIdentity, Result};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::PathBuf;
use std::time::Duration;

pub(crate) const MAX_TRANSFER: u64 = 16 * 1024 * 1024;
pub(crate) const CHUNK: u64 = 64 * 1024;
pub(crate) const MAX_FRAME: usize = 16 * 1024;
pub(crate) const MAX_EVENTS: u32 = (MAX_TRANSFER / CHUNK) as u32 + 3;
const STREAM_EVENTS: u32 = 65538;

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub(crate) enum Kind {
    Capture {
        metadata: Blob,
        expected: crate::capture_worker::Expected,
    },
    Read,
    Bootstrap {
        metadata: Blob,
        expected: crate::bootstrap::Expected,
    },
    Pull {
        metadata: Blob,
        expected: crate::ImagePullRequest,
    },
    Images {
        deadline_ns: u64,
    },
    Write {
        total: u64,
        mode: Option<u32>,
    },
    Buffered {
        metadata: Blob,
    },
    Background {
        metadata: Blob,
    },
    Streaming {
        metadata: Blob,
    },
    CheckpointInstall {
        metadata: Blob,
        expected: crate::checkpoint_install::Expected,
    },
    CheckpointMaterialize {
        metadata: Blob,
        expected: crate::checkpoint_materialize::Expected,
    },
    Grow {
        metadata: Blob,
        expected: crate::growth::GrowthProof,
    },
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Blob {
    pub path: PathBuf,
    pub device: u64,
    pub inode: u64,
    pub bytes: u64,
}
impl Blob {
    pub(crate) fn read<T: serde::de::DeserializeOwned>(
        &self,
        owner: OwnerIdentity,
        maximum: u64,
    ) -> Result<T> {
        if self.bytes == 0 || self.bytes > maximum {
            return Err(Error::before(ErrorCode::Validation));
        }
        unredirected(&self.path)?;
        private_directory(
            self.path
                .parent()
                .ok_or(Error::before(ErrorCode::Ownership))?,
        )?;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&self.path)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let meta = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if !meta.is_file()
            || meta.uid() != owner.uid
            || meta.mode() & 0o777 != 0o400
            || meta.len() != self.bytes
            || (meta.dev(), meta.ino()) != (self.device, self.inode)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut bytes = Vec::new();
        std::io::Read::by_ref(&mut file)
            .take(self.bytes + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 != self.bytes {
            return Err(Error::before(ErrorCode::Ownership));
        }
        serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Validation))
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Request {
    pub schema: u32,
    pub operation: String,
    pub owner: OwnerIdentity,
    pub socket: PathBuf,
    pub staging: PathBuf,
    pub staging_device: u64,
    pub staging_inode: u64,
    pub guest_path: String,
    pub max_bytes: u64,
    pub kind: Kind,
}

impl Request {
    pub(crate) fn validate(&self) -> Result<()> {
        if let Kind::Buffered { metadata }
        | Kind::Background { metadata }
        | Kind::Streaming { metadata }
        | Kind::Capture { metadata, .. }
        | Kind::CheckpointInstall { metadata, .. }
        | Kind::CheckpointMaterialize { metadata, .. }
        | Kind::Grow { metadata, .. }
        | Kind::Pull { metadata, .. }
        | Kind::Bootstrap { metadata, .. } = &self.kind
        {
            if metadata.path.parent() != self.staging.parent()
                || metadata.bytes == 0
                || metadata.bytes
                    > if matches!(self.kind, Kind::Bootstrap { .. }) {
                        crate::bootstrap::METADATA_BYTES
                    } else if matches!(self.kind, Kind::Pull { .. }) {
                        crate::image_pull::METADATA_BYTES
                    } else if matches!(self.kind, Kind::Capture { .. }) {
                        crate::capture_worker::METADATA_BYTES
                    } else if matches!(self.kind, Kind::CheckpointInstall { .. }) {
                        crate::checkpoint_install::METADATA_BYTES
                    } else if matches!(self.kind, Kind::CheckpointMaterialize { .. }) {
                        crate::checkpoint_materialize::METADATA_BYTES
                    } else if matches!(self.kind, Kind::Grow { .. }) {
                        crate::growth::METADATA_BYTES
                    } else {
                        crate::buffered::COMMAND_METADATA_BYTES
                    }
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        if let Kind::Bootstrap { expected, .. } = &self.kind {
            expected.source.validate()?;
            if self.max_bytes != 1
                || !crate::domain::valid_id(&expected.machine)
                || !valid_hex(&expected.metadata_sha256, 64)
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        if let Kind::Pull { expected, .. } = &self.kind {
            expected.validate()?;
            if self.max_bytes != 1 {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        if let Kind::Capture { expected, .. } = &self.kind {
            expected.validate()?;
            if self.max_bytes != 1 {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        if let Kind::CheckpointInstall { expected, .. } = &self.kind {
            expected.validate()?;
            if self.max_bytes != 1 {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        if let Kind::CheckpointMaterialize { expected, .. } = &self.kind {
            expected.validate()?;
            if self.max_bytes != 1 {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        if let Kind::Grow { expected, .. } = self.kind {
            if !(1..=64).contains(&expected.storage_gib)
                || !(1..=64).contains(&expected.overlay_gib)
                || self.max_bytes != 1
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        if let Kind::Images { deadline_ns } = self.kind {
            if deadline_ns == 0 || self.max_bytes != crate::images::IMAGE_OUTPUT_BYTES {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        let mode = match self.kind {
            Kind::Read
            | Kind::Bootstrap { .. }
            | Kind::Pull { .. }
            | Kind::Images { .. }
            | Kind::Buffered { .. }
            | Kind::Background { .. }
            | Kind::Streaming { .. }
            | Kind::Capture { .. }
            | Kind::CheckpointInstall { .. }
            | Kind::CheckpointMaterialize { .. }
            | Kind::Grow { .. } => None,
            Kind::Write { mode, .. } => mode,
        };
        FileOptions {
            guest_path: self.guest_path.clone(),
            max_bytes: self.max_bytes,
            timeout: Duration::from_secs(1),
            mode,
        }
        .validate(matches!(self.kind, Kind::Write { .. }))?;
        if self.schema != 1
            || !valid_hex(&self.operation, 32)
            || !self.socket.is_absolute()
            || self.socket.as_os_str().len() > 4096
            || self.staging.as_os_str().len() > 4096
            || self.socket.file_name() != Some("agent.sock".as_ref())
            || self
                .socket
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
            || self.owner.pid <= 0
            || self.owner.birth == 0
            || matches!(self.kind, Kind::Write { total, .. } if total > self.max_bytes)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }

    fn staging_file(&self) -> Result<File> {
        unredirected(&self.staging)?;
        private_directory(
            self.staging
                .parent()
                .ok_or(Error::before(ErrorCode::Ownership))?,
        )?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&self.staging)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        let required_mode = if matches!(
            self.kind,
            Kind::Read
                | Kind::Bootstrap { .. }
                | Kind::Pull { .. }
                | Kind::Images { .. }
                | Kind::Buffered { .. }
                | Kind::Background { .. }
                | Kind::Streaming { .. }
                | Kind::Capture { .. }
                | Kind::CheckpointInstall { .. }
                | Kind::CheckpointMaterialize { .. }
                | Kind::Grow { .. }
        ) {
            0o600
        } else {
            0o400
        };
        if !metadata.is_file()
            || metadata.uid() != self.owner.uid
            || metadata.mode() & 0o777 != required_mode
            || (metadata.dev(), metadata.ino()) != (self.staging_device, self.staging_inode)
            || match self.kind {
                Kind::Read
                | Kind::Bootstrap { .. }
                | Kind::Pull { .. }
                | Kind::Images { .. }
                | Kind::Buffered { .. }
                | Kind::Background { .. }
                | Kind::Streaming { .. }
                | Kind::Capture { .. }
                | Kind::CheckpointInstall { .. }
                | Kind::CheckpointMaterialize { .. }
                | Kind::Grow { .. } => metadata.len() != 0,
                Kind::Write { total, .. } => metadata.len() != total,
            }
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(file)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub(crate) enum Event {
    Captured {
        proof: crate::capture_worker::Proof,
    },
    StreamOutput {
        stderr: bool,
        offset: u64,
        bytes: u64,
    },
    StreamCompleted {
        completion: crate::Completion,
        exit_code: Option<i32>,
        bytes: u64,
        running: bool,
    },
    Bootstrapped {
        proof: crate::bootstrap::Proof,
    },
    ImagePulled {
        image: crate::ImageObservation,
    },
    ImagesListed {
        bytes: u64,
    },
    Ready,
    Progress {
        bytes: u64,
    },
    Acknowledged {
        bytes: u64,
    },
    Failed {
        bytes: u64,
    },
    Limited {
        bytes: u64,
    },
    CommandCompleted {
        exit_code: i32,
        stdout: u64,
        stderr: u64,
        limited: bool,
    },
    Launched {
        pid: u32,
    },
    CheckpointInstalled {
        proof: crate::checkpoint_install::Proof,
    },
    CheckpointMaterialized {
        proof: crate::checkpoint_materialize::Proof,
    },
    Grown {
        proof: crate::growth::GrowthProof,
    },
}

#[derive(Clone, Copy)]
pub(crate) struct CommandProof {
    pub exit_code: i32,
    pub stdout: u64,
    pub stderr: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Frame {
    pub operation: String,
    pub sequence: u32,
    pub event: Event,
}

pub(crate) fn encode(value: &impl Serialize) -> Result<Vec<u8>> {
    let bytes = serde_json::to_vec(value).map_err(|_| Error::before(ErrorCode::Validation))?;
    if bytes.is_empty() || bytes.len() > MAX_FRAME {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut frame = (bytes.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(&bytes);
    Ok(frame)
}

fn read_request(reader: &mut impl Read) -> Result<Request> {
    let mut header = [0u8; 4];
    reader
        .read_exact(&mut header)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > MAX_FRAME {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut bytes = vec![0; size];
    reader
        .read_exact(&mut bytes)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let request: Request =
        serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
    request.validate()?;
    Ok(request)
}

/// Incremental controller reader; no allocation from an unchecked length.
#[derive(Default)]
pub(crate) struct Decoder {
    header: [u8; 4],
    header_bytes: usize,
    body: Vec<u8>,
    size: usize,
    events: u32,
    streaming: bool,
}

impl Decoder {
    pub(crate) fn for_request(request: &Request) -> Self {
        Self {
            streaming: matches!(request.kind, Kind::Streaming { .. }),
            ..Self::default()
        }
    }
    pub(crate) fn feed(&mut self, mut bytes: &[u8]) -> Result<Vec<Frame>> {
        let mut frames = Vec::new();
        while !bytes.is_empty() {
            if self.header_bytes < 4 {
                let count = (4 - self.header_bytes).min(bytes.len());
                self.header[self.header_bytes..self.header_bytes + count]
                    .copy_from_slice(&bytes[..count]);
                self.header_bytes += count;
                bytes = &bytes[count..];
                if self.header_bytes < 4 {
                    continue;
                }
                self.size = u32::from_be_bytes(self.header) as usize;
                if self.size == 0
                    || self.size > MAX_FRAME
                    || self.events
                        >= if self.streaming {
                            STREAM_EVENTS
                        } else {
                            MAX_EVENTS
                        }
                {
                    return Err(Error::before(ErrorCode::Validation));
                }
            }
            let count = (self.size - self.body.len()).min(bytes.len());
            self.body.extend_from_slice(&bytes[..count]);
            bytes = &bytes[count..];
            if self.body.len() == self.size {
                frames.push(
                    serde_json::from_slice(&self.body)
                        .map_err(|_| Error::before(ErrorCode::Validation))?,
                );
                self.events += 1;
                self.body.clear();
                self.header_bytes = 0;
            }
        }
        Ok(frames)
    }

    pub(crate) fn complete(&self) -> bool {
        self.header_bytes == 0 && self.body.is_empty()
    }
}

pub(crate) struct Evidence {
    pub captured: Option<crate::capture_worker::Proof>,
    capture: Option<crate::capture_worker::Expected>,
    pub stream: Option<crate::CommandOutcome>,
    pub command: Option<CommandProof>,
    pub launched: Option<u32>,
    pub bootstrapped: Option<crate::bootstrap::Proof>,
    bootstrap: Option<crate::bootstrap::Expected>,
    pub pulled: Option<crate::ImageObservation>,
    pull: Option<crate::ImagePullRequest>,
    pub installed: Option<crate::checkpoint_install::Proof>,
    install: Option<crate::checkpoint_install::Expected>,
    pub materialized: Option<crate::checkpoint_materialize::Proof>,
    materialize: Option<crate::checkpoint_materialize::Expected>,
    pub grown: Option<crate::growth::GrowthProof>,
    growth: Option<crate::growth::GrowthProof>,
    pub limited: bool,
    buffered: bool,
    background: bool,
    streaming: bool,
    images: bool,
    operation: String,
    sequence: u32,
    max_bytes: u64,
    exact_write: Option<u64>,
    ready: bool,
    terminal: bool,
    retired: bool,
    pub observed_bytes: u64,
    pub acknowledged: bool,
}

impl Evidence {
    pub(crate) fn new(request: &Request) -> Self {
        Self {
            captured: None,
            capture: match &request.kind {
                Kind::Capture { expected, .. } => Some(expected.clone()),
                _ => None,
            },
            bootstrapped: None,
            bootstrap: match &request.kind {
                Kind::Bootstrap { expected, .. } => Some(expected.clone()),
                _ => None,
            },
            pulled: None,
            pull: match &request.kind {
                Kind::Pull { expected, .. } => Some(expected.clone()),
                _ => None,
            },
            images: matches!(request.kind, Kind::Images { .. }),
            operation: request.operation.clone(),
            stream: None,
            command: None,
            launched: None,
            installed: None,
            install: match &request.kind {
                Kind::CheckpointInstall { expected, .. } => Some(expected.clone()),
                _ => None,
            },
            materialized: None,
            materialize: match &request.kind {
                Kind::CheckpointMaterialize { expected, .. } => Some(expected.clone()),
                _ => None,
            },
            grown: None,
            growth: match request.kind {
                Kind::Grow { expected, .. } => Some(expected),
                _ => None,
            },
            limited: false,
            buffered: matches!(request.kind, Kind::Buffered { .. }),
            background: matches!(request.kind, Kind::Background { .. }),
            streaming: matches!(request.kind, Kind::Streaming { .. }),
            sequence: 0,
            max_bytes: request.max_bytes,
            exact_write: match request.kind {
                Kind::Read
                | Kind::Bootstrap { .. }
                | Kind::Pull { .. }
                | Kind::Images { .. }
                | Kind::Buffered { .. }
                | Kind::Background { .. }
                | Kind::Streaming { .. }
                | Kind::Capture { .. }
                | Kind::CheckpointInstall { .. }
                | Kind::CheckpointMaterialize { .. }
                | Kind::Grow { .. } => None,
                Kind::Write { total, .. } => Some(total),
            },
            ready: false,
            terminal: false,
            retired: false,
            observed_bytes: 0,
            acknowledged: false,
        }
    }

    pub(crate) fn retire(&mut self) {
        self.retired = true;
    }

    #[cfg(test)]
    pub(crate) fn ready(&self) -> bool {
        self.ready
    }

    pub(crate) fn event(&mut self, frame: Frame) -> Result<()> {
        if frame.operation != self.operation
            || frame.sequence != self.sequence
            || self.sequence
                >= if self.streaming {
                    STREAM_EVENTS
                } else {
                    MAX_EVENTS
                }
            || self.terminal
            || self.retired
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        match frame.event {
            Event::StreamOutput { offset, bytes, .. }
                if self.streaming
                    && self.ready
                    && offset == self.observed_bytes
                    && bytes > 0
                    && bytes <= CHUNK
                    && bytes <= self.max_bytes.saturating_sub(offset) =>
            {
                self.observed_bytes += bytes;
            }
            Event::StreamCompleted {
                completion,
                exit_code,
                bytes,
                running,
            } if self.streaming
                && self.ready
                && bytes == self.observed_bytes
                && completion != crate::Completion::Unknown
                && (exit_code.is_none() || running)
                && (bytes == 0 || running)
                && (completion != crate::Completion::Exited
                    || (exit_code.is_some() && running)) =>
            {
                self.acknowledged = completion == crate::Completion::Exited;
                self.limited = completion == crate::Completion::OutputLimit;
                self.terminal = true;
                self.stream = Some(crate::CommandOutcome {
                    completion,
                    dispatch: crate::Dispatch::MayHaveDispatched,
                    observed_exit: exit_code,
                    running_observed: running,
                    output_bytes: bytes,
                });
            }
            Event::Bootstrapped { proof }
                if self.ready
                    && self
                        .bootstrap
                        .as_ref()
                        .is_some_and(|expected| proof.matches(expected)) =>
            {
                self.bootstrapped = Some(proof);
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::ImagePulled { image }
                if self.ready
                    && self
                        .pull
                        .as_ref()
                        .is_some_and(|expected| expected.matches(&image)) =>
            {
                self.pulled = Some(image);
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::ImagesListed { bytes }
                if self.images && self.ready && bytes > 0 && bytes <= self.max_bytes =>
            {
                self.observed_bytes = bytes;
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::Ready if !self.ready && self.sequence == 0 => self.ready = true,
            Event::Progress { bytes }
                if self.growth.is_none()
                    && self.materialize.is_none()
                    && self.install.is_none()
                    && self.capture.is_none()
                    && self.bootstrap.is_none()
                    && self.pull.is_none()
                    && !self.images
                    && !self.background
                    && !self.streaming
                    && self.ready
                    && bytes > self.observed_bytes
                    && bytes <= self.max_bytes =>
            {
                self.observed_bytes = bytes;
            }
            Event::Acknowledged { bytes }
                if self.growth.is_none()
                    && self.materialize.is_none()
                    && self.install.is_none()
                    && self.capture.is_none()
                    && self.bootstrap.is_none()
                    && self.pull.is_none()
                    && !self.images
                    && !self.buffered
                    && !self.streaming
                    && !self.background
                    && self.ready
                    && bytes >= self.observed_bytes
                    && bytes <= self.max_bytes
                    && self.exact_write.is_none_or(|total| total == bytes) =>
            {
                self.observed_bytes = bytes;
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::Failed { bytes }
                if self.ready
                    && bytes >= self.observed_bytes
                    && bytes <= self.max_bytes
                    && ((self.growth.is_none()
                        && self.materialize.is_none()
                        && self.install.is_none()
                        && self.capture.is_none()
                        && self.pull.is_none()
                        && self.bootstrap.is_none())
                        || bytes == 0) =>
            {
                self.observed_bytes = bytes;
                self.terminal = true;
            }
            Event::Limited { bytes }
                if self.growth.is_none()
                    && self.materialize.is_none()
                    && self.install.is_none()
                    && self.capture.is_none()
                    && self.bootstrap.is_none()
                    && self.pull.is_none()
                    && self.ready
                    && bytes >= self.observed_bytes
                    && bytes <= self.max_bytes =>
            {
                self.observed_bytes = bytes;
                self.limited = true;
                self.terminal = true;
            }
            Event::CommandCompleted {
                exit_code,
                stdout,
                stderr,
                limited,
            } if self.buffered
                && self.ready
                && stdout.checked_add(stderr).is_some_and(|bytes| {
                    bytes <= self.max_bytes && bytes >= self.observed_bytes
                }) =>
            {
                self.observed_bytes = stdout + stderr;
                self.acknowledged = true;
                self.terminal = true;
                self.command = Some(CommandProof {
                    exit_code,
                    stdout,
                    stderr,
                });
                self.limited = limited;
            }
            Event::Captured { proof }
                if self.ready
                    && self
                        .capture
                        .as_ref()
                        .is_some_and(|expected| proof.matches(expected)) =>
            {
                self.captured = Some(proof);
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::CheckpointInstalled { proof }
                if self.ready
                    && self
                        .install
                        .as_ref()
                        .is_some_and(|expected| proof.matches(expected)) =>
            {
                self.installed = Some(proof);
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::CheckpointMaterialized { proof }
                if self.ready
                    && self
                        .materialize
                        .as_ref()
                        .is_some_and(|expected| proof.matches(expected)) =>
            {
                self.materialized = Some(proof);
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::Grown { proof } if self.ready && self.growth == Some(proof) => {
                self.grown = Some(proof);
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::Launched { pid }
                if self.background && self.ready && pid > 0 && self.observed_bytes == 0 =>
            {
                self.launched = Some(pid);
                self.acknowledged = true;
                self.terminal = true;
            }
            _ => return Err(Error::before(ErrorCode::Validation)),
        }
        self.sequence += 1;
        Ok(())
    }
}

struct Writer<'a, W: Write> {
    output: &'a mut W,
    operation: String,
    sequence: u32,
    progress: u64,
    failed: bool,
    streaming: bool,
}

impl<W: Write> Writer<'_, W> {
    fn event(&mut self, event: Event) -> Result<()> {
        if self.sequence
            >= if self.streaming {
                STREAM_EVENTS
            } else {
                MAX_EVENTS
            }
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        let frame = Frame {
            operation: self.operation.clone(),
            sequence: self.sequence,
            event,
        };
        self.output
            .write_all(&encode(&frame)?)
            .and_then(|()| self.output.flush())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        self.sequence += 1;
        Ok(())
    }

    fn progress(&mut self, bytes: u64) {
        // Progress carries no guest bytes and is coalesced to bound IPC events.
        if !self.failed && bytes >= self.progress.saturating_add(CHUNK) {
            self.failed = self.event(Event::Progress { bytes }).is_err();
            self.progress = bytes;
        }
    }
}

/// Called only by the packaged executable's private --file-worker entry point.
/// Its blocking SDK calls are supervised externally by the controlling engine.
pub fn run_file_worker() -> Result<()> {
    let request = read_request(&mut std::io::stdin().lock())?;
    request.owner.arm_subprocess_watch()?;
    let input = request.staging_file()?;
    let mut output = std::io::stdout().lock();
    let mut writer = Writer {
        output: &mut output,
        operation: request.operation.clone(),
        sequence: 0,
        progress: 0,
        failed: false,
        streaming: matches!(request.kind, Kind::Streaming { .. }),
    };
    writer.event(Event::Ready)?;
    if let Kind::Bootstrap { metadata, expected } = &request.kind {
        return writer.event(match crate::bootstrap::run(&request, metadata, expected) {
            Ok(proof) => Event::Bootstrapped { proof },
            Err(_) => Event::Failed { bytes: 0 },
        });
    }
    if let Kind::Pull { metadata, expected } = &request.kind {
        return writer.event(match crate::image_pull::run(&request, metadata, expected) {
            Ok(image) => Event::ImagePulled { image },
            Err(_) => Event::Failed { bytes: 0 },
        });
    }
    if matches!(request.kind, Kind::Images { .. }) {
        return writer.event(match crate::images::run(&request) {
            Ok(bytes) => Event::ImagesListed { bytes },
            Err(_) => Event::Failed { bytes: 0 },
        });
    }
    if let Kind::Capture { metadata, expected } = &request.kind {
        return writer.event(
            match crate::capture_worker::run(&request, metadata, expected) {
                Ok(proof) => Event::Captured { proof },
                Err(_) => Event::Failed { bytes: 0 },
            },
        );
    }
    if let Kind::CheckpointInstall { metadata, expected } = &request.kind {
        return writer.event(
            match crate::checkpoint_install::run(&request, metadata, expected) {
                Ok(proof) => Event::CheckpointInstalled { proof },
                Err(_) => Event::Failed { bytes: 0 },
            },
        );
    }
    if let Kind::CheckpointMaterialize { metadata, expected } = &request.kind {
        return writer.event(
            match crate::checkpoint_materialize::run(&request, metadata, expected) {
                Ok(proof) => Event::CheckpointMaterialized { proof },
                Err(_) => Event::Failed { bytes: 0 },
            },
        );
    }
    if let Kind::Grow { metadata, expected } = &request.kind {
        return writer.event(match crate::growth::run(&request, metadata, *expected) {
            Ok(proof) => Event::Grown { proof },
            Err(_) => Event::Failed { bytes: 0 },
        });
    }
    if let Kind::Buffered { metadata }
    | Kind::Background { metadata }
    | Kind::Streaming { metadata } = &request.kind
    {
        let output = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&request.staging)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let info = output
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if (info.dev(), info.ino()) != (request.staging_device, request.staging_inode) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if matches!(request.kind, Kind::Streaming { .. }) {
            return crate::streaming::run(&request, metadata, output, |event| writer.event(event));
        }
        return writer.event(crate::buffered::run(&request, metadata, output)?);
    }
    // A header-first relay bounds SDK allocation before its receive buffer.
    // AgentClient calls still own the guest protocol and create no runtime.
    let mut observed = 0;
    let result = crate::agent_io::BoundedAgent::connect(&request.socket, request.max_bytes)
        .and_then(|mut connection| {
            {
                let client = &mut connection.client;
                match request.kind {
                    Kind::Read => client
                        .read_file_to_path_capped(
                            &request.guest_path,
                            &request.staging,
                            request.max_bytes,
                            |bytes| {
                                observed = bytes;
                                writer.progress(bytes);
                            },
                        )
                        .map(|bytes| observed = bytes),
                    Kind::Write { total, mode } => client.write_file_from_reader_with_progress(
                        &request.guest_path,
                        input,
                        total,
                        smolvm::agent::FileWriteMeta::mode_only(mode),
                        |bytes| {
                            observed = bytes;
                            writer.progress(bytes);
                        },
                    ),
                    Kind::Bootstrap { .. }
                    | Kind::Pull { .. }
                    | Kind::Images { .. }
                    | Kind::Buffered { .. }
                    | Kind::Background { .. }
                    | Kind::Streaming { .. }
                    | Kind::Capture { .. }
                    | Kind::CheckpointInstall { .. }
                    | Kind::CheckpointMaterialize { .. }
                    | Kind::Grow { .. } => {
                        unreachable!()
                    }
                }
            }
            .map_err(|_| Error::uncertain(ErrorCode::Native))
        });
    if observed > request.max_bytes {
        return Err(Error::uncertain(ErrorCode::Native));
    }
    writer.event(if result.is_ok() && !writer.failed {
        Event::Acknowledged { bytes: observed }
    } else {
        Event::Failed { bytes: observed }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_requires_distinct_exact_proof_and_ignores_retired_or_generic_ack() {
        let expected = crate::capture_worker::Expected {
            metadata_sha256: "a".repeat(64),
            operation_id: "capture-1".into(),
        };
        let query = request(Kind::Capture {
            metadata: Blob {
                path: "/tmp/metadata".into(),
                device: 1,
                inode: 2,
                bytes: 1,
            },
            expected: expected.clone(),
        });
        let proof = crate::capture_worker::Proof {
            expected,
            artifact: crate::CaptureArtifact {
                sha256: "b".repeat(64),
                size_bytes: 512,
                head: "c".repeat(32),
                parent: None,
            },
            device: 1,
            inode: 2,
            source_pid: (123, 456),
            source_material_sha256: "d".repeat(64),
        };
        for event in [
            Event::Acknowledged { bytes: 0 },
            Event::Progress { bytes: 1 },
        ] {
            let mut evidence = Evidence::new(&query);
            evidence.event(frame(0, Event::Ready)).unwrap();
            assert!(evidence.event(frame(1, event)).is_err());
            assert!(evidence.captured.is_none());
        }
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        let mut crossed = proof.clone();
        crossed.expected.operation_id = "another".into();
        assert!(evidence
            .event(frame(1, Event::Captured { proof: crossed }))
            .is_err());
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        evidence.retire();
        assert!(evidence
            .event(frame(
                1,
                Event::Captured {
                    proof: proof.clone(),
                },
            ))
            .is_err());
        assert!(evidence.captured.is_none());
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        evidence
            .event(frame(
                1,
                Event::Captured {
                    proof: proof.clone(),
                },
            ))
            .unwrap();
        assert!(evidence.captured.is_some());
        assert!(evidence.acknowledged);
        assert!(evidence.event(frame(2, Event::Captured { proof })).is_err());
    }

    #[test]
    fn checkpoint_install_requires_its_own_exact_proof_and_rejects_generic_ack() {
        let expected = crate::checkpoint_install::Expected {
            metadata_sha256: "a".repeat(64),
            ticket_sha256: "b".repeat(64),
        };
        let query = request(Kind::CheckpointInstall {
            metadata: Blob {
                path: "/tmp/install-metadata".into(),
                device: 1,
                inode: 2,
                bytes: 1,
            },
            expected: expected.clone(),
        });
        let proof = crate::checkpoint_install::Proof {
            expected,
            device: 1,
            inode: 2,
            storage_gib: 1,
            overlay_gib: 1,
            inventory_sha256: "c".repeat(64),
        };
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        assert!(evidence
            .event(frame(1, Event::Acknowledged { bytes: 0 }))
            .is_err());
        let mut crossed = proof.clone();
        crossed.expected.ticket_sha256 = "d".repeat(64);
        assert!(evidence
            .event(frame(1, Event::CheckpointInstalled { proof: crossed }))
            .is_err());
        evidence
            .event(frame(
                1,
                Event::CheckpointInstalled {
                    proof: proof.clone(),
                },
            ))
            .unwrap();
        assert_eq!(evidence.installed, Some(proof.clone()));
        assert!(evidence
            .event(frame(2, Event::CheckpointInstalled { proof }))
            .is_err());
    }

    #[test]
    fn checkpoint_material_requires_distinct_correlated_proof_and_rejects_retired_or_crossed_events(
    ) {
        let expected = crate::checkpoint_materialize::Expected {
            metadata_sha256: "a".repeat(64),
            source_sha256: "b".repeat(64),
        };
        let query = request(Kind::CheckpointMaterialize {
            metadata: Blob {
                path: "/tmp/metadata".into(),
                device: 1,
                inode: 2,
                bytes: 1,
            },
            expected: expected.clone(),
        });
        let proof = crate::checkpoint_materialize::Proof {
            expected: expected.clone(),
            device: 1,
            inode: 2,
            logical_bytes: 1024,
            files: 6,
            material_sha256: "c".repeat(64),
        };
        for invalid in [
            Event::Acknowledged { bytes: 0 },
            Event::Progress { bytes: 1 },
            Event::Limited { bytes: 0 },
            Event::Grown {
                proof: crate::growth::GrowthProof {
                    storage_gib: 1,
                    overlay_gib: 1,
                },
            },
        ] {
            let mut evidence = Evidence::new(&query);
            evidence.event(frame(0, Event::Ready)).unwrap();
            assert!(evidence.event(frame(1, invalid)).is_err());
            assert!(evidence.materialized.is_none());
        }
        let mut crossed = proof.clone();
        crossed.expected.source_sha256 = "d".repeat(64);
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        assert!(evidence
            .event(frame(1, Event::CheckpointMaterialized { proof: crossed }))
            .is_err());
        evidence
            .event(frame(
                1,
                Event::CheckpointMaterialized {
                    proof: proof.clone(),
                },
            ))
            .unwrap();
        assert_eq!(evidence.materialized, Some(proof.clone()));
        assert!(evidence
            .event(frame(
                2,
                Event::CheckpointMaterialized {
                    proof: proof.clone()
                }
            ))
            .is_err());
        let mut retired = Evidence::new(&query);
        retired.event(frame(0, Event::Ready)).unwrap();
        retired.retire();
        assert!(retired
            .event(frame(1, Event::CheckpointMaterialized { proof }))
            .is_err());
    }

    #[test]
    fn growth_requires_distinct_exact_correlated_proof_and_rejects_late_success() {
        let expected = crate::growth::GrowthProof {
            storage_gib: 2,
            overlay_gib: 3,
        };
        let query = request(Kind::Grow {
            metadata: Blob {
                path: "/tmp/metadata".into(),
                device: 1,
                inode: 2,
                bytes: 1,
            },
            expected,
        });
        for invalid in [
            Event::Acknowledged { bytes: 0 },
            Event::Progress { bytes: 1 },
            Event::Launched { pid: 1 },
            Event::Limited { bytes: 0 },
            Event::CommandCompleted {
                exit_code: 0,
                stdout: 0,
                stderr: 0,
                limited: false,
            },
            Event::Grown {
                proof: crate::growth::GrowthProof {
                    storage_gib: 3,
                    overlay_gib: 3,
                },
            },
        ] {
            let mut evidence = Evidence::new(&query);
            evidence.event(frame(0, Event::Ready)).unwrap();
            assert!(evidence.event(frame(1, invalid)).is_err());
            assert!(!evidence.acknowledged);
        }
        let mut evidence = Evidence::new(&query);
        assert!(evidence
            .event(frame(0, Event::Grown { proof: expected }))
            .is_err());
        evidence.event(frame(0, Event::Ready)).unwrap();
        evidence
            .event(frame(1, Event::Grown { proof: expected }))
            .unwrap();
        assert!(evidence.acknowledged);
        assert_eq!(evidence.grown, Some(expected));
        assert!(evidence
            .event(frame(2, Event::Grown { proof: expected }))
            .is_err());
        let mut retired = Evidence::new(&query);
        retired.event(frame(0, Event::Ready)).unwrap();
        retired.retire();
        assert!(retired
            .event(frame(1, Event::Grown { proof: expected }))
            .is_err());
        assert!(!retired.acknowledged);
        let mut ordinary = Evidence::new(&request(Kind::Read));
        ordinary.event(frame(0, Event::Ready)).unwrap();
        assert!(ordinary
            .event(frame(1, Event::Grown { proof: expected }))
            .is_err());
    }
    #[test]
    fn streaming_spool_ranges_and_terminal_exit_are_correlated_without_file_ack() {
        let query = request(Kind::Streaming {
            metadata: Blob {
                path: "/private/meta".into(),
                device: 1,
                inode: 2,
                bytes: 16,
            },
        });
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        assert!(evidence
            .event(frame(1, Event::Acknowledged { bytes: 0 }))
            .is_err());
        assert!(evidence
            .event(frame(
                1,
                Event::StreamOutput {
                    stderr: false,
                    offset: 1,
                    bytes: 3
                }
            ))
            .is_err());
        evidence
            .event(frame(
                1,
                Event::StreamOutput {
                    stderr: false,
                    offset: 0,
                    bytes: 3,
                },
            ))
            .unwrap();
        assert!(evidence
            .event(frame(
                2,
                Event::StreamOutput {
                    stderr: true,
                    offset: 0,
                    bytes: 2
                }
            ))
            .is_err());
        evidence
            .event(frame(
                2,
                Event::StreamOutput {
                    stderr: true,
                    offset: 3,
                    bytes: 2,
                },
            ))
            .unwrap();
        assert!(evidence
            .event(frame(
                3,
                Event::StreamCompleted {
                    completion: crate::Completion::Exited,
                    exit_code: None,
                    bytes: 5,
                    running: true
                }
            ))
            .is_err());
        assert!(evidence
            .event(frame(
                3,
                Event::StreamCompleted {
                    completion: crate::Completion::Exited,
                    exit_code: Some(7),
                    bytes: 4,
                    running: true
                }
            ))
            .is_err());
        evidence
            .event(frame(
                3,
                Event::StreamCompleted {
                    completion: crate::Completion::Exited,
                    exit_code: Some(7),
                    bytes: 5,
                    running: true,
                },
            ))
            .unwrap();
        assert_eq!(evidence.stream.unwrap().observed_exit, Some(7));
        assert!(evidence.command.is_none() && evidence.launched.is_none());
        let mut retired = Evidence::new(&query);
        retired.event(frame(0, Event::Ready)).unwrap();
        retired.retire();
        assert!(retired
            .event(frame(
                1,
                Event::StreamOutput {
                    stderr: false,
                    offset: 0,
                    bytes: 3
                }
            ))
            .is_err());
        assert!(retired.stream.is_none());
    }
    #[test]
    fn background_launch_has_no_exit_or_file_ack_authority_and_retired_pid_is_not_promoted() {
        let query = request(Kind::Background {
            metadata: Blob {
                path: "/private/meta".into(),
                device: 1,
                inode: 2,
                bytes: 16,
            },
        });
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        for event in [
            Event::Acknowledged { bytes: 0 },
            Event::Launched { pid: 0 },
            Event::CommandCompleted {
                exit_code: 0,
                stdout: 0,
                stderr: 0,
                limited: false,
            },
        ] {
            assert!(evidence.event(frame(1, event)).is_err());
        }
        evidence
            .event(frame(1, Event::Launched { pid: 4242 }))
            .unwrap();
        assert_eq!(evidence.launched, Some(4242));
        assert!(evidence.command.is_none());
        assert_eq!(evidence.observed_bytes, 0);
        assert!(evidence
            .event(frame(2, Event::Launched { pid: 4242 }))
            .is_err());
        let mut retired = Evidence::new(&query);
        retired.event(frame(0, Event::Ready)).unwrap();
        retired.retire();
        assert!(retired
            .event(frame(1, Event::Launched { pid: 4242 }))
            .is_err());
        assert!(retired.launched.is_none());
    }
    #[test]
    fn buffered_exit_evidence_cannot_be_replaced_by_file_ack_or_worker_collection() {
        let mut query = request(Kind::Buffered {
            metadata: Blob {
                path: "/private/meta".into(),
                device: 1,
                inode: 2,
                bytes: 16,
            },
        });
        query.max_bytes = 5;
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        assert!(evidence
            .event(frame(1, Event::Acknowledged { bytes: 0 }))
            .is_err());
        assert!(evidence.command.is_none());
        assert!(evidence
            .event(frame(
                1,
                Event::CommandCompleted {
                    exit_code: 0,
                    stdout: 6,
                    stderr: 0,
                    limited: false
                }
            ))
            .is_err());
        evidence
            .event(frame(
                1,
                Event::CommandCompleted {
                    exit_code: 7,
                    stdout: 3,
                    stderr: 2,
                    limited: true,
                },
            ))
            .unwrap();
        assert_eq!(evidence.command.unwrap().exit_code, 7);
        assert!(evidence.limited);
        assert!(evidence
            .event(frame(
                2,
                Event::CommandCompleted {
                    exit_code: 0,
                    stdout: 0,
                    stderr: 0,
                    limited: false
                }
            ))
            .is_err());
        let mut retired = Evidence::new(&query);
        retired.event(frame(0, Event::Ready)).unwrap();
        retired.retire();
        assert!(retired
            .event(frame(
                1,
                Event::CommandCompleted {
                    exit_code: 0,
                    stdout: 0,
                    stderr: 0,
                    limited: false
                }
            ))
            .is_err());
        assert!(retired.command.is_none());
    }
    fn request(kind: Kind) -> Request {
        Request {
            schema: 1,
            operation: "a".repeat(32),
            owner: OwnerIdentity::capture().unwrap(),
            socket: "/private/agent.sock".into(),
            staging: "/private/owned-spool".into(),
            staging_device: 1,
            staging_inode: 1,
            guest_path: "/workspace/data".into(),
            max_bytes: MAX_TRANSFER,
            kind,
        }
    }
    fn frame(sequence: u32, event: Event) -> Frame {
        Frame {
            operation: "a".repeat(32),
            sequence,
            event,
        }
    }

    #[test]
    fn bootstrap_ack_is_distinct_and_requires_matching_full_launch_proof() {
        let plan = crate::bootstrap::tests::plan(false);
        let expected = plan.expected().unwrap();
        let image = crate::ImageObservation {
            reference: expected.source.reference.clone(),
            digest: format!("sha256:{}", "b".repeat(64)),
            size: 1,
            architecture: expected.source.platform.trim_start_matches("linux/").into(),
            os: "linux".into(),
            layer_count: 0,
        };
        let proof = crate::bootstrap::Proof {
            image,
            metadata_sha256: expected.metadata_sha256.clone(),
            container_id: Some("smolvm-fixture".into()),
        };
        let mut query = request(Kind::Bootstrap {
            metadata: Blob {
                path: "/private/metadata".into(),
                device: 1,
                inode: 1,
                bytes: 100,
            },
            expected,
        });
        query.max_bytes = 1;
        query.validate().unwrap();
        for event in [
            Event::Acknowledged { bytes: 0 },
            Event::ImagePulled {
                image: proof.image.clone(),
            },
            Event::Bootstrapped {
                proof: crate::bootstrap::Proof {
                    container_id: None,
                    ..proof.clone()
                },
            },
        ] {
            let mut evidence = Evidence::new(&query);
            evidence.event(frame(0, Event::Ready)).unwrap();
            assert!(evidence.event(frame(1, event)).is_err());
            assert!(evidence.bootstrapped.is_none());
        }
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        evidence
            .event(frame(
                1,
                Event::Bootstrapped {
                    proof: proof.clone(),
                },
            ))
            .unwrap();
        assert!(evidence.acknowledged);
        assert_eq!(evidence.bootstrapped, Some(proof));
    }

    #[test]
    fn pull_evidence_requires_exact_reference_platform_configuration_digest_and_distinct_completion(
    ) {
        let expected = crate::ImagePullRequest {
            reference: format!("registry.example/app@sha256:{}", "a".repeat(64)),
            platform: "linux/arm64".into(),
        };
        let image = crate::ImageObservation {
            reference: expected.reference.clone(),
            digest: format!("sha256:{}", "b".repeat(64)),
            size: 1,
            architecture: "arm64".into(),
            os: "linux".into(),
            layer_count: 2,
        };
        let mut query = request(Kind::Pull {
            metadata: Blob {
                path: "/private/meta".into(),
                device: 1,
                inode: 1,
                bytes: 100,
            },
            expected,
        });
        query.max_bytes = 1;
        query.validate().unwrap();
        for event in [
            Event::Acknowledged { bytes: 0 },
            Event::ImagesListed { bytes: 1 },
            Event::ImagePulled {
                image: crate::ImageObservation {
                    digest: "packed".into(),
                    ..image.clone()
                },
            },
            Event::ImagePulled {
                image: crate::ImageObservation {
                    reference: "different".into(),
                    ..image.clone()
                },
            },
            Event::ImagePulled {
                image: crate::ImageObservation {
                    architecture: "amd64".into(),
                    ..image.clone()
                },
            },
        ] {
            let mut evidence = Evidence::new(&query);
            evidence.event(frame(0, Event::Ready)).unwrap();
            assert!(evidence.event(frame(1, event)).is_err());
            assert!(evidence.pulled.is_none());
        }
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        evidence
            .event(frame(
                1,
                Event::ImagePulled {
                    image: image.clone(),
                },
            ))
            .unwrap();
        assert!(evidence.acknowledged);
        assert_eq!(evidence.pulled, Some(image.clone()));
        assert!(evidence
            .event(frame(2, Event::ImagePulled { image }))
            .is_err());
    }

    #[test]
    fn image_inventory_requires_distinct_correlated_collected_evidence() {
        let mut query = request(Kind::Images { deadline_ns: 1 });
        query.max_bytes = crate::images::IMAGE_OUTPUT_BYTES;
        query.validate().unwrap();
        for event in [
            Event::Acknowledged { bytes: 2 },
            Event::Progress { bytes: 2 },
            Event::Launched { pid: 42 },
            Event::ImagesListed { bytes: 0 },
        ] {
            let mut evidence = Evidence::new(&query);
            evidence.event(frame(0, Event::Ready)).unwrap();
            assert!(evidence.event(frame(1, event)).is_err());
        }
        let mut evidence = Evidence::new(&query);
        evidence.event(frame(0, Event::Ready)).unwrap();
        evidence
            .event(frame(1, Event::ImagesListed { bytes: 2 }))
            .unwrap();
        assert!(evidence.acknowledged);
        assert_eq!(evidence.observed_bytes, 2);
        assert!(evidence
            .event(frame(2, Event::ImagesListed { bytes: 2 }))
            .is_err());
        let mut crossed = Evidence::new(&request(Kind::Read));
        crossed.event(frame(0, Event::Ready)).unwrap();
        assert!(crossed
            .event(frame(1, Event::ImagesListed { bytes: 2 }))
            .is_err());
        query.max_bytes = 1;
        assert!(query.validate().is_err());
    }

    #[test]
    fn fragmented_frames_are_correlated_and_exact_write_ack_is_required() {
        let request = request(Kind::Write {
            total: CHUNK,
            mode: None,
        });
        let mut evidence = Evidence::new(&request);
        let stream = [
            frame(0, Event::Ready),
            frame(1, Event::Progress { bytes: CHUNK }),
            frame(2, Event::Acknowledged { bytes: CHUNK }),
        ]
        .iter()
        .flat_map(|frame| encode(frame).unwrap())
        .collect::<Vec<_>>();
        for fragment in [1, 3, 13, stream.len()] {
            let mut decoder = Decoder::default();
            let mut checked = Evidence::new(&request);
            for bytes in stream.chunks(fragment) {
                for event in decoder.feed(bytes).unwrap() {
                    checked.event(event).unwrap();
                }
            }
            assert!(decoder.complete());
            assert!(checked.acknowledged);
            assert_eq!(checked.observed_bytes, CHUNK);
        }
        evidence.event(frame(0, Event::Ready)).unwrap();
        assert!(evidence
            .event(frame(1, Event::Acknowledged { bytes: CHUNK - 1 }))
            .is_err());
        assert!(!evidence.acknowledged);
    }

    #[test]
    fn unbounded_lengths_truncated_data_and_unknown_fields_are_rejected() {
        for size in [0, MAX_FRAME as u32 + 1, u32::MAX] {
            assert!(Decoder::default().feed(&size.to_be_bytes()).is_err());
            assert!(read_request(&mut std::io::Cursor::new(size.to_be_bytes())).is_err());
        }
        let bytes = encode(&request(Kind::Read)).unwrap();
        assert!(read_request(&mut std::io::Cursor::new(&bytes[..bytes.len() - 1])).is_err());
        let mut value = serde_json::to_value(request(Kind::Read)).unwrap();
        value["receipt"] = "forbidden authority".into();
        assert!(read_request(&mut std::io::Cursor::new(encode(&value).unwrap())).is_err());
        let mut decoder = Decoder::default();
        let bytes = encode(&frame(0, Event::Ready)).unwrap();
        decoder.feed(&bytes[..bytes.len() - 1]).unwrap();
        assert!(!decoder.complete());
    }

    #[test]
    fn stale_sibling_duplicate_and_post_terminal_events_do_not_prove_ack() {
        for invalid in [
            Frame {
                operation: "b".repeat(32),
                ..frame(0, Event::Ready)
            },
            frame(1, Event::Ready),
            frame(0, Event::Acknowledged { bytes: 0 }),
        ] {
            let mut evidence = Evidence::new(&request(Kind::Read));
            assert!(evidence.event(invalid).is_err());
            assert!(!evidence.acknowledged);
        }
        let mut evidence = Evidence::new(&request(Kind::Read));
        evidence.event(frame(0, Event::Ready)).unwrap();
        evidence
            .event(frame(1, Event::Failed { bytes: 0 }))
            .unwrap();
        assert!(evidence
            .event(frame(2, Event::Acknowledged { bytes: 0 }))
            .is_err());
        assert!(!evidence.acknowledged);
    }

    #[test]
    fn retirement_rejects_late_ack_but_preserves_previously_received_ack() {
        let mut late = Evidence::new(&request(Kind::Read));
        late.event(frame(0, Event::Ready)).unwrap();
        late.retire();
        assert!(late
            .event(frame(1, Event::Acknowledged { bytes: 1 }))
            .is_err());
        assert!(!late.acknowledged);
        let mut completed = Evidence::new(&request(Kind::Read));
        completed.event(frame(0, Event::Ready)).unwrap();
        completed
            .event(frame(1, Event::Acknowledged { bytes: 1 }))
            .unwrap();
        completed.retire();
        assert!(completed.acknowledged);
    }

    #[test]
    fn staging_identity_size_and_permissions_are_checked_before_agent_access() {
        use std::os::unix::fs::PermissionsExt;
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let file = tempfile::NamedTempFile::new_in(&root).unwrap();
        let metadata = file.as_file().metadata().unwrap();
        let mut request = request(Kind::Read);
        request.staging = file.path().into();
        request.staging_device = metadata.dev();
        request.staging_inode = metadata.ino();
        request.staging_file().unwrap();
        request.staging_inode += 1;
        assert!(request.staging_file().is_err());
        request.staging_inode -= 1;
        request.kind = Kind::Write {
            total: 1,
            mode: None,
        };
        file.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .unwrap();
        assert!(request.staging_file().is_err()); // a short upload is never handed to SDK
    }
}
