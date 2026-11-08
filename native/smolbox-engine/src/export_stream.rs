//! Bounded I/O for an isolated conversion worker. No SDK manager, machine
//! ownership, launch, source receipt or publication is constructed here.
use crate::{Error, ErrorCode, ReadBudget, Result};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use sha2::{Digest, Sha256};
use smolvm_protocol::{AgentRequest, AgentResponse};
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, Write};
use std::os::unix::{fs::MetadataExt, net::UnixStream};
use std::path::Path;
use std::time::Duration;

const BLOCK: usize = 64 * 1024;
const PREFIX: &[u8] = b"{\"status\":\"data_chunk\",\"data\":\"";
const SUFFIX: &[u8] = b",\"done\":";
const FRAME: usize = smolvm_protocol::LAYER_CHUNK_SIZE.div_ceil(3) * 4 + 128;
const CONTROL: usize = 64 * 1024;

/// Guest stream evidence, never worker collection, source/VM custody, tar
/// correctness or artifact/publication authority. Partial files are not results.
#[derive(Debug)]
pub struct ContainerLayerIo {
    pub bytes: u64,
    pub sha256: String,
}
fn unknown(code: ErrorCode) -> Error {
    Error::uncertain(code)
}
fn invalid() -> std::io::Error {
    std::io::Error::from(std::io::ErrorKind::InvalidData)
}
pub(crate) struct Timed<'a> {
    socket: UnixStream,
    budget: &'a ReadBudget,
}
impl Timed<'_> {
    pub(crate) fn send(&mut self, request: &AgentRequest) -> Result<()> {
        let bytes = smolvm_protocol::encode_message(request)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        if bytes.len() > crate::AGENT_REQUEST_BYTES {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        self.socket
            .set_write_timeout(Some(Duration::from_millis(10)))
            .map_err(|_| unknown(ErrorCode::Native))?;
        let mut pending = bytes.as_slice();
        while !pending.is_empty() {
            self.budget.check().map_err(|e| unknown(e.code))?;
            match self.socket.write(pending) {
                Ok(0) => return Err(unknown(ErrorCode::Native)),
                Ok(count) => pending = &pending[count..],
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::Interrupted
                            | std::io::ErrorKind::WouldBlock
                            | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(_) => return Err(unknown(ErrorCode::Native)),
            }
        }
        Ok(())
    }
}
pub(crate) fn connect_request<'a>(
    socket: &Path,
    request: &AgentRequest,
    budget: &'a ReadBudget,
) -> Result<Timed<'a>> {
    budget.check()?;
    let request = smolvm_protocol::encode_message(request)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    if request.len() > crate::AGENT_REQUEST_BYTES {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    let mut socket = UnixStream::connect(socket).map_err(|_| Error::before(ErrorCode::Native))?;
    socket
        .set_write_timeout(Some(
            budget
                .deadline
                .saturating_duration_since(std::time::Instant::now())
                .max(Duration::from_nanos(1)),
        ))
        .map_err(|_| Error::before(ErrorCode::Native))?;
    socket
        .set_read_timeout(Some(Duration::from_millis(10)))
        .map_err(|_| Error::before(ErrorCode::Native))?;
    budget.check()?;
    socket
        .write_all(&request)
        .map_err(|_| unknown(ErrorCode::Native))?;
    Ok(Timed { socket, budget })
}
impl Read for Timed<'_> {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        loop {
            self.budget
                .check()
                .map_err(|_| std::io::Error::from(std::io::ErrorKind::TimedOut))?;
            match self.socket.read(bytes) {
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::Interrupted
                            | std::io::ErrorKind::WouldBlock
                            | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue
                }
                result => return result,
            }
        }
    }
}
struct Sink<'a> {
    output: &'a mut dyn Write,
    bytes: u64,
    maximum: u64,
    hash: Sha256,
    budget: &'a ReadBudget,
}
impl Sink<'_> {
    fn write(&mut self, data: &[u8]) -> Result<()> {
        self.budget.check().map_err(|e| unknown(e.code))?;
        let next = self
            .bytes
            .checked_add(data.len() as u64)
            .filter(|n| *n <= self.maximum)
            .ok_or(unknown(ErrorCode::OutputLimit))?;
        self.output
            .write_all(data)
            .map_err(|_| unknown(ErrorCode::Io))?;
        self.hash.update(data);
        self.bytes = next;
        self.budget.check().map_err(|e| unknown(e.code))
    }
}
fn literal(reader: &mut impl Read, wanted: &[u8]) -> std::io::Result<()> {
    let mut bytes = vec![0; wanted.len()];
    reader.read_exact(&mut bytes)?;
    if bytes != wanted {
        return Err(invalid());
    }
    Ok(())
}
/// Parse the pinned SDK encoder's canonical DataChunk envelope incrementally.
/// An invalid suffix can leave private partial bytes, never a success result.
fn frame(reader: &mut impl Read, length: usize, sink: &mut Sink<'_>) -> Result<bool> {
    let mut body = reader.take(length as u64);
    let mut prefix = vec![0; PREFIX.len().min(length)];
    body.read_exact(&mut prefix)
        .map_err(|_| unknown(ErrorCode::Native))?;
    if prefix != PREFIX {
        if length > CONTROL {
            return Err(unknown(ErrorCode::OutputLimit));
        }
        body.read_to_end(&mut prefix)
            .map_err(|_| unknown(ErrorCode::Native))?;
        let response: AgentResponse =
            serde_json::from_slice(&prefix).map_err(|_| unknown(ErrorCode::Validation))?;
        return Err(unknown(
            if matches!(response, AgentResponse::Error { .. }) {
                ErrorCode::Native
            } else {
                ErrorCode::Validation
            },
        ));
    }
    let mut encoded = Vec::with_capacity(BLOCK);
    let mut decoded = [0; BLOCK];
    let mut padded = false;
    let mut frame_bytes = 0usize;
    let mut input = BufReader::with_capacity(BLOCK, &mut body);
    loop {
        let available = input.fill_buf().map_err(|_| unknown(ErrorCode::Native))?;
        if available.is_empty() {
            return Err(unknown(ErrorCode::Validation));
        }
        let end = available
            .iter()
            .position(|b| *b == b'"')
            .unwrap_or(available.len());
        let take = end.min(BLOCK - encoded.len());
        if available[..take]
            .iter()
            .any(|b| !b.is_ascii_alphanumeric() && !b"+/=".contains(b))
        {
            return Err(unknown(ErrorCode::Validation));
        }
        if padded && take > 0 {
            return Err(unknown(ErrorCode::Validation));
        }
        encoded.extend_from_slice(&available[..take]);
        let quote = take == end && end < available.len();
        input.consume(take + usize::from(quote));
        if encoded.len() == BLOCK || quote {
            if !encoded.len().is_multiple_of(4) {
                return Err(unknown(ErrorCode::Validation));
            }
            padded = encoded.contains(&b'=');
            let count = STANDARD
                .decode_slice(&encoded, &mut decoded)
                .map_err(|_| unknown(ErrorCode::Validation))?;
            frame_bytes = frame_bytes
                .checked_add(count)
                .filter(|n| *n <= smolvm_protocol::LAYER_CHUNK_SIZE)
                .ok_or(unknown(ErrorCode::OutputLimit))?;
            sink.write(&decoded[..count])?;
            encoded.clear();
        }
        if quote {
            break;
        }
    }
    literal(&mut input, SUFFIX).map_err(|_| unknown(ErrorCode::Validation))?;
    let mut tail = Vec::new();
    input
        .take(7)
        .read_to_end(&mut tail)
        .map_err(|_| unknown(ErrorCode::Native))?;
    let done = match tail.as_slice() {
        b"true}" => true,
        b"false}" => false,
        _ => return Err(unknown(ErrorCode::Validation)),
    };
    if body.limit() != 0 || (frame_bytes == 0 && !done) {
        return Err(unknown(ErrorCode::Validation));
    }
    Ok(done)
}
pub(crate) fn validate(request: &AgentRequest, maximum: u64) -> Result<()> {
    let AgentRequest::FlattenLayers {
        lowerdirs,
        output: None,
    } = request
    else {
        return Err(Error::before(ErrorCode::Validation));
    };
    let valid = lowerdirs
        .first()
        .and_then(|p| p.strip_prefix("/mnt/source-storage/overlays/persistent-"))
        .and_then(|p| p.strip_suffix("/upper"))
        .is_some_and(crate::domain::valid_id);
    if !valid
        || lowerdirs.len() > 65537
        || maximum == 0
        || maximum > crate::JOB_EXPORT_STAGING_BYTES
        || lowerdirs.iter().skip(1).any(|p| {
            p.strip_prefix("/storage/layers/")
                .or_else(|| p.strip_prefix("/storage/imported/layers/"))
                .is_none_or(|s| !crate::domain::valid_hex(s, 64))
        })
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(())
}
/// Run only inside an isolated owned worker with an authenticated helper socket
/// and empty private regular-file spool. The parent retains source/admission and
/// must independently collect this worker and verify/register output custody.
/// Uses the original absolute deadline/cancellation; never stages a guest tar.
pub(crate) fn validate_output(output: &mut File) -> Result<()> {
    let metadata = output
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_file()
        || metadata.len() != 0
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
        || output
            .stream_position()
            .map_err(|_| Error::before(ErrorCode::Io))?
            != 0
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
pub fn stream_container_layer(
    socket: &Path,
    request: &AgentRequest,
    output: &mut File,
    maximum: u64,
    budget: &ReadBudget,
) -> Result<ContainerLayerIo> {
    budget.check()?;
    validate(request, maximum)?;
    validate_output(output)?;
    let result = stream_data(socket, request, output, maximum, budget)?;
    output.sync_all().map_err(|_| unknown(ErrorCode::Io))?;
    budget.check().map_err(|e| unknown(e.code))?;
    Ok(result)
}

pub(crate) fn read_oci_metadata(
    socket: &Path,
    path: String,
    maximum: u64,
    budget: &ReadBudget,
) -> Result<Vec<u8>> {
    if maximum == 0 || maximum > crate::OCI_METADATA_BYTES as u64 {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    let mut output = Vec::new();
    stream_data(
        socket,
        &AgentRequest::FileRead { path },
        &mut output,
        maximum,
        budget,
    )?;
    Ok(output)
}

fn stream_data(
    socket: &Path,
    request: &AgentRequest,
    output: &mut dyn Write,
    maximum: u64,
    budget: &ReadBudget,
) -> Result<ContainerLayerIo> {
    let mut reader = connect_request(socket, request, budget)?;
    let mut sink = Sink {
        output,
        bytes: 0,
        maximum,
        hash: Sha256::new(),
        budget,
    };
    let frames = maximum.div_ceil(smolvm_protocol::LAYER_CHUNK_SIZE as u64) + 4096;
    for _ in 0..frames {
        budget.check().map_err(|e| unknown(e.code))?;
        let mut header = [0; 4];
        reader
            .read_exact(&mut header)
            .map_err(|_| unknown(ErrorCode::Native))?;
        let length = u32::from_be_bytes(header) as usize;
        if length == 0 || length > FRAME {
            return Err(unknown(ErrorCode::OutputLimit));
        }
        if frame(&mut reader, length, &mut sink)? {
            if sink.bytes == 0 {
                return Err(unknown(ErrorCode::Validation));
            }
            budget.check().map_err(|e| unknown(e.code))?;
            return Ok(ContainerLayerIo {
                bytes: sink.bytes,
                sha256: hex::encode(sink.hash.finalize()),
            });
        }
    }
    Err(unknown(ErrorCode::OutputLimit))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Cancellation;
    use std::os::unix::net::UnixListener;
    fn request() -> AgentRequest {
        AgentRequest::FlattenLayers {
            lowerdirs: vec![
                "/mnt/source-storage/overlays/persistent-source/upper".into(),
                format!("/storage/layers/{}", "a".repeat(64)),
            ],
            output: None,
        }
    }
    fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(10), Cancellation::default()).unwrap()
    }
    fn peer(listener: UnixListener, responses: Vec<Vec<u8>>) -> std::thread::JoinHandle<()> {
        std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let until = std::time::Instant::now() + Duration::from_secs(3);
            let mut socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && std::time::Instant::now() < until =>
                    {
                        std::thread::yield_now()
                    }
                    Err(error) => panic!("loopback accept: {error}"),
                }
            };
            socket.set_nonblocking(false).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            socket
                .set_write_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut header = [0; 4];
            socket.read_exact(&mut header).unwrap();
            let count = u32::from_be_bytes(header) as usize;
            assert!(count <= crate::AGENT_REQUEST_BYTES);
            let mut bytes = vec![0; count];
            socket.read_exact(&mut bytes).unwrap();
            let sent: AgentRequest = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(
                serde_json::to_vec(&sent).unwrap(),
                serde_json::to_vec(&request()).unwrap()
            );
            for response in responses {
                let result = socket.write_all(&response);
                if result.is_err() {
                    break;
                }
            }
        })
    }
    #[test]
    fn sdk_sixteen_mib_chunk_streams_to_private_file_with_exact_terminal_digest() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let payload = vec![0xa5; smolvm_protocol::LAYER_CHUNK_SIZE];
        let mut expected = Sha256::new();
        expected.update(&payload);
        expected.update(b"end");
        let server = peer(
            listener,
            vec![
                smolvm_protocol::encode_message(&AgentResponse::DataChunk {
                    data: payload,
                    done: false,
                })
                .unwrap(),
                smolvm_protocol::encode_message(&AgentResponse::DataChunk {
                    data: b"end".to_vec(),
                    done: true,
                })
                .unwrap(),
            ],
        );
        let mut named_output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
        let output = named_output.as_file_mut();
        let result = stream_container_layer(&socket, &request(), output, 32 << 20, &budget());
        let proof = result.unwrap_or_else(|error| {
            panic!(
                "{error:?}; partial bytes={}",
                output.metadata().unwrap().len()
            )
        });
        server.join().unwrap();
        assert_eq!(proof.bytes, smolvm_protocol::LAYER_CHUNK_SIZE as u64 + 3);
        assert_eq!(proof.sha256, hex::encode(expected.finalize()));
        assert_eq!(output.metadata().unwrap().len(), proof.bytes);
        output.rewind().unwrap();
        let mut first = [0; 16];
        output.read_exact(&mut first).unwrap();
        assert_eq!(first, [0xa5; 16]);
    }
    #[test]
    fn partial_error_oversize_and_invalid_base64_never_return_layer_evidence() {
        for variant in 0..5 {
            let temp = tempfile::tempdir().unwrap();
            let socket = temp.path().join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let good = smolvm_protocol::encode_message(&AgentResponse::DataChunk {
                data: b"partial".to_vec(),
                done: false,
            })
            .unwrap();
            let responses = match variant {
                0 => vec![good], // EOF without terminal frame.
                1 => vec![
                    good,
                    smolvm_protocol::encode_message(&AgentResponse::Error {
                        code: None,
                        message: "guest tar failed".into(),
                    })
                    .unwrap(),
                ],
                2 => vec![smolvm_protocol::encode_message(&AgentResponse::DataChunk {
                    data: vec![1; 100],
                    done: true,
                })
                .unwrap()],
                3 => vec![((FRAME + 1) as u32).to_be_bytes().to_vec()],
                _ => {
                    let bytes = b"{\"status\":\"data_chunk\",\"data\":\"AB==\",\"done\":true}";
                    let mut frame = (bytes.len() as u32).to_be_bytes().to_vec();
                    frame.extend_from_slice(bytes);
                    vec![frame]
                }
            };
            let server = peer(listener, responses);
            let mut named_output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
            let output = named_output.as_file_mut();
            assert!(stream_container_layer(&socket, &request(), output, 99, &budget()).is_err());
            server.join().unwrap();
            assert!(output.metadata().unwrap().len() <= 99);
        }
    }
    #[test]
    fn cancellation_mid_frame_keeps_partial_file_unqualified() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let budget = budget();
        let cancel = budget.cancel.clone();
        let server = std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let until = std::time::Instant::now() + Duration::from_secs(3);
            let mut socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && std::time::Instant::now() < until =>
                    {
                        std::thread::yield_now()
                    }
                    Err(error) => panic!("loopback accept: {error}"),
                }
            };
            socket.set_nonblocking(false).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            socket
                .set_write_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut header = [0; 4];
            socket.read_exact(&mut header).unwrap();
            let mut request = vec![0; u32::from_be_bytes(header) as usize];
            socket.read_exact(&mut request).unwrap();
            socket.write_all(&100_000u32.to_be_bytes()).unwrap();
            socket.write_all(PREFIX).unwrap();
            socket.write_all(b"AAAA").unwrap();
            cancel.cancel();
        });
        let mut named_output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
        let output = named_output.as_file_mut();
        assert!(stream_container_layer(&socket, &request(), output, 100_000, &budget).is_err());
        server.join().unwrap();
        assert!(output.metadata().unwrap().len() < 100_000);
    }
    #[test]
    fn fragmented_sdk_frames_preserve_quartets_and_empty_terminal_status() {
        let budget = budget();
        let mut bytes = Vec::new();
        let mut sink = Sink {
            output: &mut bytes,
            bytes: 0,
            maximum: 128,
            hash: Sha256::new(),
            budget: &budget,
        };
        struct Fragmented(std::io::Cursor<Vec<u8>>);
        impl Read for Fragmented {
            fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
                let count = bytes.len().min(3);
                self.0.read(&mut bytes[..count])
            }
        }
        for (data, done) in [(b"binary\0\xff".to_vec(), false), (Vec::new(), true)] {
            let encoded =
                smolvm_protocol::encode_message(&AgentResponse::DataChunk { data, done }).unwrap();
            let mut reader = Fragmented(std::io::Cursor::new(encoded[4..].to_vec()));
            assert_eq!(
                frame(&mut reader, encoded.len() - 4, &mut sink).unwrap(),
                done
            );
        }
        assert_eq!(sink.bytes, 8);
        assert_eq!(bytes, b"binary\0\xff");
    }
    #[test]
    fn invalid_guest_paths_output_modes_and_existing_spools_reject_before_connection() {
        let temp = tempfile::tempdir().unwrap();
        let mut named_output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
        let output = named_output.as_file_mut();
        for selected in [
            AgentRequest::FlattenLayers {
                lowerdirs: vec!["/etc".into()],
                output: None,
            },
            AgentRequest::FlattenLayers {
                lowerdirs: vec!["/mnt/source-storage/overlays/persistent-../upper".into()],
                output: None,
            },
            AgentRequest::FlattenLayers {
                lowerdirs: vec!["/mnt/source-storage/overlays/persistent-source/upper".into()],
                output: Some("/tmp/tar".into()),
            },
        ] {
            assert_eq!(
                stream_container_layer(Path::new("/absent"), &selected, output, 1024, &budget())
                    .unwrap_err()
                    .dispatch,
                crate::Dispatch::NotDispatched
            );
        }
        output.write_all(b"existing").unwrap();
        assert_eq!(
            stream_container_layer(Path::new("/absent"), &request(), output, 1024, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(output.metadata().unwrap().len(), 8);
    }
}
