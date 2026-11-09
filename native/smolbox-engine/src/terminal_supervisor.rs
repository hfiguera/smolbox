//! Owned parent-side terminal collection. Retired jobs keep their leases until
//! their exact Child handle is collected; no PID scan or timeout releases them.
use crate::terminal_ipc::{Decoder, Direction, Frame, Identity, Payload, Proof, Startup};
use crate::transfer_supervisor::{Spool, TransferSupervisor};
use crate::{
    Cancellation, Dispatch, Error, ErrorCode, Result, TerminalFailure, TerminalOptions,
    TerminalOutcome,
};
use std::io::{Read, Write};
use std::os::{
    fd::AsRawFd,
    unix::fs::{MetadataExt, PermissionsExt},
};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(5);
pub struct TerminalOutput {
    pub sequence: u64,
    pub stderr: bool,
    pub bytes: Vec<u8>,
}
pub enum TerminalEvent {
    Opened,
    Output(TerminalOutput),
}
pub struct TerminalRunResult {
    pub outcome: TerminalOutcome,
    pub dispatch: Dispatch,
    pub collected: bool,
}
pub enum TerminalMessage {
    Attach,
    Command(crate::TerminalControl),
    Consumed { sequence: u64, bytes: u64 },
    Cancel,
}
pub struct TerminalRequest {
    pub options: TerminalOptions,
    pub deadline: Instant,
    pub cancel: Cancellation,
}
impl crate::Engine {
    /// Receipt-bound image eligibility only. This neither starts a stopped VM
    /// nor reserves a terminal/worker, probes an agent or opens a PTY. Opening
    /// must independently recheck the original authority and current state.
    pub fn terminal_preflight(
        &self,
        receipt: &crate::CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        if budget.deadline().saturating_duration_since(Instant::now()) > Duration::from_secs(30) {
            return Err(Error::before(ErrorCode::Validation));
        }
        receipt.validate(self.binding())?;
        let _permit = self.jobs.acquire(crate::jobs::Demand::observation())?;
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let record = self
            .observation_record(&receipt.name, budget)?
            .ok_or(Error::before(ErrorCode::NotFound))?;
        self.verify_record(receipt, &record)?;
        terminal_eligibility(&record)?;
        budget.check()
    }

    pub fn terminal_owned(
        &self,
        receipt: &crate::CreationReceipt,
        request: TerminalRequest,
        controls: impl FnMut() -> std::result::Result<Option<TerminalMessage>, ()>,
        output: impl FnMut(TerminalEvent) -> std::result::Result<(), ()>,
    ) -> Result<TerminalRunResult> {
        self.terminal_owned_mode(receipt, request, controls, output, None)
    }

    pub fn terminal_owned_with_volume_policy(
        &self,
        receipt: &crate::CreationReceipt,
        request: TerminalRequest,
        controls: impl FnMut() -> std::result::Result<Option<TerminalMessage>, ()>,
        output: impl FnMut(TerminalEvent) -> std::result::Result<(), ()>,
        policy: &crate::LocalVolumePolicy,
    ) -> Result<TerminalRunResult> {
        self.terminal_owned_mode(receipt, request, controls, output, Some(policy))
    }

