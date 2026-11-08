//! Private terminal-worker IPC. This codec grants no SDK ownership, guest
//! termination or child collection authority; it is not the public Port wire.
use crate::{
    Error, ErrorCode, Result, TerminalFailure, TerminalIdentity, TerminalOptions,
    TERMINAL_CHUNK_BYTES,
};
use serde::{Deserialize, Serialize};
use std::io::Read;

const FIXED: usize = 73;
pub const MAX_FRAME: usize = FIXED + 1 + TERMINAL_CHUNK_BYTES as usize;
pub const MAX_STARTUP: usize = 16 * 1024;

#[derive(Clone, PartialEq, Eq)]
pub struct Identity {
    pub epoch: String,
    pub operation: String,
}
impl Identity {
    pub fn validate(&self) -> Result<()> {
        TerminalIdentity::new(self.epoch.clone(), self.operation.clone()).map(|_| ())
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Controller,
    Worker,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Proof {
    pub observed_exit: Option<i32>,
    pub failure: Option<TerminalFailure>,
    pub output_bytes: u64,
}
impl Proof {
    fn validate(&self) -> Result<()> {
        if self.failure.is_none()
            && !matches!(self.observed_exit, Some(0..=123 | 125..=129 | 131..=255))
        {
            return Err(invalid());
        }
        Ok(())
    }
}

pub enum Payload {
    Input(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Close,
    Attach,
    Credit { sequence: u64, bytes: u64 },
    Cancel,
    Ready,
    Output { stderr: bool, bytes: Vec<u8> },
    End(Proof),
}
impl Payload {
    fn direction(&self) -> Direction {
        match self {
            Self::Ready | Self::Output { .. } | Self::End(_) => Direction::Worker,
            _ => Direction::Controller,
        }
    }
}
pub struct Frame {
    pub identity: Identity,
    pub sequence: u64,
    pub payload: Payload,
}

pub fn encode(frame: &Frame) -> Result<Vec<u8>> {
    frame.identity.validate()?;
    let mut body = Vec::with_capacity(FIXED);
    body.extend_from_slice(frame.identity.epoch.as_bytes());
    body.extend_from_slice(frame.identity.operation.as_bytes());
    body.extend_from_slice(&frame.sequence.to_be_bytes());
    match &frame.payload {
        Payload::Input(bytes)
            if !bytes.is_empty() && bytes.len() <= TERMINAL_CHUNK_BYTES as usize =>
        {
            body.push(1);
            body.extend_from_slice(bytes);
        }
        Payload::Resize { cols, rows } if *cols > 0 && *rows > 0 => {
            body.push(2);
            body.extend_from_slice(&cols.to_be_bytes());
            body.extend_from_slice(&rows.to_be_bytes());
        }
        Payload::Close => body.push(3),
        Payload::Attach => body.push(4),
        Payload::Credit { sequence, bytes } if *bytes > 0 && *bytes <= TERMINAL_CHUNK_BYTES => {
            body.push(5);
            body.extend_from_slice(&sequence.to_be_bytes());
            body.extend_from_slice(&bytes.to_be_bytes());
        }
        Payload::Cancel => body.push(6),
        Payload::Ready => body.push(16),
        Payload::Output { stderr, bytes }
            if !bytes.is_empty() && bytes.len() <= TERMINAL_CHUNK_BYTES as usize =>
        {
            body.push(17);
            body.push(u8::from(*stderr));
            body.extend_from_slice(bytes);
        }
        Payload::End(proof) => {
            proof.validate()?;
            body.push(18);
            body.extend_from_slice(&serde_json::to_vec(proof).map_err(|_| invalid())?);
        }
        _ => return Err(invalid()),
    }
    // Output has an extra stream byte compared with input.
    if body.len() > MAX_FRAME {
        return Err(invalid());
    }
    let mut bytes = (body.len() as u32).to_be_bytes().to_vec();
    bytes.extend_from_slice(&body);
    Ok(bytes)
}

fn decode(body: &[u8]) -> Result<Frame> {
    if body.len() < FIXED || body.len() > MAX_FRAME {
        return Err(invalid());
    }
    let identity = Identity {
        epoch: std::str::from_utf8(&body[..32])
            .map_err(|_| invalid())?
            .into(),
        operation: std::str::from_utf8(&body[32..64])
            .map_err(|_| invalid())?
            .into(),
    };
    identity.validate()?;
    let sequence = u64::from_be_bytes(body[64..72].try_into().map_err(|_| invalid())?);
    let data = &body[FIXED..];
    let payload = match body[72] {
        1 if !data.is_empty() && data.len() <= TERMINAL_CHUNK_BYTES as usize => {
            Payload::Input(data.to_vec())
        }
        2 if data.len() == 4 => {
            let cols = u16::from_be_bytes([data[0], data[1]]);
            let rows = u16::from_be_bytes([data[2], data[3]]);
            if cols == 0 || rows == 0 {
                return Err(invalid());
            }
            Payload::Resize { cols, rows }
        }
        3 if data.is_empty() => Payload::Close,
        4 if data.is_empty() => Payload::Attach,
        5 if data.len() == 16 => {
            let sequence = u64::from_be_bytes(data[..8].try_into().map_err(|_| invalid())?);
            let bytes = u64::from_be_bytes(data[8..].try_into().map_err(|_| invalid())?);
            if bytes == 0 || bytes > TERMINAL_CHUNK_BYTES {
                return Err(invalid());
            }
            Payload::Credit { sequence, bytes }
        }
        6 if data.is_empty() => Payload::Cancel,
        16 if data.is_empty() => Payload::Ready,
        17 if data.len() > 1 && data.len() <= TERMINAL_CHUNK_BYTES as usize + 1 && data[0] <= 1 => {
            Payload::Output {
                stderr: data[0] == 1,
                bytes: data[1..].to_vec(),
            }
        }
        18 if data.len() <= 512 => {
            Payload::End(serde_json::from_slice(data).map_err(|_| invalid())?)
        }
        _ => return Err(invalid()),
    };
    Ok(Frame {
        identity,
        sequence,
        payload,
    })
}

/// Header-first incremental decoder. One frame is yielded at a time, so a
/// coalesced read cannot allocate an unbounded event vector or bypass retirement.
pub struct Decoder {
    identity: Identity,
    direction: Direction,
    next: Option<u64>,
    header: [u8; 4],
    count: usize,
    size: usize,
    body: Vec<u8>,
    ended: bool,
    output_bytes: u64,
    proof_received: bool,
}
impl Decoder {
    pub fn new(identity: Identity, direction: Direction) -> Result<Self> {
        identity.validate()?;
        Ok(Self {
            identity,
            direction,
            next: Some(0),
            header: [0; 4],
            count: 0,
            size: 0,
            body: Vec::new(),
            ended: false,
            output_bytes: 0,
            proof_received: false,
        })
    }
    pub fn retire(&mut self) {
        self.ended = true;
        self.proof_received = false;
        self.body.clear();
    }
    pub fn feed(&mut self, mut bytes: &[u8]) -> Result<(usize, Option<Frame>)> {
        let original = bytes.len();
        if self.ended {
            self.retire();
            return Err(invalid());
        }
        if self.count < 4 {
            let take = (4 - self.count).min(bytes.len());
            self.header[self.count..self.count + take].copy_from_slice(&bytes[..take]);
            self.count += take;
            bytes = &bytes[take..];
            if self.count < 4 {
                return Ok((original, None));
            }
            self.size = u32::from_be_bytes(self.header) as usize;
            if self.size < FIXED || self.size > MAX_FRAME {
                self.retire();
                return Err(invalid());
            }
        }
        let take = (self.size - self.body.len()).min(bytes.len());
        self.body.extend_from_slice(&bytes[..take]);
        let consumed = original - bytes.len() + take;
        if self.body.len() < self.size {
            return Ok((consumed, None));
        }
        let frame = match decode(&self.body) {
            Ok(frame) => frame,
            Err(error) => {
                self.retire();
                return Err(error);
            }
        };
        if frame.identity != self.identity
            || Some(frame.sequence) != self.next
            || frame.payload.direction() != self.direction
        {
            self.retire();
            return Err(invalid());
        }
        if self.direction == Direction::Worker {
            if (frame.sequence == 0) != matches!(frame.payload, Payload::Ready) {
                self.retire();
                return Err(invalid());
            }
            match &frame.payload {
                Payload::Output { bytes, .. } => {
                    let Some(total) = self.output_bytes.checked_add(bytes.len() as u64) else {
                        self.retire();
                        return Err(invalid());
                    };
                    self.output_bytes = total;
                }
                Payload::End(proof)
                    if proof.validate().is_err() || proof.output_bytes != self.output_bytes =>
                {
                    self.retire();
                    return Err(invalid());
                }
                _ => {}
            }
        }
        self.next = frame.sequence.checked_add(1);
        self.proof_received = matches!(frame.payload, Payload::End(_));
        self.ended = matches!(frame.payload, Payload::End(_)) || self.next.is_none();
        self.count = 0;
        self.size = 0;
        self.body.clear();
        Ok((consumed, Some(frame)))
    }
    pub fn finish(&self) -> Result<()> {
        if self.count == 0
            && self.body.is_empty()
            && (self.direction == Direction::Controller || self.proof_received)
        {
            Ok(())
        } else {
            Err(invalid())
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Startup {
    pub(crate) schema: u32,
    pub(crate) epoch: String,
    pub(crate) operation: String,
    pub(crate) owner: crate::OwnerIdentity,
    pub(crate) socket: std::path::PathBuf,
    pub(crate) staging: std::path::PathBuf,
    pub(crate) metadata: crate::transfer_worker::Blob,
    pub(crate) options: TerminalOptions,
}
impl Startup {
    pub fn read(reader: &mut impl Read) -> Result<Self> {
        let mut header = [0; 4];
        reader.read_exact(&mut header).map_err(|_| invalid())?;
        let size = u32::from_be_bytes(header) as usize;
        if size == 0 || size > MAX_STARTUP {
            return Err(invalid());
        }
        let mut bytes = vec![0; size];
        reader.read_exact(&mut bytes).map_err(|_| invalid())?;
        let startup: Self = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        startup.options.validate()?;
        Identity {
            epoch: startup.epoch.clone(),
            operation: startup.operation.clone(),
        }
        .validate()?;
        if startup.schema != 1
            || !startup.socket.is_absolute()
            || startup.socket.as_os_str().len() > 4096
            || startup.socket.file_name() != Some("agent.sock".as_ref())
            || startup.owner.pid <= 0
            || startup.owner.birth == 0
            || !startup.staging.is_absolute()
            || startup.staging.as_os_str().len() > 4096
            || startup.metadata.path.parent() != Some(startup.staging.as_path())
            || startup.metadata.bytes == 0
            || startup.metadata.bytes > crate::COMMAND_METADATA_BYTES
            || [&startup.socket, &startup.staging, &startup.metadata.path]
                .iter()
                .any(|path| {
                    path.components().any(|part| {
                        matches!(
                            part,
                            std::path::Component::ParentDir | std::path::Component::CurDir
                        )
                    })
                })
        {
            return Err(invalid());
        }
        Ok(startup)
    }
}
fn invalid() -> Error {
    Error::before(ErrorCode::Validation)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn identity() -> Identity {
        Identity {
            epoch: "ab".repeat(16),
            operation: "cd".repeat(16),
        }
    }
    fn frame(sequence: u64, payload: Payload) -> Frame {
        Frame {
            identity: identity(),
            sequence,
            payload,
        }
    }
    fn send(decoder: &mut Decoder, frame: Frame) -> Frame {
        let bytes = encode(&frame).unwrap();
        let (count, decoded) = decoder.feed(&bytes).unwrap();
        assert_eq!(count, bytes.len());
        decoded.unwrap()
    }
    #[test]
    fn binary_output_survives_every_fragment_boundary_and_requires_ready_and_exact_end() {
        let mut decoder = Decoder::new(identity(), Direction::Worker).unwrap();
        send(&mut decoder, frame(0, Payload::Ready));
        let raw = vec![0, 255, 128, 10, 13];
        let bytes = encode(&frame(
            1,
            Payload::Output {
                stderr: true,
                bytes: raw.clone(),
            },
        ))
        .unwrap();
        let mut output = None;
        for byte in &bytes {
            let (consumed, event) = decoder.feed(&[*byte]).unwrap();
            assert_eq!(consumed, 1);
            if event.is_some() {
                assert!(output.is_none());
                output = event;
            }
        }
        assert!(
            matches!(output.unwrap().payload, Payload::Output { stderr: true, bytes } if bytes == raw)
        );
        send(
            &mut decoder,
            frame(
                2,
                Payload::End(Proof {
                    observed_exit: Some(7),
                    failure: None,
                    output_bytes: 5,
                }),
            ),
        );
        decoder.finish().unwrap();
        assert!(decoder
            .feed(
                &encode(&frame(
                    3,
                    Payload::Output {
                        stderr: false,
                        bytes: vec![1]
                    }
                ))
                .unwrap()
            )
            .is_err());
        assert!(decoder.finish().is_err());
    }
    #[test]
    fn coalesced_reads_yield_one_frame_at_a_time_and_never_swallow_a_retired_suffix() {
        let mut decoder = Decoder::new(identity(), Direction::Controller).unwrap();
        let first = encode(&frame(0, Payload::Attach)).unwrap();
        let second = encode(&frame(1, Payload::Input(vec![0, 255]))).unwrap();
        let combined = [first.clone(), second.clone()].concat();
        let (n, event) = decoder.feed(&combined).unwrap();
        assert_eq!(n, first.len());
        assert!(matches!(event.unwrap().payload, Payload::Attach));
        let (n, event) = decoder.feed(&combined[n..]).unwrap();
        assert_eq!(n, second.len());
        assert!(matches!(event.unwrap().payload, Payload::Input(bytes) if bytes == [0, 255]));
        decoder.retire();
        assert!(decoder.feed(&first).is_err());
    }
    #[test]
    fn direction_epoch_operation_duplicates_and_output_before_ready_reject() {
        for mode in 0..5 {
            let mut decoder = Decoder::new(identity(), Direction::Worker).unwrap();
            let mut request = frame(0, Payload::Ready);
            match mode {
                0 => request.identity.epoch = "ef".repeat(16),
                1 => request.identity.operation = "ef".repeat(16),
                2 => request.payload = Payload::Cancel,
                3 => {
                    request.payload = Payload::Output {
                        stderr: false,
                        bytes: vec![1],
                    }
                }
                _ => {
                    send(&mut decoder, frame(0, Payload::Ready));
                }
            }
            assert!(decoder.feed(&encode(&request).unwrap()).is_err());
            assert!(decoder
                .feed(&encode(&frame(0, Payload::Ready)).unwrap())
                .is_err());
        }
    }
    #[test]
    fn oversized_headers_truncated_frames_trailing_controls_and_unknown_kinds_reject() {
        let mut decoder = Decoder::new(identity(), Direction::Controller).unwrap();
        assert!(decoder
            .feed(&((MAX_FRAME + 1) as u32).to_be_bytes())
            .is_err());
        assert_eq!(decoder.body.capacity(), 0);
        let mut decoder = Decoder::new(identity(), Direction::Controller).unwrap();
        let bytes = encode(&frame(0, Payload::Input(vec![1, 2]))).unwrap();
        assert!(decoder.feed(&bytes[..bytes.len() - 1]).unwrap().1.is_none());
        assert!(decoder.finish().is_err());
        for kind in [3, 16, 255] {
            let mut broken = bytes.clone();
            broken[4 + 72] = kind;
            assert!(Decoder::new(identity(), Direction::Controller)
                .unwrap()
                .feed(&broken)
                .is_err());
        }
    }
    #[test]
    fn proof_totals_and_ambiguous_or_missing_exit_cannot_confirm_completion() {
        let mut absent = Decoder::new(identity(), Direction::Worker).unwrap();
        assert!(absent.finish().is_err());
        send(&mut absent, frame(0, Payload::Ready));
        assert!(absent.finish().is_err());
        absent.retire();
        assert!(absent.finish().is_err());
        for (exit, failure) in [
            (None, None),
            (Some(124), None),
            (Some(130), None),
            (Some(-1), None),
        ] {
            assert!(encode(&frame(
                0,
                Payload::End(Proof {
                    observed_exit: exit,
                    failure,
                    output_bytes: 0
                })
            ))
            .is_err());
        }
        let mut decoder = Decoder::new(identity(), Direction::Worker).unwrap();
        send(&mut decoder, frame(0, Payload::Ready));
        send(
            &mut decoder,
            frame(
                1,
                Payload::Output {
                    stderr: false,
                    bytes: vec![1, 2],
                },
            ),
        );
        assert!(decoder
            .feed(
                &encode(&frame(
                    2,
                    Payload::End(Proof {
                        observed_exit: Some(7),
                        failure: None,
                        output_bytes: 1
                    })
                ))
                .unwrap()
            )
            .is_err());
        let mut decoder = Decoder::new(identity(), Direction::Worker).unwrap();
        send(&mut decoder, frame(0, Payload::Ready));
        send(
            &mut decoder,
            frame(
                1,
                Payload::End(Proof {
                    observed_exit: Some(130),
                    failure: Some(TerminalFailure::ConsumerLost),
                    output_bytes: 0,
                }),
            ),
        );
    }
    #[test]
    fn maximum_raw_controls_resize_credit_and_zero_length_control_shapes_are_exact() {
        let mut decoder = Decoder::new(identity(), Direction::Controller).unwrap();
        let bytes = vec![255; TERMINAL_CHUNK_BYTES as usize];
        assert!(
            matches!(send(&mut decoder, frame(0, Payload::Input(bytes.clone()))).payload, Payload::Input(got) if got == bytes)
        );
        send(
            &mut decoder,
            frame(
                1,
                Payload::Resize {
                    cols: u16::MAX,
                    rows: 1,
                },
            ),
        );
        send(
            &mut decoder,
            frame(
                2,
                Payload::Credit {
                    sequence: 1,
                    bytes: TERMINAL_CHUNK_BYTES,
                },
            ),
        );
        send(&mut decoder, frame(3, Payload::Close));
        send(&mut decoder, frame(4, Payload::Cancel));
        assert!(encode(&frame(0, Payload::Input(vec![]))).is_err());
        assert!(encode(&frame(
            0,
            Payload::Credit {
                sequence: 1,
                bytes: 0
            }
        ))
        .is_err());
        assert!(encode(&frame(0, Payload::Resize { cols: 0, rows: 1 })).is_err());
    }
    #[test]
    fn startup_is_header_bounded_and_strict_before_any_private_file_is_read() {
        let mut oversized = std::io::Cursor::new(((MAX_STARTUP + 1) as u32).to_be_bytes());
        assert!(Startup::read(&mut oversized).is_err());
        assert_eq!(oversized.position(), 4);
        let value = serde_json::json!({
            "schema": 1, "epoch": identity().epoch, "operation": identity().operation,
            "owner": {"pid": 1, "uid": 0, "birth": 1}, "socket": "/owned/agent.sock", "staging": "/owned/job",
            "metadata": {"path": "/owned/job/metadata", "device": 1, "inode": 2, "bytes": 100},
            "options": {"program": "/bin/sh", "cols": 80, "rows": 24, "session": {"secs": 30, "nanos": 0},
                "idle": {"secs": 30, "nanos": 0}, "attach": {"secs": 5, "nanos": 0}, "close": {"secs": 1, "nanos": 0},
                "max_buffer_bytes": 1024, "max_input_bytes": 65536, "total_input_bytes": 1048576}
        });
        for mode in 0..6 {
            let mut value = value.clone();
            match mode {
                1 => value["extra"] = serde_json::json!(true),
                2 => value["metadata"]["path"] = serde_json::json!("/foreign/metadata"),
                3 => value["options"]["extra"] = serde_json::json!(true),
                4 => value["socket"] = serde_json::json!("/owned/../agent.sock"),
                5 => value["options"]["idle"]["extra"] = serde_json::json!(true),
                _ => {}
            }
            let data = serde_json::to_vec(&value).unwrap();
            let bytes = [(data.len() as u32).to_be_bytes().to_vec(), data].concat();
            assert_eq!(Startup::read(&mut bytes.as_slice()).is_ok(), mode == 0);
        }
    }
}
