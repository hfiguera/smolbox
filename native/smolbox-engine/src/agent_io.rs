//! Header-first guards around public SDK AgentClient calls. The relay neither
//! interprets nor constructs guest operations and never creates SDK state.
use crate::{Error, ErrorCode, Result};
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

pub const AGENT_REQUEST_BYTES: usize = 4 * 1024 * 1024;
pub const AGENT_REPLY_OVERHEAD: usize = 64 * 1024;

pub(crate) struct BoundedAgent {
    pub client: smolvm::agent::AgentClient,
    _guard: Relay,
    limited: Arc<AtomicBool>,
}
#[derive(Clone, Copy)]
enum Projection {
    None,
    Images,
    Pull,
    BootstrapLaunch,
}
struct Relay {
    sockets: Arc<[UnixStream; 2]>,
    threads: Vec<JoinHandle<()>>,
    _directory: tempfile::TempDir,
}
impl Drop for Relay {
    fn drop(&mut self) {
        for socket in self.sockets.iter() {
            let _ = socket.shutdown(Shutdown::Both);
        }
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}
impl BoundedAgent {
    pub(crate) fn stopper(&self) -> Stopper {
        Stopper(self._guard.sockets.clone())
    }
    pub(crate) fn limited(&self) -> bool {
        self.limited.load(Ordering::Acquire)
    }
    pub(crate) fn connect(socket: &Path, output_bytes: u64) -> Result<Self> {
        Self::connect_in(socket, output_bytes, Path::new("."))
    }
    pub(crate) fn connect_in(socket: &Path, output_bytes: u64, staging: &Path) -> Result<Self> {
        Self::connect_mode(socket, output_bytes, staging, Projection::None)
    }
    pub(crate) fn connect_images(socket: &Path) -> Result<Self> {
        Self::connect_mode(
            socket,
            crate::images::IMAGE_OUTPUT_BYTES,
            Path::new("."),
            Projection::Images,
        )
    }
    pub(crate) fn connect_pull(socket: &Path) -> Result<Self> {
        Self::connect_mode(socket, 1, Path::new("."), Projection::Pull)
    }
    pub(crate) fn connect_bootstrap_launch(socket: &Path) -> Result<Self> {
        Self::connect_mode(socket, 1, Path::new("."), Projection::BootstrapLaunch)
    }
    fn connect_mode(
        socket: &Path,
        output_bytes: u64,
        staging: &Path,
        projection: Projection,
    ) -> Result<Self> {
        if output_bytes == 0 || output_bytes > 16 * 1024 * 1024 {
            return Err(Error::before(ErrorCode::Validation));
        }
        // The worker's CWD is an exclusively owned private spool directory.
        // Bind relative names so long home/domain paths do not exceed UDS limits.
        let checked = if staging == Path::new(".") {
            std::env::current_dir().map_err(|_| Error::before(ErrorCode::Io))?
        } else {
            staging.to_path_buf()
        };
        crate::host::private_directory(&checked)?;
        let directory = tempfile::Builder::new()
            .prefix("agent-")
            .tempdir_in(staging)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let endpoint = directory.path().join("rpc.sock");
        let listener = UnixListener::bind(&endpoint).map_err(|_| Error::before(ErrorCode::Io))?;
        listener
            .set_nonblocking(true)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let upstream = UnixStream::connect(socket).map_err(|_| Error::before(ErrorCode::Native))?;
        let reply_cap = output_bytes.div_ceil(3) as usize * 4 + AGENT_REPLY_OVERHEAD;
        let relay_limit = Arc::new(AtomicBool::new(false));
        let observed_limit = relay_limit.clone();
        let flag = relay_limit.clone();
        // Accept concurrently with the public SDK socket connection.
        let accept = std::thread::spawn(
            move || -> std::io::Result<([UnixStream; 2], Vec<JoinHandle<()>>)> {
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
                let downstream = loop {
                    match listener.accept() {
                        Ok((stream, _)) => break stream,
                        Err(error)
                            if error.kind() == std::io::ErrorKind::WouldBlock
                                && std::time::Instant::now() < deadline =>
                        {
                            std::thread::sleep(std::time::Duration::from_millis(1))
                        }
                        Err(error) => return Err(error),
                    }
                };
                downstream.set_nonblocking(false)?;
                let request_read = downstream.try_clone()?;
                let request_write = upstream.try_clone()?;
                let response_read = upstream.try_clone()?;
                let response_write = downstream.try_clone()?;
                let first = std::thread::spawn(move || {
                    pump(
                        request_read,
                        request_write,
                        AGENT_REQUEST_BYTES,
                        flag.clone(),
                    )
                });
                let second = std::thread::spawn(move || match projection {
                    Projection::Images => pump_images(response_read, response_write, relay_limit),
                    Projection::Pull => pump_pull(response_read, response_write, relay_limit),
                    Projection::BootstrapLaunch => {
                        pump_bootstrap_launch(response_read, response_write, relay_limit)
                    }
                    Projection::None => pump(response_read, response_write, reply_cap, relay_limit),
                });
                Ok(([downstream, upstream], vec![first, second]))
            },
        );
        let client = smolvm::agent::AgentClient::connect(&endpoint);
        let (sockets, threads) = accept
            .join()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let guard = Relay {
            sockets: Arc::new(sockets),
            threads,
            _directory: directory,
        };
        match client {
            Ok(client) => Ok(Self {
                client,
                _guard: guard,
                limited: observed_limit,
            }),
            Err(_) => {
                drop(guard);
                Err(Error::before(ErrorCode::Native))
            }
        }
    }
}
pub(crate) struct Stopper(Arc<[UnixStream; 2]>);
impl Stopper {
    pub(crate) fn stop(&self) {
        for socket in self.0.iter() {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
}
fn pump(mut input: UnixStream, mut output: UnixStream, maximum: usize, limited: Arc<AtomicBool>) {
    let result = (|| -> std::io::Result<()> {
        loop {
            let mut header = [0; 4];
            input.read_exact(&mut header)?;
            let size = u32::from_be_bytes(header) as usize;
            if size == 0 || size > maximum {
                limited.store(true, Ordering::Release);
                return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
            }
            // Never deliver a rejected header to the SDK allocator.
            output.write_all(&header)?;
            let mut left = size;
            let mut bytes = [0; 64 * 1024];
            while left > 0 {
                let take = left.min(bytes.len());
                input.read_exact(&mut bytes[..take])?;
                output.write_all(&bytes[..take])?;
                left -= take;
            }
        }
    })();
    let _ = result;
    let _ = input.shutdown(Shutdown::Both);
    let _ = output.shutdown(Shutdown::Both);
}

// Single-response ListImages projection. Reject oversized frames before reading
// their body; discard unneeded SDK metadata before its generic JSON allocation.
fn pump_images(mut input: UnixStream, mut output: UnixStream, limited: Arc<AtomicBool>) {
    let result = (|| -> std::io::Result<()> {
        let invalid = || std::io::Error::from(std::io::ErrorKind::InvalidData);
        let mut header = [0; 4];
        input.read_exact(&mut header)?;
        let size = u32::from_be_bytes(header) as usize;
        if size == 0 || size > crate::images::IMAGE_REPLY_BYTES {
            limited.store(true, Ordering::Release);
            return Err(invalid());
        }
        let mut bytes = vec![0; size];
        input.read_exact(&mut bytes)?;
        let images = crate::images::decode_reply(&bytes).map_err(|_| invalid())?;
        drop(bytes);
        let data: Vec<_> = images
            .into_iter()
            .map(|i| smolvm_protocol::ImageInfo {
                reference: i.reference,
                digest: i.digest,
                size: i.size,
                architecture: i.architecture,
                os: i.os,
                layer_count: i.layer_count as usize,
                created: None,
                layers: Vec::new(),
                entrypoint: Vec::new(),
                cmd: Vec::new(),
                env: Vec::new(),
                workdir: None,
                user: None,
            })
            .collect();
        let bytes = serde_json::to_vec(&serde_json::json!({"status":"ok", "data":data}))
            .map_err(|_| invalid())?;
        if bytes.len() as u64 > crate::images::IMAGE_OUTPUT_BYTES {
            return Err(invalid());
        }
        output.write_all(&(bytes.len() as u32).to_be_bytes())?;
        output.write_all(&bytes)?;
        Ok(())
    })();
    let _ = result;
    let _ = input.shutdown(Shutdown::Both);
    let _ = output.shutdown(Shutdown::Both);
}

// Pull progress carries no result/ownership evidence. Bound frames and total IO,
// skip untrusted diagnostics without constructing their nested JSON values, and
// deliver only the final public image projection before SDK allocation.
fn pump_pull(mut input: UnixStream, mut output: UnixStream, limited: Arc<AtomicBool>) {
    let result = (|| -> std::io::Result<()> {
        #[derive(serde::Deserialize)]
        struct Status<'a> {
            status: &'a str,
        }
        let invalid = || std::io::Error::from(std::io::ErrorKind::InvalidData);
        let mut total = 0usize;
        for _ in 0..=crate::image_pull::PROGRESS_FRAMES {
            let mut header = [0; 4];
            input.read_exact(&mut header)?;
            let size = u32::from_be_bytes(header) as usize;
            if size == 0
                || size > crate::images::IMAGE_REPLY_BYTES
                || size > crate::image_pull::REPLY_TOTAL_BYTES.saturating_sub(total)
            {
                limited.store(true, Ordering::Release);
                return Err(invalid());
            }
            total += size;
            let mut bytes = vec![0; size];
            input.read_exact(&mut bytes)?;
            let status: Status<'_> = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
            if status.status == "progress" {
                continue;
            }
            let i = crate::images::decode_pulled(&bytes).map_err(|_| invalid())?;
            drop(bytes);
            let info = smolvm_protocol::ImageInfo {
                reference: i.reference,
                digest: i.digest,
                size: i.size,
                architecture: i.architecture,
                os: i.os,
                layer_count: i.layer_count as usize,
                created: None,
                layers: Vec::new(),
                entrypoint: Vec::new(),
                cmd: Vec::new(),
                env: Vec::new(),
                workdir: None,
                user: None,
            };
            let bytes = serde_json::to_vec(&serde_json::json!({"status":"ok","data":info}))
                .map_err(|_| invalid())?;
            if bytes.len() > crate::transfer_worker::MAX_FRAME {
                return Err(invalid());
            }
            output.write_all(&(bytes.len() as u32).to_be_bytes())?;
            output.write_all(&bytes)?;
            return Ok(());
        }
        limited.store(true, Ordering::Release);
        Err(invalid())
    })();
    let _ = result;
    let _ = input.shutdown(Shutdown::Both);
    let _ = output.shutdown(Shutdown::Both);
}

// Detached startup reports a container acknowledgment, not process Exit.
// Charge original bytes, discard progress/diagnostics before SDK allocation,
// and deliver only a bounded successful Completed envelope once.
fn pump_bootstrap_launch(mut input: UnixStream, mut output: UnixStream, limited: Arc<AtomicBool>) {
    let result = (|| -> std::io::Result<()> {
        #[derive(serde::Deserialize)]
        struct Status<'a> {
            status: &'a str,
        }
        let invalid = || std::io::Error::from(std::io::ErrorKind::InvalidData);
        let mut total = 0;
        for _ in 0..=crate::bootstrap::LAUNCH_FRAMES {
            let mut header = [0; 4];
            input.read_exact(&mut header)?;
            let size = u32::from_be_bytes(header) as usize;
            if size == 0
                || size > 64 * 1024
                || size > crate::bootstrap::LAUNCH_REPLY_BYTES.saturating_sub(total)
            {
                limited.store(true, Ordering::Release);
                return Err(invalid());
            }
            total += size;
            let mut bytes = vec![0; size];
            input.read_exact(&mut bytes)?;
            let status: Status<'_> = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
            if status.status == "progress" {
                continue;
            }
            if status.status != "completed" {
                return Err(invalid());
            }
            let response: smolvm_protocol::AgentResponse =
                serde_json::from_slice(&bytes).map_err(|_| invalid())?;
            let smolvm_protocol::AgentResponse::Completed {
                exit_code: 0,
                stdout,
                stderr,
            } = response
            else {
                return Err(invalid());
            };
            if stdout.len() + stderr.len() > crate::bootstrap::LAUNCH_OUTPUT_BYTES as usize {
                return Err(invalid());
            }
            let response = smolvm_protocol::AgentResponse::Completed {
                exit_code: 0,
                stdout,
                stderr: Vec::new(),
            };
            let bytes = serde_json::to_vec(&response).map_err(|_| invalid())?;
            output.write_all(&(bytes.len() as u32).to_be_bytes())?;
            output.write_all(&bytes)?;
            return Ok(());
        }
        limited.store(true, Ordering::Release);
        Err(invalid())
    })();
    let _ = result;
    let _ = input.shutdown(Shutdown::Both);
    let _ = output.shutdown(Shutdown::Both);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bootstrap_relay_discards_progress_and_stderr_and_bounds_the_original_reply_bytes() {
        for oversized in [false, true] {
            let (mut peer, input) = UnixStream::pair().unwrap();
            let (output, mut consumer) = UnixStream::pair().unwrap();
            consumer
                .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                .unwrap();
            let limited = Arc::new(AtomicBool::new(false));
            let flag = limited.clone();
            let thread = std::thread::spawn(move || pump_bootstrap_launch(input, output, flag));
            if oversized {
                peer.write_all(&65537u32.to_be_bytes()).unwrap();
                assert_eq!(consumer.read(&mut [0]).unwrap(), 0);
                assert!(limited.load(Ordering::Acquire));
            } else {
                let progress = br#"{"status":"progress","message":"PRIVATE=discard"}"#;
                peer.write_all(&(progress.len() as u32).to_be_bytes())
                    .unwrap();
                peer.write_all(progress).unwrap();
                let done = smolvm_protocol::AgentResponse::Completed {
                    exit_code: 0,
                    stdout: b"smolvm-fixture".to_vec(),
                    stderr: b"PRIVATE=discard".to_vec(),
                };
                let bytes = serde_json::to_vec(&done).unwrap();
                peer.write_all(&(bytes.len() as u32).to_be_bytes()).unwrap();
                peer.write_all(&bytes).unwrap();
                let mut header = [0; 4];
                consumer.read_exact(&mut header).unwrap();
                let mut body = vec![0; u32::from_be_bytes(header) as usize];
                consumer.read_exact(&mut body).unwrap();
                let smolvm_protocol::AgentResponse::Completed {
                    exit_code,
                    stdout,
                    stderr,
                } = serde_json::from_slice(&body).unwrap()
                else {
                    panic!()
                };
                assert_eq!(exit_code, 0);
                assert_eq!(stdout, b"smolvm-fixture");
                assert!(stderr.is_empty());
            }
            thread.join().unwrap();
        }
    }

