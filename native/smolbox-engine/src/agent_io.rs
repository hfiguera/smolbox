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
                let second = std::thread::spawn(move || {
                    pump(response_read, response_write, reply_cap, relay_limit)
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

#[cfg(test)]
mod tests {
    use super::*;
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