    fn terminal_owned_mode(
        &self,
        receipt: &crate::CreationReceipt,
        request: TerminalRequest,
        mut controls: impl FnMut() -> std::result::Result<Option<TerminalMessage>, ()>,
        mut output: impl FnMut(TerminalEvent) -> std::result::Result<(), ()>,
        policy: Option<&crate::LocalVolumePolicy>,
    ) -> Result<TerminalRunResult> {
        request.options.validate()?;
        let deadline = request
            .deadline
            .min(Instant::now() + request.options.session);
        let record = self.guest_work_record(receipt)?;
        terminal_eligibility(&record)?;
        let command = crate::BufferedCommand {
            argv: vec![request.options.program.clone()],
            env: vec![],
            workdir: None,
            user: None,
            stdin: None,
            timeout: request.options.session,
            max_output_bytes: request.options.max_buffer_bytes,
        };
        let metadata = crate::buffered::Metadata::new(&record, command, deadline)?;
        metadata.terminal(&request.options)?;
        let mount_budget = crate::ReadBudget::new(
            deadline
                .saturating_duration_since(Instant::now())
                .min(Duration::from_secs(30))
                .max(Duration::from_nanos(1)),
            request.cancel.clone(),
        )?;
        let mounts = self.worker_mounts(receipt, &record, policy, &mount_budget)?;
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source = self.source_lease(receipt)?;
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let bytes =
            serde_json::to_vec(&metadata).map_err(|_| Error::before(ErrorCode::Validation))?;
        let (permit, mount_authority) = self.reserve_mounted_worker(
            receipt,
            mounts,
            crate::jobs::Demand::terminal(&request.options, bytes.len() as u64)?,
            &mount_budget,
        )?;
        let prepared = supervisor.prepare_terminal_reserved(
            permit,
            &self.transfer_directory()?,
            self.vm_directory(&receipt.name).join("agent.sock"),
            &bytes,
            request.options,
        )?;
        if self.inspect(receipt)?.state != crate::ObservedState::Running {
            return Err(Error::before(ErrorCode::State));
        }
        supervisor.run_terminal(
            prepared,
            Box::new((machine, source, self.domain.clone(), mount_authority)),
            deadline,
            &request.cancel,
            &mut || {
                controls().map(|value| {
                    value.map(|value| match value {
                        TerminalMessage::Attach => Payload::Attach,
                        TerminalMessage::Consumed { sequence, bytes } => {
                            Payload::Credit { sequence, bytes }
                        }
                        TerminalMessage::Cancel => Payload::Cancel,
                        TerminalMessage::Command(command) => match command {
                            crate::TerminalControl::Input(bytes) => Payload::Input(bytes),
                            crate::TerminalControl::Resize { cols, rows } => {
                                Payload::Resize { cols, rows }
                            }
                            crate::TerminalControl::Close => Payload::Close,
                        },
                    })
                })
            },
            &mut output,
        )
    }
}

fn terminal_eligibility(record: &smolvm::config::VmRecord) -> Result<()> {
    if record.forkpoint_held {
        return Err(Error::before(ErrorCode::State));
    }
    if record.image.as_ref().is_none_or(|image| image.is_empty()) || record.forkable_on_start() {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(())
}
pub(crate) struct Prepared {
    startup: Startup,
    metadata: Spool,
    _permit: crate::jobs::JobLease,
}
struct Owned {
    child: Child,
    input: Option<ChildStdin>,
    output: Option<ChildStdout>,
    _prepared: Prepared,
    _leases: Box<dyn Send>,
}
fn nonblocking(fd: i32) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(Error::before(ErrorCode::Io));
    }
    Ok(())
}
fn nonce() -> Result<String> {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).map_err(|_| Error::before(ErrorCode::Native))?;
    Ok(hex::encode(bytes))
}
impl TransferSupervisor {
    #[cfg(test)]
    pub(crate) fn prepare_terminal(
        &self,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        options: TerminalOptions,
    ) -> Result<Prepared> {
        let permit = self
            .pool
            .acquire(crate::jobs::Demand::terminal(&options, bytes.len() as u64)?)?;
        self.prepare_terminal_reserved(permit, directory, socket, bytes, options)
    }