    #[test]
    fn pull_relay_discards_progress_and_unused_metadata_before_publishing_one_final_image() {
        let (mut peer, input) = UnixStream::pair().unwrap();
        let (output, mut consumer) = UnixStream::pair().unwrap();
        consumer
            .set_read_timeout(Some(std::time::Duration::from_secs(2)))
            .unwrap();
        let flag = Arc::new(AtomicBool::new(false));
        let thread = std::thread::spawn(move || pump_pull(input, output, flag));
        for value in [
            serde_json::json!({"status":"progress","message":"PRIVATE=discard",
            "extra":{"nested":[1,2,3]}}),
            serde_json::json!({"status":"ok","data":{
                "reference":"fixture", "digest":format!("sha256:{}", "b".repeat(64)),
                "size":1,"architecture":"arm64","os":"linux","layer_count":2,
                "env":["PRIVATE=discard"],"layers":["unused"]}}),
        ] {
            let bytes = serde_json::to_vec(&value).unwrap();
            peer.write_all(&(bytes.len() as u32).to_be_bytes()).unwrap();
            peer.write_all(&bytes).unwrap();
        }
        let mut header = [0; 4];
        consumer.read_exact(&mut header).unwrap();
        let mut body = vec![0; u32::from_be_bytes(header) as usize];
        consumer.read_exact(&mut body).unwrap();
        assert!(!String::from_utf8_lossy(&body).contains("PRIVATE"));
        let reply: smolvm_protocol::AgentResponse = serde_json::from_slice(&body).unwrap();
        let smolvm_protocol::AgentResponse::Ok { data: Some(data) } = reply else {
            panic!()
        };
        let image: smolvm_protocol::ImageInfo = serde_json::from_value(data).unwrap();
        assert_eq!(image.layer_count, 2);
        assert!(image.env.is_empty() && image.layers.is_empty());
        assert_eq!(consumer.read(&mut [0]).unwrap(), 0);
        thread.join().unwrap();
    }
    #[test]
    fn pull_relay_rejects_oversized_headers_and_guest_errors_without_diagnostic_output() {
        for error in [false, true] {
            let (mut peer, input) = UnixStream::pair().unwrap();
            let (output, mut consumer) = UnixStream::pair().unwrap();
            consumer
                .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                .unwrap();
            let limited = Arc::new(AtomicBool::new(false));
            let flag = limited.clone();
            let thread = std::thread::spawn(move || pump_pull(input, output, flag));
            if error {
                let bytes = br#"{"status":"error","message":"PRIVATE=discard"}"#;
                peer.write_all(&(bytes.len() as u32).to_be_bytes()).unwrap();
                peer.write_all(bytes).unwrap();
            } else {
                peer.write_all(&((crate::images::IMAGE_REPLY_BYTES + 1) as u32).to_be_bytes())
                    .unwrap();
            }
            assert_eq!(consumer.read(&mut [0]).unwrap(), 0);
            assert_eq!(limited.load(Ordering::Acquire), !error);
            thread.join().unwrap();
        }
    }
    #[test]
    fn pull_progress_cannot_exhaust_unbounded_reply_frames() {
        let (mut peer, input) = UnixStream::pair().unwrap();
        let (output, mut consumer) = UnixStream::pair().unwrap();
        consumer
            .set_read_timeout(Some(std::time::Duration::from_secs(2)))
            .unwrap();
        let limited = Arc::new(AtomicBool::new(false));
        let flag = limited.clone();
        let thread = std::thread::spawn(move || pump_pull(input, output, flag));
        let bytes = br#"{"status":"progress"}"#;
        for _ in 0..=crate::image_pull::PROGRESS_FRAMES {
            peer.write_all(&(bytes.len() as u32).to_be_bytes()).unwrap();
            peer.write_all(bytes).unwrap();
        }
        assert_eq!(consumer.read(&mut [0]).unwrap(), 0);
        assert!(limited.load(Ordering::Acquire));
        thread.join().unwrap();
    }
    #[test]
    fn pull_reply_aggregate_budget_rejects_the_next_header_before_its_body() {
        let (mut peer, input) = UnixStream::pair().unwrap();
        let (output, mut consumer) = UnixStream::pair().unwrap();
        consumer
            .set_read_timeout(Some(std::time::Duration::from_secs(2)))
            .unwrap();
        let limited = Arc::new(AtomicBool::new(false));
        let flag = limited.clone();
        let thread = std::thread::spawn(move || pump_pull(input, output, flag));
        let prefix = br#"{"status":"progress","padding":""#;
        let suffix = br#""}"#;
        let mut bytes = prefix.to_vec();
        bytes.resize(crate::images::IMAGE_REPLY_BYTES - suffix.len(), b' ');
        bytes.extend_from_slice(suffix);
        for _ in 0..crate::image_pull::REPLY_TOTAL_BYTES / crate::images::IMAGE_REPLY_BYTES {
            peer.write_all(&(bytes.len() as u32).to_be_bytes()).unwrap();
            peer.write_all(&bytes).unwrap();
        }
        peer.write_all(&1u32.to_be_bytes()).unwrap();
        assert_eq!(consumer.read(&mut [0]).unwrap(), 0);
        assert!(limited.load(Ordering::Acquire));
        thread.join().unwrap();
    }
    #[test]
    fn image_projection_relay_rejects_headers_before_body_and_bounds_sdk_metadata() {
        for oversized in [false, true] {
            let (mut peer, input) = UnixStream::pair().unwrap();
            let (output, mut consumer) = UnixStream::pair().unwrap();
            consumer
                .set_read_timeout(Some(std::time::Duration::from_secs(1)))
                .unwrap();
            let limited = Arc::new(AtomicBool::new(false));
            let flag = limited.clone();
            let thread = std::thread::spawn(move || pump_images(input, output, flag));
            if oversized {
                peer.write_all(&((crate::images::IMAGE_REPLY_BYTES + 1) as u32).to_be_bytes())
                    .unwrap();
                let mut byte = [0];
                assert_eq!(consumer.read(&mut byte).unwrap(), 0);
                assert!(limited.load(Ordering::Acquire));
            } else {
                let bytes = serde_json::to_vec(&serde_json::json!({"status":"ok","data":[{
                    "reference":"fixture", "digest":"packed","size":1,"architecture":"arm64",
                    "os":"linux","layer_count":0,"env":["PRIVATE=discard"],"layers":["unused"]
                }]}))
                .unwrap();
                peer.write_all(&(bytes.len() as u32).to_be_bytes()).unwrap();
                peer.write_all(&bytes).unwrap();
                let mut header = [0; 4];
                consumer.read_exact(&mut header).unwrap();
                let mut body = vec![0; u32::from_be_bytes(header) as usize];
                consumer.read_exact(&mut body).unwrap();
                let reply: smolvm_protocol::AgentResponse = serde_json::from_slice(&body).unwrap();
                let smolvm_protocol::AgentResponse::Ok { data: Some(data) } = reply else {
                    panic!()
                };
                let images: Vec<smolvm_protocol::ImageInfo> = serde_json::from_value(data).unwrap();
                assert_eq!(images[0].digest, "packed");
                assert!(images[0].layers.is_empty() && images[0].env.is_empty());
            }
            thread.join().unwrap();
        }
    }
    #[test]
    fn an_oversized_header_is_rejected_without_forwarding_it_or_waiting_for_its_body() {
        let (mut peer, input) = UnixStream::pair().unwrap();
        let (output, mut consumer) = UnixStream::pair().unwrap();
        consumer
            .set_read_timeout(Some(std::time::Duration::from_secs(1)))
            .unwrap();
        let limited = Arc::new(AtomicBool::new(false));
        let flag = limited.clone();
        let thread = std::thread::spawn(move || pump(input, output, 64, flag));
        peer.write_all(&65u32.to_be_bytes()).unwrap();
        assert_eq!(consumer.read(&mut [0; 4]).unwrap(), 0);
        thread.join().unwrap();
        assert!(limited.load(Ordering::Acquire));
    }
    #[test]
    fn ordinary_frames_are_forwarded_exactly_across_fragmented_writes() {
        let (mut peer, input) = UnixStream::pair().unwrap();
        let (output, mut consumer) = UnixStream::pair().unwrap();
        let thread =
            std::thread::spawn(move || pump(input, output, 128, Arc::new(AtomicBool::new(false))));
        let body = b"{\"opaque\":\"utf8-and-binary-base64\"}";
        for byte in (body.len() as u32).to_be_bytes().iter().chain(body.iter()) {
            peer.write_all(&[*byte]).unwrap();
        }
        let mut observed = vec![0; body.len() + 4];
        consumer.read_exact(&mut observed).unwrap();
        assert_eq!(&observed[4..], body);
        peer.shutdown(Shutdown::Both).unwrap();
        thread.join().unwrap();
    }
}
