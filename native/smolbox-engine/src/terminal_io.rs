//! SDK channel I/O for a future isolated owned terminal worker. No manager, VM
//! initialization, host tty or signal handler is installed by this path.
use crate::{
    Cancellation, Error, ErrorCode, Output, Result, Stream, TerminalControl, TerminalFailure,
    TerminalOptions, TERMINAL_CHUNK_BYTES,
};
use smolvm::agent::{InteractiveInput, InteractiveOutput, RunConfig};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{self, Receiver, RecvTimeoutError},
    Arc, Mutex,
};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(5);

/// SDK evidence only: this is not owned-child collection or a public result.
pub struct TerminalIoProof {
    pub observed_exit: Option<i32>,
    pub failure: Option<TerminalFailure>,
}
pub struct TerminalIoRequest {
    pub socket: PathBuf,
    pub staging: PathBuf,
    pub config: RunConfig,
    pub options: TerminalOptions,
    pub deadline: Instant,
    pub cancel: Cancellation,
}
struct Finish {
    done: Arc<AtomicBool>,
    stopper: crate::agent_io::Stopper,
}
impl Drop for Finish {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Release);
        self.stopper.stop();
    }
}
struct State {
    failure: Option<TerminalFailure>,
    active: Instant,
    close: Option<Instant>,
}
fn failed(state: &Mutex<State>, reason: TerminalFailure) {
    let mut state = state.lock().unwrap_or_else(|error| error.into_inner());
    if state.failure.is_none() {
        state.failure = Some(reason);
    }
}