    pub(crate) fn prepare_terminal_reserved(
        &self,
        permit: crate::jobs::JobLease,
        directory: &Path,
        socket: PathBuf,
        bytes: &[u8],
        options: TerminalOptions,
    ) -> Result<Prepared> {
        crate::jobs::Demand::terminal(&options, bytes.len() as u64)?;
        let mut metadata = Spool::new(directory)?;
        metadata
            .file
            .write_all(bytes)
            .and_then(|()| metadata.file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        metadata
            .file
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let stat = metadata
            .file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let startup = Startup {
            schema: 1,
            epoch: self
                .epoch
                .as_ref()
                .map_or_else(nonce, |epoch| Ok(epoch.identity()))?,
            operation: nonce()?,
            owner: self.owner,
            socket,
            staging: directory.into(),
            metadata: crate::transfer_worker::Blob {
                path: metadata.path.clone(),
                device: stat.dev(),
                inode: stat.ino(),
                bytes: bytes.len() as u64,
            },
            options,
        };
        let encoded =
            serde_json::to_vec(&startup).map_err(|_| Error::before(ErrorCode::Validation))?;
        if encoded.len() > crate::terminal_ipc::MAX_STARTUP {
            return Err(Error::before(ErrorCode::Validation));
        }
        Startup::read(
            &mut [(encoded.len() as u32).to_be_bytes().to_vec(), encoded]
                .concat()
                .as_slice(),
        )?;
        Ok(Prepared {
            startup,
            metadata,
            _permit: permit,
        })
    }

    /// Callbacks must be finite/nonblocking. Queuing output returns no credit:
    /// the bridge sends an explicit Credit only after whole consumer removal.
    pub(crate) fn run_terminal(
        &self,
        prepared: Prepared,
        leases: Box<dyn Send>,
        deadline: Instant,
        cancel: &Cancellation,
        controls: &mut dyn FnMut() -> std::result::Result<Option<Payload>, ()>,
        output: &mut dyn FnMut(TerminalEvent) -> std::result::Result<(), ()>,
    ) -> Result<TerminalRunResult> {
        if Instant::now() >= deadline || cancel.is_cancelled() {
            return Err(Error::before(ErrorCode::State));
        }
        crate::host::verified_executable(&self.executable)?;
        prepared.metadata.verify()?;
        let identity = Identity {
            epoch: prepared.startup.epoch.clone(),
            operation: prepared.startup.operation.clone(),
        };
        let startup = serde_json::to_vec(&prepared.startup)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        let mut pending = [(startup.len() as u32).to_be_bytes().to_vec(), startup].concat();
        let grace = prepared.startup.options.close + Duration::from_secs(1);
        let mut child = Command::new(&self.executable.path)
            .arg("--terminal-worker")
            .env_clear()
            .env(
                if cfg!(target_os = "macos") {
                    "DYLD_LIBRARY_PATH"
                } else {
                    "LD_LIBRARY_PATH"
                },
                std::env::join_paths([&self.libraries])
                    .map_err(|_| Error::before(ErrorCode::Validation))?,
            )
            .current_dir(&prepared.startup.staging)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let birth = smolvm::process::process_start_time(child.id() as i32);
        let input = child.stdin.take();
        let stream = child.stdout.take();
        let mut owned = Owned {
            child,
            input,
            output: stream,
            _prepared: prepared,
            _leases: leases,
        };
        let mut reason = None;
        let mut retirement = None;
        let mut sent = 0usize;
        let mut written = false;
        let mut control_seq = 0u64;
        let mut eof = false;
        let mut ready = false;
        let mut proof: Option<Proof> = None;
        let setup = owned
            .input
            .as_ref()
            .is_some_and(|pipe| nonblocking(pipe.as_raw_fd()).is_ok())
            && owned
                .output
                .as_ref()
                .is_some_and(|pipe| nonblocking(pipe.as_raw_fd()).is_ok());
        let enrolled = self.epoch.as_ref().is_none_or(|epoch| {
            birth.is_some_and(|birth| {
                epoch
                    .register_transfer(
                        crate::OwnerIdentity {
                            pid: owned.child.id() as i32,
                            birth,
                            uid: self.owner.uid,
                        },
                        &identity.operation,
                        owned
                            ._prepared
                            .startup
                            .socket
                            .parent()
                            .and_then(|path| path.file_name())
                            .and_then(|name| name.to_str())
                            .unwrap_or(""),
                    )
                    .is_ok()
            })
        });
        if !setup || !enrolled {
            reason = Some(TerminalFailure::Native);
            retirement = Some(Instant::now());
            owned.input.take();
            if !setup {
                owned.output.take();
                eof = true;
            }
        }
        let mut decoder = Decoder::new(identity.clone(), Direction::Worker)?;
        loop {
            let now = Instant::now();
            if reason.is_none() && (now >= deadline || cancel.is_cancelled()) {
                reason = Some(if cancel.is_cancelled() {
                    TerminalFailure::Cancelled
                } else {
                    TerminalFailure::SessionDeadline
                });
            }
            if reason.is_none()
                && ready
                && owned.input.is_some()
                && sent == pending.len()
                && proof.is_none()
            {
                match controls() {
                    Ok(Some(payload))
                        if !matches!(
                            payload,
                            Payload::Ready | Payload::Output { .. } | Payload::End(_)
                        ) =>
                    {
                        match crate::terminal_ipc::encode(&Frame {
                            identity: identity.clone(),
                            sequence: control_seq,
                            payload,
                        }) {
                            Ok(bytes) => {
                                pending = bytes;
                                sent = 0;
                                match control_seq.checked_add(1) {
                                    Some(next) => control_seq = next,
                                    None => reason = Some(TerminalFailure::Protocol),
                                }
                            }
                            Err(_) => reason = Some(TerminalFailure::Protocol),
                        }
                    }
                    Ok(None) => {}
                    _ => reason = Some(TerminalFailure::ConsumerLost),
                }
            }
            if reason.is_some() && retirement.is_none() {
                retirement = Some(now);
                owned.input.take();
            }
            if reason.is_none() && owned.input.is_some() && sent < pending.len() {
                match owned.input.as_mut().unwrap().write(&pending[sent..]) {
                    Ok(0) => reason = Some(TerminalFailure::Native),
                    Ok(n) => {
                        sent += n;
                        written = true;
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                        ) => {}
                    Err(e) if ready && e.kind() == std::io::ErrorKind::BrokenPipe => {
                        // A normally exiting worker can close its control pipe
                        // before we send the last output credit. Keep draining
                        // its result pipe: only a valid correlated End and
                        // successful exact-child collection can confirm Exit.
                        // No more controls can be delivered; bound that final
                        // drain by the existing retirement grace and deadline.
                        owned.input.take();
                        pending.clear();
                        sent = 0;
                        retirement = Some(now);
                    }
                    Err(_) => reason = Some(TerminalFailure::Native),
                }
            }
            if setup && !eof {
                let mut buffer = [0; 8192];
                for _ in 0..8 {
                    match owned.output.as_mut().unwrap().read(&mut buffer) {
                        Ok(0) => {
                            eof = true;
                            break;
                        }
                        Ok(n) => {
                            if reason.is_some() {
                                continue;
                            }
                            let mut bytes = &buffer[..n];
                            while !bytes.is_empty() {
                                match decoder.feed(bytes) {
                                    Ok((used, event)) => {
                                        bytes = &bytes[used..];
                                        match event.map(|frame| (frame.sequence, frame.payload)) {
                                            Some((_, Payload::Ready)) => {
                                                ready = true;
                                                if output(TerminalEvent::Opened).is_err() {
                                                    reason = Some(TerminalFailure::ConsumerLost);
                                                    break;
                                                }
                                            }
                                            Some((sequence, Payload::Output { stderr, bytes })) => {
                                                if output(TerminalEvent::Output(TerminalOutput {
                                                    sequence,
                                                    stderr,
                                                    bytes,
                                                }))
                                                .is_err()
                                                {
                                                    reason = Some(TerminalFailure::ConsumerLost);
                                                    break;
                                                }
                                            }
                                            Some((_, Payload::End(value))) => proof = Some(value),
                                            None => {}
                                            _ => {
                                                reason = Some(TerminalFailure::Protocol);
                                                break;
                                            }
                                        }
                                    }
                                    Err(_) => {
                                        reason = Some(TerminalFailure::Protocol);
                                        break;
                                    }
                                }
                            }
                        }
                        Err(e)
                            if matches!(
                                e.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                            ) =>
                        {
                            break
                        }
                        Err(_) => {
                            reason = Some(TerminalFailure::Native);
                            break;
                        }
                    }
                }
            }
            let status = match owned.child.try_wait() {
                Ok(status) => status,
                Err(_) => {
                    if reason.is_none() {
                        reason = Some(TerminalFailure::Native);
                    }
                    None
                }
            };
            if let Some(status) = status.filter(|_| !setup || eof) {
                let complete = status.success() && decoder.finish().is_ok() && proof.is_some();
                let failure = reason.or_else(|| {
                    if complete {
                        proof.as_ref().and_then(|p| p.failure)
                    } else {
                        Some(TerminalFailure::Native)
                    }
                });
                let result = TerminalRunResult {
                    outcome: TerminalOutcome {
                        observed_exit: proof.as_ref().and_then(|p| p.observed_exit),
                        failure,
                    },
                    dispatch: if written {
                        Dispatch::MayHaveDispatched
                    } else {
                        Dispatch::NotDispatched
                    },
                    collected: true,
                };
                drop(owned);
                return Ok(result);
            }
            if eof && proof.is_none() && reason.is_none() {
                reason = Some(TerminalFailure::Native);
            }
            if retirement.is_some_and(|at| now.saturating_duration_since(at) >= grace) {
                self.pool.quarantine();
                let result = TerminalRunResult {
                    outcome: TerminalOutcome {
                        observed_exit: proof.as_ref().and_then(|p| p.observed_exit),
                        failure: reason.or(Some(TerminalFailure::Uncollected)),
                    },
                    dispatch: if written {
                        Dispatch::MayHaveDispatched
                    } else {
                        Dispatch::NotDispatched
                    },
                    collected: false,
                };
                retain(owned);
                return Ok(result);
            }
            std::thread::sleep(POLL);
        }
    }
}
fn retain(owned: Owned) {
    let (sender, receiver) = std::sync::mpsc::sync_channel::<Owned>(1);
    let collector = std::thread::Builder::new()
        .name("smolbox-terminal-collect".into())
        .spawn(move || {
            if let Ok(mut owned) = receiver.recv() {
                loop {
                    if let Some(output) = &mut owned.output {
                        let mut bytes = [0; 8192];
                        for _ in 0..4 {
                            if !matches!(output.read(&mut bytes), Ok(1..)) {
                                break;
                            }
                        }
                    }
                    if owned.child.try_wait().ok().flatten().is_some() {
                        return;
                    }
                    std::thread::sleep(POLL);
                }
            }
        });
    if collector.is_ok() {
        if let Err(error) = sender.send(owned) {
            Box::leak(Box::new(error.0));
        }
    } else {
        Box::leak(Box::new(owned));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use smolvm_protocol::{encode_message, AgentRequest, AgentResponse, Envelope};
    use std::os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
    };
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    };

