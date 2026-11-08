//! Bounded owner-process SDK exchanges shared by branch and boot observations.
use crate::{Error, ErrorCode, ReadBudget, Result};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

pub(crate) fn exchange<T>(
    socket: &Path,
    staging: &Path,
    output_bytes: u64,
    budget: &ReadBudget,
    action: impl FnOnce(&mut smolvm::agent::AgentClient, Duration) -> Result<T>,
) -> Result<T> {
    budget.check()?;
    let original_stage = crate::export_source::Root::open(staging)?;
    // Owner-process calls cannot change CWD as workers do. Keep the relay
    // endpoint short even when the admitted domain path exceeds sockaddr_un.
    // This private temporary directory carries no SDK or durable authority.
    let temporary_root = std::path::Path::new("/tmp")
        .canonicalize()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let socket_directory = tempfile::Builder::new()
        .prefix("sbx-branch-")
        .permissions(std::fs::Permissions::from_mode(0o700))
        .tempdir_in(temporary_root)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let socket_root = crate::export_source::Root::open(socket_directory.path())?;
    let connection = crate::agent_io::BoundedAgent::connect_in_until(
        socket,
        output_bytes,
        socket_directory.path(),
        budget.deadline,
    );
    // Cancellation/expiry during connection setup remains a pre-action result.
    // Do not invoke the SDK action after a late successful connect or prefer a
    // transport error over the original caller's already expired budget.
    budget.check()?;
    let mut agent = connection?;
    let _deadline = Deadline::new(agent.stopper(), budget)?;
    original_stage.verify()?;
    socket_root.verify()?;
    let remaining = budget
        .deadline
        .saturating_duration_since(std::time::Instant::now());
    if remaining.is_zero() {
        return Err(Error::uncertain(ErrorCode::State));
    }
    // The local SDK connection uses a short setup timeout. Branch identity and
    // release can take longer; their requests share the original remaining
    // budget, while the socket-only guardian also bounds partial-frame stalls.
    let _timeout = agent
        .client
        .set_extended_read_timeout(remaining)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    budget.check()?;
    let result = action(&mut agent.client, remaining);
    budget.check().map_err(|e| Error::uncertain(e.code))?;
    if agent.limited() {
        return Err(Error::uncertain(ErrorCode::Admission));
    }
    original_stage
        .verify()
        .map_err(|e| Error::uncertain(e.code))?;
    socket_root.verify().map_err(|e| Error::uncertain(e.code))?;
    result
}

pub(crate) fn boot_probe(socket: &Path, staging: &Path, budget: &ReadBudget) -> Result<()> {
    exchange(socket, staging, 1, budget, |client, _| {
        client.ping().map(|_| ()).map_err(|error| {
            // Only transport failures can mean the guest accept loop is
            // still becoming ready. Never retry a decoded agent rejection
            // or malformed response, and never expose its diagnostics.
            let code = match error {
                smolvm::Error::Io(_) => ErrorCode::Native,
                smolvm::Error::Agent { operation, .. } if operation == "send message" => {
                    ErrorCode::Native
                }
                _ => ErrorCode::Unsupported,
            };
            Error::uncertain(code)
        })
    })
}

/// One fixed, read-only command on the enrolled checkpoint guest. A ping can
/// succeed even when the restored guest cannot deliver timer interrupts.
pub(crate) fn checkpoint_timer_probe(
    socket: &Path,
    staging: &Path,
    budget: &ReadBudget,
) -> Result<()> {
    let attempt = ReadBudget {
        deadline: budget
            .deadline
            .min(std::time::Instant::now() + Duration::from_secs(4)),
        cancel: budget.cancel.clone(),
    };
    let result = exchange(socket, staging, 4096, &attempt, |client, remaining| {
        let (exit, stdout, stderr) = client
            .vm_exec(
                vec!["/bin/sh".into(), "-c".into(), "exec sleep 1".into()],
                vec![],
                Some("/".into()),
                Some(remaining),
                None,
            )
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        match exit {
            0 if stdout.is_empty() && stderr.is_empty() => Ok(()),
            124 => Err(Error::uncertain(ErrorCode::Deadline)),
            _ => Err(Error::uncertain(ErrorCode::Native)),
        }
    });
    if !attempt.cancel.is_cancelled() && std::time::Instant::now() >= attempt.deadline {
        return Err(Error::uncertain(ErrorCode::Deadline));
    }
    result.map_err(|error| Error::uncertain(error.code))
}