/// Caller must already have authenticated the existing image/mount/overlay
/// config, reserved queue/process resources and correlated each control through
/// TerminalSession. The input source and output callback must be bounded and
/// nonblocking; an owned supervisor supplies their physical collection boundary.
/// This runner alone never enables a native capability or releases any lease.
pub fn run_terminal_agent(
    request: TerminalIoRequest,
    input: Receiver<TerminalControl>,
    mut output: impl FnMut(Output) -> std::result::Result<(), ()>,
) -> Result<TerminalIoProof> {
    let TerminalIoRequest {
        socket,
        staging,
        mut config,
        options,
        deadline,
        cancel,
    } = request;
    options.validate()?;
    let now = Instant::now();
    if deadline <= now
        || config.command != [options.program.clone()]
        || config.image.is_empty()
        || config.image.len() > 16_384
        || config.image.contains('\0')
        || config.stdin.is_some()
        || config.timeout.is_some()
        || config.stop_vm_on_exit
        || !config.s3_volumes.is_empty()
        || config.env.len() > 64
        || config.env.iter().any(|(key, value)| {
            key.is_empty()
                || key.len() > 128
                || value.len() > 8192
                || key.contains('\0')
                || value.contains('\0')
        })
        || config
            .user
            .as_ref()
            .is_some_and(|user| user.is_empty() || user.len() > 128 || user.contains('\0'))
        || config.workdir.as_ref().is_some_and(|path| {
            path.len() > 4096
                || !path.starts_with('/')
                || path.contains('\0')
                || path.split('/').any(|part| part == "..")
        })
        || config
            .persistent_overlay_id
            .as_ref()
            .is_some_and(|id| id.len() > 16384 || id.contains('\0'))
        || config.mounts.len() > 64
        || config.mounts.iter().any(|(tag, path, _)| {
            tag.is_empty()
                || tag.len() > 4096
                || tag.contains('\0')
                || path.len() > 4096
                || !path.starts_with('/')
                || path.contains('\0')
                || path.split('/').any(|part| part == "..")
        })
        || !socket.is_absolute()
        || socket.file_name() != Some("agent.sock".as_ref())
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    config.tty = true;
    let deadline = deadline.min(now + options.session);
    let mut agent =
        crate::agent_io::BoundedAgent::connect_in(&socket, TERMINAL_CHUNK_BYTES, &staging)?;
    if Instant::now() >= deadline || cancel.is_cancelled() {
        return Ok(TerminalIoProof {
            observed_exit: None,
            failure: Some(if cancel.is_cancelled() {
                TerminalFailure::Cancelled
            } else {
                TerminalFailure::SessionDeadline
            }),
        });
    }
    let stopper = agent.stopper();
    let done = Arc::new(AtomicBool::new(false));
    let state = Arc::new(Mutex::new(State {
        failure: None,
        active: now,
        close: None,
    }));
    let (sender, receiver) = mpsc::sync_channel(2);
    sender
        .send(InteractiveInput::Resize {
            cols: options.cols,
            rows: options.rows,
        })
        .map_err(|_| Error::before(ErrorCode::Native))?;
    let result = std::thread::scope(|scope| {
        let _finish = Finish {
            done: done.clone(),
            stopper: agent.stopper(),
        };
        let shared = state.clone();
        let finished = done.clone();
        let input_stop = agent.stopper();
        scope.spawn(move || {
            let mut total = 0u64;
            let mut closing = false;
            while !finished.load(Ordering::Acquire) {
                match input.recv_timeout(POLL) {
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => {
                        failed(&shared, TerminalFailure::ConsumerLost);
                        input_stop.stop();
                        break;
                    }
                    Ok(command) => {
                        if closing {
                            failed(&shared, TerminalFailure::Protocol);
                            input_stop.stop();
                            break;
                        }
                        let (charge, command) = match command {
                            TerminalControl::Input(bytes)
                                if !bytes.is_empty()
                                    && bytes.len() as u64 <= options.max_input_bytes =>
                            {
                                (bytes.len() as u64, InteractiveInput::Stdin(bytes))
                            }
                            TerminalControl::Resize { cols, rows } if cols > 0 && rows > 0 => {
                                (4, InteractiveInput::Resize { cols, rows })
                            }
                            TerminalControl::Close => {
                                closing = true;
                                shared.lock().unwrap_or_else(|e| e.into_inner()).close =
                                    Some(Instant::now() + options.close);
                                (0, InteractiveInput::Eof)
                            }
                            _ => {
                                failed(&shared, TerminalFailure::Protocol);
                                input_stop.stop();
                                break;
                            }
                        };
                        let Some(next) = total
                            .checked_add(charge)
                            .filter(|n| *n <= options.total_input_bytes)
                        else {
                            failed(&shared, TerminalFailure::InputLimit);
                            input_stop.stop();
                            break;
                        };
                        total = next;
                        shared.lock().unwrap_or_else(|e| e.into_inner()).active = Instant::now();
                        if sender.send(command).is_err() {
                            break;
                        }
                    }
                }
            }
            // Keep the SDK sender alive through EOF observation; dropping it
            // immediately causes the SDK disconnect sentinel instead of Exit.
        });
        let shared = state.clone();
        let finished = done.clone();
        scope.spawn(move || {
            while !finished.load(Ordering::Acquire) {
                let now = Instant::now();
                let s = shared.lock().unwrap_or_else(|e| e.into_inner());
                let reason = if cancel.is_cancelled() {
                    Some(TerminalFailure::Cancelled)
                } else if s.close.is_some_and(|close| now >= close) {
                    Some(TerminalFailure::CloseDeadline)
                } else if now >= deadline {
                    Some(TerminalFailure::SessionDeadline)
                } else if now.saturating_duration_since(s.active) >= options.idle {
                    Some(TerminalFailure::IdleDeadline)
                } else {
                    None
                };
                drop(s);
                if let Some(reason) = reason {
                    failed(&shared, reason);
                    stopper.stop();
                    break;
                }
                std::thread::sleep(POLL);
            }
        });
        let output_stop = agent.stopper();
        agent.client.run_interactive_io(config, receiver, |event| {
            let (stream, bytes) = match event {
                InteractiveOutput::Stdout(bytes) => (Stream::Stdout, bytes),
                InteractiveOutput::Stderr(bytes) => (Stream::Stderr, bytes),
            };
            if bytes.len() as u64 > TERMINAL_CHUNK_BYTES {
                failed(&state, TerminalFailure::OutputLimit);
                output_stop.stop();
                return;
            }
            for bytes in bytes.chunks(options.max_buffer_bytes.min(TERMINAL_CHUNK_BYTES) as usize) {
                state.lock().unwrap_or_else(|e| e.into_inner()).active = Instant::now();
                if output(Output {
                    stream,
                    bytes: bytes.to_vec(),
                })
                .is_err()
                {
                    failed(&state, TerminalFailure::ConsumerLost);
                    output_stop.stop();
                    break;
                }
            }
        })
    });
    if agent.limited() {
        failed(&state, TerminalFailure::OutputLimit);
    }
    let exit = result.ok();
    if exit.is_none() {
        failed(&state, TerminalFailure::Native);
    } else if !matches!(exit, Some(0..=123 | 125..=129 | 131..=255)) {
        failed(&state, TerminalFailure::AmbiguousExit);
    }
    let failure = state.lock().unwrap_or_else(|e| e.into_inner()).failure;
    Ok(TerminalIoProof {
        observed_exit: exit,
        failure,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use smolvm_protocol::{encode_message, AgentRequest, AgentResponse, Envelope};
    use std::io::{Read, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};

    fn options() -> TerminalOptions {
        TerminalOptions {
            program: "/bin/sh".into(),
            cols: 100,
            rows: 37,
            session: Duration::from_secs(30),
            idle: Duration::from_secs(30),
            attach: Duration::from_secs(5),
            close: Duration::from_secs(5),
            max_buffer_bytes: 1024,
            max_input_bytes: 65536,
            total_input_bytes: 1_048_576,
        }
    }
    fn read(socket: &mut UnixStream) -> Option<AgentRequest> {
        let mut header = [0; 4];
        if socket.read_exact(&mut header).is_err() {
            return None;
        }
        let size = u32::from_be_bytes(header) as usize;
        assert!(size <= crate::AGENT_REQUEST_BYTES);
        let mut body = vec![0; size];
        socket.read_exact(&mut body).unwrap();
        Some(
            serde_json::from_slice::<Envelope<AgentRequest>>(&body)
                .unwrap()
                .body,
        )
    }
    fn accept(listener: &UnixListener) -> UnixStream {
        listener.set_nonblocking(true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match listener.accept() {
                Ok((socket, _)) => {
                    socket.set_nonblocking(false).unwrap();
                    socket
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    return socket;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline);
                    std::thread::sleep(POLL);
                }
                Err(_) => panic!("non-VM peer accept failed"),
            }
        }
    }
    fn request(root: PathBuf) -> TerminalIoRequest {
        let mut config = RunConfig::new("image", vec!["/bin/sh".into()]);
        config.user = Some("1234:2345".into());
        config.persistent_overlay_id = Some("0123456789abcdef".into());
        TerminalIoRequest {
            socket: root.join("agent.sock"),
            staging: root,
            config,
            options: options(),
            deadline: Instant::now() + Duration::from_secs(20),
            cancel: Cancellation::new(),
        }
    }

    #[test]
    fn natural_agent_exit_preserves_final_output_without_input_close() {
        for _ in 0..16 {
            let directory = tempfile::tempdir_in("/tmp").unwrap();
            let root = directory.path().canonicalize().unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
            let listener = UnixListener::bind(root.join("agent.sock")).unwrap();
            let (_input, receiver) = mpsc::channel();
            let peer = std::thread::spawn(move || {
                let mut socket = accept(&listener);
                assert!(matches!(read(&mut socket), Some(AgentRequest::Run { .. })));
                socket
                    .write_all(&encode_message(&AgentResponse::Started).unwrap())
                    .unwrap();
                assert!(matches!(
                    read(&mut socket),
                    Some(AgentRequest::Resize { .. })
                ));
                socket
                    .write_all(
                        &[
                            encode_message(&AgentResponse::Stdout {
                                data: vec![0, 255, 128],
                            })
                            .unwrap(),
                            encode_message(&AgentResponse::Exited {
                                exit_code: 7,
                                oom: false,
                            })
                            .unwrap(),
                        ]
                        .concat(),
                    )
                    .unwrap();
            });
            let mut bytes = vec![];
            let proof = run_terminal_agent(request(root), receiver, |output| {
                bytes.extend(output.bytes);
                Ok(())
            })
            .unwrap();
            peer.join().unwrap();
            assert_eq!(bytes, [0, 255, 128]);
            assert_eq!(proof.observed_exit, Some(7));
            assert_eq!(proof.failure, None);
        }
    }

    #[test]
    fn sdk_channels_preserve_context_initial_resize_binary_input_eof_exit_and_large_streams() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = directory.path().canonicalize().unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let listener = UnixListener::bind(root.join("agent.sock")).unwrap();
        let (input, receiver) = mpsc::channel();
        let peer = std::thread::spawn(move || {
            let mut socket = accept(&listener);
            match read(&mut socket).unwrap() {
                AgentRequest::Run {
                    command,
                    tty,
                    timeout_ms,
                    interactive,
                    background,
                    user,
                    persistent_overlay_id,
                    stdin_data,
                    stop_vm_on_exit,
                    ..
                } => {
                    assert_eq!(command, ["/bin/sh"]);
                    assert!(tty && interactive);
                    assert!(!background && !stop_vm_on_exit);
                    assert!(timeout_ms.is_none() && stdin_data.is_none());
                    assert_eq!(user.as_deref(), Some("1234:2345"));
                    assert_eq!(persistent_overlay_id.as_deref(), Some("0123456789abcdef"));
                }
                _ => panic!("unexpected SDK session request"),
            }
            socket
                .write_all(&encode_message(&AgentResponse::Started).unwrap())
                .unwrap();
            let initial = read(&mut socket);
            assert!(
                matches!(
                    initial,
                    Some(AgentRequest::Resize {
                        cols: 100,
                        rows: 37
                    })
                ),
                "initial SDK control: {initial:?}"
            );
            socket
                .write_all(
                    &encode_message(&AgentResponse::Stdout {
                        data: vec![0, 255, 7],
                    })
                    .unwrap(),
                )
                .unwrap();
            assert!(
                matches!(read(&mut socket), Some(AgentRequest::Stdin { data }) if data == [0, 255, 128])
            );
            socket
                .write_all(
                    &encode_message(&AgentResponse::Stderr {
                        data: vec![128, 0, 254],
                    })
                    .unwrap(),
                )
                .unwrap();
            assert!(matches!(
                read(&mut socket),
                Some(AgentRequest::Resize {
                    cols: 120,
                    rows: 43
                })
            ));
            socket
                .write_all(
                    &encode_message(&AgentResponse::Stdout {
                        data: b"resized".to_vec(),
                    })
                    .unwrap(),
                )
                .unwrap();
            assert!(
                matches!(read(&mut socket), Some(AgentRequest::Stdin { data }) if data.is_empty())
            );
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
        let mut total = 0;
        let result = run_terminal_agent(request(root), receiver, |output| {
            assert!(output.bytes.len() <= 1024);
            total += output.bytes.len();
            match output.bytes.as_slice() {
                [0, 255, 7] => input
                    .send(TerminalControl::Input(vec![0, 255, 128]))
                    .unwrap(),
                [128, 0, 254] => {
                    assert!(matches!(output.stream, Stream::Stderr));
                    input
                        .send(TerminalControl::Resize {
                            cols: 120,
                            rows: 43,
                        })
                        .unwrap();
                }
                b"resized" => input.send(TerminalControl::Close).unwrap(),
                bytes => assert!(bytes.iter().all(|b| *b == 42)),
            }
            Ok(())
        })
        .unwrap();
        peer.join().unwrap();
        assert_eq!(total, 12 * 1024 * 1024 + 13);
        assert_eq!(result.observed_exit, Some(7));
        assert_eq!(result.failure, None);
    }

    #[test]
    fn sdk_read_timeout_removal_cannot_extend_deadline_cancel_or_close_observation() {
        for mode in ["deadline", "cancel", "close"] {
            let directory = tempfile::tempdir_in("/tmp").unwrap();
            let root = directory.path().canonicalize().unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
            let listener = UnixListener::bind(root.join("agent.sock")).unwrap();
            let mut config = request(root);
            config.deadline = Instant::now() + Duration::from_secs(2);
            config.options.close = Duration::from_millis(500);
            let cancel = config.cancel.clone();
            let (input, receiver) = mpsc::channel();
            let peer = std::thread::spawn(move || {
                let mut socket = accept(&listener);
                assert!(matches!(read(&mut socket), Some(AgentRequest::Run { .. })));
                socket
                    .write_all(&encode_message(&AgentResponse::Started).unwrap())
                    .unwrap();
                let initial = read(&mut socket);
                assert!(
                    matches!(initial, Some(AgentRequest::Resize { .. })),
                    "initial SDK control: {initial:?}"
                );
                if mode == "cancel" {
                    cancel.cancel();
                }
                if mode == "close" {
                    assert!(
                        matches!(read(&mut socket), Some(AgentRequest::Stdin { data }) if data.is_empty())
                    );
                }
                assert!(read(&mut socket).is_none());
            });
            if mode == "close" {
                input.send(TerminalControl::Close).unwrap();
            }
            let result = run_terminal_agent(config, receiver, |_| Ok(())).unwrap();
            peer.join().unwrap();
            assert_eq!(
                result.failure,
                Some(match mode {
                    "close" => TerminalFailure::CloseDeadline,
                    "cancel" => TerminalFailure::Cancelled,
                    _ => TerminalFailure::SessionDeadline,
                })
            );
        }
    }

    #[test]
    fn input_limit_consumer_loss_and_oversized_reply_close_only_existing_agent_io() {
        for mode in ["input", "consumer", "reply"] {
            let directory = tempfile::tempdir_in("/tmp").unwrap();
            let root = directory.path().canonicalize().unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
            let listener = UnixListener::bind(root.join("agent.sock")).unwrap();
            let mut config = request(root);
            config.options.total_input_bytes = 1;
            let (input, receiver) = mpsc::channel();
            let peer = std::thread::spawn(move || {
                let mut socket = accept(&listener);
                assert!(matches!(read(&mut socket), Some(AgentRequest::Run { .. })));
                socket
                    .write_all(&encode_message(&AgentResponse::Started).unwrap())
                    .unwrap();
                assert!(matches!(
                    read(&mut socket),
                    Some(AgentRequest::Resize { .. })
                ));
                if mode == "reply" {
                    socket.write_all(&10_000_000u32.to_be_bytes()).unwrap();
                } else {
                    socket
                        .write_all(
                            &encode_message(&AgentResponse::Stdout { data: vec![0, 255] }).unwrap(),
                        )
                        .unwrap();
                }
                assert!(read(&mut socket).is_none());
            });
            let result = run_terminal_agent(config, receiver, |_| {
                if mode == "input" {
                    input.send(TerminalControl::Input(vec![0, 255])).unwrap();
                }
                if mode == "consumer" {
                    Err(())
                } else {
                    Ok(())
                }
            })
            .unwrap();
            peer.join().unwrap();
            assert_eq!(
                result.failure,
                Some(match mode {
                    "input" => TerminalFailure::InputLimit,
                    "consumer" => TerminalFailure::ConsumerLost,
                    _ => TerminalFailure::OutputLimit,
                })
            );
        }
    }
}