    fn preflight_budget() -> crate::ReadBudget {
        crate::ReadBudget::new(Duration::from_secs(5), Cancellation::default()).unwrap()
    }

    #[test]
    fn stopped_image_preflight_reads_original_authority_without_allocating_terminal_work() {
        let root = tempfile::tempdir().unwrap();
        let (native, receipt) = crate::export_source::tests::fixture(root.path(), true);
        let before = serde_json::to_vec(&native.db.get_vm(&receipt.name).unwrap()).unwrap();
        let work = (0..crate::JOB_WORK_SLOTS)
            .map(|_| {
                native
                    .jobs
                    .acquire(crate::jobs::Demand::streaming())
                    .unwrap()
            })
            .collect::<Vec<_>>();
        let counts = native.jobs.counts();
        assert!(native.transfers.is_none());
        native
            .terminal_preflight(&receipt, &preflight_budget())
            .unwrap();
        assert_eq!(native.jobs.counts(), counts);
        assert_eq!(
            before,
            serde_json::to_vec(&native.db.get_vm(&receipt.name).unwrap()).unwrap()
        );
        assert_eq!(native.runtime_pid(&receipt.name), None);
        assert!(native.owned_managers.lock().unwrap().is_empty());
        drop(work);
    }

    #[test]
    fn preflight_rejects_bare_empty_image_branchable_and_held_records_without_mutation() {
        for kind in 0..4 {
            let root = tempfile::tempdir().unwrap();
            let (native, receipt) =
                crate::export_source::tests::fixture_record(root.path(), kind != 0, |record| {
                    match kind {
                        1 => record.image = Some(String::new()),
                        2 => record.forkable = true,
                        3 => record.forkpoint_held = true,
                        _ => {}
                    }
                });
            let before = serde_json::to_vec(&native.db.get_vm(&receipt.name).unwrap()).unwrap();
            let error = native
                .terminal_preflight(&receipt, &preflight_budget())
                .unwrap_err();
            assert_eq!(error.dispatch, Dispatch::NotDispatched);
            assert!(matches!(
                error.code,
                ErrorCode::Unsupported | ErrorCode::State
            ));
            assert_eq!(
                before,
                serde_json::to_vec(&native.db.get_vm(&receipt.name).unwrap()).unwrap()
            );
            assert_eq!(native.jobs.counts(), crate::jobs::Counts::default());
        }
    }

