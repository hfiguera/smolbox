use crate::{adapter, output, package::Config};
use crossbeam_channel::{bounded, Receiver, Sender};
use smolbox_engine::{Cancellation, Engine};
use smolbox_protocol as wire;
use std::collections::{BTreeMap, VecDeque};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const WORKERS: usize = smolbox_engine::JOB_WORK_SLOTS;
const OBSERVATION_WORKERS: usize = smolbox_engine::JOB_CONTROL_SLOTS;
const CONTROL_WORKERS: usize = 2;
const MAX_INPUT_BYTES: usize = 4 * 1024 * 1024;
const MAX_UPLOAD_BYTES: u64 = 128 * 1024 * 1024;
const HANDSHAKE_GRACE: Duration = Duration::from_secs(5);
const CANCEL_GRACE: Duration = Duration::from_millis(wire::CANCEL_GRACE_MS);
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);
const WRITER_GRACE: u64 = 5000;

type BridgeResult<T> = Result<T, ()>;
struct Input {
    message: wire::ClientMessage,
    received: Instant,
    encoded: usize,
}
struct Work {
    id: u64,
    operation: wire::Operation,
    deadline: Instant,
    cancel: Cancellation,
    upload: Option<tempfile::NamedTempFile>,
}
struct Handle {
    terminal: Option<TerminalInbox>,
    cancel: Cancellation,
    started: bool,
    deadline: Instant,
    cancellation_requested: Option<Instant>,
    operation: wire::Operation,
    upload: Option<tempfile::NamedTempFile>,
    upload_reservation: u64,
}
struct TerminalInbox {
    controls: VecDeque<smolbox_engine::TerminalMessage>,
    credit: VecDeque<smolbox_engine::TerminalMessage>,
    outstanding: VecDeque<(u64, u64)>,
}
pub trait TerminalBridge {
    fn opened(&mut self) -> BridgeResult<()>;
    fn control(&mut self) -> BridgeResult<Option<smolbox_engine::TerminalMessage>>;
    fn output(&mut self, output: smolbox_engine::TerminalOutput) -> BridgeResult<()>;
}
struct TerminalChannel {
    shared: Arc<Shared>,
    id: u64,
}
impl TerminalBridge for TerminalChannel {
    fn opened(&mut self) -> BridgeResult<()> {
        let mut state = self.shared.state.lock().map_err(|_| ())?;
        self.shared
            .output
            .send(0, || state.session.terminal_opened(self.id).map_err(|_| ()))
    }
    fn control(&mut self) -> BridgeResult<Option<smolbox_engine::TerminalMessage>> {
        let mut state = self.shared.state.lock().map_err(|_| ())?;
        let handle = state.handles.get_mut(&self.id).ok_or(())?;
        if handle.cancel.is_cancelled() || handle.cancellation_requested.is_some() {
            return Err(());
        }
        let inbox = handle.terminal.as_mut().ok_or(())?;
        Ok(inbox
            .credit
            .pop_front()
            .or_else(|| inbox.controls.pop_front()))
    }
    fn output(&mut self, output: smolbox_engine::TerminalOutput) -> BridgeResult<()> {
        // Queue the mapping while holding the same registry lock as public
        // emission; consumption cannot race ahead of its private ticket.
        let mut state = self.shared.state.lock().map_err(|_| ())?;
        let deadline = state.handles.get(&self.id).ok_or(())?.deadline;
        loop {
            let handle = state.handles.get(&self.id).ok_or(())?;
            if state.closing
                || handle.cancellation_requested.is_some()
                || handle.cancel.is_cancelled()
            {
                return Err(());
            }
            if state.session.available_credit(self.id).map_err(|_| ())? >= output.bytes.len() as u64
                && state
                    .session
                    .available_event_credit(self.id)
                    .map_err(|_| ())?
                    > 0
            {
                break;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(());
            }
            state = self
                .shared
                .credit_changed
                .wait_timeout(state, remaining.min(Duration::from_millis(10)))
                .map_err(|_| ())?
                .0;
        }
        let handle = state.handles.get_mut(&self.id).ok_or(())?;
        let inbox = handle.terminal.as_mut().ok_or(())?;
        if inbox.outstanding.len() >= wire::INITIAL_CREDIT_EVENTS as usize {
            return Err(());
        }
        inbox
            .outstanding
            .push_back((output.sequence, output.bytes.len() as u64));
        self.shared.output.send(output.bytes.len(), || {
            state
                .session
                .event(self.id, wire::Stream::Terminal, &output.bytes)
                .map_err(|_| ())
        })
    }
}
struct State {
    session: wire::Session,
    handles: BTreeMap<u64, Handle>,
    upload_bytes: u64,
    approved: bool,
    closing: bool,
    unavailable: bool,
    reserved_observations: usize,
}
struct Shared {
    state: Mutex<State>,
    credit_changed: Condvar,
    output: output::Output,
    fatal: AtomicBool,
    eof: AtomicBool,
    writer_stop: AtomicBool,
    writer_done: AtomicBool,
    writer_started_ms: AtomicU64,
    origin: Instant,
    input_bytes: AtomicUsize,
    heartbeat_ms: AtomicU64,
    finished: AtomicBool,
}
struct Finished(Arc<Shared>);
impl Drop for Finished {
    fn drop(&mut self) {
        self.0.finished.store(true, Ordering::Release);
    }
}
impl Shared {
    fn terminal(&self, id: u64, outcome: wire::Outcome) -> BridgeResult<()> {
        let mut state = self.state.lock().map_err(|_| ())?;
        self.terminal_locked(&mut state, id, outcome)
    }
    fn finish_queued(&self, id: u64, code: wire::SafeCode) -> BridgeResult<()> {
        let mut state = self.state.lock().map_err(|_| ())?;
        if state.handles.get(&id).is_some_and(|h| !h.started) {
            self.terminal_locked(&mut state, id, before(code))?;
        }
        Ok(())
    }
    fn terminal_locked(
        &self,
        state: &mut State,
        id: u64,
        outcome: wire::Outcome,
    ) -> BridgeResult<()> {
        if !state.handles.contains_key(&id) {
            return Ok(());
        }
        self.output
            .send(0, || state.session.terminal(id, outcome).map_err(|_| ()))?;
        let handle = state.handles.remove(&id).ok_or(())?;
        state.upload_bytes -= handle.upload_reservation;
        Ok(())
    }
    fn event(&self, id: u64, stream: wire::Stream, bytes: &[u8]) -> BridgeResult<()> {
        let mut state = self.state.lock().map_err(|_| ())?;
        let credit_deadline = state
            .handles
            .get(&id)
            .ok_or(())?
            .deadline
            .min(Instant::now() + Duration::from_secs(1));
        loop {
            let handle = state.handles.get(&id).ok_or(())?;
            if state.closing
                || handle.cancellation_requested.is_some()
                || handle.cancel.is_cancelled()
            {
                return Err(());
            }
            if state.session.available_credit(id).map_err(|_| ())? >= bytes.len() as u64
                && state.session.available_event_credit(id).map_err(|_| ())? > 0
            {
                break;
            }
            let remaining = credit_deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(());
            }
            state = self
                .credit_changed
                .wait_timeout(state, remaining)
                .map_err(|_| ())?
                .0;
        }
        self.output.send(bytes.len(), || {
            state.session.event(id, stream, bytes).map_err(|_| ())
        })
    }
    fn cancel(&self, id: u64, controls: &Sender<Cancellation>) -> BridgeResult<()> {
        let mut state = self.state.lock().map_err(|_| ())?;
        let Some(handle) = state.handles.get_mut(&id) else {
            return Ok(());
        };
        if handle.cancellation_requested.is_none() {
            handle.cancellation_requested = Some(Instant::now());
            controls.try_send(handle.cancel.clone()).map_err(|_| ())?;
            self.credit_changed.notify_all();
        }
        Ok(())
    }
}

