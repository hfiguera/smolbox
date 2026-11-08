//! Private isolated terminal entry. Parent supervision remains the only physical
//! collection authority; this worker neither creates a runtime nor accepts a receipt.
use crate::terminal_ipc::{Decoder, Direction, Frame, Identity, Payload, Proof, Startup};
use crate::{
    Cancellation, Error, ErrorCode, Result, TerminalControl, TerminalFailure, TerminalIdentity,
    TerminalIoRequest, TerminalSession,
};
use std::io::Read;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{self, TrySendError},
    Arc, Condvar, Mutex,
};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(5);
struct Shared {
    session: TerminalSession,
    control: u64,
    output: u64,
    bytes: u64,
}
fn fail(shared: &Mutex<Shared>, cancel: &Cancellation, reason: TerminalFailure) {
    shared
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .session
        .fail(reason);
    cancel.cancel();
}
struct Nonblocking(i32);
impl Nonblocking {
    fn stdout() -> Result<Self> {
        let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(libc::STDOUT_FILENO, &mut metadata) } != 0
            || !matches!(
                metadata.st_mode & libc::S_IFMT,
                libc::S_IFIFO | libc::S_IFSOCK
            )
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        let flags = unsafe { libc::fcntl(libc::STDOUT_FILENO, libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(libc::STDOUT_FILENO, libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err(Error::before(ErrorCode::Io));
        }
        Ok(Self(flags))
    }
}

impl Drop for Nonblocking {
    fn drop(&mut self) {
        unsafe {
            libc::fcntl(libc::STDOUT_FILENO, libc::F_SETFL, self.0);
        }
    }
}
fn emit(frame: &Frame, deadline: Instant, cancel: Option<&Cancellation>) -> Result<()> {
    let bytes = crate::terminal_ipc::encode(frame)?;
    let mut pending = bytes.as_slice();
    while !pending.is_empty() {
        if Instant::now() >= deadline || cancel.is_some_and(Cancellation::is_cancelled) {
            return Err(Error::uncertain(ErrorCode::Io));
        }
        let written =
            unsafe { libc::write(libc::STDOUT_FILENO, pending.as_ptr().cast(), pending.len()) };
        let result = if written < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(written as usize)
        };
        match result {
            Ok(0) => return Err(Error::uncertain(ErrorCode::Io)),
            Ok(n) => pending = &pending[n..],
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(POLL),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return Err(Error::uncertain(ErrorCode::Io)),
        }
    }
    Ok(())
}

