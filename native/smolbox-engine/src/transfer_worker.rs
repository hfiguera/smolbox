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

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub(crate) enum Kind {
    Read,
    Write { total: u64, mode: Option<u32> },
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
        let mode = match self.kind {
            Kind::Read => None,
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
        let required_mode = if matches!(self.kind, Kind::Read) {
            0o600
        } else {
            0o400
        };
        if !metadata.is_file()
            || metadata.uid() != self.owner.uid
            || metadata.mode() & 0o777 != required_mode
            || (metadata.dev(), metadata.ino()) != (self.staging_device, self.staging_inode)
            || match self.kind {
                Kind::Read => metadata.len() != 0,
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
    Ready,
    Progress { bytes: u64 },
    Acknowledged { bytes: u64 },
    Failed { bytes: u64 },
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
}

impl Decoder {
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
                if self.size == 0 || self.size > MAX_FRAME || self.events >= MAX_EVENTS {
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
            operation: request.operation.clone(),
            sequence: 0,
            max_bytes: request.max_bytes,
            exact_write: match request.kind {
                Kind::Read => None,
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
            || self.sequence >= MAX_EVENTS
            || self.terminal
            || self.retired
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        match frame.event {
            Event::Ready if !self.ready && self.sequence == 0 => self.ready = true,
            Event::Progress { bytes }
                if self.ready && bytes > self.observed_bytes && bytes <= self.max_bytes =>
            {
                self.observed_bytes = bytes;
            }
            Event::Acknowledged { bytes }
                if self.ready
                    && bytes >= self.observed_bytes
                    && bytes <= self.max_bytes
                    && self.exact_write.is_none_or(|total| total == bytes) =>
            {
                self.observed_bytes = bytes;
                self.acknowledged = true;
                self.terminal = true;
            }
            Event::Failed { bytes }
                if self.ready && bytes >= self.observed_bytes && bytes <= self.max_bytes =>
            {
                self.observed_bytes = bytes;
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
}

impl<W: Write> Writer<'_, W> {
    fn event(&mut self, event: Event) -> Result<()> {
        if self.sequence >= MAX_EVENTS {
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
    };
    writer.event(Event::Ready)?;
    // AgentClient::connect does not start a VM or create SDK domain state.
    let mut observed = 0;
    let result = smolvm::agent::AgentClient::connect(&request.socket).and_then(|mut client| {
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
        }
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