struct Deadline {
    done: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Deadline {
    fn new(stopper: crate::agent_io::Stopper, budget: &ReadBudget) -> Result<Self> {
        budget.check()?;
        let done = Arc::new(AtomicBool::new(false));
        let finished = done.clone();
        let budget = budget.clone();
        let thread = std::thread::Builder::new()
            .name("smolbox-branch-agent-budget".into())
            .spawn(move || {
                while !finished.load(Ordering::Acquire) {
                    if budget.check().is_err() {
                        stopper.stop();
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
            })
            .map_err(|_| Error::before(ErrorCode::Native))?;
        Ok(Self {
            done,
            thread: Some(thread),
        })
    }
}
impl Drop for Deadline {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};

    #[test]
    fn full_connection_backlog_cannot_extend_deadline_or_cancellation_into_sdk_entry() {
        use std::os::fd::AsRawFd;
        for cancelled in [false, true] {
            let (directory, listener, socket) = peer();
            // Fake Unix peer only. A minimal queue lets the test saturate the
            // connector without a VM, process fault or production listener.
            assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 1) }, 0);
            let mut queued = Vec::new();
            let mut full = false;
            for _ in 0..16 {
                match smolvm::platform::uds::UdsStream::connect_timeout(
                    &socket,
                    Duration::from_millis(5),
                ) {
                    Ok(stream) => queued.push(stream),
                    Err(error) => {
                        // Linux can report POLLHUP with no SO_ERROR after
                        // EAGAIN on a full AF_UNIX queue. The pinned SDK's
                        // socket2 connector returns this explicit Other error.
                        let linux_hangup = cfg!(target_os = "linux")
                            && error.kind() == std::io::ErrorKind::Other
                            && error.raw_os_error().is_none()
                            && error.to_string() == "no error set after POLLHUP";
                        assert!(
                            matches!(
                                error.kind(),
                                std::io::ErrorKind::WouldBlock
                                    | std::io::ErrorKind::TimedOut
                                    | std::io::ErrorKind::ConnectionRefused
                            ) || linux_hangup,
                            "unexpected backlog error: {error:?}"
                        );
                        assert!(
                            !queued.is_empty(),
                            "no connection reached the fake listener"
                        );
                        full = true;
                        break;
                    }
                }
            }
            assert!(full, "fake listener did not saturate its minimal backlog");
            let (collected, collect) = std::sync::mpsc::channel();
            let peer = std::thread::spawn(move || {
                // Finite fallback also collects a regressed blocking connector;
                // the test fails by elapsed time instead of hanging its runner.
                let _ = collect.recv_timeout(Duration::from_secs(2));
                listener.set_nonblocking(true).unwrap();
                while let Ok((stream, _)) = listener.accept() {
                    drop(stream);
                }
            });
            let cancel = crate::Cancellation::default();
            let stop = cancel.clone();
            let cancellation = cancelled.then(|| {
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(20));
                    stop.cancel();
                })
            });
            let budget = ReadBudget::new(
                if cancelled {
                    Duration::from_secs(5)
                } else {
                    Duration::from_millis(40)
                },
                cancel,
            )
            .unwrap();
            let entered = std::cell::Cell::new(false);
            let start = std::time::Instant::now();
            let result = exchange(&socket, directory.path(), 1, &budget, |_, _| {
                entered.set(true);
                Ok(())
            });
            let elapsed = start.elapsed();
            let _ = collected.send(());
            drop(queued);
            peer.join().unwrap();
            if let Some(thread) = cancellation {
                thread.join().unwrap();
            }
            assert!(elapsed < Duration::from_secs(1), "setup escaped its budget");
            assert!(!entered.get());
            assert_eq!(result.unwrap_err().dispatch, crate::Dispatch::NotDispatched);
        }
    }

    #[test]
    fn owner_exchange_preserves_reply_time_beyond_the_local_setup_timeout() {
        let (directory, listener, socket) = peer();
        let peer = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_ping(&mut stream);
            std::thread::sleep(Duration::from_millis(40));
            let body = serde_json::to_vec(&smolvm_protocol::AgentResponse::Pong {
                version: 1,
                capabilities: vec![],
            })
            .unwrap();
            stream
                .write_all(&(body.len() as u32).to_be_bytes())
                .unwrap();
            stream.write_all(&body).unwrap();
        });
        let budget =
            ReadBudget::new(Duration::from_secs(2), crate::Cancellation::default()).unwrap();
        let result = exchange(&socket, directory.path(), 1, &budget, |client, _| {
            client
                .ping()
                .map_err(|_| Error::uncertain(ErrorCode::Native))
        });
        peer.join().unwrap();
        assert_eq!(result.unwrap(), 1);
    }

    fn peer() -> (tempfile::TempDir, UnixListener, std::path::PathBuf) {
        let directory = tempfile::Builder::new()
            .prefix("sbx-probe-test-")
            .permissions(std::fs::Permissions::from_mode(0o700))
            .tempdir_in(Path::new("/tmp").canonicalize().unwrap())
            .unwrap();
        let socket = directory.path().join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        (directory, listener, socket)
    }
    fn read_request(stream: &mut UnixStream) -> smolvm_protocol::AgentRequest {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut header = [0; 4];
        stream.read_exact(&mut header).unwrap();
        let count = u32::from_be_bytes(header) as usize;
        assert!(count < 1024);
        let mut body = vec![0; count];
        stream.read_exact(&mut body).unwrap();
        serde_json::from_slice(&body).unwrap()
    }
    fn read_ping(stream: &mut UnixStream) {
        assert!(matches!(
            read_request(stream),
            smolvm_protocol::AgentRequest::Ping
        ));
    }

    #[test]
    fn checkpoint_timer_probe_requires_a_completed_sleep_under_the_original_deadline() {
        use smolvm_protocol::{encode_message, AgentRequest, AgentResponse};

        for completes in [true, false] {
            let (directory, listener, socket) = peer();
            let peer = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let AgentRequest::VmExec {
                    command,
                    workdir,
                    timeout_ms: Some(timeout),
                    interactive: false,
                    ..
                } = read_request(&mut stream)
                else {
                    panic!("expected the fixed timer probe");
                };
                assert_eq!(command, ["/bin/sh", "-c", "exec sleep 1"]);
                assert_eq!(workdir.as_deref(), Some("/"));
                assert!((1..=500).contains(&timeout));
                if completes {
                    let response = AgentResponse::Completed {
                        exit_code: 0,
                        stdout: vec![],
                        stderr: vec![],
                    };
                    stream
                        .write_all(&encode_message(&response).unwrap())
                        .unwrap();
                }
                assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
            });
            let budget =
                ReadBudget::new(Duration::from_millis(500), crate::Cancellation::default())
                    .unwrap();
            let result = checkpoint_timer_probe(&socket, directory.path(), &budget);
            peer.join().unwrap();
            if completes {
                result.unwrap();
            } else {
                assert_eq!(result.unwrap_err(), Error::uncertain(ErrorCode::Deadline));
            }
        }
    }
    #[test]
    fn boot_probe_waits_for_delayed_sdk_reply_without_booting_or_mutating() {
        let (directory, listener, socket) = peer();
        let peer = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_ping(&mut stream);
            std::thread::sleep(Duration::from_millis(40));
            let pong = serde_json::to_vec(&smolvm_protocol::AgentResponse::Pong {
                version: 1,
                capabilities: vec![],
            })
            .unwrap();
            stream
                .write_all(&(pong.len() as u32).to_be_bytes())
                .unwrap();
            stream.write_all(&pong).unwrap();
        });
        let budget =
            ReadBudget::new(Duration::from_secs(2), crate::Cancellation::default()).unwrap();
        boot_probe(&socket, directory.path(), &budget).unwrap();
        peer.join().unwrap();
    }
    #[test]
    fn cancelled_boot_probe_closes_only_observation_sockets_and_collects_relay() {
        let (directory, listener, socket) = peer();
        let cancel = crate::Cancellation::default();
        let cancelled = cancel.clone();
        let peer = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_ping(&mut stream);
            cancelled.cancel();
            assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
        });
        let budget = ReadBudget::new(Duration::from_secs(2), cancel).unwrap();
        assert_eq!(
            boot_probe(&socket, directory.path(), &budget).unwrap_err(),
            Error::uncertain(ErrorCode::State)
        );
        peer.join().unwrap();
    }
    #[test]
    fn boot_probe_rejects_oversized_header_before_sdk_allocation() {
        let (directory, listener, socket) = peer();
        let peer = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_ping(&mut stream);
            stream.write_all(&u32::MAX.to_be_bytes()).unwrap();
        });
        let budget =
            ReadBudget::new(Duration::from_secs(2), crate::Cancellation::default()).unwrap();
        assert_eq!(
            boot_probe(&socket, directory.path(), &budget).unwrap_err(),
            Error::uncertain(ErrorCode::Admission)
        );
        peer.join().unwrap();
    }
    #[test]
    fn boot_probe_never_retries_or_exposes_agent_rejection_and_malformed_json() {
        for response in [
            b"{invalid PRIVATE diagnostic".as_slice(),
            br#"{"status":"error","message":"PRIVATE diagnostic"}"#.as_slice(),
        ] {
            let (directory, listener, socket) = peer();
            let body = response.to_vec();
            let peer = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                read_ping(&mut stream);
                stream
                    .write_all(&(body.len() as u32).to_be_bytes())
                    .unwrap();
                stream.write_all(&body).unwrap();
            });
            let budget =
                ReadBudget::new(Duration::from_secs(2), crate::Cancellation::default()).unwrap();
            let error = boot_probe(&socket, directory.path(), &budget).unwrap_err();
            assert_eq!(error, Error::uncertain(ErrorCode::Unsupported));
            assert!(!format!("{error:?}").contains("PRIVATE"));
            peer.join().unwrap();
        }
    }
}