    #[test]
    fn preflight_bounds_cancellation_rows_and_machine_conflicts_and_rejects_foreign_authority() {
        let root = tempfile::tempdir().unwrap();
        let (native, receipt) = crate::export_source::tests::fixture(root.path(), true);
        let long =
            crate::ReadBudget::for_volume_work(Duration::from_secs(3600), Cancellation::default())
                .unwrap();
        assert_eq!(
            native.terminal_preflight(&receipt, &long).unwrap_err().code,
            ErrorCode::Validation
        );
        let mut missing = receipt.clone();
        missing.name = "missing".into();
        assert_eq!(
            native
                .terminal_preflight(&missing, &preflight_budget())
                .unwrap_err()
                .code,
            ErrorCode::NotFound
        );
        assert!(!native.vm_directory(&missing.name).exists());
        let cancel = Cancellation::default();
        let budget = crate::ReadBudget::new(Duration::from_secs(5), cancel.clone()).unwrap();
        cancel.cancel();
        assert!(native.terminal_preflight(&receipt, &budget).is_err());
        let gate = native.observation_gate(&receipt.name).unwrap();
        let held = gate.try_lock().unwrap();
        assert_eq!(
            native
                .terminal_preflight(&receipt, &preflight_budget())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(held);
        let mut foreign = receipt.clone();
        foreign.owner_token = "f".repeat(64);
        assert_eq!(
            native
                .terminal_preflight(&foreign, &preflight_budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        native
            .db
            .update_vm(&receipt.name, |record| {
                record.env.push((
                    "oversized".into(),
                    "x".repeat(crate::observations::MAX_RECORD_BYTES + 1),
                ));
            })
            .unwrap();
        assert_eq!(
            native
                .terminal_preflight(&receipt, &preflight_budget())
                .unwrap_err()
                .code,
            ErrorCode::OutputLimit
        );
        assert_eq!(native.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    #[ignore = "requires built helper; explicit ordinary non-VM supervised terminal peer"]
    fn ordinary_terminal_supervisor_holds_leases_until_exact_normal_collection() {
        ordinary_terminal_peer(false, Some(7));
    }

    #[test]
    #[ignore = "requires built helper; explicit ordinary non-VM terminal natural-exit peer"]
    fn ordinary_terminal_natural_exit_preserves_final_output_and_collected_exit() {
        for _ in 0..16 {
            ordinary_terminal_peer(true, Some(7));
        }
    }

    #[test]
    #[ignore = "requires built helper; explicit ordinary non-VM terminal result peer"]
    fn ordinary_terminal_eof_and_ambiguous_exit_do_not_confirm_completion() {
        for exit in [None, Some(124), Some(130)] {
            ordinary_terminal_peer(true, exit);
        }
    }

    fn ordinary_terminal_peer(natural_exit: bool, exit: Option<i32>) {
        fn read(socket: &mut UnixStream) -> AgentRequest {
            let mut header = [0; 4];
            socket.read_exact(&mut header).unwrap();
            let mut data = vec![0; u32::from_be_bytes(header) as usize];
            socket.read_exact(&mut data).unwrap();
            serde_json::from_slice::<Envelope<AgentRequest>>(&data)
                .unwrap()
                .body
        }
        struct Lease(Arc<AtomicBool>);
        impl Drop for Lease {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let root = directory.path().canonicalize().unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let executable =
            PathBuf::from(std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper"));
        let identity = crate::Executable {
            sha256: hex::encode(Sha256::digest(std::fs::read(&executable).unwrap())),
            path: executable,
        };
        let host = crate::HostContext::capture(
            crate::DomainBinding {
                target_id: "owned".into(),
                generation: "a".repeat(32),
                database: root.join("db"),
                vm_root: root.clone(),
            },
            "b".repeat(32),
            "c".repeat(64),
            crate::ExecutableLocator {
                boot: identity.clone(),
                file_worker: identity,
                library_directory: std::env::var_os("LIBKRUN_BUNDLE")
                    .map_or_else(|| root.clone(), PathBuf::from),
            },
        )
        .unwrap();
        let pool = crate::jobs::JobPool::default();
        let supervisor = TransferSupervisor::new(&host, pool.clone()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        let options = TerminalOptions {
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
        };
        let mut record =
            smolvm::config::VmRecord::new("0123456789abcdef".into(), 1, 512, vec![], vec![], false);
        record.image = Some("local-dir:/fixture".into());
        let command = crate::BufferedCommand {
            argv: vec!["/bin/sh".into()],
            env: vec![],
            workdir: None,
            user: None,
            stdin: None,
            timeout: Duration::from_secs(30),
            max_output_bytes: 1024,
        };
        let metadata = crate::buffered::Metadata::new(&record, command, deadline).unwrap();
        let socket = root.join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let peer = std::thread::spawn(move || {
            let mut socket = loop {
                match listener.accept() {
                    Ok((s, _)) => break s,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline);
                        std::thread::sleep(POLL);
                    }
                    Err(_) => panic!("normal SDK peer accept failed"),
                }
            };
            socket.set_nonblocking(false).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            assert!(matches!(
                read(&mut socket),
                AgentRequest::Run { tty: true, .. }
            ));
            socket
                .write_all(&encode_message(&AgentResponse::Started).unwrap())
                .unwrap();
            assert!(matches!(
                read(&mut socket),
                AgentRequest::Resize {
                    cols: 100,
                    rows: 37
                }
            ));
            let output = encode_message(&AgentResponse::Stdout {
                data: vec![0, 255, 128],
            })
            .unwrap();
            if natural_exit {
                let mut frames = output;
                if let Some(exit_code) = exit {
                    frames.extend(
                        encode_message(&AgentResponse::Exited {
                            exit_code,
                            oom: false,
                        })
                        .unwrap(),
                    );
                }
                socket.write_all(&frames).unwrap();
                return;
            }
            socket.write_all(&output).unwrap();
            assert!(matches!(read(&mut socket), AgentRequest::Stdin { data } if data == [255, 0]));
            assert!(matches!(read(&mut socket), AgentRequest::Stdin { data } if data.is_empty()));
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
        let prepared = supervisor
            .prepare_terminal(
                &root,
                socket,
                &serde_json::to_vec(&metadata).unwrap(),
                options,
            )
            .unwrap();
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().children, 1);
        let released = Arc::new(AtomicBool::new(false));
        let messages = Arc::new(Mutex::new(std::collections::VecDeque::from([
            Payload::Attach,
        ])));
        let source = messages.clone();
        let sink = messages.clone();
        let result = supervisor
            .run_terminal(
                prepared,
                Box::new(Lease(released.clone())),
                deadline,
                &Cancellation::new(),
                &mut || Ok(source.lock().unwrap().pop_front()),
                &mut |output| {
                    let TerminalEvent::Output(output) = output else {
                        return Ok(());
                    };
                    assert!(!released.load(Ordering::Acquire));
                    assert_eq!(pool.counts().work, 1);
                    assert_eq!(output.bytes, [0, 255, 128]);
                    let mut queue = sink.lock().unwrap();
                    queue.push_back(Payload::Credit {
                        sequence: output.sequence,
                        bytes: 3,
                    });
                    if !natural_exit {
                        queue.push_back(Payload::Input(vec![255, 0]));
                        queue.push_back(Payload::Close);
                    }
                    Ok(())
                },
            )
            .unwrap();
        assert!(result.collected);
        if exit == Some(7) {
            assert_eq!(
                result.outcome.confirmed_exit(),
                Some(7),
                "exit={:?}, failure={:?}",
                result.outcome.observed_exit,
                result.outcome.failure
            );
        } else {
            assert_eq!(result.outcome.confirmed_exit(), None);
            assert!(result.outcome.failure.is_some());
        }
        assert!(released.load(Ordering::Acquire));
        assert_eq!(pool.counts(), crate::jobs::Counts::default());
        peer.join().unwrap();
    }
}