pub fn run_terminal_worker() -> Result<()> {
    let startup = Startup::read(&mut std::io::stdin().lock())?;
    startup.owner.arm_subprocess_watch()?;
    crate::host::private_directory(&startup.staging)?;
    if std::env::current_dir().map_err(|_| Error::before(ErrorCode::Io))? != startup.staging {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let metadata: crate::buffered::Metadata = startup
        .metadata
        .read(startup.owner, crate::COMMAND_METADATA_BYTES)?;
    let (config, deadline) = metadata.terminal(&startup.options)?;
    let identity = Identity {
        epoch: startup.epoch,
        operation: startup.operation,
    };
    let token = TerminalIdentity::new(identity.epoch.clone(), identity.operation.clone())?;
    let options = startup.options;
    let shared = Arc::new(Mutex::new(Shared {
        session: TerminalSession::new(token.clone(), options.clone(), Instant::now(), deadline)?,
        control: 0,
        output: 0,
        bytes: 0,
    }));
    let notify = Arc::new(Condvar::new());
    let done = Arc::new(AtomicBool::new(false));
    let cancel = Cancellation::new();
    let (sender, receiver) = mpsc::sync_channel(2);
    let _nonblocking = Nonblocking::stdout()?;
    let budgets = shared.clone();
    let finished = done.clone();
    let expired = cancel.clone();
    std::thread::Builder::new()
        .name("smolbox-terminal-budget".into())
        .spawn(move || {
            while !finished.load(Ordering::Acquire) {
                let mut state = budgets.lock().unwrap_or_else(|e| e.into_inner());
                state.session.expire(Instant::now());
                if state.session.failure().is_some() {
                    expired.cancel();
                    break;
                }
                drop(state);
                std::thread::sleep(POLL);
            }
        })
        .map_err(|_| Error::before(ErrorCode::Native))?;
    emit(
        &Frame {
            identity: identity.clone(),
            sequence: 0,
            payload: Payload::Ready,
        },
        deadline,
        None,
    )?;
    let state = shared.clone();
    let finished = done.clone();
    let signal = notify.clone();
    let input_cancel = cancel.clone();
    let input_identity = identity.clone();
    let input_token = token.clone();
    std::thread::Builder::new()
        .name("smolbox-terminal-input".into())
        .spawn(move || {
            let mut decoder = match Decoder::new(input_identity, Direction::Controller) {
                Ok(d) => d,
                Err(_) => return,
            };
            let mut stdin = std::io::stdin().lock();
            let mut buffer = [0; 4096];
            while !finished.load(Ordering::Acquire) {
                let size = match stdin.read(&mut buffer) {
                    Ok(0) | Err(_) => {
                        if !finished.load(Ordering::Acquire) {
                            fail(&state, &input_cancel, TerminalFailure::ConsumerLost);
                        }
                        break;
                    }
                    Ok(n) => n,
                };
                let mut bytes = &buffer[..size];
                while !bytes.is_empty() && !finished.load(Ordering::Acquire) {
                    let (n, frame) = match decoder.feed(bytes) {
                        Ok(value) => value,
                        Err(_) => {
                            fail(&state, &input_cancel, TerminalFailure::Protocol);
                            return;
                        }
                    };
                    bytes = &bytes[n..];
                    let Some(frame) = frame else {
                        continue;
                    };
                    let mut current = state.lock().unwrap_or_else(|e| e.into_inner());
                    let accepted = match frame.payload {
                        Payload::Attach => current.session.attach(&input_token, Instant::now()),
                        Payload::Credit { sequence, bytes } => {
                            current.session.consumed(&input_token, sequence, bytes)
                        }
                        Payload::Cancel => {
                            current.session.fail(TerminalFailure::Cancelled);
                            input_cancel.cancel();
                            Ok(())
                        }
                        payload => {
                            let (command, charge) = match payload {
                                Payload::Input(bytes) => {
                                    let charge = bytes.len() as u64;
                                    (TerminalControl::Input(bytes), charge)
                                }
                                Payload::Resize { cols, rows } => {
                                    (TerminalControl::Resize { cols, rows }, 4)
                                }
                                Payload::Close => (TerminalControl::Close, 0),
                                _ => {
                                    current.session.fail(TerminalFailure::Protocol);
                                    input_cancel.cancel();
                                    return;
                                }
                            };
                            match current.control.checked_add(1) {
                                None => Err(Error::uncertain(ErrorCode::State)),
                                Some(sequence) => {
                                    let valid = current.session.control(
                                        &input_token,
                                        sequence,
                                        &command,
                                        charge,
                                        Instant::now(),
                                    );
                                    if valid.is_ok() {
                                        current.control = sequence;
                                        match sender.try_send(command) {
                                            Ok(()) => {}
                                            Err(TrySendError::Full(_))
                                            | Err(TrySendError::Disconnected(_)) => {
                                                current.session.fail(TerminalFailure::InputLimit);
                                                input_cancel.cancel();
                                            }
                                        }
                                    }
                                    valid
                                }
                            }
                        }
                    };
                    if accepted.is_err() {
                        current.session.fail(TerminalFailure::Protocol);
                        input_cancel.cancel();
                    }
                    signal.notify_all();
                }
            }
        })
        .map_err(|_| Error::before(ErrorCode::Native))?;

    let proof = crate::run_terminal_agent(
        TerminalIoRequest {
            socket: startup.socket,
            // The supervisor fixes this isolated worker's private CWD. Keep
            // relay socket names relative even for a long admitted domain.
            staging: ".".into(),
            config,
            options: options.clone(),
            deadline,
            cancel: cancel.clone(),
        },
        receiver,
        |output| {
            let size = output.bytes.len() as u64;
            let mut current = shared.lock().unwrap_or_else(|e| e.into_inner());
            loop {
                current.session.expire(Instant::now());
                if cancel.is_cancelled() || current.session.failure().is_some() {
                    return Err(());
                }
                let (bytes, events) = current.session.output_window();
                if bytes >= size && events > 0 {
                    break;
                }
                current = notify
                    .wait_timeout(current, POLL)
                    .unwrap_or_else(|e| e.into_inner())
                    .0;
            }
            let Some(sequence) = current.output.checked_add(1) else {
                return Err(());
            };
            if current
                .session
                .output(&token, sequence, size, Instant::now())
                .is_err()
            {
                return Err(());
            }
            current.output = sequence;
            drop(current);
            let sent = emit(
                &Frame {
                    identity: identity.clone(),
                    sequence,
                    payload: Payload::Output {
                        stderr: matches!(output.stream, crate::Stream::Stderr),
                        bytes: output.bytes,
                    },
                },
                deadline,
                Some(&cancel),
            );
            if sent.is_err() {
                fail(&shared, &cancel, TerminalFailure::ConsumerLost);
                return Err(());
            }
            let mut current = shared.lock().unwrap_or_else(|e| e.into_inner());
            let Some(bytes) = current.bytes.checked_add(size) else {
                return Err(());
            };
            current.bytes = bytes;
            Ok(())
        },
    );
    done.store(true, Ordering::Release);
    let mut current = shared.lock().unwrap_or_else(|e| e.into_inner());
    let (exit, failure) = match proof {
        Ok(proof) => (proof.observed_exit, proof.failure),
        Err(_) => (None, Some(TerminalFailure::Native)),
    };
    if let Some(reason) = failure {
        current.session.fail(reason);
    }
    if let Some(exit) = exit {
        let _ = current.session.observe_exit(&token, exit, Instant::now());
    }
    current.session.expire(Instant::now());
    let failure = current.session.failure();
    let sequence = current
        .output
        .checked_add(1)
        .ok_or(Error::uncertain(ErrorCode::State))?;
    // No TerminalSession.collected call: only the parent can collect this worker.
    emit(
        &Frame {
            identity,
            sequence,
            payload: Payload::End(Proof {
                observed_exit: exit,
                failure,
                output_bytes: current.bytes,
            }),
        },
        deadline + options.close,
        None,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use smolvm_protocol::{encode_message, AgentRequest, AgentResponse, Envelope};
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    };
    use std::process::{Command, Stdio};

    fn message(socket: &mut UnixStream) -> AgentRequest {
        let mut header = [0; 4];
        socket.read_exact(&mut header).unwrap();
        let size = u32::from_be_bytes(header) as usize;
        assert!(size <= crate::AGENT_REQUEST_BYTES);
        let mut bytes = vec![0; size];
        socket.read_exact(&mut bytes).unwrap();
        serde_json::from_slice::<Envelope<AgentRequest>>(&bytes)
            .unwrap()
            .body
    }
    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM terminal peer"]
    fn ordinary_terminal_worker_authenticates_metadata_and_obeys_consumption_credit() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = directory.path().canonicalize().unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = root.join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        // The guest endpoint stays short; the actual private worker spool
        // exceeds sockaddr_un on both supported platforms.
        let root = root.join("private-terminal-spool-".repeat(6));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(root.as_os_str().len() > 108);
        let (seen, delivered) = mpsc::channel();
        let deadline = Instant::now() + Duration::from_secs(15);
        let peer = std::thread::spawn(move || {
            let mut socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline);
                        std::thread::sleep(POLL);
                    }
                    Err(_) => panic!("ordinary terminal peer accept failed"),
                }
            };
            socket.set_nonblocking(false).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            assert!(matches!(
                message(&mut socket),
                AgentRequest::Run {
                    tty: true,
                    interactive: true,
                    background: false,
                    stop_vm_on_exit: false,
                    timeout_ms: None,
                    ..
                }
            ));
            socket
                .write_all(&encode_message(&AgentResponse::Started).unwrap())
                .unwrap();
            assert!(matches!(
                message(&mut socket),
                AgentRequest::Resize {
                    cols: 100,
                    rows: 37
                }
            ));
            socket
                .write_all(
                    &encode_message(&AgentResponse::Stdout {
                        data: vec![42; 2048],
                    })
                    .unwrap(),
                )
                .unwrap();
            delivered.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(
                matches!(message(&mut socket), AgentRequest::Stdin { data } if data == [0, 255, 128])
            );
            assert!(
                matches!(message(&mut socket), AgentRequest::Stdin { data } if data.is_empty())
            );
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
        let mut record =
            smolvm::config::VmRecord::new("0123456789abcdef".into(), 1, 512, vec![], vec![], false);
        record.image = Some("local-dir:/fixture".into());
        let command = crate::BufferedCommand {
            argv: vec!["/bin/sh".into()],
            env: vec![],
            workdir: Some("/workspace".into()),
            user: Some("1234:2345".into()),
            stdin: None,
            timeout: Duration::from_secs(30),
            max_output_bytes: 1024,
        };
        let metadata = crate::buffered::Metadata::new(&record, command, deadline).unwrap();
        let data = serde_json::to_vec(&metadata).unwrap();
        let path = root.join("metadata");
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o400)
            .open(&path)
            .unwrap();
        file.write_all(&data).unwrap();
        file.sync_all().unwrap();
        let stat = file.metadata().unwrap();
        let identity = Identity {
            epoch: "ab".repeat(16),
            operation: "cd".repeat(16),
        };
        let startup = Startup {
            schema: 1,
            epoch: identity.epoch.clone(),
            operation: identity.operation.clone(),
            owner: crate::OwnerIdentity::capture().unwrap(),
            socket,
            staging: root.clone(),
            metadata: crate::transfer_worker::Blob {
                path,
                device: stat.dev(),
                inode: stat.ino(),
                bytes: data.len() as u64,
            },
            options: crate::TerminalOptions {
                program: "/bin/sh".into(),
                cols: 100,
                rows: 37,
                session: Duration::from_secs(30),
                idle: Duration::from_secs(30),
                attach: Duration::from_secs(5),
                close: Duration::from_secs(5),
                max_buffer_bytes: 1024,
                max_input_bytes: 65536,
                total_input_bytes: 1048576,
            },
        };
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path");
        let mut child = Command::new(executable)
            .arg("--terminal-worker")
            .current_dir(&root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut input = child.stdin.take().unwrap();
        let output = child.stdout.take().unwrap();
        let request = serde_json::to_vec(&startup).unwrap();
        input
            .write_all(&(request.len() as u32).to_be_bytes())
            .unwrap();
        input.write_all(&request).unwrap();
        input.flush().unwrap();
        let (out_sender, out_receiver) = mpsc::sync_channel(2);
        let expected = identity.clone();
        let reader = std::thread::spawn(move || {
            let mut output = output;
            let mut decoder = Decoder::new(expected, Direction::Worker).unwrap();
            let mut buffer = [0; 4096];
            loop {
                let size = output.read(&mut buffer).unwrap();
                if size == 0 {
                    break;
                }
                let mut pending = &buffer[..size];
                while !pending.is_empty() {
                    let (n, frame) = decoder.feed(pending).unwrap();
                    pending = &pending[n..];
                    if let Some(frame) = frame {
                        out_sender.send(frame).unwrap();
                    }
                }
            }
            decoder.finish().unwrap();
        });
        let mut seq = 0u64;
        let mut send = |payload| {
            let frame = crate::terminal_ipc::encode(&Frame {
                identity: identity.clone(),
                sequence: seq,
                payload,
            })
            .unwrap();
            seq += 1;
            input.write_all(&frame).unwrap();
            input.flush().unwrap();
        };
        assert!(matches!(
            out_receiver
                .recv_timeout(Duration::from_secs(5))
                .unwrap()
                .payload,
            Payload::Ready
        ));
        send(Payload::Attach);
        let first = out_receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(
            matches!(&first.payload, Payload::Output { bytes, .. } if bytes == &vec![42; 1024])
        );
        assert!(out_receiver
            .recv_timeout(Duration::from_millis(30))
            .is_err());
        send(Payload::Credit {
            sequence: first.sequence,
            bytes: 1024,
        });
        let second = out_receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(
            matches!(&second.payload, Payload::Output { bytes, .. } if bytes == &vec![42; 1024])
        );
        send(Payload::Credit {
            sequence: second.sequence,
            bytes: 1024,
        });
        seen.send(()).unwrap();
        send(Payload::Input(vec![0, 255, 128]));
        std::thread::sleep(Duration::from_millis(20));
        send(Payload::Close);
        assert!(matches!(
            out_receiver
                .recv_timeout(Duration::from_secs(5))
                .unwrap()
                .payload,
            Payload::End(Proof {
                observed_exit: Some(7),
                failure: None,
                output_bytes: 2048
            })
        ));
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(POLL);
        };
        assert!(status.success());
        reader.join().unwrap();
        peer.join().unwrap();

        // A normally launched helper with the same live parent must still reject
        // changed protected-file identity before connecting to any SDK agent.
        let mut altered = startup;
        altered.metadata.inode ^= 1;
        let executable = std::env::var_os("SMOLBOX_TEST_FILE_WORKER").unwrap();
        let mut rejected = Command::new(executable)
            .arg("--terminal-worker")
            .current_dir(&root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let data = serde_json::to_vec(&altered).unwrap();
        let mut input = rejected.stdin.take().unwrap();
        input.write_all(&(data.len() as u32).to_be_bytes()).unwrap();
        input.write_all(&data).unwrap();
        input.flush().unwrap();
        let status = loop {
            if let Some(status) = rejected.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(POLL);
        };
        assert_eq!(status.code(), Some(2));
        let mut bytes = Vec::new();
        rejected
            .stdout
            .take()
            .unwrap()
            .read_to_end(&mut bytes)
            .unwrap();
        assert!(bytes.is_empty());
    }
}