pub trait Native: Send + Sync + 'static {
    fn create_registry_prepared(
        &self,
        _create: wire::RegistryCreate,
        _size: u64,
        _approval: crate::package::RegistryApproval,
        _remaining: Duration,
        _cancel: Cancellation,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
    fn prepare_artifact(
        &self,
        _approval: crate::package::RegistryApproval,
        _token: Option<wire::RegistryToken>,
        _remaining: Duration,
        _cancel: Cancellation,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
    fn terminal(
        &self,
        _receipt: wire::Receipt,
        _spec: wire::TerminalSpec,
        _remaining: Duration,
        _cancel: Cancellation,
        _bridge: &mut dyn TerminalBridge,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
    fn available(&self) -> bool {
        true
    }
    fn run(
        &self,
        operation: wire::Operation,
        remaining: Duration,
        cancel: Cancellation,
        upload: Option<File>,
        emit: &mut dyn FnMut(wire::Stream, &[u8]) -> BridgeResult<()>,
    ) -> wire::Outcome;
    fn shutdown(&self) -> BridgeResult<()>;
}
impl Native for Engine {
    fn create_registry_prepared(
        &self,
        create: wire::RegistryCreate,
        size: u64,
        approval: crate::package::RegistryApproval,
        remaining: Duration,
        cancel: Cancellation,
    ) -> wire::Outcome {
        adapter::create_registry_prepared(self, create, size, approval, remaining, cancel)
    }
    fn prepare_artifact(
        &self,
        approval: crate::package::RegistryApproval,
        token: Option<wire::RegistryToken>,
        remaining: Duration,
        cancel: Cancellation,
    ) -> wire::Outcome {
        adapter::prepare_artifact(self, approval, token, remaining, cancel)
    }
    fn terminal(
        &self,
        receipt: wire::Receipt,
        spec: wire::TerminalSpec,
        remaining: Duration,
        cancel: Cancellation,
        bridge: &mut dyn TerminalBridge,
    ) -> wire::Outcome {
        adapter::terminal(self, receipt, spec, remaining, cancel, bridge)
    }
    fn available(&self) -> bool {
        Engine::available(self)
    }
    fn run(
        &self,
        operation: wire::Operation,
        remaining: Duration,
        cancel: Cancellation,
        upload: Option<File>,
        emit: &mut dyn FnMut(wire::Stream, &[u8]) -> BridgeResult<()>,
    ) -> wire::Outcome {
        adapter::run(self, operation, remaining, cancel, upload, emit)
    }
    fn shutdown(&self) -> BridgeResult<()> {
        if Engine::shutdown(self)
            .iter()
            .any(|(_, result)| result.is_err())
        {
            Err(())
        } else {
            Ok(())
        }
    }
}

pub fn serve(engine: Engine, hello: wire::Hello, config: Config) -> BridgeResult<()> {
    // Owned temp directory, independent of shared inventory. No prefix cleanup.
    let spools = tempfile::Builder::new()
        .prefix("port-uploads-")
        .tempdir_in(
            engine
                .binding()
                .database
                .parent()
                .ok_or(())?
                .join("smolbox"),
        )
        .map_err(|_| ())?;
    serve_io(
        std::io::stdin(),
        std::io::stdout(),
        Arc::new(engine),
        hello,
        config,
        spools,
    )
}
fn serve_io(
    input: impl Read + Send + 'static,
    writer: impl Write + Send + 'static,
    native: Arc<dyn Native>,
    hello: wire::Hello,
    config: Config,
    spools: tempfile::TempDir,
) -> BridgeResult<()> {
    let (output, frames) = output::Output::new();
    let shared = Arc::new(Shared {
        state: Mutex::new(State {
            session: wire::Session::new(hello.clone()).map_err(|_| ())?,
            handles: BTreeMap::new(),
            upload_bytes: 0,
            approved: false,
            closing: false,
            unavailable: false,
            reserved_observations: if hello.major == wire::PARITY_PROTOCOL_MAJOR
                && hello
                    .sdk
                    .as_ref()
                    .is_some_and(|sdk| sdk.feature_versions.get("job_resources") == Some(&1))
            {
                OBSERVATION_WORKERS
            } else {
                0
            },
        }),
        output,
        fatal: AtomicBool::new(false),
        eof: AtomicBool::new(false),
        writer_stop: AtomicBool::new(false),
        writer_done: AtomicBool::new(false),
        writer_started_ms: AtomicU64::new(0),
        origin: Instant::now(),
        input_bytes: AtomicUsize::new(0),
        credit_changed: Condvar::new(),
        heartbeat_ms: AtomicU64::new(0),
        finished: AtomicBool::new(false),
    });
    let _finished = Finished(shared.clone());
    #[cfg(not(test))]
    {
        let watchdog = shared.clone();
        std::thread::spawn(move || {
            while !watchdog.finished.load(Ordering::Acquire) {
                let elapsed = watchdog.origin.elapsed().as_millis() as u64;
                if elapsed.saturating_sub(watchdog.heartbeat_ms.load(Ordering::Acquire)) > 10_000 {
                    // Includes stalled upload I/O or a poisoned/stuck registry.
                    // Process loss preserves uncertainty; no terminal is invented.
                    std::process::exit(2);
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });
    }
    shared.output.send(0, || {
        Ok(wire::ServerMessage::Hello {
            hello: hello.clone().into(),
        })
    })?;
    spawn_writer(shared.clone(), frames, writer);
    let (input_sender, inputs) = bounded(wire::MAX_IN_FLIGHT);
    let (jobs, work) = bounded::<Work>(wire::MAX_IN_FLIGHT);
    for _ in 0..WORKERS {
        spawn_worker(shared.clone(), native.clone(), work.clone(), config.clone());
    }
    let (observations, observation_work) = bounded::<Work>(wire::MAX_IN_FLIGHT);
    for _ in 0..OBSERVATION_WORKERS {
        spawn_worker(
            shared.clone(),
            native.clone(),
            observation_work.clone(),
            config.clone(),
        );
    }
    drop(observation_work);
    let (controls, cancellations) = bounded::<Cancellation>(wire::MAX_IN_FLIGHT);
    for _ in 0..CONTROL_WORKERS {
        let receiver = cancellations.clone();
        std::thread::spawn(move || {
            while let Ok(cancel) = receiver.recv() {
                cancel.cancel();
            }
        });
    }
    spawn_reader(
        shared.clone(),
        input_sender,
        input,
        controls.clone(),
        config,
    );
    drop(cancellations);
    drop(work);
    let result = loop {
        shared.heartbeat_ms.store(
            shared.origin.elapsed().as_millis() as u64,
            Ordering::Release,
        );
        if shared.fatal.load(Ordering::Acquire) {
            break Err(());
        }
        if shared.eof.load(Ordering::Acquire) {
            break Ok(());
        }
        if !native.available() {
            let mut state = shared.state.lock().map_err(|_| ())?;
            if state.approved && !state.unavailable {
                state.unavailable = true;
                shared.output.send(0, || {
                    Ok(wire::ServerMessage::Unavailable {
                        epoch: hello.epoch.clone(),
                    })
                })?;
            }
        }
        let writer_at = shared.writer_started_ms.load(Ordering::Acquire);
        if writer_at != 0
            && shared.origin.elapsed().as_millis() as u64 + 1 - writer_at > WRITER_GRACE
        {
            break Err(());
        }
        if tick(&shared, &controls).is_err() {
            break Err(());
        }
        match inputs.recv_timeout(Duration::from_millis(10)) {
            Ok(input) => {
                shared
                    .input_bytes
                    .fetch_sub(input.encoded, Ordering::AcqRel);
                match handle_input(&shared, &jobs, &observations, spools.path(), input) {
                    Ok(true) => break Ok(()),
                    Ok(false) => {}
                    Err(()) => break Err(()),
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                break if shared.fatal.load(Ordering::Acquire) {
                    Err(())
                } else {
                    Ok(())
                }
            }
        }
    };
    // Keep the account/domain lock held throughout cancellation and native
    // shutdown. A stuck call makes the whole channel uncertain; main exits and
    // owner-bound native children see parent loss. No disk deletion or adoption.
    {
        shared.state.lock().map_err(|_| ())?.closing = true;
    }
    let ids = shared
        .state
        .lock()
        .map_err(|_| ())?
        .handles
        .keys()
        .copied()
        .collect::<Vec<_>>();
    for id in ids {
        let _ = shared.cancel(id, &controls);
    }
    drop(jobs);
    drop(observations);
    let shutdown_at = Instant::now();
    while shared
        .state
        .lock()
        .map_err(|_| ())?
        .handles
        .values()
        .any(|h| h.started)
    {
        shared.heartbeat_ms.store(
            shared.origin.elapsed().as_millis() as u64,
            Ordering::Release,
        );
        if shutdown_at.elapsed() > CANCEL_GRACE {
            return Err(());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    // Drain queued requests as not dispatched, including unfinished uploads.
    let ids = shared
        .state
        .lock()
        .map_err(|_| ())?
        .handles
        .keys()
        .copied()
        .collect::<Vec<_>>();
    for id in ids {
        if shared
            .terminal(id, before(wire::SafeCode::Cancelled))
            .is_err()
        {
            shared.fatal.store(true, Ordering::Release);
        }
    }
    drop(controls);
    let shutdown_done = Arc::new(AtomicBool::new(false));
    let done = shutdown_done.clone();
    let shutdown_shared = shared.clone();
    std::thread::spawn(move || {
        if native.shutdown().is_err() {
            shutdown_shared.fatal.store(true, Ordering::Release);
        }
        done.store(true, Ordering::Release);
    });
    shared.writer_stop.store(true, Ordering::Release);
    while !shutdown_done.load(Ordering::Acquire) || !shared.writer_done.load(Ordering::Acquire) {
        shared.heartbeat_ms.store(
            shared.origin.elapsed().as_millis() as u64,
            Ordering::Release,
        );
        if shutdown_at.elapsed() > SHUTDOWN_GRACE {
            return Err(());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if shared.fatal.load(Ordering::Acquire) {
        Err(())
    } else {
        result
    }
}
fn before(code: wire::SafeCode) -> wire::Outcome {
    wire::Outcome::Error {
        code,
        dispatch: wire::Dispatch::NotDispatched,
    }
}
fn is_observation(operation: &wire::Operation) -> bool {
    matches!(
        operation,
        wire::Operation::Health
            | wire::Operation::Capacity
            | wire::Operation::Metrics
            | wire::Operation::Readiness
            | wire::Operation::List
            | wire::Operation::Measurements { .. }
            | wire::Operation::InspectGrowth { .. }
            | wire::Operation::InspectOciCreation { .. }
            | wire::Operation::InspectRegistryCreation { .. }
    )
}
fn tick(shared: &Shared, controls: &Sender<Cancellation>) -> BridgeResult<()> {
    let now = Instant::now();
    let (approved, expired, stuck) = {
        let state = shared.state.lock().map_err(|_| ())?;
        (
            state.approved,
            state
                .handles
                .iter()
                .filter(|(_, h)| {
                    now >= h.deadline || (h.cancellation_requested.is_some() && !h.started)
                })
                .map(|(id, h)| (*id, h.started, now >= h.deadline))
                .collect::<Vec<_>>(),
            state.handles.values().any(|h| {
                h.started
                    && h.cancellation_requested
                        .is_some_and(|at| now.duration_since(at) > CANCEL_GRACE)
            }),
        )
    };
    if (!approved && shared.origin.elapsed() > HANDSHAKE_GRACE) || stuck {
        return Err(());
    }
    for (id, _started, deadline) in expired {
        shared.cancel(id, controls)?;
        shared.finish_queued(
            id,
            if deadline {
                wire::SafeCode::Deadline
            } else {
                wire::SafeCode::Cancelled
            },
        )?;
    }
    Ok(())
}
fn admit_request(
    shared: &Shared,
    message: wire::ClientMessage,
    received: Instant,
    config: &Config,
) -> BridgeResult<bool> {
    let wire::ClientMessage::Request {
        id,
        operation,
        budget_ms,
        ..
    } = &message
    else {
        unreachable!()
    };
    let id = *id;
    let operation = operation.clone();
    let deadline = received + Duration::from_millis(*budget_ms);
    let upload_reservation = if let wire::Operation::WriteFile { total_bytes, .. } = operation {
        total_bytes
    } else {
        0
    };
    let mut state = shared.state.lock().map_err(|_| ())?;
    if state.closing {
        return Err(());
    }
    let selected_artifact = match &operation {
        wire::Operation::Create { create } | wire::Operation::InspectCreation { create } => {
            Some(&create.artifact)
        }
        wire::Operation::QualifyCreation { artifact, .. } => Some(artifact),
        _ => None,
    };
    let rejection = if let Some(artifact) = selected_artifact {
        if !config.approved_artifacts.contains(artifact) {
            Some(wire::SafeCode::Unsupported)
        } else {
            None
        }
    } else {
        None
    };
    let rejection = if let Some(source) = operation.oci_source() {
        if config
            .approved_oci_sources
            .as_ref()
            .is_some_and(|approved| approved.contains(&source))
        {
            rejection
        } else {
            Some(wire::SafeCode::Unsupported)
        }
    } else {
        rejection
    };
    let rejection = if let Some(source) = operation.registry_source() {
        if config
            .approved_registry_sources
            .as_ref()
            .is_some_and(|catalog| {
                catalog.iter().any(|approval| {
                    approval.source.reference == source.reference
                        && approval.source.platform == source.platform
                        && approval.source.content_sha256 == source.content_sha256
                        && matches!(&operation,wire::Operation::PrepareArtifact {credential_ref,identity_token,..}
                            if approval.credential_ref.as_deref()==credential_ref.as_deref() && approval.credential_ref.is_some()==identity_token.is_some())
                })
            })
        {
            rejection
        } else {
            Some(wire::SafeCode::Unsupported)
        }
    } else {
        rejection
    };
    let rejection = if let Some(identity) = operation.registry_identity() {
        let source = identity.request();
        if config
            .approved_registry_sources
            .as_ref()
            .is_some_and(|catalog| {
                catalog
                    .iter()
                    .any(|approval| approval.matches(&source, identity.credential_ref.as_deref()) &&
                        !matches!(&operation,wire::Operation::CreateRegistryPrepared {size_bytes,..} if *size_bytes>approval.max_bytes))
            })
        {
            rejection
        } else {
            Some(wire::SafeCode::Unsupported)
        }
    } else {
        rejection
    };
    let rejection = if state.unavailable
        && !(state.session.protocol_major() == wire::PARITY_PROTOCOL_MAJOR
            && is_observation(&operation))
    {
        Some(wire::SafeCode::State)
    } else {
        rejection
    }
    .or(
        if state.upload_bytes + upload_reservation > MAX_UPLOAD_BYTES {
            Some(wire::SafeCode::Overload)
        } else {
            None
        },
    )
    .or_else(|| {
        // A full work queue cannot consume the two request identities needed
        // to reach the independently scheduled observation lane. Cancellation
        // and credit bypass both queues in the reader, as before.
        let work_requests = state
            .handles
            .values()
            .filter(|h| !is_observation(&h.operation))
            .count();
        (!is_observation(&operation)
            && work_requests >= wire::MAX_IN_FLIGHT - state.reserved_observations)
            .then_some(wire::SafeCode::Overload)
    });
    let mut accepted = false;
    shared.output.send(0, || {
        let response = state
            .session
            .admit_with_policy(message, rejection)
            .map_err(|_| ())?;
        accepted = matches!(response, wire::ServerMessage::Accepted { .. });
        Ok(response)
    })?;
    if !accepted {
        return Ok(false);
    }
    let cancel = Cancellation::new();
    state.upload_bytes += upload_reservation;
    state.handles.insert(
        id,
        Handle {
            terminal: if matches!(operation, wire::Operation::TerminalOpen { .. }) {
                Some(TerminalInbox {
                    controls: VecDeque::new(),
                    credit: VecDeque::new(),
                    outstanding: VecDeque::new(),
                })
            } else {
                None
            },
            cancel: cancel.clone(),
            started: false,
            deadline,
            cancellation_requested: None,
            operation: operation.sanitized(),
            upload: None,
            upload_reservation,
        },
    );
    drop(state);
    Ok(true)
}

fn handle_input(
    shared: &Shared,
    jobs: &Sender<Work>,
    observations: &Sender<Work>,
    spool_directory: &std::path::Path,
    input: Input,
) -> BridgeResult<bool> {
    match input.message {
        message @ wire::ClientMessage::Request { .. } => {
            let wire::ClientMessage::Request {
                id,
                operation,
                budget_ms,
                ..
            } = message
            else {
                unreachable!()
            };
            let deadline = input.received + Duration::from_millis(budget_ms);
            let (cancel, upload_reservation) = {
                let state = shared.state.lock().map_err(|_| ())?;
                let Some(handle) = state.handles.get(&id) else {
                    return Ok(false);
                };
                if handle.cancellation_requested.is_some() {
                    return Ok(false);
                }
                (handle.cancel.clone(), handle.upload_reservation)
            };
            if matches!(operation, wire::Operation::WriteFile { .. }) {
                let spool = match tempfile::NamedTempFile::new_in(spool_directory) {
                    Ok(spool) => spool,
                    Err(_) => {
                        shared.terminal(id, before(wire::SafeCode::Io))?;
                        return Ok(false);
                    }
                };
                if let Some(handle) = shared.state.lock().map_err(|_| ())?.handles.get_mut(&id) {
                    handle.upload = Some(spool);
                }
                if upload_reservation != 0 {
                    return Ok(false);
                }
                queue_upload(shared, jobs, id)?;
            } else {
                let queue = if is_observation(&operation) {
                    observations
                } else {
                    jobs
                };
                queue
                    .try_send(Work {
                        id,
                        operation,
                        deadline,
                        cancel,
                        upload: None,
                    })
                    .map_err(|_| ())?;
            }
        }
        wire::ClientMessage::Upload {
            epoch,
            id,
            offset,
            data_base64,
        } => {
            let (mut spool, data) = {
                let mut state = shared.state.lock().map_err(|_| ())?;
                state.session.cancel(&epoch, id).map_err(|_| ())?;
                if !state.handles.contains_key(&id) {
                    return Ok(false);
                }
                let data = state
                    .session
                    .upload(&epoch, id, offset, &data_base64)
                    .map_err(|_| ())?;
                let spool = state
                    .handles
                    .get_mut(&id)
                    .ok_or(())?
                    .upload
                    .take()
                    .ok_or(())?;
                (spool, data)
            };
            // No registry lock is held across disk I/O or native cancellation.
            if spool.write_all(&data).is_err() {
                shared.terminal(id, before(wire::SafeCode::Io))?;
                return Ok(false);
            }
            let complete = {
                let mut state = shared.state.lock().map_err(|_| ())?;
                let Some(handle) = state.handles.get_mut(&id) else {
                    return Ok(false);
                };
                handle.upload = Some(spool);
                state.session.upload_complete(id).map_err(|_| ())?
            };
            if complete {
                queue_upload(shared, jobs, id)?;
            }
        }
        wire::ClientMessage::Approve { .. }
        | wire::ClientMessage::TerminalControl { .. }
        | wire::ClientMessage::Cancel { .. }
        | wire::ClientMessage::Credit { .. } => return Err(()),
        wire::ClientMessage::Shutdown { epoch } => {
            let state = shared.state.lock().map_err(|_| ())?;
            if !state.approved {
                return Err(());
            }
            // cancel's ID validation is not appropriate for an empty session.
            drop(state);
            // Epoch is checked by the same domain-independent channel guard.
            shared
                .state
                .lock()
                .map_err(|_| ())?
                .session
                .check_epoch(&epoch)
                .map_err(|_| ())?;
            return Ok(true);
        }
    }
    Ok(false)
}
fn queue_upload(shared: &Shared, jobs: &Sender<Work>, id: u64) -> BridgeResult<()> {
    let mut state = shared.state.lock().map_err(|_| ())?;
    let handle = state.handles.get_mut(&id).ok_or(())?;
    let mut spool = handle.upload.take().ok_or(())?;
    spool.seek(SeekFrom::Start(0)).map_err(|_| ())?;
    jobs.try_send(Work {
        id,
        operation: handle.operation.clone(),
        deadline: handle.deadline,
        cancel: handle.cancel.clone(),
        upload: Some(spool),
    })
    .map_err(|_| ())
}
fn spawn_worker(
    shared: Arc<Shared>,
    native: Arc<dyn Native>,
    work: Receiver<Work>,
    config: Config,
) {
    std::thread::spawn(move || {
        while let Ok(work) = work.recv() {
            let remaining = work.deadline.saturating_duration_since(Instant::now());
            let (should_run, unavailable) = {
                let Ok(mut state) = shared.state.lock() else {
                    shared.fatal.store(true, Ordering::Release);
                    return;
                };
                let unavailable = (state.unavailable || !native.available())
                    && !(state.session.protocol_major() == wire::PARITY_PROTOCOL_MAJOR
                        && is_observation(&work.operation));
                let should_run = if state.closing || unavailable {
                    false
                } else {
                    match state.handles.get_mut(&work.id) {
                        Some(handle)
                            if !remaining.is_zero() && handle.cancellation_requested.is_none() =>
                        {
                            handle.started = true;
                            true
                        }
                        _ => false,
                    }
                };
                (should_run, unavailable)
            };
            if !should_run {
                let code = if remaining.is_zero() {
                    wire::SafeCode::Deadline
                } else if unavailable {
                    wire::SafeCode::State
                } else {
                    wire::SafeCode::Cancelled
                };
                if shared.terminal(work.id, before(code)).is_err() {
                    shared.fatal.store(true, Ordering::Release);
                }
                continue;
            }
            let upload = match work.upload.as_ref().map(|file| file.reopen()).transpose() {
                Ok(file) => file,
                Err(_) => {
                    if shared
                        .terminal(work.id, before(wire::SafeCode::Io))
                        .is_err()
                    {
                        shared.fatal.store(true, Ordering::Release);
                    }
                    continue;
                }
            };
            let result =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match work.operation {
                    wire::Operation::TerminalOpen { receipt, terminal } => native.terminal(
                        receipt,
                        terminal,
                        remaining,
                        work.cancel.clone(),
                        &mut TerminalChannel {
                            shared: shared.clone(),
                            id: work.id,
                        },
                    ),
                    wire::Operation::PrepareArtifact {
                        source,
                        credential_ref,
                        identity_token,
                    } => match config
                        .approved_registry_sources
                        .as_ref()
                        .and_then(|catalog| {
                            catalog.iter().find(|approval| {
                                approval.source.reference == source.reference
                                    && approval.source.platform == source.platform
                                    && approval.source.content_sha256 == source.content_sha256
                                    && approval.credential_ref.as_deref()
                                        == credential_ref.as_deref()
                            })
                        }) {
                        Some(approval) => native.prepare_artifact(
                            approval.clone(),
                            identity_token,
                            remaining,
                            work.cancel.clone(),
                        ),
                        None => before(wire::SafeCode::Unsupported),
                    },
                    wire::Operation::CreateRegistryPrepared { create, size_bytes } => {
                        let source = create.source.request();
                        match config
                            .approved_registry_sources
                            .as_ref()
                            .and_then(|catalog| {
                                catalog.iter().find(|approval| {
                                    approval
                                        .matches(&source, create.source.credential_ref.as_deref())
                                })
                            }) {
                            Some(approval) if size_bytes <= approval.max_bytes => native
                                .create_registry_prepared(
                                    create,
                                    size_bytes,
                                    approval.clone(),
                                    remaining,
                                    work.cancel.clone(),
                                ),
                            _ => before(wire::SafeCode::Unsupported),
                        }
                    }
                    operation => native.run(
                        operation,
                        remaining,
                        work.cancel.clone(),
                        upload,
                        &mut |stream, bytes| shared.event(work.id, stream, bytes),
                    ),
                }));
            let mut outcome = match result {
                Ok(outcome) => outcome,
                Err(_) => {
                    shared.fatal.store(true, Ordering::Release);
                    return;
                } // No synthetic evidence from panic.
            };
            if Instant::now() >= work.deadline {
                match &mut outcome {
                    wire::Outcome::Command { completion, .. }
                    | wire::Outcome::Terminal { completion, .. }
                    | wire::Outcome::File { completion, .. } => {
                        *completion = wire::Completion::Deadline
                    }
                    _ => {} // A verified lifecycle result remains useful evidence.
                }
            }
            if shared.terminal(work.id, outcome).is_err() {
                shared.fatal.store(true, Ordering::Release);
            }
        }
    });
}
fn reader_control(
    shared: &Shared,
    controls: &Sender<Cancellation>,
    message: wire::ClientMessage,
) -> BridgeResult<()> {
    match message {
        wire::ClientMessage::Approve { hello } => {
            let mut state = shared.state.lock().map_err(|_| ())?;
            state.session.approve(&hello).map_err(|_| ())?;
            state.approved = true;
        }
        wire::ClientMessage::TerminalControl {
            epoch,
            id,
            sequence,
            control,
        } => {
            let mut state = shared.state.lock().map_err(|_| ())?;
            if !state
                .session
                .terminal_control(&epoch, id, sequence, &control)
                .map_err(|_| ())?
            {
                return Ok(());
            }
            let handle = state.handles.get_mut(&id).ok_or(())?;
            if handle.cancellation_requested.is_some() {
                return Ok(());
            }
            let inbox = handle.terminal.as_mut().ok_or(())?;
            if inbox.controls.len() >= 2 {
                handle.cancellation_requested = Some(Instant::now());
                controls.try_send(handle.cancel.clone()).map_err(|_| ())?;
                return Ok(());
            }
            inbox.controls.push_back(match control {
                wire::TerminalAction::Attach => smolbox_engine::TerminalMessage::Attach,
                wire::TerminalAction::Input { data_base64 } => {
                    smolbox_engine::TerminalMessage::Command(
                        smolbox_engine::TerminalControl::Input(
                            wire::decode_chunk(&data_base64).map_err(|_| ())?,
                        ),
                    )
                }
                wire::TerminalAction::Resize { cols, rows } => {
                    smolbox_engine::TerminalMessage::Command(
                        smolbox_engine::TerminalControl::Resize { cols, rows },
                    )
                }
                wire::TerminalAction::Close => {
                    smolbox_engine::TerminalMessage::Command(smolbox_engine::TerminalControl::Close)
                }
            });
        }
        wire::ClientMessage::Cancel { epoch, id } => {
            shared
                .state
                .lock()
                .map_err(|_| ())?
                .session
                .cancel(&epoch, id)
                .map_err(|_| ())?;
            shared.cancel(id, controls)?;
        }
        wire::ClientMessage::Credit {
            epoch,
            id,
            decoded_bytes,
            events,
        } => {
            let mut state = shared.state.lock().map_err(|_| ())?;
            state
                .session
                .credit(&epoch, id, decoded_bytes, events)
                .map_err(|_| ())?;
            if let Some(inbox) = state
                .handles
                .get_mut(&id)
                .and_then(|handle| handle.terminal.as_mut())
            {
                if inbox.credit.len() + events as usize > wire::INITIAL_CREDIT_EVENTS as usize {
                    return Err(());
                }
                let mut total = 0;
                for _ in 0..events {
                    let (sequence, bytes) = inbox.outstanding.pop_front().ok_or(())?;
                    total += bytes;
                    inbox
                        .credit
                        .push_back(smolbox_engine::TerminalMessage::Consumed { sequence, bytes });
                }
                if total != decoded_bytes {
                    return Err(());
                }
            }
            shared.credit_changed.notify_all();
        }
        _ => return Err(()),
    }
    Ok(())
}

#[allow(deprecated)] // fetch_update is supported by the minimum native toolchain.
fn spawn_reader(
    shared: Arc<Shared>,
    sender: Sender<Input>,
    mut input: impl Read + Send + 'static,
    controls: Sender<Cancellation>,
    config: Config,
) {
    std::thread::spawn(move || loop {
        let value = match wire::read_frame(&mut input) {
            Ok(Some(value)) => value,
            Ok(None) => {
                shared.eof.store(true, Ordering::Release);
                return;
            }
            Err(_) => {
                shared.fatal.store(true, Ordering::Release);
                return;
            }
        };
        let received = Instant::now();
        let encoded = match serde_json::to_vec(&value) {
            Ok(bytes) => bytes.len(),
            Err(_) => {
                shared.fatal.store(true, Ordering::Release);
                return;
            }
        };
        let message = match wire::ClientMessage::decode(value) {
            Ok(message) => message,
            Err(_) => {
                shared.fatal.store(true, Ordering::Release);
                return;
            }
        };
        if matches!(
            message,
            wire::ClientMessage::Approve { .. }
                | wire::ClientMessage::TerminalControl { .. }
                | wire::ClientMessage::Cancel { .. }
                | wire::ClientMessage::Credit { .. }
        ) {
            if reader_control(&shared, &controls, message).is_err() {
                shared.fatal.store(true, Ordering::Release);
                return;
            }
            continue;
        }
        if matches!(message, wire::ClientMessage::Request { .. }) {
            match admit_request(&shared, message.clone(), received, &config) {
                Ok(true) => {}
                Ok(false) => continue,
                Err(()) => {
                    shared.fatal.store(true, Ordering::Release);
                    return;
                }
            }
        }
        if shared
            .input_bytes
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |bytes| {
                (bytes + encoded <= MAX_INPUT_BYTES).then_some(bytes + encoded)
            })
            .is_err()
            || sender
                .try_send(Input {
                    message,
                    received,
                    encoded,
                })
                .is_err()
        {
            shared.fatal.store(true, Ordering::Release);
            return;
        }
    });
}
fn spawn_writer(
    shared: Arc<Shared>,
    frames: Receiver<output::Frame>,
    mut writer: impl Write + Send + 'static,
) {
    std::thread::spawn(move || {
        loop {
            match frames.recv_timeout(Duration::from_millis(10)) {
                Ok(frame) => {
                    shared.writer_started_ms.store(
                        shared.origin.elapsed().as_millis() as u64 + 1,
                        Ordering::Release,
                    );
                    if output::write(&mut writer, &frame).is_err() {
                        shared.fatal.store(true, Ordering::Release);
                        break;
                    }
                    shared.output.complete(&frame);
                    shared.writer_started_ms.store(0, Ordering::Release);
                }
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                    if shared.writer_stop.load(Ordering::Acquire) {
                        break;
                    }
                }
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
            }
        }
        shared.writer_done.store(true, Ordering::Release);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;
    struct Fake {
        available: AtomicBool,
        shutdown_called: AtomicBool,
        shutdown_failed: AtomicBool,
        hold_health: AtomicBool,
        started: Sender<()>,
        calls: AtomicUsize,
        uploaded: Mutex<Vec<u8>>,
    }
    impl Native for Fake {
        fn create_registry_prepared(
            &self,
            _create: wire::RegistryCreate,
            _size: u64,
            _approval: crate::package::RegistryApproval,
            _remaining: Duration,
            _cancel: Cancellation,
        ) -> wire::Outcome {
            self.calls.fetch_add(1, Ordering::AcqRel);
            before(wire::SafeCode::Native)
        }
        fn prepare_artifact(
            &self,
            approval: crate::package::RegistryApproval,
            _token: Option<wire::RegistryToken>,
            _remaining: Duration,
            _cancel: Cancellation,
        ) -> wire::Outcome {
            self.calls.fetch_add(1, Ordering::AcqRel);
            wire::Outcome::PreparedArtifact {
                source: wire::RegistrySource {
                    reference: approval.source.reference,
                    platform: approval.source.platform,
                    content_sha256: approval.source.content_sha256,
                },
                size_bytes: 12,
                already_cached: false,
            }
        }
        fn terminal(
            &self,
            _receipt: wire::Receipt,
            spec: wire::TerminalSpec,
            remaining: Duration,
            cancel: Cancellation,
            bridge: &mut dyn TerminalBridge,
        ) -> wire::Outcome {
            self.calls.fetch_add(1, Ordering::AcqRel);
            bridge.opened().unwrap();
            if spec.program == "credit_wait" || spec.program == "controls_wait" {
                let bytes = if spec.program == "credit_wait" {
                    vec![0; 1024]
                } else {
                    vec![0, 255, 128]
                };
                let delivered = bytes.len() as u64;
                bridge
                    .output(smolbox_engine::TerminalOutput {
                        sequence: 1,
                        stderr: false,
                        bytes,
                    })
                    .unwrap();
                if spec.program == "credit_wait" {
                    assert!(bridge
                        .output(smolbox_engine::TerminalOutput {
                            sequence: 2,
                            stderr: false,
                            bytes: vec![1],
                        })
                        .is_err());
                } else {
                    // Deliberately do not consume controls. The bounded inbox
                    // must cancel this operation without closing the channel.
                    let end = Instant::now() + remaining;
                    while Instant::now() < end && !cancel.is_cancelled() {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    assert!(cancel.is_cancelled());
                }
                return wire::Outcome::Terminal {
                    completion: wire::Completion::Cancelled,
                    dispatch: wire::Dispatch::MayHaveDispatched,
                    observed_exit: None,
                    worker_collected: true,
                    output_bytes: delivered,
                };
            }
            bridge
                .output(smolbox_engine::TerminalOutput {
                    sequence: 1,
                    stderr: false,
                    bytes: vec![0, 255, 128],
                })
                .unwrap();
            let end = Instant::now() + remaining;
            let mut attached = false;
            let mut credited = false;
            let mut input = false;
            let mut resized = false;
            while Instant::now() < end && !cancel.is_cancelled() {
                match bridge.control() {
                    Ok(Some(smolbox_engine::TerminalMessage::Attach)) => attached = true,
                    Ok(Some(smolbox_engine::TerminalMessage::Consumed { sequence, bytes })) => {
                        assert_eq!((sequence, bytes), (1, 3));
                        credited = true;
                    }
                    Ok(Some(smolbox_engine::TerminalMessage::Command(
                        smolbox_engine::TerminalControl::Input(bytes),
                    ))) => {
                        assert_eq!(bytes, [255, 0]);
                        input = true;
                    }
                    Ok(Some(smolbox_engine::TerminalMessage::Command(
                        smolbox_engine::TerminalControl::Resize { cols, rows },
                    ))) => {
                        assert_eq!((cols, rows), (120, 43));
                        resized = true;
                    }
                    Ok(Some(smolbox_engine::TerminalMessage::Command(
                        smolbox_engine::TerminalControl::Close,
                    ))) => {
                        assert!(attached && credited && input && resized);
                        return wire::Outcome::Terminal {
                            completion: wire::Completion::Exited,
                            dispatch: wire::Dispatch::MayHaveDispatched,
                            observed_exit: Some(7),
                            worker_collected: true,
                            output_bytes: 3,
                        };
                    }
                    Ok(None) => {}
                    _ => break,
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            wire::Outcome::Terminal {
                completion: wire::Completion::Cancelled,
                dispatch: wire::Dispatch::MayHaveDispatched,
                observed_exit: None,
                worker_collected: true,
                output_bytes: 3,
            }
        }
        fn available(&self) -> bool {
            self.available.load(Ordering::Acquire)
        }
        fn run(
            &self,
            operation: wire::Operation,
            remaining: Duration,
            cancel: Cancellation,
            upload: Option<File>,
            emit: &mut dyn FnMut(wire::Stream, &[u8]) -> BridgeResult<()>,
        ) -> wire::Outcome {
            self.calls.fetch_add(1, Ordering::AcqRel);
            match operation {
                wire::Operation::QualifyOciCreation { .. } => wire::Outcome::Qualified,
                wire::Operation::PullImage { source, .. } => wire::Outcome::Pulled {
                    image: wire::ImageObservation {
                        reference: source.reference,
                        digest: format!("sha256:{}", "b".repeat(64)),
                        size: 123,
                        architecture: source.platform.trim_start_matches("linux/").into(),
                        os: "linux".into(),
                        layer_count: 2,
                    },
                },
                wire::Operation::Health if self.hold_health.load(Ordering::Acquire) => {
                    self.started.send(()).unwrap();
                    let at = Instant::now();
                    while !cancel.is_cancelled() && at.elapsed() < remaining {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    before(wire::SafeCode::Cancelled)
                }
                wire::Operation::Health => wire::Outcome::Health {
                    snapshot: wire::HealthSnapshot {
                        total: 0,
                        running: 0,
                        uptime_seconds: 1,
                    },
                },
                wire::Operation::Readiness if !self.available() => before(wire::SafeCode::State),
                wire::Operation::Readiness => wire::Outcome::Ready,
                wire::Operation::Exec { command, .. } if command.argv[0] == "unavailable" => {
                    self.available.store(false, Ordering::Release);
                    wire::Outcome::Command {
                        completion: wire::Completion::Unknown,
                        dispatch: wire::Dispatch::MayHaveDispatched,
                        observed_exit: None,
                        running_observed: false,
                        output_bytes: 0,
                    }
                }
                wire::Operation::Exec { command, .. } if command.argv[0] == "hold" => {
                    self.started.send(()).unwrap();
                    let at = Instant::now();
                    while !cancel.is_cancelled() && at.elapsed() < remaining {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    wire::Outcome::Command {
                        completion: wire::Completion::Cancelled,
                        dispatch: wire::Dispatch::MayHaveDispatched,
                        observed_exit: None,
                        running_observed: false,
                        output_bytes: 0,
                    }
                }
                wire::Operation::Exec { command, .. } if command.argv[0] == "collect" => {
                    self.started.send(()).unwrap();
                    while !cancel.is_cancelled() {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    // Modeled transfer collection window; no process or signal.
                    std::thread::sleep(Duration::from_millis(2200));
                    self.available.store(false, Ordering::Release);
                    wire::Outcome::Command {
                        completion: wire::Completion::Unknown,
                        dispatch: wire::Dispatch::MayHaveDispatched,
                        observed_exit: None,
                        running_observed: false,
                        output_bytes: 0,
                    }
                }
                wire::Operation::Exec { command, .. }
                    if matches!(command.argv[0].as_str(), "bulk" | "tiny") =>
                {
                    let mut total = 0;
                    let chunk = vec![b'Z'; if command.argv[0] == "tiny" { 1 } else { 65536 }];
                    while total < command.max_output_bytes {
                        let count =
                            (command.max_output_bytes - total).min(chunk.len() as u64) as usize;
                        total += count as u64;
                        if emit(wire::Stream::Stdout, &chunk[..count]).is_err() {
                            return wire::Outcome::Command {
                                completion: wire::Completion::ConsumerLost,
                                dispatch: wire::Dispatch::MayHaveDispatched,
                                observed_exit: Some(0),
                                running_observed: true,
                                output_bytes: total,
                            };
                        }
                    }
                    wire::Outcome::Command {
                        completion: wire::Completion::Exited,
                        dispatch: wire::Dispatch::MayHaveDispatched,
                        observed_exit: Some(0),
                        running_observed: true,
                        output_bytes: total,
                    }
                }
                wire::Operation::Exec { .. } => {
                    let bytes = b"safe\0\xff";
                    let forwarded = emit(wire::Stream::Stdout, bytes).is_ok();
                    wire::Outcome::Command {
                        completion: if forwarded {
                            wire::Completion::Exited
                        } else {
                            wire::Completion::ConsumerLost
                        },
                        dispatch: wire::Dispatch::MayHaveDispatched,
                        observed_exit: Some(0),
                        running_observed: true,
                        output_bytes: bytes.len() as u64,
                    }
                }
                wire::Operation::WriteFile { total_bytes, .. } => {
                    let mut data = Vec::new();
                    upload.unwrap().take(32).read_to_end(&mut data).unwrap();
                    assert_eq!(total_bytes, data.len() as u64);
                    *self.uploaded.lock().unwrap() = data;
                    wire::Outcome::File {
                        completion: wire::Completion::Completed,
                        dispatch: wire::Dispatch::MayHaveDispatched,
                        observed_bytes: total_bytes,
                        native_acknowledged: true,
                    }
                }
                _ => before(wire::SafeCode::Unsupported),
            }
        }
        fn shutdown(&self) -> BridgeResult<()> {
            self.shutdown_called.store(true, Ordering::Release);
            if self.shutdown_failed.load(Ordering::Acquire) {
                Err(())
            } else {
                Ok(())
            }
        }
    }
    fn hello() -> wire::Hello {
        wire::Hello {
            major: 1,
            minor: wire::PROTOCOL_MINOR,
            epoch: "ab".repeat(16),
            domain: wire::DomainIdentity {
                target_id: "test".into(),
                generation: "cd".repeat(16),
            },
            package: wire::PackageIdentity {
                engine_version: "0.1.0".into(),
                smolvm_revision: "ef".repeat(20),
                source_sha256: "01".repeat(32),
                build_sha256: "23".repeat(32),
                assets_sha256: "45".repeat(32),
                platform: "macos".into(),
                architecture: "aarch64".into(),
            },
            capabilities: vec![wire::Capability::Exec, wire::Capability::WriteFile],
            limits: wire::Limits::default(),
            preflight: wire::Preflight::Ready,
            sdk: None,
        }
    }
    fn receipt() -> wire::Receipt {
        wire::Receipt {
            target_id: "test".into(),
            domain_generation: "cd".repeat(16),
            name: "owned".into(),
            owner_token: "67".repeat(32),
            incarnation: "89".repeat(16),
            material_sha256: "ab".repeat(32),
            material: None,
        }
    }
    fn send(client: &mut UnixStream, message: wire::ClientMessage) {
        wire::write_frame(client, &serde_json::to_value(message).unwrap()).unwrap();
    }
    fn receive(client: &mut UnixStream) -> wire::ServerMessage {
        wire::ServerMessage::decode(wire::read_frame(client).unwrap().unwrap()).unwrap()
    }

    fn terminal_hello() -> wire::Hello {
        let wire::ServerMessage::Hello { hello: fixture } = wire::ServerMessage::decode(
            serde_json::from_str(include_str!(
                "../../smolbox-protocol/fixtures/hello-v2.json"
            ))
            .unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        let mut h = *fixture;
        h.domain = hello().domain;
        h.epoch = hello().epoch;
        h.sdk.as_mut().unwrap().feature_versions.extend([
            ("terminals".into(), 1),
            ("buffered_exec".into(), 1),
            ("job_resources".into(), 1),
            ("observability".into(), 1),
        ]);
        h.limits = wire::Limits::for_sdk(h.sdk.as_ref().unwrap());
        h.capabilities
            .extend([wire::Capability::TerminalOpen, wire::Capability::Readiness]);
        h
    }
    fn terminal_request(h: &wire::Hello, program: Option<&str>) -> wire::ClientMessage {
        let value = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/terminal-open-request.json"
        ))
        .unwrap();
        let mut open = wire::ClientMessage::decode(value).unwrap();
        if let wire::ClientMessage::Request {
            epoch,
            budget_ms,
            operation: wire::Operation::TerminalOpen { receipt, terminal },
            ..
        } = &mut open
        {
            *epoch = h.epoch.clone();
            *budget_ms = 1000;
            receipt.target_id = h.domain.target_id.clone();
            if let Some(program) = program {
                terminal.program = program.into();
            }
        } else {
            unreachable!()
        }
        open
    }
    #[test]
    fn terminal_bridge_routes_whole_credit_and_controls_without_starving_readiness() {
        let h = terminal_hello();
        let (mut client, fake, _started, thread) = start_with(h.clone());
        send(&mut client, terminal_request(&h, None));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::TerminalOpened { id: 1, .. }
        ));
        assert!(
            matches!(receive(&mut client), wire::ServerMessage::Event { id: 1, event: wire::Event { stream: wire::Stream::Terminal, data_base64 }, .. } if wire::decode_chunk(&data_base64).unwrap() == [0, 255, 128])
        );
        send(&mut client, request(2, wire::Operation::Readiness));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 2, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 2,
                outcome: wire::Outcome::Ready,
                ..
            }
        ));
        send(
            &mut client,
            wire::ClientMessage::Credit {
                epoch: h.epoch.clone(),
                id: 1,
                decoded_bytes: 3,
                events: 1,
            },
        );
        for (sequence, control) in [
            (1, wire::TerminalAction::Attach),
            (
                2,
                wire::TerminalAction::Input {
                    data_base64: wire::encode_chunk(&[255, 0]).unwrap(),
                },
            ),
            (
                3,
                wire::TerminalAction::Resize {
                    cols: 120,
                    rows: 43,
                },
            ),
            (4, wire::TerminalAction::Close),
        ] {
            send(
                &mut client,
                wire::ClientMessage::TerminalControl {
                    epoch: h.epoch.clone(),
                    id: 1,
                    sequence,
                    control,
                },
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 1,
                outcome: wire::Outcome::Terminal {
                    completion: wire::Completion::Exited,
                    observed_exit: Some(7),
                    worker_collected: true,
                    ..
                },
                ..
            }
        ));
        send(
            &mut client,
            wire::ClientMessage::Shutdown { epoch: h.epoch },
        );
        assert!(thread.join().unwrap().is_ok());
        assert!(fake.shutdown_called.load(Ordering::Acquire));
    }
    #[test]
    fn terminal_credit_wait_and_input_exhaustion_preserve_control_isolation() {
        for program in ["credit_wait", "controls_wait"] {
            let h = terminal_hello();
            let (mut client, _fake, _, thread) = start_with(h.clone());
            send(&mut client, terminal_request(&h, Some(program)));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { id: 1, .. }
            ));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::TerminalOpened { id: 1, .. }
            ));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Event { id: 1, .. }
            ));
            send(&mut client, request(2, wire::Operation::Readiness));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { id: 2, .. }
            ));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    id: 2,
                    outcome: wire::Outcome::Ready,
                    ..
                }
            ));
            if program == "credit_wait" {
                send(
                    &mut client,
                    wire::ClientMessage::Cancel {
                        epoch: h.epoch.clone(),
                        id: 1,
                    },
                );
            } else {
                for (sequence, control) in [
                    (1, wire::TerminalAction::Attach),
                    (
                        2,
                        wire::TerminalAction::Input {
                            data_base64: wire::encode_chunk(&[255]).unwrap(),
                        },
                    ),
                    (3, wire::TerminalAction::Resize { cols: 80, rows: 24 }),
                ] {
                    send(
                        &mut client,
                        wire::ClientMessage::TerminalControl {
                            epoch: h.epoch.clone(),
                            id: 1,
                            sequence,
                            control,
                        },
                    );
                }
            }
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    id: 1,
                    outcome: wire::Outcome::Terminal {
                        completion: wire::Completion::Cancelled,
                        observed_exit: None,
                        ..
                    },
                    ..
                }
            ));
            send(&mut client, request(3, wire::Operation::Readiness));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { id: 3, .. }
            ));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    id: 3,
                    outcome: wire::Outcome::Ready,
                    ..
                }
            ));
            send(
                &mut client,
                wire::ClientMessage::Shutdown { epoch: h.epoch },
            );
            assert!(thread.join().unwrap().is_ok());
        }
    }
    fn request(id: u64, operation: wire::Operation) -> wire::ClientMessage {
        wire::ClientMessage::Request {
            epoch: hello().epoch,
            id,
            budget_ms: 1000,
            initial_credit: wire::INITIAL_CREDIT_BYTES,
            initial_event_credit: wire::INITIAL_CREDIT_EVENTS,
            operation,
        }
    }
    fn exec(name: &str) -> wire::Operation {
        wire::Operation::Exec {
            receipt: receipt(),
            command: wire::Command {
                argv: vec![name.into()],
                env: Default::default(),
                workdir: None,
                user: None,
                max_output_bytes: 1024,
            },
        }
    }
    fn start() -> (
        UnixStream,
        Arc<Fake>,
        Receiver<()>,
        std::thread::JoinHandle<BridgeResult<()>>,
    ) {
        start_with(hello())
    }
    fn start_with(
        approved: wire::Hello,
    ) -> (
        UnixStream,
        Arc<Fake>,
        Receiver<()>,
        std::thread::JoinHandle<BridgeResult<()>>,
    ) {
        start_with_sources(approved, None)
    }
    fn start_with_sources(
        approved: wire::Hello,
        approved_oci_sources: Option<Vec<wire::OciSource>>,
    ) -> (
        UnixStream,
        Arc<Fake>,
        Receiver<()>,
        std::thread::JoinHandle<BridgeResult<()>>,
    ) {
        start_with_catalogs(approved, approved_oci_sources, None)
    }
    fn start_with_catalogs(
        approved: wire::Hello,
        approved_oci_sources: Option<Vec<wire::OciSource>>,
        approved_registry_sources: Option<Vec<crate::package::RegistryApproval>>,
    ) -> (
        UnixStream,
        Arc<Fake>,
        Receiver<()>,
        std::thread::JoinHandle<BridgeResult<()>>,
    ) {
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let input = server.try_clone().unwrap();
        let (started_sender, started) = bounded(8);
        let fake = Arc::new(Fake {
            available: AtomicBool::new(true),
            shutdown_called: AtomicBool::new(false),
            shutdown_failed: AtomicBool::new(false),
            hold_health: AtomicBool::new(false),
            started: started_sender,
            calls: AtomicUsize::new(0),
            uploaded: Mutex::new(Vec::new()),
        });
        let native = fake.clone();
        let config = Config {
            publish_address: None,
            schema: approved.major as u8,
            target_id: "test".into(),
            generation: "cd".repeat(16),
            allow_initialize: false,
            package_manifest_sha256: "01".repeat(32),
            approved_artifacts: vec![],
            approved_oci_sources,
            approved_registry_sources,
        };
        let declared = approved.clone();
        let thread = std::thread::spawn(move || {
            serve_io(
                input,
                server,
                native,
                declared,
                config,
                tempfile::tempdir().unwrap(),
            )
        });
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Hello { .. }
        ));
        send(
            &mut client,
            wire::ClientMessage::Approve { hello: approved },
        );
        (client, fake, started, thread)
    }
    #[test]
    fn registry_catalog_rejects_missing_crossed_and_credentials_before_native_preparation() {
        let mut h = terminal_hello();
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("remote_sources".into(), 1);
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("compact_creation".into(), 1);
        h.capabilities = h.sdk.as_ref().unwrap().capabilities();
        h.limits = wire::Limits::for_sdk(h.sdk.as_ref().unwrap());
        let source = wire::RegistrySource {
            reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
            platform: "linux/arm64".into(),
            content_sha256: "b".repeat(64),
        };
        let approval = crate::package::RegistryApproval {
            source: smolbox_engine::RegistryArtifactSource {
                reference: source.reference.clone(),
                platform: source.platform.clone(),
                content_sha256: source.content_sha256.clone(),
            },
            max_bytes: 1024,
            cache_policy: smolbox_engine::RegistryCachePolicy {
                max_bytes: 4096,
                max_files: 2,
            },
            credential_ref: None,
            token_realm: None,
        };
        let mut crossed = approval.clone();
        crossed.source.content_sha256 = "c".repeat(64);
        let mut authenticated = approval.clone();
        authenticated.credential_ref = Some("tenant".into());
        authenticated.token_realm = Some("https://auth.example/token".into());
        for (catalog, allowed) in [
            (None, false),
            (Some(vec![crossed]), false),
            (Some(vec![authenticated]), false),
            (Some(vec![approval]), true),
        ] {
            let (mut client, fake, _started, thread) =
                start_with_catalogs(h.clone(), None, catalog);
            send(
                &mut client,
                request(
                    1,
                    wire::Operation::PrepareArtifact {
                        source: source.clone(),
                        credential_ref: None,
                        identity_token: None,
                    },
                ),
            );
            if allowed {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Accepted { id: 1, .. }
                ));
                assert!(
                    matches!(receive(&mut client),wire::ServerMessage::Terminal {outcome:wire::Outcome::PreparedArtifact {source:actual,..},..} if actual==source)
                );
                assert_eq!(fake.calls.load(Ordering::Acquire), 1);
            } else {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Terminal {
                        outcome: wire::Outcome::Error {
                            code: wire::SafeCode::Unsupported,
                            dispatch: wire::Dispatch::NotDispatched
                        },
                        ..
                    }
                ));
                assert_eq!(fake.calls.load(Ordering::Acquire), 0);
            }
            send(
                &mut client,
                wire::ClientMessage::Shutdown {
                    epoch: h.epoch.clone(),
                },
            );
            assert!(thread.join().unwrap().is_ok());
        }
    }

    #[test]
    fn pull_catalog_rejects_before_native_entry_and_exact_approval_returns_typed_evidence() {
        let mut h = terminal_hello();
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("images".into(), 1);
        h.capabilities = h.sdk.as_ref().unwrap().capabilities();
        let source = wire::OciSource {
            reference: format!("registry.example/app@sha256:{}", "a".repeat(64)),
            platform: "linux/arm64".into(),
        };
        let mut receipt = serde_json::from_slice::<Vec<wire::GrowthTransition>>(include_bytes!(
            "../../smolbox-protocol/fixtures/growth-transitions-v1.json"
        ))
        .unwrap()
        .remove(0)
        .previous;
        receipt.target_id = h.domain.target_id.clone();
        receipt.domain_generation = h.domain.generation.clone();
        let other = wire::OciSource {
            reference: format!("registry.example/other@sha256:{}", "a".repeat(64)),
            ..source.clone()
        };
        for (catalog, approved) in [
            (None, false),
            (Some(vec![other]), false),
            (Some(vec![source.clone()]), true),
        ] {
            let (mut client, fake, _started, thread) = start_with_sources(h.clone(), catalog);
            send(
                &mut client,
                request(
                    1,
                    wire::Operation::PullImage {
                        receipt: receipt.clone(),
                        source: source.clone(),
                    },
                ),
            );
            if approved {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Accepted { id: 1, .. }
                ));
                assert!(
                    matches!(receive(&mut client),wire::ServerMessage::Terminal {outcome:wire::Outcome::Pulled {image},..} if image.matches(&source).is_ok())
                );
                assert_eq!(fake.calls.load(Ordering::Acquire), 1);
            } else {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Terminal {
                        outcome: wire::Outcome::Error {
                            code: wire::SafeCode::Unsupported,
                            dispatch: wire::Dispatch::NotDispatched
                        },
                        ..
                    }
                ));
                assert_eq!(fake.calls.load(Ordering::Acquire), 0);
            }
            send(
                &mut client,
                wire::ClientMessage::Shutdown {
                    epoch: h.epoch.clone(),
                },
            );
            assert!(thread.join().unwrap().is_ok());
        }
    }

    #[test]
    fn registry_credential_admission_matches_ref_and_never_echoes_token() {
        let mut h = terminal_hello();
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("remote_sources".into(), 1);
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("compact_creation".into(), 1);
        h.capabilities = h.sdk.as_ref().unwrap().capabilities();
        h.limits = wire::Limits::for_sdk(h.sdk.as_ref().unwrap());
        let source = wire::RegistrySource {
            reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
            platform: "linux/arm64".into(),
            content_sha256: "b".repeat(64),
        };
        let approval = crate::package::RegistryApproval {
            source: smolbox_engine::RegistryArtifactSource {
                reference: source.reference.clone(),
                platform: source.platform.clone(),
                content_sha256: source.content_sha256.clone(),
            },
            max_bytes: 123,
            cache_policy: smolbox_engine::RegistryCachePolicy {
                max_bytes: 123,
                max_files: 1,
            },
            credential_ref: Some("tenant".into()),
            token_realm: Some("https://auth.example/token".into()),
        };
        for reference in ["wrong", "tenant"] {
            let (mut client, fake, _started, thread) =
                start_with_catalogs(h.clone(), None, Some(vec![approval.clone()]));
            send(
                &mut client,
                request(
                    1,
                    wire::Operation::PrepareArtifact {
                        source: source.clone(),
                        credential_ref: Some(reference.into()),
                        identity_token: Some(
                            serde_json::from_value(serde_json::json!("private-token")).unwrap(),
                        ),
                    },
                ),
            );
            if reference == "tenant" {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Accepted { id: 1, .. }
                ));
            }
            let outcome = receive(&mut client);
            assert!(!serde_json::to_string(&outcome)
                .unwrap()
                .contains("private-token"));
            assert_eq!(
                fake.calls.load(Ordering::Acquire),
                usize::from(reference == "tenant")
            );
            send(
                &mut client,
                wire::ClientMessage::Shutdown {
                    epoch: h.epoch.clone(),
                },
            );
            assert!(thread.join().unwrap().is_ok());
        }
    }

    #[test]
    fn registry_creation_catalog_and_prepared_size_gate_before_native_entry() {
        let mut h = terminal_hello();
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("remote_sources".into(), 1);
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("compact_creation".into(), 1);
        h.limits = wire::Limits::for_sdk(h.sdk.as_ref().unwrap());
        h.capabilities = h.sdk.as_ref().unwrap().capabilities();
        let source = wire::RegistryIdentity {
            kind: "registry".into(),
            id: "pack".into(),
            sha256: "a".repeat(64),
            architecture: "aarch64".into(),
            reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
            content_sha256: "b".repeat(64),
            credential_ref: Some("tenant".into()),
        };
        let approval = crate::package::RegistryApproval {
            source: smolbox_engine::RegistryArtifactSource {
                reference: source.reference.clone(),
                platform: "linux/arm64".into(),
                content_sha256: source.content_sha256.clone(),
            },
            max_bytes: 123,
            cache_policy: smolbox_engine::RegistryCachePolicy {
                max_bytes: 123,
                max_files: 1,
            },
            credential_ref: Some("tenant".into()),
            token_realm: Some("https://auth.example/token".into()),
        };
        let create = wire::RegistryCreate {
            name: "fresh".into(),
            owner_token: "c".repeat(64),
            incarnation: "d".repeat(32),
            source,
            resources: wire::Resources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: BTreeMap::new(),
            features: None,
        };
        let mut wrong = approval.clone();
        wrong.credential_ref = Some("other".into());
        for (catalog, size, allowed) in [
            (None, 123, false),
            (Some(vec![wrong]), 123, false),
            (Some(vec![approval.clone()]), 124, false),
            (Some(vec![approval]), 123, true),
        ] {
            let (mut client, fake, _started, thread) =
                start_with_catalogs(h.clone(), None, catalog);
            send(
                &mut client,
                request(
                    1,
                    wire::Operation::CreateRegistryPrepared {
                        create: create.clone(),
                        size_bytes: size,
                    },
                ),
            );
            if allowed {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Accepted { id: 1, .. }
                ));
            }
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    outcome: wire::Outcome::Error {
                        dispatch: wire::Dispatch::NotDispatched,
                        ..
                    },
                    ..
                }
            ));
            assert_eq!(fake.calls.load(Ordering::Acquire), usize::from(allowed));
            send(
                &mut client,
                wire::ClientMessage::Shutdown {
                    epoch: h.epoch.clone(),
                },
            );
            assert!(thread.join().unwrap().is_ok());
        }
    }

    #[test]
    fn source_catalog_and_feature_gate_qualification_before_any_native_entry() {
        let mut h = terminal_hello();
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("remote_sources".into(), 1);
        h.sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("compact_creation".into(), 1);
        h.limits = wire::Limits::for_sdk(h.sdk.as_ref().unwrap());
        h.capabilities = h.sdk.as_ref().unwrap().capabilities();
        let source = wire::OciIdentity {
            kind: "oci".into(),
            id: "approved-source".into(),
            sha256: "a".repeat(64),
            architecture: "aarch64".into(),
            reference: format!("registry.example/app@sha256:{}", "a".repeat(64)),
        };
        let other = wire::OciSource {
            reference: format!("registry.example/other@sha256:{}", "a".repeat(64)),
            platform: "linux/arm64".into(),
        };
        for (catalog, approved) in [
            (None, false),
            (Some(vec![other]), false),
            (Some(vec![source.request()]), true),
        ] {
            let (mut client, fake, _started, thread) = start_with_sources(h.clone(), catalog);
            send(
                &mut client,
                request(
                    1,
                    wire::Operation::QualifyOciCreation {
                        source: source.clone(),
                        resources: wire::Resources {
                            cpus: 1,
                            memory_mib: 256,
                            storage_gib: 1,
                            overlay_gib: 1,
                        },
                        user: None,
                        features: None,
                    },
                ),
            );
            if approved {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Accepted { .. }
                ));
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Terminal {
                        outcome: wire::Outcome::Qualified,
                        ..
                    }
                ));
                assert_eq!(fake.calls.load(Ordering::Acquire), 1);
            } else {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Terminal {
                        outcome: wire::Outcome::Error {
                            code: wire::SafeCode::Unsupported,
                            dispatch: wire::Dispatch::NotDispatched
                        },
                        ..
                    }
                ));
                assert_eq!(fake.calls.load(Ordering::Acquire), 0);
            }
            send(
                &mut client,
                wire::ClientMessage::Shutdown {
                    epoch: h.epoch.clone(),
                },
            );
            assert!(thread.join().unwrap().is_ok());
        }
    }

    #[test]
    fn full_work_queue_preserves_observation_dispatch_and_graceful_control() {
        let sdk = crate::package::sdk_identity()
            .unwrap_or_else(|_| panic!("invalid compiled SDK policy"));
        let mut approved = hello();
        approved.major = wire::PARITY_PROTOCOL_MAJOR;
        approved.minor = wire::PARITY_PROTOCOL_MINOR;
        approved.package.engine_version = env!("CARGO_PKG_VERSION").into();
        approved.package.smolvm_revision = sdk.source_revision.clone();
        approved.limits = wire::Limits::for_sdk(&sdk);
        approved.sdk = Some(Box::new(sdk));
        approved
            .capabilities
            .extend([wire::Capability::Health, wire::Capability::Readiness]);
        let (mut client, fake, started, thread) = start_with(approved);
        let work_capacity = wire::MAX_IN_FLIGHT - OBSERVATION_WORKERS;
        for id in 1..=work_capacity as u64 {
            let mut operation = exec("hold");
            if let wire::Operation::Exec { receipt, .. } = &mut operation {
                receipt.material = Some(Box::new(wire::MaterialProof {
                    schema: 2,
                    revision: 0,
                    record_sha256: receipt.material_sha256.clone(),
                    chain_sha256: "cd".repeat(32),
                    operation_id: None,
                    request_sha256: None,
                }));
            }
            let mut message = request(id, operation.clone());
            if let wire::ClientMessage::Request { budget_ms, .. } = &mut message {
                *budget_ms = 5000;
            }
            send(&mut client, message);
            assert!(
                matches!(receive(&mut client), wire::ServerMessage::Accepted { id: actual, .. } if actual == id)
            );
            if id <= WORKERS as u64 {
                started.recv_timeout(Duration::from_secs(1)).unwrap();
            }
            if id == work_capacity as u64 {
                send(&mut client, request(id + 1, operation));
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Terminal {
                        sequence: 0,
                        outcome: wire::Outcome::Error {
                            code: wire::SafeCode::Overload,
                            dispatch: wire::Dispatch::NotDispatched,
                        },
                        ..
                    }
                ));
            }
        }
        assert_eq!(fake.calls.load(Ordering::Acquire), WORKERS);
        fake.hold_health.store(true, Ordering::Release);
        let health_id = work_capacity as u64 + 2;
        send(&mut client, request(health_id, wire::Operation::Health));
        assert!(
            matches!(receive(&mut client), wire::ServerMessage::Accepted { id, .. } if id == health_id)
        );
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        // One observation is now blocked alongside all four work threads.
        // The second reserved request/thread still dispatches readiness.
        let ready_id = health_id + 1;
        send(&mut client, request(ready_id, wire::Operation::Readiness));
        assert!(
            matches!(receive(&mut client), wire::ServerMessage::Accepted { id, .. } if id == ready_id)
        );
        assert!(
            matches!(receive(&mut client), wire::ServerMessage::Terminal {
            id,
            outcome: wire::Outcome::Ready,
            ..
        } if id == ready_id)
        );
        assert_eq!(fake.calls.load(Ordering::Acquire), WORKERS + 2);
        send(
            &mut client,
            wire::ClientMessage::Cancel {
                epoch: hello().epoch,
                id: health_id,
            },
        );
        assert!(
            matches!(receive(&mut client), wire::ServerMessage::Terminal {
            id,
            outcome: wire::Outcome::Error { code: wire::SafeCode::Cancelled, .. },
            ..
        } if id == health_id)
        );
        // Explicit normal shutdown cancels every modeled command. There is no
        // helper, SDK runtime, VM, owner loss or forced process termination.
        shutdown(client, thread);
        assert!(fake.shutdown_called.load(Ordering::Acquire));
    }

    #[test]
    fn protocol_two_bridge_rejects_stripped_proofs_before_native_dispatch() {
        let sdk = crate::package::sdk_identity()
            .unwrap_or_else(|_| panic!("invalid compiled SDK policy"));
        let mut approved = hello();
        approved.major = wire::PARITY_PROTOCOL_MAJOR;
        approved.minor = wire::PARITY_PROTOCOL_MINOR;
        approved.package.engine_version = env!("CARGO_PKG_VERSION").into();
        approved.package.smolvm_revision = sdk.source_revision.clone();
        approved.limits = wire::Limits::for_sdk(&sdk);
        approved.sdk = Some(Box::new(sdk));
        let (mut client, fake, _, thread) = start_with(approved);
        send(&mut client, request(1, exec("emit")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 1,
                sequence: 0,
                outcome: wire::Outcome::Error {
                    code: wire::SafeCode::Ownership,
                    dispatch: wire::Dispatch::NotDispatched,
                },
                ..
            }
        ));
        assert_eq!(fake.calls.load(Ordering::Acquire), 0);
        let mut operation = exec("emit");
        if let wire::Operation::Exec { receipt, .. } = &mut operation {
            receipt.material = Some(Box::new(wire::MaterialProof {
                schema: 2,
                revision: 0,
                record_sha256: receipt.material_sha256.clone(),
                chain_sha256: "cd".repeat(32),
                operation_id: None,
                request_sha256: None,
            }));
        }
        send(&mut client, request(2, operation));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 2, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Event { id: 2, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 2,
                outcome: wire::Outcome::Command {
                    observed_exit: Some(0),
                    ..
                },
                ..
            }
        ));
        assert_eq!(fake.calls.load(Ordering::Acquire), 1);
        shutdown(client, thread);
        assert!(fake.shutdown_called.load(Ordering::Acquire));
    }
    fn shutdown(mut client: UnixStream, thread: std::thread::JoinHandle<BridgeResult<()>>) {
        send(
            &mut client,
            wire::ClientMessage::Shutdown {
                epoch: hello().epoch,
            },
        );
        assert!(thread.join().unwrap().is_ok());
    }
    #[test]
    fn normal_shutdown_never_reports_success_when_native_sealing_failed() {
        let (mut client, fake, _, thread) = start();
        fake.shutdown_failed.store(true, Ordering::Release);
        send(
            &mut client,
            wire::ClientMessage::Shutdown {
                epoch: hello().epoch,
            },
        );
        assert!(thread.join().unwrap().is_err());
        assert!(fake.shutdown_called.load(Ordering::Acquire));
        assert_eq!(fake.calls.load(Ordering::Acquire), 0);
    }
    #[test]
    fn unavailable_notice_preserves_owner_and_terminal_without_new_dispatch() {
        let (mut client, fake, _, thread) = start();
        send(&mut client, request(1, exec("unavailable")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        unavailable_and_terminal(&mut client);
        assert!(!thread.is_finished());
        assert!(!fake.shutdown_called.load(Ordering::Acquire));
        send(&mut client, request(2, exec("emit")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 2,
                sequence: 0,
                outcome: wire::Outcome::Error {
                    code: wire::SafeCode::State,
                    dispatch: wire::Dispatch::NotDispatched,
                },
                ..
            }
        ));
        assert_eq!(fake.calls.load(Ordering::Acquire), 1);
        shutdown(client, thread);
        assert!(fake.shutdown_called.load(Ordering::Acquire));
    }

    #[test]
    fn parity_quarantine_preserves_bounded_observations_without_restoring_work_or_readiness() {
        let sdk = crate::package::sdk_identity()
            .unwrap_or_else(|_| panic!("invalid compiled SDK policy"));
        let mut approved = hello();
        approved.major = wire::PARITY_PROTOCOL_MAJOR;
        approved.minor = wire::PARITY_PROTOCOL_MINOR;
        approved.package.engine_version = env!("CARGO_PKG_VERSION").into();
        approved.package.smolvm_revision = sdk.source_revision.clone();
        approved.limits = wire::Limits::for_sdk(&sdk);
        approved.sdk = Some(Box::new(sdk));
        approved
            .capabilities
            .extend([wire::Capability::Health, wire::Capability::Readiness]);
        let (mut client, fake, _, thread) = start_with(approved);
        let mut operation = exec("unavailable");
        if let wire::Operation::Exec { receipt, .. } = &mut operation {
            receipt.material = Some(Box::new(wire::MaterialProof {
                schema: 2,
                revision: 0,
                record_sha256: receipt.material_sha256.clone(),
                chain_sha256: "cd".repeat(32),
                operation_id: None,
                request_sha256: None,
            }));
        }
        send(&mut client, request(1, operation.clone()));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        unavailable_and_terminal(&mut client);
        send(&mut client, request(2, wire::Operation::Health));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 2, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 2,
                outcome: wire::Outcome::Health { .. },
                ..
            }
        ));
        send(&mut client, request(3, wire::Operation::Readiness));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 3, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 3,
                outcome: wire::Outcome::Error {
                    code: wire::SafeCode::State,
                    dispatch: wire::Dispatch::NotDispatched
                },
                ..
            }
        ));
        send(&mut client, request(4, operation));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 4,
                sequence: 0,
                outcome: wire::Outcome::Error {
                    code: wire::SafeCode::State,
                    dispatch: wire::Dispatch::NotDispatched
                },
                ..
            }
        ));
        assert_eq!(fake.calls.load(Ordering::Acquire), 3);
        assert!(!fake.available());
        assert!(!fake.shutdown_called.load(Ordering::Acquire));
        shutdown(client, thread);
    }
    #[test]
    fn cancellation_grace_covers_modeled_worker_collection_before_quarantine() {
        let (mut client, fake, started, thread) = start();
        send(&mut client, request(1, exec("collect")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { .. }
        ));
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        send(
            &mut client,
            wire::ClientMessage::Cancel {
                epoch: hello().epoch,
                id: 1,
            },
        );
        unavailable_and_terminal(&mut client);
        assert!(!fake.shutdown_called.load(Ordering::Acquire));
        shutdown(client, thread);
    }
    fn unavailable_and_terminal(client: &mut UnixStream) {
        let frames = [receive(client), receive(client)];
        assert_eq!(
            frames
                .iter()
                .filter(|frame| matches!(frame,
            wire::ServerMessage::Unavailable { epoch } if epoch == &hello().epoch))
                .count(),
            1
        );
        assert_eq!(
            frames
                .iter()
                .filter(|frame| matches!(
                    frame,
                    wire::ServerMessage::Terminal {
                        id: 1,
                        outcome: wire::Outcome::Command {
                            dispatch: wire::Dispatch::MayHaveDispatched,
                            observed_exit: None,
                            ..
                        },
                        ..
                    }
                ))
                .count(),
            1
        );
    }
    #[test]
    fn blocking_work_does_not_block_cancellation_or_an_unrelated_stream() {
        let (mut client, fake, started, thread) = start();
        send(&mut client, request(1, exec("hold")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        started.recv_timeout(Duration::from_secs(1)).unwrap();
        send(&mut client, request(2, exec("emit")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 2, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Event {
                id: 2,
                sequence: 1,
                ..
            }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 2,
                sequence: 2,
                outcome: wire::Outcome::Command {
                    observed_exit: Some(0),
                    ..
                },
                ..
            }
        ));
        send(
            &mut client,
            wire::ClientMessage::Cancel {
                epoch: hello().epoch,
                id: 1,
            },
        );
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 1,
                outcome: wire::Outcome::Command {
                    observed_exit: None,
                    completion: wire::Completion::Cancelled,
                    ..
                },
                ..
            }
        ));
        assert_eq!(fake.calls.load(Ordering::Acquire), 2);
        shutdown(client, thread);
    }
    #[test]
    fn upload_is_spooled_and_dispatches_only_after_the_exact_total() {
        let (mut client, fake, _, thread) = start();
        let op = wire::Operation::WriteFile {
            receipt: receipt(),
            options: wire::FileOptions {
                guest_path: "/workspace/a".into(),
                max_bytes: 5,
                mode: Some(0o600),
            },
            total_bytes: 5,
        };
        send(&mut client, request(1, op));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        send(
            &mut client,
            wire::ClientMessage::Upload {
                epoch: hello().epoch,
                id: 1,
                offset: 0,
                data_base64: wire::encode_chunk(b"abc").unwrap(),
            },
        );
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(fake.calls.load(Ordering::Acquire), 0);
        send(
            &mut client,
            wire::ClientMessage::Upload {
                epoch: hello().epoch,
                id: 1,
                offset: 3,
                data_base64: wire::encode_chunk(b"de").unwrap(),
            },
        );
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                outcome: wire::Outcome::File {
                    observed_bytes: 5,
                    completion: wire::Completion::Completed,
                    ..
                },
                ..
            }
        ));
        assert_eq!(*fake.uploaded.lock().unwrap(), b"abcde");
        shutdown(client, thread);
    }
    #[test]
    fn cancelling_a_partial_upload_never_dispatches_it() {
        let (mut client, fake, _, thread) = start();
        send(
            &mut client,
            request(
                1,
                wire::Operation::WriteFile {
                    receipt: receipt(),
                    options: wire::FileOptions {
                        guest_path: "/a".into(),
                        max_bytes: 5,
                        mode: None,
                    },
                    total_bytes: 5,
                },
            ),
        );
        receive(&mut client);
        send(
            &mut client,
            wire::ClientMessage::Upload {
                epoch: hello().epoch,
                id: 1,
                offset: 0,
                data_base64: wire::encode_chunk(b"abc").unwrap(),
            },
        );
        send(
            &mut client,
            wire::ClientMessage::Cancel {
                epoch: hello().epoch,
                id: 1,
            },
        );
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                outcome: wire::Outcome::Error {
                    code: wire::SafeCode::Cancelled,
                    dispatch: wire::Dispatch::NotDispatched
                },
                ..
            }
        ));
        assert_eq!(fake.calls.load(Ordering::Acquire), 0);
        shutdown(client, thread);
    }
    #[test]
    fn malformed_and_wrong_epoch_input_never_create_a_native_reply() {
        let (mut client, fake, _, thread) = start();
        send(
            &mut client,
            wire::ClientMessage::Cancel {
                epoch: "00".repeat(16),
                id: 1,
            },
        );
        assert!(thread.join().unwrap().is_err());
        assert_eq!(fake.calls.load(Ordering::Acquire), 0);
        let (mut client, fake, _, thread) = start();
        client.write_all(&u32::MAX.to_be_bytes()).unwrap();
        assert!(thread.join().unwrap().is_err());
        assert_eq!(fake.calls.load(Ordering::Acquire), 0);
    }
    #[test]
    fn queue_timeout_does_not_retire_an_already_started_operation_as_not_dispatched() {
        // Regression for a snapshot race between watchdog selection and worker
        // start. complete_if_queued must recheck started under the same lock.
        let (output, _) = output::Output::new();
        let mut session = wire::Session::new(hello()).unwrap();
        session.approve(&hello()).unwrap();
        session.admit(request(1, exec("hold"))).unwrap();
        let shared = Shared {
            state: Mutex::new(State {
                session,
                handles: [(
                    1,
                    Handle {
                        terminal: None,
                        cancel: Cancellation::new(),
                        started: true,
                        deadline: Instant::now(),
                        cancellation_requested: None,
                        operation: exec("hold"),
                        upload: None,
                        upload_reservation: 0,
                    },
                )]
                .into(),
                upload_bytes: 0,
                approved: true,
                closing: false,
                unavailable: false,
                reserved_observations: 0,
            }),
            output,
            fatal: AtomicBool::new(false),
            eof: AtomicBool::new(false),
            writer_stop: AtomicBool::new(false),
            writer_done: AtomicBool::new(false),
            writer_started_ms: AtomicU64::new(0),
            origin: Instant::now(),
            input_bytes: AtomicUsize::new(0),
            credit_changed: Condvar::new(),
            heartbeat_ms: AtomicU64::new(0),
            finished: AtomicBool::new(false),
        };
        shared.finish_queued(1, wire::SafeCode::Deadline).unwrap();
        assert!(shared.state.lock().unwrap().handles.contains_key(&1));
    }
    #[test]
    fn replenished_credit_delivers_more_than_the_initial_window() {
        let (mut client, _, _, thread) = start();
        let mut operation = exec("bulk");
        if let wire::Operation::Exec { command, .. } = &mut operation {
            command.max_output_bytes = 1048593;
        }
        send(&mut client, request(1, operation));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        let mut total = 0;
        loop {
            match receive(&mut client) {
                wire::ServerMessage::Event { id: 1, event, .. } => {
                    let bytes = wire::decode_chunk(&event.data_base64).unwrap();
                    total += bytes.len();
                    send(
                        &mut client,
                        wire::ClientMessage::Credit {
                            epoch: hello().epoch,
                            id: 1,
                            decoded_bytes: bytes.len() as u64,
                            events: 1,
                        },
                    );
                }
                wire::ServerMessage::Terminal {
                    outcome:
                        wire::Outcome::Command {
                            completion: wire::Completion::Exited,
                            observed_exit: Some(0),
                            ..
                        },
                    ..
                } => break,
                _ => panic!("bulk stream failed"),
            }
        }
        assert_eq!(total, 1048593);
        shutdown(client, thread);
    }
    #[test]
    fn exhausted_tiny_event_credit_does_not_block_other_work_or_cancellation() {
        let (mut client, _, _, thread) = start();
        send(&mut client, request(1, exec("tiny")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        for sequence in 1..=wire::INITIAL_CREDIT_EVENTS {
            assert!(
                matches!(receive(&mut client), wire::ServerMessage::Event { id: 1, sequence: actual, .. } if actual == sequence)
            );
        }
        // Byte credit remains, but an unconsumed message window is exhausted.
        // Its worker waits without holding the registry or reader control path.
        send(&mut client, request(2, exec("other")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 2, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Event { id: 2, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 2,
                outcome: wire::Outcome::Command {
                    completion: wire::Completion::Exited,
                    ..
                },
                ..
            }
        ));
        send(
            &mut client,
            wire::ClientMessage::Cancel {
                epoch: hello().epoch,
                id: 1,
            },
        );
        assert!(
            matches!(receive(&mut client), wire::ServerMessage::Terminal { id: 1, outcome: wire::Outcome::Command { completion, .. }, .. } if completion != wire::Completion::Exited)
        );
        shutdown(client, thread);
    }
    #[test]
    fn reader_cancels_before_the_coordinator_processes_an_accepted_request() {
        let (output, frames) = output::Output::new();
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                session: wire::Session::new(hello()).unwrap(),
                handles: BTreeMap::new(),
                upload_bytes: 0,
                approved: false,
                closing: false,
                unavailable: false,
                reserved_observations: 0,
            }),
            output,
            credit_changed: Condvar::new(),
            fatal: AtomicBool::new(false),
            eof: AtomicBool::new(false),
            writer_stop: AtomicBool::new(false),
            writer_done: AtomicBool::new(false),
            writer_started_ms: AtomicU64::new(0),
            origin: Instant::now(),
            input_bytes: AtomicUsize::new(0),
            heartbeat_ms: AtomicU64::new(0),
            finished: AtomicBool::new(false),
        });
        let (mut client, server) = UnixStream::pair().unwrap();
        let (queued, inputs) = bounded(32);
        let (controls, cancellations) = bounded(32);
        let config = Config {
            publish_address: None,
            schema: 1,
            target_id: "test".into(),
            generation: "cd".repeat(16),
            allow_initialize: false,
            package_manifest_sha256: "01".repeat(32),
            approved_artifacts: vec![],
            approved_oci_sources: None,
            approved_registry_sources: None,
        };
        spawn_reader(shared.clone(), queued, server, controls, config);
        send(&mut client, wire::ClientMessage::Approve { hello: hello() });
        send(&mut client, request(1, exec("hold")));
        let accepted = frames.recv_timeout(Duration::from_secs(1)).unwrap();
        shared.output.complete(&accepted);
        // No coordinator consumes `inputs`, so no native work or spool can run.
        send(
            &mut client,
            wire::ClientMessage::Cancel {
                epoch: hello().epoch,
                id: 1,
            },
        );
        let token = cancellations.recv_timeout(Duration::from_secs(1)).unwrap();
        token.cancel();
        let state = shared.state.lock().unwrap();
        assert!(!state.handles[&1].started);
        assert!(state.handles[&1].cancellation_requested.is_some());
        assert!(state.handles[&1].cancel.is_cancelled());
        assert_eq!(inputs.len(), 1);
        drop(state);
        drop(client);
    }
}
