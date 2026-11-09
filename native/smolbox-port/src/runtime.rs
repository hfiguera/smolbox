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
        let branch = matches!(
            &outcome,
            wire::Outcome::BranchCreated { .. }
                | wire::Outcome::CollectedBranchMaterialPublished { .. }
                | wire::Outcome::UnbootedBranchChildAbsent { .. }
                | wire::Outcome::PartialBranchChildAbsent { .. }
                | wire::Outcome::BranchChildAbsent { .. }
                | wire::Outcome::BranchBackingReleased { .. }
                | wire::Outcome::PreparedBranchRetired { .. }
                | wire::Outcome::UnbootedBranchDisposalCandidate { .. }
                | wire::Outcome::UnbootedBranchDisposed { .. }
                | wire::Outcome::ReleasedBranchDeletionContinued { .. }
                | wire::Outcome::PartialBranchDisposed { .. }
                | wire::Outcome::PartialBranchCleanupCandidate { .. }
                | wire::Outcome::PartialBranchDisposalCleaned { .. }
                | wire::Outcome::PartialBranchCleanupUnneeded { .. }
                | wire::Outcome::PartialBranchCollected { .. }
                | wire::Outcome::PartialBranchCollectionCandidate { .. }
                | wire::Outcome::BranchDeletionCollected { .. }
                | wire::Outcome::ReleasedBranchDeletionCleaned { .. }
                | wire::Outcome::ReleasedBranchDeletionResolved { .. }
                | wire::Outcome::HeldBranchDeletionResolved { .. }
                | wire::Outcome::HeldBranchDeletionContinued { .. }
                | wire::Outcome::HeldBranchDeletionCleaned { .. }
                | wire::Outcome::BranchCompletionPresence { .. }
                | wire::Outcome::HeldBranchReleased { .. }
                | wire::Outcome::HeldBranchReleasePresence { .. }
        );
        let build = || state.session.terminal(id, outcome).map_err(|_| ());
        if branch {
            self.output.send_branch_terminal(build)?;
        } else {
            self.output.send(0, build)?;
        }
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
    fn export(
        &self,
        _operation: wire::Operation,
        _approval: crate::package::ExportApproval,
        _remaining: Duration,
        _cancel: Cancellation,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
    fn checkpoint(
        &self,
        _operation: wire::Operation,
        _approval: crate::package::CheckpointApproval,
        _remaining: Duration,
        _cancel: Cancellation,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
    fn run_with_volume_policy(
        &self,
        _operation: wire::Operation,
        _policy: smolbox_engine::LocalVolumePolicy,
        _remaining: Duration,
        _cancel: Cancellation,
        _upload: Option<File>,
        _emit: &mut dyn FnMut(wire::Stream, &[u8]) -> BridgeResult<()>,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
    fn create_registry_mounted_prepared(
        &self,
        _create: wire::RegistryCreate,
        _size: u64,
        _approval: crate::package::RegistryApproval,
        _policy: smolbox_engine::LocalVolumePolicy,
        _remaining: Duration,
        _cancel: Cancellation,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
    fn branch(
        &self,
        _operation: wire::Operation,
        _approval: wire::BranchApproval,
        _remaining: Duration,
        _cancel: Cancellation,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
    fn volume(
        &self,
        _policy: smolbox_engine::LocalVolumePolicy,
        _request: wire::VolumeRequest,
        _remaining: Duration,
        _cancel: Cancellation,
    ) -> wire::Outcome {
        before(wire::SafeCode::Unsupported)
    }
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
        _policy: Option<smolbox_engine::LocalVolumePolicy>,
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
    fn branch(
        &self,
        operation: wire::Operation,
        approval: wire::BranchApproval,
        remaining: Duration,
        cancel: Cancellation,
    ) -> wire::Outcome {
        adapter::branch(self, operation, approval, remaining, cancel)
    }
    fn run_with_volume_policy(
        &self,
        operation: wire::Operation,
        policy: smolbox_engine::LocalVolumePolicy,
        remaining: Duration,
        cancel: Cancellation,
        upload: Option<File>,
        emit: &mut dyn FnMut(wire::Stream, &[u8]) -> BridgeResult<()>,
    ) -> wire::Outcome {
        adapter::run_with_policy(
            self,
            operation,
            Some(policy),
            remaining,
            cancel,
            upload,
            emit,
        )
    }
    fn create_registry_mounted_prepared(
        &self,
        create: wire::RegistryCreate,
        size: u64,
        approval: crate::package::RegistryApproval,
        policy: smolbox_engine::LocalVolumePolicy,
        remaining: Duration,
        cancel: Cancellation,
    ) -> wire::Outcome {
        adapter::create_registry_with_policy(
            self,
            create,
            size,
            approval,
            Some(policy),
            remaining,
            cancel,
        )
    }
    fn volume(
        &self,
        policy: smolbox_engine::LocalVolumePolicy,
        request: wire::VolumeRequest,
        remaining: Duration,
        cancel: Cancellation,
    ) -> wire::Outcome {
        adapter::volume(self, policy, request, remaining, cancel)
    }
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
    fn export(
        &self,
        operation: wire::Operation,
        approval: crate::package::ExportApproval,
        remaining: Duration,
        cancel: Cancellation,
    ) -> wire::Outcome {
        adapter::export(self, operation, approval, remaining, cancel)
    }
    fn checkpoint(
        &self,
        operation: wire::Operation,
        approval: crate::package::CheckpointApproval,
        remaining: Duration,
        cancel: Cancellation,
    ) -> wire::Outcome {
        adapter::checkpoint(self, operation, approval, remaining, cancel)
    }
    fn terminal(
        &self,
        receipt: wire::Receipt,
        spec: wire::TerminalSpec,
        policy: Option<smolbox_engine::LocalVolumePolicy>,
        remaining: Duration,
        cancel: Cancellation,
        bridge: &mut dyn TerminalBridge,
    ) -> wire::Outcome {
        adapter::terminal(self, receipt, spec, policy, remaining, cancel, bridge)
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
    if let wire::Operation::Volume { request } = operation {
        return request.is_observation();
    }
    matches!(
        operation,
        wire::Operation::Health
            | wire::Operation::Capacity
            | wire::Operation::Metrics
            | wire::Operation::Readiness
            | wire::Operation::List
            | wire::Operation::Measurements { .. }
            | wire::Operation::TerminalPreflight { .. }
            | wire::Operation::InspectGrowth { .. }
            | wire::Operation::InspectExport { .. }
            | wire::Operation::InspectCapture { .. }
            | wire::Operation::InspectCaptureResolution { .. }
            | wire::Operation::InspectOciCreation { .. }
            | wire::Operation::InspectRegistryCreation { .. }
            | wire::Operation::InspectCheckpointCreation { .. }
            | wire::Operation::CheckpointPreflight { .. }
            | wire::Operation::InspectUnbootedBranchDisposal { quiesced: true, .. }
            | wire::Operation::InspectBranchCompletion { .. }
            | wire::Operation::QualifyHeldBranchRelease { .. }
            | wire::Operation::QualifyUnbootedBranchChildAbsence { .. }
            | wire::Operation::QualifyPartialBranchChildAbsence { .. }
            | wire::Operation::QualifyBranchChildAbsence { .. }
    )
}
fn is_control(operation: &wire::Operation) -> bool {
    is_observation(operation)
        || matches!(
            operation,
            wire::Operation::ResolveReadyBranchCompletion { quiesced: true, .. }
                | wire::Operation::PublishCollectedBranchMaterial { quiesced: true, .. }
        )
        || operation
            .unbooted_disposal_request()
            .is_some_and(|r| r.request.quiesced)
        || matches!(operation, wire::Operation::ReleaseUnbootedBranchBacking { request } if request.quiesced && request.backing_removed)
        || matches!(operation, wire::Operation::ReleasePartialBranchBacking { request } if request.quiesced && request.backing_removed)
        || matches!(operation, wire::Operation::RetirePreparedBranch { request } if request.quiesced)
        || operation
            .held_deletion_action_request()
            .is_some_and(|request| request.quiesced)
        || matches!(operation, wire::Operation::ContinueReleasedBranchDeletion { request } if request.quiesced)
        || operation
            .partial_disposal_request()
            .is_some_and(|r| r.quiesced)
        || matches!(operation, wire::Operation::QualifyPartialBranchCleanup { request } if request.quiesced)
        || matches!(operation, wire::Operation::CleanupPartialBranchDisposal { request } if request.quiesced)
        || matches!(operation, wire::Operation::ResolvePartialBranchCleanup { request } if request.quiesced)
        || matches!(operation, wire::Operation::CollectPartialBranch { request } | wire::Operation::InspectPartialBranchCollection { request } if request.quiesced)
        || matches!(operation, wire::Operation::CollectBranchDeletion { request } if request.quiesced)
        || matches!(operation, wire::Operation::CleanupReleasedBranchDeletion { request } if request.quiesced)
        || matches!(operation, wire::Operation::ResolveReleasedBranchDeletion { request } if request.quiesced)
        || matches!(operation, wire::Operation::ResolveHeldBranchDeletion { request } if request.quiesced)
        || matches!(operation, wire::Operation::ReleaseBranchBacking { request } if request.quiesced && request.backing_removed)
        || matches!(
            operation,
            wire::Operation::CleanupExportStaging { quiesced: true, .. }
                | wire::Operation::ResolveCapture { quiesced: true, .. }
                | wire::Operation::CleanupCaptureStaging { quiesced: true, .. }
                | wire::Operation::QualifyAbortedCaptureSource { quiesced: true, .. }
                | wire::Operation::AbortCaptureStaging { quiesced: true, .. }
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
    let rejection = if let Some(mounts) = operation.creation_mounts() {
        if config
            .approved_volume_policy
            .as_ref()
            .is_some_and(|policy| {
                mounts.iter().all(|mount| {
                    mount.proof.backing.policy.id == policy.id
                        && mount.proof.backing.policy.root == policy.root.to_string_lossy()
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
    let rejection = if let Some(approval) = operation.branch_approval() {
        if config
            .approved_branches
            .as_ref()
            .is_some_and(|catalog| catalog.contains(approval))
        {
            rejection
        } else {
            Some(wire::SafeCode::Unsupported)
        }
    } else {
        rejection
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
    let rejection = match &operation {
        wire::Operation::QualifyExport { request, .. }
        | wire::Operation::AdmitExport { request, .. }
        | wire::Operation::ExportMachine { request, .. } => {
            if config
                .approved_export_destinations
                .as_ref()
                .is_some_and(|destinations| {
                    destinations
                        .iter()
                        .any(|approval| approval.matches(request))
                })
            {
                rejection
            } else {
                Some(wire::SafeCode::Unsupported)
            }
        }
        _ => rejection,
    };
    let rejection = if let Some((source, resources)) = operation.checkpoint_source() {
        if config.approved_checkpoints.as_ref().is_some_and(|catalog| {
            catalog
                .iter()
                .any(|approval| approval.matches(source, resources))
        }) {
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
    let rejection = if let wire::Operation::Volume { request } = &operation {
        if config
            .approved_volume_policy
            .as_ref()
            .is_some_and(|policy| policy.id == request.policy_id)
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
            && is_control(&operation))
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
        // to reach the independently scheduled observation/resolution lane. Cancellation
        // and credit bypass both queues in the reader, as before.
        let work_requests = state
            .handles
            .values()
            .filter(|h| !is_control(&h.operation))
            .count();
        (!is_control(&operation)
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
                let queue = if is_control(&operation) {
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
                        && is_control(&work.operation));
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
                    operation @ (wire::Operation::InspectUnbootedBranchDisposal { .. }
                    | wire::Operation::DisposeUnbootedBranch { .. }
                    | wire::Operation::ResolveUnbootedBranchDisposal { .. }
                    | wire::Operation::ReleaseUnbootedBranchBacking { .. }
                    | wire::Operation::RetirePreparedBranch { .. }
                    | wire::Operation::CreateBranch { .. }
                    | wire::Operation::InspectBranchCompletion { .. }
                    | wire::Operation::ResolveReadyBranchCompletion { .. }
                    | wire::Operation::PublishCollectedBranchMaterial { .. }
                    | wire::Operation::ReleaseHeldBranch { .. }
                    | wire::Operation::QualifyHeldBranchRelease { .. }
                    | wire::Operation::QualifyUnbootedBranchChildAbsence { .. }
                    | wire::Operation::QualifyPartialBranchChildAbsence { .. }
                    | wire::Operation::ReleasePartialBranchBacking { .. }
                    | wire::Operation::QualifyBranchChildAbsence { .. }
                    | wire::Operation::ReleaseBranchBacking { .. }
                    | wire::Operation::ContinueReleasedBranchDeletion { .. }
                    | wire::Operation::DisposePartialBranch { .. }
                    | wire::Operation::ResolvePartialBranchDisposal { .. }
                    | wire::Operation::CleanupPartialBranchDisposal { .. }
                    | wire::Operation::ResolvePartialBranchCleanup { .. }
                    | wire::Operation::QualifyPartialBranchCleanup { .. }
                    | wire::Operation::CollectPartialBranch { .. }
                    | wire::Operation::InspectPartialBranchCollection { .. }
                    | wire::Operation::CollectBranchDeletion { .. }
                    | wire::Operation::CleanupReleasedBranchDeletion { .. }
                    | wire::Operation::ResolveReleasedBranchDeletion { .. }
                    | wire::Operation::ResolveHeldBranchDeletion { .. }
                    | wire::Operation::ContinueHeldBranchDeletion { .. }
                    | wire::Operation::CleanupHeldBranchDeletion { .. }) => {
                        // All branch control requests share the immutable approval catalog.
                        let approval = operation
                            .branch_approval()
                            .and_then(|wanted| {
                                config.approved_branches.as_ref().and_then(|catalog| {
                                    catalog.iter().find(|approved| *approved == wanted)
                                })
                            })
                            .cloned();
                        match approval {
                            Some(approval) => {
                                native.branch(operation, approval, remaining, work.cancel.clone())
                            }
                            None => before(wire::SafeCode::Unsupported),
                        }
                    }
                    operation @ (wire::Operation::QualifyExport { .. }
                    | wire::Operation::AdmitExport { .. }
                    | wire::Operation::ExportMachine { .. }) => {
                        let request = match &operation {
                            wire::Operation::QualifyExport { request, .. }
                            | wire::Operation::AdmitExport { request, .. }
                            | wire::Operation::ExportMachine { request, .. } => request,
                            _ => unreachable!(),
                        };
                        match config
                            .approved_export_destinations
                            .as_ref()
                            .and_then(|catalog| {
                                catalog.iter().find(|approval| approval.matches(request))
                            }) {
                            Some(approval) => native.export(
                                operation,
                                approval.clone(),
                                remaining,
                                work.cancel.clone(),
                            ),
                            None => before(wire::SafeCode::Unsupported),
                        }
                    }
                    operation @ (wire::Operation::QualifyCheckpointCreation { .. }
                    | wire::Operation::CreateCheckpoint { .. }
                    | wire::Operation::InspectCheckpointCreation { .. }) => {
                        let approval =
                            operation
                                .checkpoint_source()
                                .and_then(|(source, resources)| {
                                    config.approved_checkpoints.as_ref().and_then(|catalog| {
                                        catalog
                                            .iter()
                                            .find(|approval| approval.matches(source, resources))
                                    })
                                });
                        match approval {
                            Some(approval) => native.checkpoint(
                                operation,
                                approval.clone(),
                                remaining,
                                work.cancel.clone(),
                            ),
                            None => before(wire::SafeCode::Unsupported),
                        }
                    }
                    wire::Operation::TerminalOpen { receipt, terminal } => native.terminal(
                        receipt,
                        terminal,
                        config.approved_volume_policy.clone(),
                        remaining,
                        work.cancel.clone(),
                        &mut TerminalChannel {
                            shared: shared.clone(),
                            id: work.id,
                        },
                    ),
                    wire::Operation::Volume { request } => match config
                        .approved_volume_policy
                        .as_ref()
                    {
                        Some(policy) if policy.id == request.policy_id => {
                            native.volume(policy.clone(), request, remaining, work.cancel.clone())
                        }
                        _ => before(wire::SafeCode::Unsupported),
                    },
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
                            Some(approval) if size_bytes <= approval.max_bytes => {
                                if create.volume_mounts.is_some() {
                                    match &config.approved_volume_policy {
                                        Some(policy) => native.create_registry_mounted_prepared(
                                            create,
                                            size_bytes,
                                            approval.clone(),
                                            policy.clone(),
                                            remaining,
                                            work.cancel.clone(),
                                        ),
                                        None => before(wire::SafeCode::Unsupported),
                                    }
                                } else {
                                    native.create_registry_prepared(
                                        create,
                                        size_bytes,
                                        approval.clone(),
                                        remaining,
                                        work.cancel.clone(),
                                    )
                                }
                            }
                            _ => before(wire::SafeCode::Unsupported),
                        }
                    }
                    operation
                        if operation.creation_mounts().is_some()
                            || matches!(
                                &operation,
                                wire::Operation::Start { .. }
                                    | wire::Operation::StartOci { .. }
                                    | wire::Operation::Exec { .. }
                                    | wire::Operation::ExecBuffered { .. }
                                    | wire::Operation::ExecStream { .. }
                                    | wire::Operation::ExecBackground { .. }
                                    | wire::Operation::ReadFile { .. }
                                    | wire::Operation::WriteFile { .. }
                            ) && config.approved_volume_policy.is_some() =>
                    {
                        match &config.approved_volume_policy {
                            Some(policy) => native.run_with_volume_policy(
                                operation,
                                policy.clone(),
                                remaining,
                                work.cancel.clone(),
                                upload,
                                &mut |stream, bytes| shared.event(work.id, stream, bytes),
                            ),
                            None => before(wire::SafeCode::Unsupported),
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
        platform: String,
        epoch: String,
        available: AtomicBool,
        shutdown_called: AtomicBool,
        shutdown_failed: AtomicBool,
        hold_health: AtomicBool,
        started: Sender<()>,
        calls: AtomicUsize,
        uploaded: Mutex<Vec<u8>>,
        file_policy_calls: AtomicUsize,
    }
    impl Native for Fake {
        fn branch(
            &self,
            operation: wire::Operation,
            approval: wire::BranchApproval,
            _remaining: Duration,
            _cancel: Cancellation,
        ) -> wire::Outcome {
            self.calls.fetch_add(1, Ordering::AcqRel);
            if let wire::Operation::InspectUnbootedBranchDisposal { request, .. } = &operation {
                assert!(request.approval == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/unbooted-branch-disposal-candidate-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::BranchCreateRequest>(row["creation"].clone())
                            .unwrap()
                            == **request
                            && row["candidate"]["publication"]["change"]["platform"]
                                == self.platform
                            && row["candidate"]["publication"]["change"]["child_origin"]["intent"]
                                ["epoch"]
                                == self.epoch
                    })
                    .unwrap();
                return wire::Outcome::UnbootedBranchDisposalCandidate {
                    candidate: Box::new(serde_json::from_value(row["candidate"].clone()).unwrap()),
                };
            }
            if operation.unbooted_disposal_request().is_some()
                || matches!(
                    operation,
                    wire::Operation::ReleaseUnbootedBranchBacking { .. }
                )
            {
                assert!(operation.branch_approval() == Some(&approval));
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/unbooted-branch-disposal-v1.json"
                ))
                .unwrap();
                if let Some(request) = operation.unbooted_disposal_request() {
                    let row = rows
                        .into_iter()
                        .find(|row| {
                            serde_json::from_value::<wire::UnbootedBranchDisposalRequest>(
                                row["request"].clone(),
                            )
                            .unwrap()
                                == *request
                        })
                        .unwrap();
                    return wire::Outcome::UnbootedBranchDisposed {
                        proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                    };
                }
                let wire::Operation::ReleaseUnbootedBranchBacking { request } = &operation else {
                    unreachable!()
                };
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::UnbootedBranchBackingReleaseRequest>(
                            row["backing_request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .unwrap();
                return wire::Outcome::BranchBackingReleased {
                    proof: Box::new(serde_json::from_value(row["backing_proof"].clone()).unwrap()),
                };
            }
            if let wire::Operation::RetirePreparedBranch { request } = &operation {
                assert!(request.creation.approval == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/prepared-branch-retirement-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PreparedBranchRetirementRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .expect("exact synthetic prepared retirement request");
                return wire::Outcome::PreparedBranchRetired {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                };
            }
            if let Some(request) = operation.held_deletion_action_request() {
                assert!(*request.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/held-branch-deletion-action-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::HeldBranchDeletionActionRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == *request
                    })
                    .expect("exact synthetic action request");
                return match request.action {
                    wire::HeldBranchDeletionAction::Continue => {
                        wire::Outcome::HeldBranchDeletionContinued {
                            proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                        }
                    }
                    wire::HeldBranchDeletionAction::Cleanup => {
                        wire::Outcome::HeldBranchDeletionCleaned {
                            proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                        }
                    }
                };
            }
            if let wire::Operation::ContinueReleasedBranchDeletion { request } = &operation {
                assert!(*request.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/released-branch-deletion-continuation-v1.json"
                ))
                .unwrap();
                let proof = rows
                    .into_iter()
                    .find_map(|row| {
                        let expected: wire::ReleasedBranchDeletionContinuationRequest =
                            serde_json::from_value(row["request"].clone()).unwrap();
                        (expected == **request).then(|| {
                            serde_json::from_value::<wire::ReleasedBranchDeletionContinuation>(
                                row["proof"].clone(),
                            )
                            .unwrap()
                        })
                    })
                    .expect("exact synthetic released deletion request");
                return wire::Outcome::ReleasedBranchDeletionContinued {
                    proof: Box::new(proof),
                };
            }
            if let wire::Operation::CleanupReleasedBranchDeletion { request } = &operation {
                assert!(*request.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/released-branch-deletion-cleanup-v1.json"
                ))
                .unwrap();
                let proof = rows
                    .into_iter()
                    .find_map(|row| {
                        let expected: wire::ReleasedBranchDeletionCleanupRequest =
                            serde_json::from_value(row["request"].clone()).unwrap();
                        (expected == **request).then(|| {
                            serde_json::from_value::<wire::ReleasedBranchDeletionResolution>(
                                row["proof"].clone(),
                            )
                            .unwrap()
                        })
                    })
                    .expect("exact synthetic released deletion request");
                return wire::Outcome::ReleasedBranchDeletionCleaned {
                    proof: Box::new(proof),
                };
            }
            if let wire::Operation::QualifyPartialBranchCleanup { request } = &operation {
                assert!(request.collection_request.creation.approval == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/partial-branch-cleanup-candidate-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PartialBranchDisposalRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .expect("exact original qualification request");
                return wire::Outcome::PartialBranchCleanupCandidate {
                    candidate: Box::new(serde_json::from_value(row["candidate"].clone()).unwrap()),
                };
            }
            if let wire::Operation::ResolvePartialBranchCleanup { request } = &operation {
                assert!(
                    request
                        .disposal_request
                        .collection_request
                        .creation
                        .approval
                        == approval
                );
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/partial-branch-cleanup-unneeded-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PartialBranchDisposalCleanupRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .expect("exact synthetic unnecessary cleanup request");
                let native: smolbox_engine::PartialBranchDisposalCleanupUnneeded =
                    serde_json::from_value(row["proof"].clone()).unwrap();
                native
                    .matches_request(&serde_json::from_value(row["request"].clone()).unwrap())
                    .unwrap();
                return wire::Outcome::PartialBranchCleanupUnneeded {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                };
            }
            if let wire::Operation::CleanupPartialBranchDisposal { request } = &operation {
                assert!(
                    request
                        .disposal_request
                        .collection_request
                        .creation
                        .approval
                        == approval
                );
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/partial-branch-disposal-cleanup-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PartialBranchDisposalCleanupRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .expect("exact synthetic cleanup request");
                // Check unchanged engine DTOs as well as the independent wire readers.
                let native: smolbox_engine::PartialBranchDisposalCleanup =
                    serde_json::from_value(row["proof"].clone()).unwrap();
                native.validate().unwrap();
                let native_request: smolbox_engine::PartialBranchDisposalCleanupRequest =
                    serde_json::from_value(row["request"].clone()).unwrap();
                native_request.matches(&native).unwrap();
                return wire::Outcome::PartialBranchDisposalCleaned {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                };
            }
            if let Some(request) = operation.partial_disposal_request() {
                assert!(request.collection_request.creation.approval == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/partial-branch-disposal-v1.json"
                ))
                .unwrap();
                let completion =
                    if matches!(operation, wire::Operation::DisposePartialBranch { .. }) {
                        "deleted"
                    } else {
                        "resolved_absent"
                    };
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PartialBranchDisposalRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == *request
                            && row["proof"]["completion"] == completion
                    })
                    .expect("exact synthetic partial disposal request");
                return wire::Outcome::PartialBranchDisposed {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                };
            }
            if let wire::Operation::InspectPartialBranchCollection { request } = &operation {
                assert!(request.creation.approval == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/partial-branch-collection-candidate-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PartialBranchCollectionRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .expect("exact synthetic partial collection candidate request");
                return wire::Outcome::PartialBranchCollectionCandidate {
                    candidate: Box::new(serde_json::from_value(row["candidate"].clone()).unwrap()),
                };
            }
            if let wire::Operation::CollectPartialBranch { request } = &operation {
                assert!(request.creation.approval == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/partial-branch-collection-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PartialBranchCollectionRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .expect("exact synthetic partial collection request");
                return wire::Outcome::PartialBranchCollected {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                    platform: self.platform.clone(),
                };
            }
            if let wire::Operation::CollectBranchDeletion { request } = &operation {
                assert!(*request.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/branch-deletion-collection-v1.json"
                ))
                .unwrap();
                let proof = rows
                    .into_iter()
                    .find_map(|row| {
                        let expected: wire::BranchDeletionCollectionRequest =
                            serde_json::from_value(row["request"].clone()).unwrap();
                        (expected == **request).then(|| {
                            serde_json::from_value::<wire::BranchDeletionCollection>(
                                row["proof"].clone(),
                            )
                            .unwrap()
                        })
                    })
                    .expect("exact synthetic released deletion request");
                return wire::Outcome::BranchDeletionCollected {
                    proof: Box::new(proof),
                };
            }
            if let wire::Operation::ResolveReleasedBranchDeletion { request } = &operation {
                assert!(*request.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/released-branch-deletion-v1.json"
                ))
                .unwrap();
                let proof = rows
                    .into_iter()
                    .find_map(|row| {
                        let expected: wire::ReleasedBranchDeletionRequest =
                            serde_json::from_value(row["request"].clone()).unwrap();
                        (expected == **request).then(|| {
                            serde_json::from_value::<wire::ReleasedBranchDeletionResolution>(
                                row["proof"].clone(),
                            )
                            .unwrap()
                        })
                    })
                    .expect("exact synthetic released deletion request");
                return wire::Outcome::ReleasedBranchDeletionResolved {
                    proof: Box::new(proof),
                };
            }
            if let wire::Operation::ResolveHeldBranchDeletion { request } = &operation {
                assert!(*request.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/held-branch-deletion-v1.json"
                ))
                .unwrap();
                let proof = rows
                    .into_iter()
                    .find_map(|row| {
                        let expected: wire::HeldBranchDeletionRequest =
                            serde_json::from_value(row["request"].clone()).unwrap();
                        (expected == **request).then(|| {
                            serde_json::from_value::<wire::BranchDeletionResolution>(
                                row["proof"].clone(),
                            )
                            .unwrap()
                        })
                    })
                    .expect("exact synthetic held deletion request");
                return wire::Outcome::HeldBranchDeletionResolved {
                    proof: Box::new(proof),
                };
            }
            if let wire::Operation::ReleaseBranchBacking { request } = &operation {
                assert!(*request.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/branch-backing-release-v1.json"
                ))
                .unwrap();
                let proof = rows
                    .into_iter()
                    .find_map(|row| {
                        let expected: wire::BranchBackingReleaseRequest =
                            serde_json::from_value(row["request"].clone()).unwrap();
                        (expected == **request).then(|| {
                            serde_json::from_value::<wire::BranchBackingRelease>(
                                row["proof"].clone(),
                            )
                            .unwrap()
                        })
                    })
                    .expect("exact synthetic backing request");
                return wire::Outcome::BranchBackingReleased {
                    proof: Box::new(proof),
                };
            }
            if let wire::Operation::ReleasePartialBranchBacking { request } = &operation {
                assert!(request.approval() == &approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/partial-branch-backing-release-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PartialBranchBackingReleaseRequest>(
                            row["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .unwrap();
                return wire::Outcome::BranchBackingReleased {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                };
            }
            if let wire::Operation::QualifyPartialBranchChildAbsence { request } = &operation {
                assert!(request.approval() == &approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/partial-branch-child-absence-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::PartialBranchChildAbsenceRequest>(
                            row["proof"]["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .unwrap();
                return wire::Outcome::PartialBranchChildAbsent {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                };
            }
            if let wire::Operation::QualifyUnbootedBranchChildAbsence { request } = &operation {
                assert!(request.approval() == &approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/unbooted-branch-child-absence-v1.json"
                ))
                .unwrap();
                let row = rows
                    .into_iter()
                    .find(|row| {
                        serde_json::from_value::<wire::UnbootedBranchChildAbsenceRequest>(
                            row["proof"]["request"].clone(),
                        )
                        .unwrap()
                            == **request
                    })
                    .unwrap();
                return wire::Outcome::UnbootedBranchChildAbsent {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                };
            }
            if let wire::Operation::QualifyBranchChildAbsence { request } = &operation {
                assert!(*request.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/branch-child-absence-v1.json"
                ))
                .unwrap();
                let proof = rows
                    .into_iter()
                    .find_map(|row| {
                        let expected: wire::BranchChildAbsenceRequest =
                            serde_json::from_value(row["request"].clone()).unwrap();
                        (expected == **request).then(|| {
                            serde_json::from_value::<wire::BranchChildAbsence>(row["proof"].clone())
                                .unwrap()
                        })
                    })
                    .expect("exact synthetic absence request");
                return wire::Outcome::BranchChildAbsent {
                    proof: Box::new(proof),
                };
            }
            if let Some(wanted) = operation.held_branch_request() {
                assert!(*wanted.approval() == approval);
                let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                    "../../smolbox-protocol/fixtures/branch-held-release-v1.json"
                ))
                .unwrap();
                let transition = rows
                    .into_iter()
                    .find_map(|row| {
                        let request: wire::BranchHeldReleaseRequest =
                            serde_json::from_value(row["request"].clone()).unwrap();
                        (request == *wanted).then(|| {
                            Box::new(
                                serde_json::from_value::<wire::BranchReleaseTransition>(
                                    row["transition"].clone(),
                                )
                                .unwrap(),
                            )
                        })
                    })
                    .unwrap();
                return if matches!(operation, wire::Operation::ReleaseHeldBranch { .. }) {
                    wire::Outcome::HeldBranchReleased { transition }
                } else {
                    wire::Outcome::HeldBranchReleasePresence {
                        transition: Some(transition),
                    }
                };
            }
            let wanted = operation.branch_request().unwrap();
            assert!(wanted.approval == approval);
            let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
                "../../smolbox-protocol/fixtures/branch-creation-v1.json"
            ))
            .unwrap();
            let completion = rows
                .into_iter()
                .find_map(|row| {
                    let request: wire::BranchCreateRequest =
                        serde_json::from_value(row["request"].clone()).unwrap();
                    (request == *wanted).then(|| {
                        serde_json::from_value::<wire::BranchCompletion>(row["completion"].clone())
                            .unwrap()
                    })
                })
                .unwrap();
            match operation {
                wire::Operation::CreateBranch { .. } => wire::Outcome::BranchCreated {
                    completion: Box::new(completion),
                },
                wire::Operation::PublishCollectedBranchMaterial { .. } => {
                    wire::Outcome::CollectedBranchMaterialPublished {
                        publication: Box::new(completion.publication),
                    }
                }
                _ => wire::Outcome::BranchCompletionPresence {
                    completion: Some(Box::new(completion)),
                },
            }
        }
        fn export(
            &self,
            operation: wire::Operation,
            approval: crate::package::ExportApproval,
            _remaining: Duration,
            _cancel: Cancellation,
        ) -> wire::Outcome {
            self.calls.fetch_add(1, Ordering::AcqRel);
            match operation {
                wire::Operation::QualifyExport { request, .. }
                | wire::Operation::AdmitExport { request, .. } => {
                    assert!(approval.matches(&request));
                    wire::Outcome::Qualified
                }
                wire::Operation::ExportMachine {
                    receipt,
                    operation_id,
                    request,
                    push_token,
                } => {
                    assert!(approval.matches(&request));
                    assert_eq!(push_token.into_secret(), "fixture-export-token");
                    let proof = export_fixture();
                    proof
                        .matches_request(&receipt, &operation_id, &request)
                        .unwrap();
                    wire::Outcome::Exported {
                        publication: Box::new(proof),
                    }
                }
                _ => before(wire::SafeCode::Validation),
            }
        }
        fn run_with_volume_policy(
            &self,
            operation: wire::Operation,
            policy: smolbox_engine::LocalVolumePolicy,
            _remaining: Duration,
            _cancel: Cancellation,
            _upload: Option<File>,
            _emit: &mut dyn FnMut(wire::Stream, &[u8]) -> BridgeResult<()>,
        ) -> wire::Outcome {
            if let Some(mounts) = operation.creation_mounts() {
                assert!(!mounts.is_empty());
                for mount in mounts {
                    assert_eq!(mount.proof.backing.policy.id, policy.id);
                    assert_eq!(
                        mount.proof.backing.policy.root,
                        policy.root.to_str().unwrap()
                    );
                }
            } else {
                assert!(matches!(
                    operation,
                    wire::Operation::Start { .. }
                        | wire::Operation::StartOci { .. }
                        | wire::Operation::Exec { .. }
                        | wire::Operation::ExecBuffered { .. }
                        | wire::Operation::ExecStream { .. }
                        | wire::Operation::ExecBackground { .. }
                        | wire::Operation::ReadFile { .. }
                        | wire::Operation::WriteFile { .. }
                ));
            }
            self.calls.fetch_add(1, Ordering::AcqRel);
            if matches!(
                &operation,
                wire::Operation::Exec { .. }
                    | wire::Operation::ExecBuffered { .. }
                    | wire::Operation::ExecStream { .. }
            ) {
                assert_eq!(policy.id, "local");
                assert_eq!(policy.root, std::path::Path::new("/srv/smolvm/volumes"));
                _emit(wire::Stream::Stdout, &[0, 255, 128]).unwrap();
                return wire::Outcome::Command {
                    completion: wire::Completion::Exited,
                    dispatch: wire::Dispatch::MayHaveDispatched,
                    observed_exit: Some(0),
                    running_observed: true,
                    output_bytes: 3,
                };
            }
            if matches!(
                &operation,
                wire::Operation::ReadFile { .. } | wire::Operation::WriteFile { .. }
            ) {
                assert_eq!(policy.id, "local");
                assert_eq!(policy.root, std::path::Path::new("/srv/smolvm/volumes"));
                self.file_policy_calls.fetch_add(1, Ordering::AcqRel);
                match operation {
                    wire::Operation::ReadFile { options, .. } => {
                        assert_eq!(options.guest_path, "/mnt/volumes/data/value");
                        _emit(wire::Stream::File, &[0, 255, 128]).unwrap();
                    }
                    wire::Operation::WriteFile {
                        options,
                        total_bytes,
                        ..
                    } => {
                        assert_eq!(options.guest_path, "/mnt/volumes/data/value");
                        let mut data = vec![];
                        _upload.unwrap().take(32).read_to_end(&mut data).unwrap();
                        assert_eq!(total_bytes, data.len() as u64);
                        *self.uploaded.lock().unwrap() = data;
                    }
                    _ => unreachable!(),
                }
                return wire::Outcome::File {
                    completion: wire::Completion::Completed,
                    dispatch: wire::Dispatch::MayHaveDispatched,
                    observed_bytes: 3,
                    native_acknowledged: true,
                };
            }
            before(wire::SafeCode::Native)
        }
        fn create_registry_mounted_prepared(
            &self,
            create: wire::RegistryCreate,
            _size: u64,
            _approval: crate::package::RegistryApproval,
            policy: smolbox_engine::LocalVolumePolicy,
            _remaining: Duration,
            _cancel: Cancellation,
        ) -> wire::Outcome {
            self.run_with_volume_policy(
                wire::Operation::InspectRegistryCreation { create },
                policy,
                _remaining,
                _cancel,
                None,
                &mut |_, _| Err(()),
            )
        }
        fn volume(
            &self,
            policy: smolbox_engine::LocalVolumePolicy,
            request: wire::VolumeRequest,
            _remaining: Duration,
            _cancel: Cancellation,
        ) -> wire::Outcome {
            self.calls.fetch_add(1, Ordering::AcqRel);
            assert_eq!(policy.id, request.policy_id);
            wire::Outcome::Volume {
                volume: wire::VolumeResult::Unverified,
            }
        }
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
        fn checkpoint(
            &self,
            operation: wire::Operation,
            approval: crate::package::CheckpointApproval,
            _remaining: Duration,
            _cancel: Cancellation,
        ) -> wire::Outcome {
            let (source, resources) = operation.checkpoint_source().unwrap();
            assert!(approval.matches(source, resources));
            self.calls.fetch_add(1, Ordering::AcqRel);
            match operation {
                wire::Operation::QualifyCheckpointCreation { .. } => wire::Outcome::Qualified,
                wire::Operation::InspectCheckpointCreation { .. } => {
                    wire::Outcome::CreationPresence {
                        presence: wire::CreationPresence::Unverified,
                    }
                }
                _ => before(wire::SafeCode::Native),
            }
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
            policy: Option<smolbox_engine::LocalVolumePolicy>,
            remaining: Duration,
            cancel: Cancellation,
            bridge: &mut dyn TerminalBridge,
        ) -> wire::Outcome {
            if let Some(policy) = policy {
                assert_eq!(policy.id, "local");
                assert_eq!(policy.root, std::path::Path::new("/srv/smolvm/volumes"));
            }
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
                    Ok(Some(smolbox_engine::TerminalMessage::Attach)) => {
                        attached = true;
                        if spec.program == "paced_controls" {
                            self.started.send(()).unwrap();
                        }
                    }
                    Ok(Some(smolbox_engine::TerminalMessage::Consumed { sequence, bytes })) => {
                        assert_eq!((sequence, bytes), (1, 3));
                        credited = true;
                    }
                    Ok(Some(smolbox_engine::TerminalMessage::Command(
                        smolbox_engine::TerminalControl::Input(bytes),
                    ))) => {
                        assert_eq!(bytes, [255, 0]);
                        input = true;
                        if spec.program == "paced_controls" {
                            self.started.send(()).unwrap();
                        }
                    }
                    Ok(Some(smolbox_engine::TerminalMessage::Command(
                        smolbox_engine::TerminalControl::Resize { cols, rows },
                    ))) => {
                        assert_eq!((cols, rows), (120, 43));
                        resized = true;
                        if spec.program == "paced_controls" {
                            self.started.send(()).unwrap();
                        }
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
                wire::Operation::BranchPreflight { .. } => {
                    let fixture: serde_json::Value = serde_json::from_str(include_str!(
                        "../../smolbox-protocol/fixtures/branch-preflight-v1.json"
                    ))
                    .unwrap();
                    serde_json::from_value(fixture["outcome"].clone()).unwrap()
                }
                wire::Operation::QualifyAbortedCaptureSource {
                    receipt,
                    operation_id,
                    request,
                    quiesced: true,
                } => {
                    let proofs: Vec<wire::CaptureAbortSourceQualification> =
                        serde_json::from_str(include_str!(
                            "../../smolbox-protocol/fixtures/capture-abort-sources-v1.json"
                        ))
                        .unwrap();
                    let Some(proof) = proofs
                        .into_iter()
                        .find(|proof| proof.matches(&receipt, &operation_id, &request).is_ok())
                    else {
                        return wire::Outcome::Error {
                            code: wire::SafeCode::Ownership,
                            dispatch: wire::Dispatch::NotDispatched,
                        };
                    };
                    wire::Outcome::AbortedCaptureSourceQualified {
                        qualification: Box::new(proof),
                    }
                }
                wire::Operation::InspectExport {
                    receipt,
                    operation_id,
                    request_sha256,
                } => {
                    let proof = export_fixture();
                    proof
                        .matches(&receipt, &operation_id, &request_sha256)
                        .unwrap();
                    wire::Outcome::ExportPresence {
                        publication: Some(Box::new(proof)),
                    }
                }
                wire::Operation::CleanupExportStaging {
                    receipt,
                    operation_id,
                    request_sha256,
                    quiesced: true,
                } => wire::Outcome::ExportStagingCleaned {
                    cleanup: Box::new(wire::ExportStageCleanup {
                        schema: 1,
                        source: receipt,
                        operation_id,
                        request_sha256,
                        stage_sha256: "d".repeat(64),
                    }),
                },
                wire::Operation::AbortCaptureStaging {
                    receipt,
                    operation_id,
                    request,
                    quiesced: true,
                } => wire::Outcome::CaptureStagingAborted {
                    cleanup: Box::new(wire::CaptureStagingCleanupReceipt {
                        schema: 1,
                        previous: receipt,
                        operation_id,
                        request,
                        stage_sha256: "d".repeat(64),
                    }),
                },
                wire::Operation::CleanupCaptureStaging {
                    receipt,
                    operation_id,
                    request,
                    quiesced: true,
                } => wire::Outcome::CaptureStagingCleaned {
                    cleanup: Box::new(wire::CaptureStagingCleanupReceipt {
                        schema: 1,
                        previous: receipt,
                        operation_id,
                        request,
                        stage_sha256: "d".repeat(64),
                    }),
                },
                wire::Operation::ResolveCapture {
                    receipt,
                    operation_id,
                    request,
                    quiesced: true,
                } => {
                    let proofs: Vec<wire::CaptureResolutionTransition> = serde_json::from_str(
                        include_str!("../../smolbox-protocol/fixtures/capture-resolutions-v1.json"),
                    )
                    .unwrap();
                    match proofs
                        .into_iter()
                        .find(|proof| proof.matches(&receipt, &operation_id, &request).is_ok())
                    {
                        Some(proof) => wire::Outcome::CaptureResolved {
                            transition: Box::new(proof),
                        },
                        None => before(wire::SafeCode::Ownership),
                    }
                }
                wire::Operation::InspectCaptureResolution {
                    receipt,
                    operation_id,
                    request,
                } => {
                    let proofs: Vec<wire::CaptureResolutionTransition> = serde_json::from_str(
                        include_str!("../../smolbox-protocol/fixtures/capture-resolutions-v1.json"),
                    )
                    .unwrap();
                    let proof = proofs
                        .into_iter()
                        .find(|proof| proof.matches(&receipt, &operation_id, &request).is_ok());
                    wire::Outcome::CaptureResolutionPresence {
                        transition: proof.map(Box::new),
                    }
                }
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
    // These protocol peers use explicit macOS fixture identities even when the
    // test executable is compiled on Linux. Their descriptor must belong to that
    // modeled platform, not inherit optional capabilities of the test host.
    // package::tests separately checks the actual compiled platform policy.
    fn model_sdk_identity() -> Result<wire::SdkIdentity, serde_json::Error> {
        let policy: serde_json::Value =
            serde_json::from_slice(include_bytes!("../../policy.json"))?;
        let mut sdk: wire::SdkIdentity = serde_json::from_value(policy["sdk"].clone())?;
        // Branch models opt in explicitly. A newly qualified package policy
        // must not silently turn on the negative (missing-feature) fixtures.
        for feature in [
            "branches",
            "partial_collection_preflight",
            "partial_cleanup_resolution",
        ] {
            sdk.feature_versions.remove(feature);
        }
        Ok(sdk)
    }

    fn model_branch_sdk_identity() -> Result<wire::SdkIdentity, serde_json::Error> {
        let mut sdk = model_sdk_identity()?;
        // Branch tests opt into each capability independently of package defaults.
        sdk.feature_versions.remove("branches");
        sdk.feature_versions.remove("partial_collection_preflight");
        sdk.feature_versions.remove("partial_cleanup_resolution");
        Ok(sdk)
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
    fn terminal_with_volume_policy_preserves_credit_resize_normal_close_and_control() {
        let mut h = terminal_hello();
        let sdk = h.sdk.as_mut().unwrap();
        sdk.feature_versions
            .extend([("volumes".into(), 1), ("compact_creation".into(), 1)]);
        h.capabilities = sdk.capabilities();
        h.limits = wire::Limits::for_sdk(sdk);
        h.package.platform = "linux".into();
        h.package.architecture = "x86_64".into();
        let policy = smolbox_engine::LocalVolumePolicy {
            id: "local".into(),
            root: "/srv/smolvm/volumes".into(),
        };
        let (mut client, fake, started, thread) =
            start_with_all_catalogs(h.clone(), None, None, Some(policy));
        send(&mut client, terminal_request(&h, Some("paced_controls")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::TerminalOpened { id: 1, .. }
        ));
        assert!(
            matches!(receive(&mut client), wire::ServerMessage::Event { event, .. }
            if event.stream == wire::Stream::Terminal && wire::decode_chunk(&event.data_base64).unwrap() == [0, 255, 128])
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
            if sequence < 4 {
                started.recv_timeout(Duration::from_secs(1)).unwrap();
            }
        }
        let closed = receive(&mut client);
        assert!(
            matches!(
                closed,
                wire::ServerMessage::Terminal {
                    id: 1,
                    outcome: wire::Outcome::Terminal {
                        completion: wire::Completion::Exited,
                        observed_exit: Some(7),
                        worker_collected: true,
                        output_bytes: 3,
                        ..
                    },
                    ..
                }
            ),
            "{}",
            serde_json::to_string(&closed).unwrap()
        );
        assert_eq!(fake.calls.load(Ordering::Acquire), 2);
        shutdown(client, thread);
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
        start_with_all_catalogs(
            approved,
            approved_oci_sources,
            approved_registry_sources,
            None,
        )
    }
    fn start_with_all_catalogs(
        approved: wire::Hello,
        approved_oci_sources: Option<Vec<wire::OciSource>>,
        approved_registry_sources: Option<Vec<crate::package::RegistryApproval>>,
        approved_volume_policy: Option<smolbox_engine::LocalVolumePolicy>,
    ) -> (
        UnixStream,
        Arc<Fake>,
        Receiver<()>,
        std::thread::JoinHandle<BridgeResult<()>>,
    ) {
        start_with_catalogs_and_artifacts(
            approved,
            approved_oci_sources,
            approved_registry_sources,
            approved_volume_policy,
            vec![],
        )
    }
    fn start_with_catalogs_and_artifacts(
        approved: wire::Hello,
        approved_oci_sources: Option<Vec<wire::OciSource>>,
        approved_registry_sources: Option<Vec<crate::package::RegistryApproval>>,
        approved_volume_policy: Option<smolbox_engine::LocalVolumePolicy>,
        approved_artifacts: Vec<wire::Artifact>,
    ) -> (
        UnixStream,
        Arc<Fake>,
        Receiver<()>,
        std::thread::JoinHandle<BridgeResult<()>>,
    ) {
        start_with_complete_catalogs(
            approved,
            approved_oci_sources,
            approved_registry_sources,
            approved_volume_policy,
            approved_artifacts,
            None,
        )
    }
    fn start_with_complete_catalogs(
        approved: wire::Hello,
        approved_oci_sources: Option<Vec<wire::OciSource>>,
        approved_registry_sources: Option<Vec<crate::package::RegistryApproval>>,
        approved_volume_policy: Option<smolbox_engine::LocalVolumePolicy>,
        approved_artifacts: Vec<wire::Artifact>,
        approved_checkpoints: Option<Vec<crate::package::CheckpointApproval>>,
    ) -> (
        UnixStream,
        Arc<Fake>,
        Receiver<()>,
        std::thread::JoinHandle<BridgeResult<()>>,
    ) {
        start_with_export_catalogs(
            approved,
            approved_oci_sources,
            approved_registry_sources,
            approved_volume_policy,
            approved_artifacts,
            approved_checkpoints,
            None,
        )
    }
    fn start_with_export_catalogs(
        approved: wire::Hello,
        approved_oci_sources: Option<Vec<wire::OciSource>>,
        approved_registry_sources: Option<Vec<crate::package::RegistryApproval>>,
        approved_volume_policy: Option<smolbox_engine::LocalVolumePolicy>,
        approved_artifacts: Vec<wire::Artifact>,
        approved_checkpoints: Option<Vec<crate::package::CheckpointApproval>>,
        approved_export_destinations: Option<Vec<crate::package::ExportApproval>>,
    ) -> (
        UnixStream,
        Arc<Fake>,
        Receiver<()>,
        std::thread::JoinHandle<BridgeResult<()>>,
    ) {
        start_with_policy_catalogs(
            approved,
            approved_oci_sources,
            approved_registry_sources,
            approved_volume_policy,
            approved_artifacts,
            approved_checkpoints,
            (approved_export_destinations, None),
        )
    }
    fn start_with_policy_catalogs(
        approved: wire::Hello,
        approved_oci_sources: Option<Vec<wire::OciSource>>,
        approved_registry_sources: Option<Vec<crate::package::RegistryApproval>>,
        approved_volume_policy: Option<smolbox_engine::LocalVolumePolicy>,
        approved_artifacts: Vec<wire::Artifact>,
        approved_checkpoints: Option<Vec<crate::package::CheckpointApproval>>,
        catalogs: (
            Option<Vec<crate::package::ExportApproval>>,
            Option<Vec<wire::BranchApproval>>,
        ),
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
            platform: approved.package.platform.clone(),
            epoch: approved.epoch.clone(),
            available: AtomicBool::new(true),
            shutdown_called: AtomicBool::new(false),
            shutdown_failed: AtomicBool::new(false),
            hold_health: AtomicBool::new(false),
            started: started_sender,
            calls: AtomicUsize::new(0),
            uploaded: Mutex::new(Vec::new()),
            file_policy_calls: AtomicUsize::new(0),
        });
        let native = fake.clone();
        let config = Config {
            publish_address: None,
            schema: approved.major as u8,
            target_id: approved.domain.target_id.clone(),
            generation: approved.domain.generation.clone(),
            allow_initialize: false,
            package_manifest_sha256: "01".repeat(32),
            approved_artifacts,
            approved_oci_sources,
            approved_registry_sources,
            approved_volume_policy,
            approved_checkpoints,
            approved_export_destinations: catalogs.0,
            approved_branches: catalogs.1,
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
    fn policy_command_dispatch_preserves_credited_bytes_and_sibling_control() {
        let mut h = terminal_hello();
        let sdk = h.sdk.as_mut().unwrap();
        sdk.feature_versions.extend([
            ("volumes".into(), 1),
            ("compact_creation".into(), 1),
            ("streaming_exec".into(), 1),
        ]);
        h.capabilities = sdk.capabilities();
        h.limits = wire::Limits::for_sdk(sdk);
        h.package.platform = "linux".into();
        h.package.architecture = "x86_64".into();
        let mut receipt = serde_json::from_slice::<Vec<wire::GrowthTransition>>(include_bytes!(
            "../../smolbox-protocol/fixtures/growth-transitions-v1.json"
        ))
        .unwrap()
        .remove(0)
        .previous;
        receipt.target_id = h.domain.target_id.clone();
        receipt.domain_generation = h.domain.generation.clone();
        let policy = smolbox_engine::LocalVolumePolicy {
            id: "local".into(),
            root: "/srv/smolvm/volumes".into(),
        };
        let (mut client, fake, _started, thread) =
            start_with_all_catalogs(h.clone(), None, None, Some(policy));
        let command = wire::BufferedCommand {
            argv: vec!["true".into()],
            env: Default::default(),
            workdir: None,
            user: None,
            stdin: None,
            max_output_bytes: 1024,
        };
        for (index, operation) in [
            wire::Operation::ExecBuffered {
                receipt: receipt.clone(),
                command: command.clone(),
            },
            wire::Operation::ExecStream {
                receipt: receipt.clone(),
                command,
            },
        ]
        .into_iter()
        .enumerate()
        {
            send(&mut client, request(index as u64 + 1, operation));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { .. }
            ));
            assert!(
                matches!(receive(&mut client), wire::ServerMessage::Event { event, .. }
                if event.stream == wire::Stream::Stdout && wire::decode_chunk(&event.data_base64).unwrap() == [0, 255, 128])
            );
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    outcome: wire::Outcome::Command {
                        observed_exit: Some(0),
                        output_bytes: 3,
                        ..
                    },
                    ..
                }
            ));
        }
        assert_eq!(fake.calls.load(Ordering::Acquire), 2);
        send(&mut client, request(3, wire::Operation::Readiness));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                outcome: wire::Outcome::Ready,
                ..
            }
        ));
        shutdown(client, thread);
    }

    #[test]
    fn policy_file_dispatch_preserves_binary_credit_and_stages_exact_upload_before_entry() {
        let mut h = terminal_hello();
        let sdk = h.sdk.as_mut().unwrap();
        sdk.feature_versions
            .extend([("volumes".into(), 1), ("compact_creation".into(), 1)]);
        h.capabilities = sdk.capabilities();
        h.limits = wire::Limits::for_sdk(sdk);
        h.package.platform = "linux".into();
        h.package.architecture = "x86_64".into();
        let mut supplied = serde_json::from_slice::<Vec<wire::GrowthTransition>>(include_bytes!(
            "../../smolbox-protocol/fixtures/growth-transitions-v1.json"
        ))
        .unwrap()
        .remove(0)
        .previous;
        supplied.target_id = h.domain.target_id.clone();
        supplied.domain_generation = h.domain.generation.clone();
        let policy = smolbox_engine::LocalVolumePolicy {
            id: "local".into(),
            root: "/srv/smolvm/volumes".into(),
        };
        let (mut client, fake, _, thread) =
            start_with_all_catalogs(h.clone(), None, None, Some(policy));
        let options = wire::FileOptions {
            guest_path: "/mnt/volumes/data/value".into(),
            max_bytes: 1024,
            mode: None,
        };
        send(
            &mut client,
            request(
                1,
                wire::Operation::ReadFile {
                    receipt: supplied.clone(),
                    options: options.clone(),
                },
            ),
        );
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 1, .. }
        ));
        assert!(
            matches!(receive(&mut client), wire::ServerMessage::Event {event, ..} if event.stream==wire::Stream::File && wire::decode_chunk(&event.data_base64).unwrap()==[0,255,128])
        );
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                outcome: wire::Outcome::File {
                    native_acknowledged: true,
                    observed_bytes: 3,
                    ..
                },
                ..
            }
        ));
        send(
            &mut client,
            request(
                2,
                wire::Operation::WriteFile {
                    receipt: supplied,
                    options,
                    total_bytes: 3,
                },
            ),
        );
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 2, .. }
        ));
        send(
            &mut client,
            wire::ClientMessage::Upload {
                epoch: h.epoch.clone(),
                id: 2,
                offset: 0,
                data_base64: wire::encode_chunk(&[0]).unwrap(),
            },
        );
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(fake.file_policy_calls.load(Ordering::Acquire), 1);
        send(
            &mut client,
            wire::ClientMessage::Upload {
                epoch: h.epoch,
                id: 2,
                offset: 1,
                data_base64: wire::encode_chunk(&[255, 128]).unwrap(),
            },
        );
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                outcome: wire::Outcome::File {
                    native_acknowledged: true,
                    observed_bytes: 3,
                    ..
                },
                ..
            }
        ));
        assert_eq!(fake.file_policy_calls.load(Ordering::Acquire), 2);
        assert_eq!(*fake.uploaded.lock().unwrap(), [0, 255, 128]);
        send(&mut client, request(3, wire::Operation::Readiness));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 3, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                outcome: wire::Outcome::Ready,
                ..
            }
        ));
        shutdown(client, thread);
    }

    #[test]
    fn mounted_source_creation_and_pack_start_forward_exact_operator_policy() {
        let mut h = terminal_hello();
        let sdk = h.sdk.as_mut().unwrap();
        sdk.feature_versions.extend([
            ("volumes".into(), 1),
            ("compact_creation".into(), 1),
            ("remote_sources".into(), 1),
        ]);
        h.capabilities = sdk.capabilities();
        h.limits = wire::Limits::for_sdk(sdk);
        h.package.platform = "linux".into();
        h.package.architecture = "x86_64".into();
        let mut fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/mounted-creation-request.json"
        ))
        .unwrap();
        let create = &mut fixture["operation"]["create"];
        create["volume_mounts"][0]["proof"]["backing"]["target_id"] =
            serde_json::json!(h.domain.target_id);
        create["volume_mounts"][0]["proof"]["backing"]["domain_generation"] =
            serde_json::json!(h.domain.generation);
        let local: wire::Create = serde_json::from_value(create.clone()).unwrap();
        let source = wire::OciSource {
            reference: format!("registry.example/app@sha256:{}", "d".repeat(64)),
            platform: "linux/amd64".into(),
        };
        create.as_object_mut().unwrap().remove("artifact");
        create["source"] = serde_json::json!({"kind":"oci","id":"approved","sha256":"d".repeat(64),"architecture":"x86_64","reference":source.reference});
        let oci: wire::OciCreate = serde_json::from_value(create.clone()).unwrap();
        let mut registry = create.clone();
        registry["source"]["kind"] = serde_json::json!("registry");
        registry["source"]["content_sha256"] = serde_json::json!("e".repeat(64));
        let registry: wire::RegistryCreate = serde_json::from_value(registry).unwrap();
        let approval = crate::package::RegistryApproval {
            source: smolbox_engine::RegistryArtifactSource {
                reference: source.reference.clone(),
                platform: source.platform.clone(),
                content_sha256: "e".repeat(64),
            },
            max_bytes: 1024,
            cache_policy: smolbox_engine::RegistryCachePolicy {
                max_bytes: 1024,
                max_files: 1,
            },
            credential_ref: None,
            token_realm: None,
        };
        for root in ["/foreign", "/srv/smolvm/volumes"] {
            let policy = smolbox_engine::LocalVolumePolicy {
                id: "local".into(),
                root: root.into(),
            };
            let (mut client, fake, _started, thread) = start_with_catalogs_and_artifacts(
                h.clone(),
                Some(vec![source.clone()]),
                Some(vec![approval.clone()]),
                Some(policy),
                vec![local.artifact.clone()],
            );
            for (index, operation) in [
                wire::Operation::Create {
                    create: local.clone(),
                },
                wire::Operation::CreateOci {
                    create: oci.clone(),
                },
                wire::Operation::CreateRegistryPrepared {
                    create: registry.clone(),
                    size_bytes: 123,
                },
            ]
            .into_iter()
            .enumerate()
            {
                send(&mut client, request(index as u64 + 1, operation));
                if root == "/srv/smolvm/volumes" {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Terminal {
                            outcome: wire::Outcome::Error {
                                code: wire::SafeCode::Native,
                                dispatch: wire::Dispatch::NotDispatched
                            },
                            ..
                        }
                    ));
                    assert_eq!(fake.calls.load(Ordering::Acquire), index + 1);
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
            }
            let mut start_receipt = serde_json::from_slice::<Vec<wire::GrowthTransition>>(
                include_bytes!("../../smolbox-protocol/fixtures/growth-transitions-v1.json"),
            )
            .unwrap()
            .remove(0)
            .previous;
            start_receipt.target_id = h.domain.target_id.clone();
            start_receipt.domain_generation = h.domain.generation.clone();
            send(
                &mut client,
                request(
                    4,
                    wire::Operation::Start {
                        receipt: start_receipt.clone(),
                    },
                ),
            );
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { .. }
            ));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    outcome: wire::Outcome::Error {
                        code: wire::SafeCode::Native,
                        ..
                    },
                    ..
                }
            ));
            assert_eq!(
                fake.calls.load(Ordering::Acquire),
                if root == "/foreign" { 1 } else { 4 }
            );
            send(
                &mut client,
                request(
                    5,
                    wire::Operation::StartOci {
                        receipt: start_receipt,
                        source: oci.source.clone(),
                    },
                ),
            );
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { .. }
            ));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    outcome: wire::Outcome::Error {
                        code: wire::SafeCode::Native,
                        ..
                    },
                    ..
                }
            ));
            assert_eq!(
                fake.calls.load(Ordering::Acquire),
                if root == "/foreign" { 2 } else { 5 }
            );
            shutdown(client, thread);
        }
    }

    #[test]
    fn checkpoint_catalog_and_feature_reject_before_native_dispatch() {
        let source = wire::CheckpointIdentity {
            kind: "checkpoint".into(),
            id: "idle-v1".into(),
            sha256: "a".repeat(64),
            architecture: "aarch64".into(),
        };
        let resources = wire::Resources {
            cpus: 1,
            memory_mib: 256,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let approval = crate::package::CheckpointApproval {
            source: source.clone(),
            path: "/operator/idle.smolcheckpoint".into(),
            max_bytes: 1024,
            sdk_version: smolvm::VERSION.into(),
            host_platform: "darwin/arm64".into(),
            resources: resources.clone(),
        };
        for (enabled, catalog, exact) in [
            (false, Some(vec![approval.clone()]), true),
            (true, None, true),
            (true, Some(vec![approval.clone()]), false),
            (true, Some(vec![approval]), true),
        ] {
            let dispatch = enabled && catalog.is_some() && exact;
            let mut h = terminal_hello();
            if enabled {
                h.sdk
                    .as_mut()
                    .unwrap()
                    .feature_versions
                    .insert("checkpoints".into(), 1);
            }
            let (mut client, fake, _, thread) =
                start_with_complete_catalogs(h, None, None, None, vec![], catalog);
            let mut requested = resources.clone();
            if !exact {
                requested.memory_mib = 512;
            }
            let create = wire::CheckpointCreate {
                checkpointable: None,
                name: "new-checkpoint".into(),
                owner_token: "b".repeat(64),
                incarnation: "c".repeat(32),
                source: source.clone(),
                resources: requested.clone(),
                labels: Default::default(),
            };
            for (i, operation) in [
                wire::Operation::QualifyCheckpointCreation {
                    checkpointable: None,
                    source: source.clone(),
                    resources: requested,
                },
                wire::Operation::CreateCheckpoint {
                    create: create.clone(),
                },
                wire::Operation::InspectCheckpointCreation { create },
            ]
            .into_iter()
            .enumerate()
            {
                send(&mut client, request(i as u64 + 1, operation));
                if dispatch {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let outcome = receive(&mut client);
                    assert!(matches!(
                        (i, outcome),
                        (
                            0,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::Qualified,
                                ..
                            },
                        ) | (
                            1,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::Error {
                                    code: wire::SafeCode::Native,
                                    dispatch: wire::Dispatch::NotDispatched,
                                },
                                ..
                            },
                        ) | (
                            2,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::CreationPresence {
                                    presence: wire::CreationPresence::Unverified,
                                },
                                ..
                            },
                        )
                    ));
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
                }
            }
            assert_eq!(
                fake.calls.load(Ordering::Acquire),
                if dispatch { 3 } else { 0 }
            );
            shutdown(client, thread);
        }
    }

    #[test]
    fn volume_requests_require_exact_operator_catalog_before_native_entry() {
        let mut approved = terminal_hello();
        let sdk = approved.sdk.as_mut().unwrap();
        sdk.feature_versions.insert("volumes".into(), 1);
        sdk.feature_versions.insert("compact_creation".into(), 1);
        approved.capabilities = sdk.capabilities();
        approved.limits = wire::Limits::for_sdk(sdk);
        approved.package.platform = "linux".into();
        approved.package.architecture = "x86_64".into();
        let operation = |policy_id: &str| wire::Operation::Volume {
            request: wire::VolumeRequest {
                policy_id: policy_id.into(),
                intent: wire::VolumeIntent {
                    worker_volume_id: format!("sbv-{}", "a".repeat(32)),
                    size_gb: 4,
                },
                action: wire::VolumeAction::InspectProvision,
            },
        };
        for catalog in [
            None,
            Some(smolbox_engine::LocalVolumePolicy {
                id: "local".into(),
                root: "/srv/smolvm/volumes".into(),
            }),
        ] {
            let present = catalog.is_some();
            let (mut client, fake, _started, thread) =
                start_with_all_catalogs(approved.clone(), None, None, catalog);
            send(&mut client, request(1, operation("other")));
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
            send(&mut client, request(2, operation("local")));
            if present {
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Accepted { id: 2, .. }
                ));
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Terminal {
                        outcome: wire::Outcome::Volume {
                            volume: wire::VolumeResult::Unverified
                        },
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
                            ..
                        },
                        ..
                    }
                ));
                assert_eq!(fake.calls.load(Ordering::Acquire), 0);
            }
            shutdown(client, thread);
        }
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
            checkpointable: None,
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
            volume_mounts: None,
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
    fn branch_creation_lookup_and_ready_resolution_require_feature_and_exact_immutable_operator_catalog(
    ) {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-creation-v1.json"
        ))
        .unwrap();
        for row in rows {
            for mode in 0..4 {
                let lookup = mode != 0;
                for policy in 0..4 {
                    let wanted: wire::BranchCreateRequest =
                        serde_json::from_value(row["request"].clone()).unwrap();
                    let mut sdk =
                        model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                    if policy != 0 {
                        sdk.feature_versions.insert("branches".into(), 1);
                    }
                    let mut h = hello();
                    h.major = wire::PARITY_PROTOCOL_MAJOR;
                    h.minor = wire::PARITY_PROTOCOL_MINOR;
                    h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                    h.package.smolvm_revision = sdk.source_revision.clone();
                    h.package.platform = "macos".into();
                    if mode >= 2 {
                        h.epoch = row["completion"]["publication"]["change"]["child_origin"]
                            ["intent"]["epoch"]
                            .as_str()
                            .unwrap()
                            .into();
                    }
                    h.package.architecture = "aarch64".into();
                    h.domain.target_id = wanted.source.target_id.clone();
                    h.domain.generation = wanted.source.domain_generation.clone();
                    h.limits = wire::Limits::for_sdk(&sdk);
                    h.capabilities = sdk.capabilities();
                    h.sdk = Some(Box::new(sdk));
                    let catalog = match policy {
                        1 => None,
                        2 => {
                            let mut wrong = wanted.approval.clone();
                            wrong.resources.disk_gb += 1;
                            Some(vec![wrong])
                        }
                        _ => Some(vec![wanted.approval.clone()]),
                    };
                    let operation = if mode == 3 {
                        wire::Operation::PublishCollectedBranchMaterial {
                            request: Box::new(wanted),
                            quiesced: true,
                        }
                    } else if mode == 2 {
                        wire::Operation::ResolveReadyBranchCompletion {
                            request: Box::new(wanted),
                            quiesced: true,
                        }
                    } else if lookup {
                        wire::Operation::InspectBranchCompletion {
                            request: Box::new(wanted),
                        }
                    } else {
                        wire::Operation::CreateBranch {
                            request: Box::new(wanted),
                        }
                    };
                    assert_eq!(is_observation(&operation), mode == 1);
                    assert_eq!(is_control(&operation), lookup);
                    let epoch = h.epoch.clone();
                    let (mut client, fake, _, thread) = start_with_policy_catalogs(
                        h,
                        None,
                        None,
                        None,
                        vec![],
                        None,
                        (None, catalog),
                    );
                    if mode == 3 {
                        fake.available.store(false, Ordering::Release);
                        assert!(matches!(
                            receive(&mut client),
                            wire::ServerMessage::Unavailable { .. }
                        ));
                    }
                    let mut message = request(1, operation);
                    if let wire::ClientMessage::Request {
                        epoch: supplied, ..
                    } = &mut message
                    {
                        *supplied = epoch.clone();
                    }
                    send(&mut client, message);
                    let response = receive(&mut client);
                    if policy == 3 {
                        assert!(matches!(response, wire::ServerMessage::Accepted { .. }));
                        let result = receive(&mut client);
                        assert!(
                            matches!(
                                result,
                                wire::ServerMessage::Terminal {
                                    outcome: wire::Outcome::BranchCreated { .. },
                                    ..
                                }
                            ) && !lookup
                                || matches!(
                                    result,
                                    wire::ServerMessage::Terminal {
                                        outcome: wire::Outcome::BranchCompletionPresence { .. },
                                        ..
                                    }
                                ) && lookup
                                    && mode != 3
                                || matches!(
                                    result,
                                    wire::ServerMessage::Terminal {
                                        outcome: wire::Outcome::CollectedBranchMaterialPublished { .. },
                                        ..
                                    }
                                ) && mode == 3
                        );
                        assert_eq!(fake.calls.load(Ordering::Acquire), 1);
                    } else {
                        assert!(matches!(
                            response,
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
                    send(&mut client, wire::ClientMessage::Shutdown { epoch });
                    assert!(thread.join().unwrap().is_ok());
                }
            }
        }
    }
    #[test]
    fn held_release_and_qualification_require_feature_catalog_and_separate_lanes() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-held-release-v1.json"
        ))
        .unwrap();
        for row in rows {
            for qualify in [false, true] {
                for policy in 0..4 {
                    let wanted: wire::BranchHeldReleaseRequest =
                        serde_json::from_value(row["request"].clone()).unwrap();
                    let mut sdk =
                        model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                    if policy != 0 {
                        sdk.feature_versions.insert("branches".into(), 1);
                    }
                    let mut h = hello();
                    h.major = wire::PARITY_PROTOCOL_MAJOR;
                    h.minor = wire::PARITY_PROTOCOL_MINOR;
                    h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                    h.package.smolvm_revision = sdk.source_revision.clone();
                    h.package.platform = wanted.completion.publication.change.platform.clone();
                    h.package.architecture = if h.package.platform == "linux" {
                        "x86_64"
                    } else {
                        "aarch64"
                    }
                    .into();
                    h.domain.target_id = wanted.source.target_id.clone();
                    h.domain.generation = wanted.source.domain_generation.clone();
                    h.limits = wire::Limits::for_sdk(&sdk);
                    h.capabilities = sdk.capabilities();
                    h.sdk = Some(Box::new(sdk));
                    let catalog = match policy {
                        1 => None,
                        2 => {
                            let mut wrong = wanted.approval().clone();
                            wrong.resources.disk_gb += 1;
                            Some(vec![wrong])
                        }
                        _ => Some(vec![wanted.approval().clone()]),
                    };
                    let operation = if qualify {
                        wire::Operation::QualifyHeldBranchRelease {
                            request: Box::new(wanted),
                        }
                    } else {
                        wire::Operation::ReleaseHeldBranch {
                            request: Box::new(wanted),
                        }
                    };
                    assert_eq!(is_observation(&operation), qualify);
                    assert_eq!(is_control(&operation), qualify);
                    let (mut client, fake, _, thread) = start_with_policy_catalogs(
                        h,
                        None,
                        None,
                        None,
                        vec![],
                        None,
                        (None, catalog),
                    );
                    send(&mut client, request(1, operation));
                    let response = receive(&mut client);
                    if policy == 3 {
                        assert!(matches!(response, wire::ServerMessage::Accepted { .. }));
                        let response = receive(&mut client);
                        assert!(
                            matches!(
                                response,
                                wire::ServerMessage::Terminal {
                                    outcome: wire::Outcome::HeldBranchReleased { .. },
                                    ..
                                }
                            ) && !qualify
                                || matches!(
                                    response,
                                    wire::ServerMessage::Terminal {
                                        outcome: wire::Outcome::HeldBranchReleasePresence { .. },
                                        ..
                                    }
                                ) && qualify
                        );
                        assert_eq!(fake.calls.load(Ordering::Acquire), 1);
                    } else {
                        assert!(matches!(
                            response,
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
                    shutdown(client, thread);
                }
            }
        }
    }
    #[test]
    fn branch_child_absence_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-child-absence-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::BranchChildAbsenceRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..4 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = wanted.completion.publication.change.platform.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.child.target_id.clone();
                h.domain.generation = wanted.child.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::QualifyBranchChildAbsence {
                    request: Box::new(wanted.clone()),
                };
                assert!(is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::BranchChildAbsent { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn branch_backing_release_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-backing-release-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::BranchBackingReleaseRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..4 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = wanted.completion.publication.change.platform.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.child.target_id.clone();
                h.domain.generation = wanted.child.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::ReleaseBranchBacking {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::BranchBackingReleased { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn released_delete_continuation_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/released-branch-deletion-continuation-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::ReleasedBranchDeletionContinuationRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..4 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = wanted.completion.publication.change.platform.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.child.target_id.clone();
                h.domain.generation = wanted.child.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::ContinueReleasedBranchDeletion {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::ReleasedBranchDeletionContinued { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn released_delete_cleanup_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/released-branch-deletion-cleanup-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::ReleasedBranchDeletionCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..4 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = wanted.completion.publication.change.platform.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.child.target_id.clone();
                h.domain.generation = wanted.child.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::CleanupReleasedBranchDeletion {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::ReleasedBranchDeletionCleaned { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn original_delete_collection_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-deletion-collection-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::BranchDeletionCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..4 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = wanted.completion.publication.change.platform.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.child.target_id.clone();
                h.domain.generation = wanted.child.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::CollectBranchDeletion {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::BranchDeletionCollected { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn partial_collection_preflight_requires_feature_and_exact_catalog_while_quiesced() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-collection-candidate-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PartialBranchCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..5 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                    if policy != 4 {
                        sdk.feature_versions
                            .insert("partial_collection_preflight".into(), 1);
                    }
                }
                let mut h = hello();
                h.epoch = row["candidate"]["epoch"].as_str().unwrap().into();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["platform"].as_str().unwrap().to_owned();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.creation.source.target_id.clone();
                h.domain.generation = wanted.creation.source.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.creation.approval.clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.creation.approval.clone()]),
                };
                let operation = wire::Operation::InspectPartialBranchCollection {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::PartialBranchCollectionCandidate { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn partial_branch_collection_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-collection-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PartialBranchCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..4 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["platform"].as_str().unwrap().to_owned();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.creation.source.target_id.clone();
                h.domain.generation = wanted.creation.source.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.creation.approval.clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.creation.approval.clone()]),
                };
                let operation = wire::Operation::CollectPartialBranch {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::PartialBranchCollected { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn partial_branch_disposal_uses_exact_fenced_control_without_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for resolve in [false, true] {
                for policy in 0..4 {
                    let mut sdk =
                        model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                    if policy != 0 {
                        sdk.feature_versions.insert("branches".into(), 1);
                    }
                    let mut h = hello();
                    h.epoch = row["proof"]["publication"]["change"]["child_origin"]["intent"]
                        ["epoch"]
                        .as_str()
                        .unwrap()
                        .into();
                    h.major = 2;
                    h.minor = 0;
                    h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                    h.package.smolvm_revision = sdk.source_revision.clone();
                    h.package.platform = row["platform"].as_str().unwrap().to_owned();
                    h.package.architecture = if h.package.platform == "macos" {
                        "aarch64"
                    } else {
                        "x86_64"
                    }
                    .into();
                    h.domain.target_id =
                        wanted.collection_request.creation.source.target_id.clone();
                    h.domain.generation = wanted
                        .collection_request
                        .creation
                        .source
                        .domain_generation
                        .clone();
                    h.limits = wire::Limits::for_sdk(&sdk);
                    h.capabilities = sdk.capabilities();
                    h.sdk = Some(Box::new(sdk));
                    let catalog = match policy {
                        1 => None,
                        2 => {
                            let mut wrong = wanted.collection_request.creation.approval.clone();
                            wrong.resources.disk_gb += 1;
                            Some(vec![wrong])
                        }
                        _ => Some(vec![wanted.collection_request.creation.approval.clone()]),
                    };
                    let operation = if resolve {
                        wire::Operation::ResolvePartialBranchDisposal {
                            request: Box::new(wanted.clone()),
                        }
                    } else {
                        wire::Operation::DisposePartialBranch {
                            request: Box::new(wanted.clone()),
                        }
                    };
                    assert!(!is_observation(&operation) && is_control(&operation));
                    let (mut client, fake, _, thread) = start_with_policy_catalogs(
                        h,
                        None,
                        None,
                        None,
                        vec![],
                        None,
                        (None, catalog),
                    );
                    fake.available.store(false, Ordering::Release);
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Unavailable { .. }
                    ));
                    send(
                        &mut client,
                        wire::ClientMessage::Request {
                            epoch: fake.epoch.clone(),
                            id: 1,
                            budget_ms: 1000,
                            initial_credit: wire::INITIAL_CREDIT_BYTES,
                            initial_event_credit: wire::INITIAL_CREDIT_EVENTS,
                            operation,
                        },
                    );
                    if policy == 3 {
                        assert!(matches!(
                            receive(&mut client),
                            wire::ServerMessage::Accepted { .. }
                        ));
                        let terminal = receive(&mut client);
                        assert!(
                            matches!(
                                terminal,
                                wire::ServerMessage::Terminal {
                                    outcome: wire::Outcome::PartialBranchDisposed { .. },
                                    ..
                                }
                            ),
                            "{}",
                            serde_json::to_string(&terminal).unwrap()
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
                            epoch: fake.epoch.clone(),
                        },
                    );
                    assert!(thread.join().unwrap().is_ok());
                }
            }
        }
    }
    #[test]
    fn partial_disposal_cleanup_uses_exact_fenced_control_without_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-disposal-cleanup-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..6 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.epoch = row["proof"]["disposal"]["publication"]["change"]["child_origin"]
                    ["intent"]["epoch"]
                    .as_str()
                    .unwrap()
                    .into();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["platform"].as_str().unwrap().to_owned();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted
                    .disposal_request
                    .collection_request
                    .creation
                    .source
                    .target_id
                    .clone();
                h.domain.generation = wanted
                    .disposal_request
                    .collection_request
                    .creation
                    .source
                    .domain_generation
                    .clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted
                            .disposal_request
                            .collection_request
                            .creation
                            .approval
                            .clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted
                        .disposal_request
                        .collection_request
                        .creation
                        .approval
                        .clone()]),
                };
                if policy == 4 {
                    h.capabilities
                        .retain(|cap| *cap != wire::Capability::Delete);
                }
                if policy == 5 {
                    h.domain.generation = "0".repeat(32);
                }
                let operation = wire::Operation::CleanupPartialBranchDisposal {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(
                    &mut client,
                    wire::ClientMessage::Request {
                        epoch: fake.epoch.clone(),
                        id: 1,
                        budget_ms: 1000,
                        initial_credit: wire::INITIAL_CREDIT_BYTES,
                        initial_event_credit: wire::INITIAL_CREDIT_EVENTS,
                        operation,
                    },
                );
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::PartialBranchDisposalCleaned { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
                    );
                    assert_eq!(fake.calls.load(Ordering::Acquire), 1);
                } else {
                    let expected = if policy == 5 {
                        wire::SafeCode::Ownership
                    } else {
                        wire::SafeCode::Unsupported
                    };
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Terminal {
                            outcome: wire::Outcome::Error {
                                code,
                                dispatch: wire::Dispatch::NotDispatched
                            },
                            ..
                        } if code == expected
                    ));
                    assert_eq!(fake.calls.load(Ordering::Acquire), 0);
                }
                send(
                    &mut client,
                    wire::ClientMessage::Shutdown {
                        epoch: fake.epoch.clone(),
                    },
                );
                assert!(thread.join().unwrap().is_ok());
            }
        }
    }
    #[test]
    fn partial_cleanup_qualification_uses_original_fenced_inspection_without_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-cleanup-candidate-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..6 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.epoch = row["candidate"]["publication"]["change"]["child_origin"]["intent"]
                    ["epoch"]
                    .as_str()
                    .unwrap()
                    .into();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["platform"].as_str().unwrap().to_owned();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.collection_request.creation.source.target_id.clone();
                h.domain.generation = wanted
                    .collection_request
                    .creation
                    .source
                    .domain_generation
                    .clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.collection_request.creation.approval.clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.collection_request.creation.approval.clone()]),
                };
                if policy == 4 {
                    h.capabilities
                        .retain(|cap| *cap != wire::Capability::Inspect);
                }
                if policy == 5 {
                    h.domain.generation = "0".repeat(32);
                }
                let operation = wire::Operation::QualifyPartialBranchCleanup {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(
                    &mut client,
                    wire::ClientMessage::Request {
                        epoch: fake.epoch.clone(),
                        id: 1,
                        budget_ms: 1000,
                        initial_credit: wire::INITIAL_CREDIT_BYTES,
                        initial_event_credit: wire::INITIAL_CREDIT_EVENTS,
                        operation,
                    },
                );
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::PartialBranchCleanupCandidate { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
                    );
                    assert_eq!(fake.calls.load(Ordering::Acquire), 1);
                } else {
                    let expected = if policy == 5 {
                        wire::SafeCode::Ownership
                    } else {
                        wire::SafeCode::Unsupported
                    };
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Terminal {
                            outcome: wire::Outcome::Error {
                                code,
                                dispatch: wire::Dispatch::NotDispatched
                            },
                            ..
                        } if code == expected
                    ));
                    assert_eq!(fake.calls.load(Ordering::Acquire), 0);
                }
                send(
                    &mut client,
                    wire::ClientMessage::Shutdown {
                        epoch: fake.epoch.clone(),
                    },
                );
                assert!(thread.join().unwrap().is_ok());
            }
        }
    }
    #[test]
    fn unneeded_cleanup_resolution_uses_original_inspect_control_without_removal_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-cleanup-unneeded-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..7 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                    if policy != 6 {
                        sdk.feature_versions
                            .insert("partial_cleanup_resolution".into(), 1);
                    }
                }
                let mut h = hello();
                h.epoch = row["proof"]["disposal"]["publication"]["change"]["child_origin"]
                    ["intent"]["epoch"]
                    .as_str()
                    .unwrap()
                    .into();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["platform"].as_str().unwrap().to_owned();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted
                    .disposal_request
                    .collection_request
                    .creation
                    .source
                    .target_id
                    .clone();
                h.domain.generation = wanted
                    .disposal_request
                    .collection_request
                    .creation
                    .source
                    .domain_generation
                    .clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted
                            .disposal_request
                            .collection_request
                            .creation
                            .approval
                            .clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted
                        .disposal_request
                        .collection_request
                        .creation
                        .approval
                        .clone()]),
                };
                if policy == 4 {
                    h.capabilities
                        .retain(|cap| *cap != wire::Capability::Inspect);
                }
                if policy == 5 {
                    h.domain.generation = "0".repeat(32);
                }
                let operation = wire::Operation::ResolvePartialBranchCleanup {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(
                    &mut client,
                    wire::ClientMessage::Request {
                        epoch: fake.epoch.clone(),
                        id: 1,
                        budget_ms: 1000,
                        initial_credit: wire::INITIAL_CREDIT_BYTES,
                        initial_event_credit: wire::INITIAL_CREDIT_EVENTS,
                        operation,
                    },
                );
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::PartialBranchCleanupUnneeded { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
                    );
                    assert_eq!(fake.calls.load(Ordering::Acquire), 1);
                } else {
                    let expected = if policy == 5 {
                        wire::SafeCode::Ownership
                    } else {
                        wire::SafeCode::Unsupported
                    };
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Terminal {
                            outcome: wire::Outcome::Error {
                                code,
                                dispatch: wire::Dispatch::NotDispatched
                            },
                            ..
                        } if code == expected
                    ));
                    assert_eq!(fake.calls.load(Ordering::Acquire), 0);
                }
                send(
                    &mut client,
                    wire::ClientMessage::Shutdown {
                        epoch: fake.epoch.clone(),
                    },
                );
                assert!(thread.join().unwrap().is_ok());
            }
        }
    }
    #[test]
    fn released_delete_resolution_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/released-branch-deletion-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::ReleasedBranchDeletionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..4 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = wanted.completion.publication.change.platform.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.child.target_id.clone();
                h.domain.generation = wanted.child.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::ResolveReleasedBranchDeletion {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::ReleasedBranchDeletionResolved { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn held_delete_resolution_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/held-branch-deletion-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::HeldBranchDeletionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..4 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = wanted.completion.publication.change.platform.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.child.target_id.clone();
                h.domain.generation = wanted.child.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::ResolveHeldBranchDeletion {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::HeldBranchDeletionResolved { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn partial_child_absence_uses_exact_original_catalog_epoch_and_control_output() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-child-absence-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PartialBranchChildAbsenceRequest =
                serde_json::from_value(row["proof"]["request"].clone()).unwrap();
            for policy in 0..5 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["proof"]["request"]["disposal"]["publication"]["change"]
                    ["platform"]
                    .as_str()
                    .unwrap()
                    .into();
                h.epoch = row["proof"]["request"]["disposal"]["publication"]["change"]
                    ["child_origin"]["intent"]["epoch"]
                    .as_str()
                    .unwrap()
                    .into();
                let epoch = h.epoch.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted
                    .disposal
                    .request
                    .collection_request
                    .creation
                    .source
                    .target_id
                    .clone();
                h.domain.generation = wanted
                    .disposal
                    .request
                    .collection_request
                    .creation
                    .source
                    .domain_generation
                    .clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                if policy == 4 {
                    h.capabilities
                        .retain(|value| *value != wire::Capability::Inspect);
                }

                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::QualifyPartialBranchChildAbsence {
                    request: Box::new(wanted.clone()),
                };
                assert!(is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                let mut message = request(1, operation);
                if let wire::ClientMessage::Request { epoch: value, .. } = &mut message {
                    *value = epoch.clone();
                }
                send(&mut client, message);
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::PartialBranchChildAbsent { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                        epoch: epoch.clone(),
                    },
                );
                assert!(thread.join().unwrap().is_ok());
            }
        }
    }
    #[test]
    fn partial_backing_uses_exact_original_catalog_epoch_and_control_output() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/partial-branch-backing-release-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PartialBranchBackingReleaseRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..5 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["request"]["disposal"]["publication"]["change"]
                    ["platform"]
                    .as_str()
                    .unwrap()
                    .into();
                h.epoch = row["request"]["disposal"]["publication"]["change"]["child_origin"]
                    ["intent"]["epoch"]
                    .as_str()
                    .unwrap()
                    .into();
                let epoch = h.epoch.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted
                    .disposal
                    .request
                    .collection_request
                    .creation
                    .source
                    .target_id
                    .clone();
                h.domain.generation = wanted
                    .disposal
                    .request
                    .collection_request
                    .creation
                    .source
                    .domain_generation
                    .clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                if policy == 4 {
                    h.capabilities
                        .retain(|value| *value != wire::Capability::Inspect);
                }

                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::ReleasePartialBranchBacking {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                let mut message = request(1, operation);
                if let wire::ClientMessage::Request { epoch: value, .. } = &mut message {
                    *value = epoch.clone();
                }
                send(&mut client, message);
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::BranchBackingReleased { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                        epoch: epoch.clone(),
                    },
                );
                assert!(thread.join().unwrap().is_ok());
            }
        }
    }
    #[test]
    fn unbooted_child_absence_uses_exact_original_catalog_epoch_and_control_output() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/unbooted-branch-child-absence-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::UnbootedBranchChildAbsenceRequest =
                serde_json::from_value(row["proof"]["request"].clone()).unwrap();
            for policy in 0..5 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["proof"]["request"]["disposal"]["publication"]["change"]
                    ["platform"]
                    .as_str()
                    .unwrap()
                    .into();
                h.epoch = row["proof"]["request"]["disposal"]["publication"]["change"]
                    ["child_origin"]["intent"]["epoch"]
                    .as_str()
                    .unwrap()
                    .into();
                let epoch = h.epoch.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.disposal.creation.source.target_id.clone();
                h.domain.generation = wanted.disposal.creation.source.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                if policy == 4 {
                    h.capabilities
                        .retain(|value| *value != wire::Capability::Inspect);
                }

                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = wire::Operation::QualifyUnbootedBranchChildAbsence {
                    request: Box::new(wanted.clone()),
                };
                assert!(is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                let mut message = request(1, operation);
                if let wire::ClientMessage::Request { epoch: value, .. } = &mut message {
                    *value = epoch.clone();
                }
                send(&mut client, message);
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::UnbootedBranchChildAbsent { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                        epoch: epoch.clone(),
                    },
                );
                assert!(thread.join().unwrap().is_ok());
            }
        }
    }
    #[test]
    fn unbooted_candidate_uses_readonly_control_exact_catalog_and_original_epoch() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/unbooted-branch-disposal-candidate-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::BranchCreateRequest =
                serde_json::from_value(row["creation"].clone()).unwrap();
            for policy in 0..5 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = row["candidate"]["publication"]["change"]["platform"]
                    .as_str()
                    .unwrap()
                    .into();
                h.epoch = row["candidate"]["publication"]["change"]["child_origin"]["intent"]
                    ["epoch"]
                    .as_str()
                    .unwrap()
                    .into();
                let epoch = h.epoch.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.source.target_id.clone();
                h.domain.generation = wanted.source.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                if policy == 4 {
                    h.capabilities
                        .retain(|value| *value != wire::Capability::Inspect);
                }

                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval.clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval.clone()]),
                };
                let operation = wire::Operation::InspectUnbootedBranchDisposal {
                    quiesced: true,
                    request: Box::new(wanted.clone()),
                };
                assert!(is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                let mut message = request(1, operation);
                if let wire::ClientMessage::Request { epoch: value, .. } = &mut message {
                    *value = epoch.clone();
                }
                send(&mut client, message);
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::UnbootedBranchDisposalCandidate { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                        epoch: epoch.clone(),
                    },
                );
                assert!(thread.join().unwrap().is_ok());
            }
        }
    }
    #[test]
    fn prepared_retirement_uses_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/prepared-branch-retirement-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::PreparedBranchRetirementRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..5 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = "macos".into();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.creation.source.target_id.clone();
                h.domain.generation = wanted.creation.source.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                if policy == 4 {
                    h.capabilities
                        .retain(|value| *value != wire::Capability::Inspect);
                }

                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.creation.approval.clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.creation.approval.clone()]),
                };
                let operation = wire::Operation::RetirePreparedBranch {
                    request: Box::new(wanted.clone()),
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::PreparedBranchRetired { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn unbooted_controls_require_exact_catalog_capability_and_fenced_branch_output() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/unbooted-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::UnbootedBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for kind in 0..3 {
                for policy in 0..5 {
                    let mut sdk =
                        model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                    if policy != 0 {
                        sdk.feature_versions.insert("branches".into(), 1);
                    }
                    let mut h = hello();
                    h.major = 2;
                    h.minor = 0;
                    h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                    h.package.smolvm_revision = sdk.source_revision.clone();
                    h.package.platform = row["proof"]["publication"]["change"]["platform"]
                        .as_str()
                        .unwrap()
                        .into();
                    h.package.architecture = if h.package.platform == "macos" {
                        "aarch64"
                    } else {
                        "x86_64"
                    }
                    .into();
                    h.domain.target_id = wanted.creation.source.target_id.clone();
                    h.domain.generation = wanted.creation.source.domain_generation.clone();
                    h.limits = wire::Limits::for_sdk(&sdk);
                    h.capabilities = sdk.capabilities();
                    if policy == 4 {
                        h.capabilities.retain(|value| {
                            *value
                                != if kind == 0 {
                                    wire::Capability::Delete
                                } else {
                                    wire::Capability::Inspect
                                }
                        });
                    }

                    h.sdk = Some(Box::new(sdk));
                    let catalog = match policy {
                        1 => None,
                        2 => {
                            let mut wrong = wanted.creation.approval.clone();
                            wrong.resources.disk_gb += 1;
                            Some(vec![wrong])
                        }
                        _ => Some(vec![wanted.creation.approval.clone()]),
                    };
                    let operation = match kind {
                        0 => wire::Operation::DisposeUnbootedBranch {
                            request: Box::new(wanted.clone()),
                        },
                        1 => wire::Operation::ResolveUnbootedBranchDisposal {
                            request: Box::new(wanted.clone()),
                        },
                        _ => wire::Operation::ReleaseUnbootedBranchBacking {
                            request: Box::new(
                                serde_json::from_value(row["backing_request"].clone()).unwrap(),
                            ),
                        },
                    };
                    assert!(!is_observation(&operation) && is_control(&operation));
                    let (mut client, fake, _, thread) = start_with_policy_catalogs(
                        h,
                        None,
                        None,
                        None,
                        vec![],
                        None,
                        (None, catalog),
                    );
                    fake.available.store(false, Ordering::Release);
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Unavailable { .. }
                    ));
                    send(&mut client, request(1, operation));
                    if policy == 3 {
                        assert!(matches!(
                            receive(&mut client),
                            wire::ServerMessage::Accepted { .. }
                        ));
                        let terminal = receive(&mut client);
                        assert!(
                            matches!(
                                terminal,
                                wire::ServerMessage::Terminal {
                                    outcome: wire::Outcome::UnbootedBranchDisposed { .. }
                                        | wire::Outcome::BranchBackingReleased { .. },
                                    ..
                                }
                            ),
                            "{}",
                            serde_json::to_string(&terminal).unwrap()
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
                    shutdown(client, thread);
                }
            }
        }
    }
    #[test]
    fn held_delete_actions_use_fenced_control_with_exact_catalog_and_no_sdk_fallback() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/held-branch-deletion-action-v1.json"
        ))
        .unwrap();
        for row in rows {
            let wanted: wire::HeldBranchDeletionActionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for policy in 0..5 {
                let mut sdk = model_branch_sdk_identity().unwrap_or_else(|_| panic!("SDK policy"));
                if policy != 0 {
                    sdk.feature_versions.insert("branches".into(), 1);
                }
                let mut h = hello();
                h.major = 2;
                h.minor = 0;
                h.package.engine_version = env!("CARGO_PKG_VERSION").into();
                h.package.smolvm_revision = sdk.source_revision.clone();
                h.package.platform = wanted.completion.publication.change.platform.clone();
                h.package.architecture = if h.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                h.domain.target_id = wanted.child.target_id.clone();
                h.domain.generation = wanted.child.domain_generation.clone();
                h.limits = wire::Limits::for_sdk(&sdk);
                h.capabilities = sdk.capabilities();
                if policy == 4 {
                    h.capabilities
                        .retain(|capability| *capability != wire::Capability::Delete);
                }
                h.sdk = Some(Box::new(sdk));
                let catalog = match policy {
                    1 => None,
                    2 => {
                        let mut wrong = wanted.approval().clone();
                        wrong.resources.disk_gb += 1;
                        Some(vec![wrong])
                    }
                    _ => Some(vec![wanted.approval().clone()]),
                };
                let operation = match wanted.action {
                    wire::HeldBranchDeletionAction::Continue => {
                        wire::Operation::ContinueHeldBranchDeletion {
                            request: Box::new(wanted.clone()),
                        }
                    }
                    wire::HeldBranchDeletionAction::Cleanup => {
                        wire::Operation::CleanupHeldBranchDeletion {
                            request: Box::new(wanted.clone()),
                        }
                    }
                };
                assert!(!is_observation(&operation) && is_control(&operation));
                let (mut client, fake, _, thread) =
                    start_with_policy_catalogs(h, None, None, None, vec![], None, (None, catalog));
                fake.available.store(false, Ordering::Release);
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Unavailable { .. }
                ));
                send(&mut client, request(1, operation));
                if policy == 3 {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let terminal = receive(&mut client);
                    assert!(
                        matches!(
                            terminal,
                            wire::ServerMessage::Terminal {
                                outcome: wire::Outcome::HeldBranchDeletionContinued { .. }
                                    | wire::Outcome::HeldBranchDeletionCleaned { .. },
                                ..
                            }
                        ),
                        "{}",
                        serde_json::to_string(&terminal).unwrap()
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
                shutdown(client, thread);
            }
        }
    }
    #[test]
    fn branch_source_requires_its_feature_and_uses_work_without_stream_or_boot_authority() {
        // Semantic helper peer only: no SDK source, fork or VM.
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-preflight-v1.json"
        ))
        .unwrap();
        let operation: wire::Operation =
            serde_json::from_value(fixture["operation"].clone()).unwrap();
        assert!(!is_observation(&operation) && !is_control(&operation));
        for enabled in [false, true] {
            let mut sdk = model_branch_sdk_identity()
                .unwrap_or_else(|_| panic!("invalid compiled SDK policy"));
            if enabled {
                sdk.feature_versions.insert("branches".into(), 1);
            }
            let mut approved = hello();
            approved.major = wire::PARITY_PROTOCOL_MAJOR;
            approved.minor = wire::PARITY_PROTOCOL_MINOR;
            approved.package.engine_version = env!("CARGO_PKG_VERSION").into();
            approved.package.smolvm_revision = sdk.source_revision.clone();
            let source = operation.receipt().unwrap();
            approved.domain.target_id = source.target_id.clone();
            approved.domain.generation = source.domain_generation.clone();
            approved.limits = wire::Limits::for_sdk(&sdk);
            approved.capabilities = sdk.capabilities();
            approved.sdk = Some(Box::new(sdk));
            let (mut client, fake, _, thread) = start_with(approved);
            send(&mut client, request(1, operation.clone()));
            let response = receive(&mut client);
            if enabled {
                assert!(matches!(response, wire::ServerMessage::Accepted { .. }));
                assert!(matches!(
                    receive(&mut client),
                    wire::ServerMessage::Terminal {
                        outcome: wire::Outcome::Observed {
                            observation: wire::Observation {
                                state: wire::ObservedState::Running,
                                ..
                            }
                        },
                        ..
                    }
                ));
                assert_eq!(fake.calls.load(Ordering::Acquire), 1);
            } else {
                assert!(matches!(
                    response,
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
            shutdown(client, thread);
        }
    }
    #[test]
    fn capture_resolution_control_dispatch_survives_busy_workers_and_modeled_quarantine() {
        // Pure native peer model: no SDK, VM, process loss or forced termination.
        let proofs: Vec<wire::CaptureResolutionTransition> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/capture-resolutions-v1.json"
        ))
        .unwrap();
        let proof = &proofs[0];
        let mut sdk =
            model_sdk_identity().unwrap_or_else(|_| panic!("invalid compiled SDK policy"));
        sdk.feature_versions.insert("checkpoints".into(), 1);
        let mut approved = hello();
        approved.major = wire::PARITY_PROTOCOL_MAJOR;
        approved.minor = wire::PARITY_PROTOCOL_MINOR;
        approved.package.engine_version = env!("CARGO_PKG_VERSION").into();
        approved.package.smolvm_revision = sdk.source_revision.clone();
        approved.domain.target_id = proof.previous.target_id.clone();
        approved.domain.generation = proof.previous.domain_generation.clone();
        approved.limits = wire::Limits::for_sdk(&sdk);
        approved.sdk = Some(Box::new(sdk));
        approved.capabilities.extend([
            wire::Capability::Health,
            wire::Capability::Readiness,
            wire::Capability::Inspect,
        ]);
        let (mut client, fake, started, thread) = start_with(approved);
        let command = |name: &str| {
            let mut operation = exec(name);
            if let wire::Operation::Exec { receipt, .. } = &mut operation {
                *receipt = proof.previous.clone();
            }
            operation
        };
        for id in 1..=WORKERS as u64 {
            let mut message = request(id, command("hold"));
            if let wire::ClientMessage::Request { budget_ms, .. } = &mut message {
                *budget_ms = 5000;
            }
            send(&mut client, message);
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { .. }
            ));
            started.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        let resolution = wire::Operation::ResolveCapture {
            receipt: proof.previous.clone(),
            operation_id: proof.change.intent.operation_id.clone(),
            request: proof.change.intent.request.clone(),
            quiesced: true,
        };
        assert!(!is_observation(&resolution));
        assert!(is_control(&resolution));
        send(&mut client, request(5, resolution.clone()));
        let response = receive(&mut client);
        assert!(
            matches!(response, wire::ServerMessage::Accepted { id: 5, .. }),
            "{}",
            serde_json::to_string(&response).unwrap()
        );
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 5,
                outcome: wire::Outcome::CaptureResolved { .. },
                ..
            }
        ));
        let cleanup = wire::Operation::CleanupCaptureStaging {
            receipt: proof.previous.clone(),
            operation_id: proof.change.intent.operation_id.clone(),
            request: proof.change.intent.request.clone(),
            quiesced: true,
        };
        send(&mut client, request(6, cleanup));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 6, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 6,
                outcome: wire::Outcome::CaptureStagingCleaned { .. },
                ..
            }
        ));
        let abort = wire::Operation::AbortCaptureStaging {
            receipt: proof.previous.clone(),
            operation_id: proof.change.intent.operation_id.clone(),
            request: proof.change.intent.request.clone(),
            quiesced: true,
        };
        assert!(!is_observation(&abort));
        assert!(is_control(&abort));
        send(&mut client, request(7, abort.clone()));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 7, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 7,
                outcome: wire::Outcome::CaptureStagingAborted { .. },
                ..
            }
        ));
        let qualification = wire::Operation::QualifyAbortedCaptureSource {
            receipt: proof.previous.clone(),
            operation_id: proof.change.intent.operation_id.clone(),
            request: proof.change.intent.request.clone(),
            quiesced: true,
        };
        assert!(!is_observation(&qualification));
        assert!(is_control(&qualification));
        send(&mut client, request(8, qualification.clone()));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 8, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 8,
                outcome: wire::Outcome::AbortedCaptureSourceQualified { .. },
                ..
            }
        ));
        for id in 1..=WORKERS as u64 {
            send(
                &mut client,
                wire::ClientMessage::Cancel {
                    epoch: hello().epoch,
                    id,
                },
            );
        }
        for _ in 0..WORKERS {
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    outcome: wire::Outcome::Command {
                        completion: wire::Completion::Cancelled,
                        ..
                    },
                    ..
                }
            ));
        }
        send(&mut client, request(9, command("unavailable")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 9, .. }
        ));
        unavailable_and_terminal_id(&mut client, 9);
        send(&mut client, request(10, resolution));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 10, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 10,
                outcome: wire::Outcome::CaptureResolved { .. },
                ..
            }
        ));
        let lookup = wire::Operation::InspectCaptureResolution {
            receipt: proof.previous.clone(),
            operation_id: proof.change.intent.operation_id.clone(),
            request: proof.change.intent.request.clone(),
        };
        send(&mut client, request(11, lookup));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 11, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 11,
                outcome: wire::Outcome::CaptureResolutionPresence {
                    transition: Some(_)
                },
                ..
            }
        ));
        let cleanup = wire::Operation::CleanupCaptureStaging {
            receipt: proof.previous.clone(),
            operation_id: proof.change.intent.operation_id.clone(),
            request: proof.change.intent.request.clone(),
            quiesced: true,
        };
        assert!(!is_observation(&cleanup));
        assert!(is_control(&cleanup));
        send(&mut client, request(12, cleanup));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 12, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 12,
                outcome: wire::Outcome::CaptureStagingCleaned { .. },
                ..
            }
        ));
        send(&mut client, request(13, abort));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 13, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 13,
                outcome: wire::Outcome::CaptureStagingAborted { .. },
                ..
            }
        ));
        send(&mut client, request(14, qualification));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Accepted { id: 14, .. }
        ));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 14,
                outcome: wire::Outcome::AbortedCaptureSourceQualified { .. },
                ..
            }
        ));
        send(&mut client, request(15, command("hold")));
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Terminal {
                id: 15,
                sequence: 0,
                outcome: wire::Outcome::Error {
                    code: wire::SafeCode::State,
                    dispatch: wire::Dispatch::NotDispatched
                },
                ..
            }
        ));
        assert!(!fake.available());
        shutdown(client, thread);
    }

    #[test]
    fn full_work_queue_preserves_observation_dispatch_and_graceful_control() {
        let sdk = model_sdk_identity().unwrap_or_else(|_| panic!("invalid compiled SDK policy"));
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
        let sdk = model_sdk_identity().unwrap_or_else(|_| panic!("invalid compiled SDK policy"));
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
        let sdk = model_sdk_identity().unwrap_or_else(|_| panic!("invalid compiled SDK policy"));
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
        unavailable_and_terminal_id(client, 1);
    }
    fn unavailable_and_terminal_id(client: &mut UnixStream, expected_id: u64) {
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
                        id,
                        outcome: wire::Outcome::Command {
                            dispatch: wire::Dispatch::MayHaveDispatched,
                            observed_exit: None,
                            ..
                        },
                        ..
                    } if *id == expected_id
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
            approved_branches: None,
            publish_address: None,
            schema: 1,
            target_id: "test".into(),
            generation: "cd".repeat(16),
            allow_initialize: false,
            package_manifest_sha256: "01".repeat(32),
            approved_artifacts: vec![],
            approved_oci_sources: None,
            approved_registry_sources: None,
            approved_volume_policy: None,
            approved_checkpoints: None,
            approved_export_destinations: None,
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
    fn export_fixture() -> wire::ExportPublication {
        serde_json::from_str::<Vec<wire::ExportPublication>>(include_str!(
            "../../smolbox-protocol/fixtures/export-publications-v1.json"
        ))
        .unwrap()
        .remove(0)
    }
    fn export_hello() -> wire::Hello {
        let proof = export_fixture();
        let mut hello = terminal_hello();
        hello.domain.target_id = proof.source.target_id;
        hello.domain.generation = proof.source.domain_generation;
        hello.package.platform = "linux".into();
        hello.package.architecture = "x86_64".into();
        hello
            .sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("exports".into(), 1);
        hello
            .sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("compact_creation".into(), 1);
        hello.capabilities = hello.sdk.as_ref().unwrap().capabilities();
        hello.limits = wire::Limits::for_sdk(hello.sdk.as_ref().unwrap());
        hello
    }
    fn export_request() -> wire::ExportRequest {
        let proof = export_fixture();
        wire::ExportRequest {
            request_sha256: proof.request_sha256,
            destination_id: proof.identity.destination_id,
            destination_sha256: proof.identity.destination_sha256,
            tag: proof.identity.tag,
            max_artifact_bytes: 1048576,
            max_staging_bytes: 4194304,
        }
    }
    fn export_approval() -> crate::package::ExportApproval {
        let proof = export_fixture();
        let identity = proof.identity;
        let mut approval: crate::package::ExportApproval = serde_json::from_value(serde_json::json!({"id":identity.destination_id,"registry":identity.registry,"repository":identity.repository,"credential_ref":"publisher","immutable_tags":true,"allow_insecure_loopback":false,"ca_cert_file":null,"ca_certificate_sha256":null,"destination_sha256":identity.destination_sha256,"max_artifact_bytes":1048576,"max_staging_bytes":4194304})).unwrap();
        approval
            .resolve()
            .unwrap_or_else(|_| panic!("invalid export fixture approval"));
        approval
    }
    #[test]
    fn export_conversion_resources_are_explicit_validated_and_legacy_catalogs_grant_none() {
        let legacy = export_approval();
        assert!(legacy.conversion_resources.is_none());
        assert!(serde_json::to_value(&legacy)
            .unwrap()
            .get("conversion_resources")
            .is_none());
        let mut configured = serde_json::to_value(&legacy).unwrap();
        configured["conversion_resources"] =
            serde_json::json!({"slots":1,"cpus":4,"memory_mb":4608,"disk_gb":128});
        let mut approval: crate::package::ExportApproval =
            serde_json::from_value(configured.clone()).unwrap();
        assert!(approval.resolve().is_ok());
        assert!(approval
            .conversion_resources
            .unwrap()
            .plan(1 << 30, 30 << 30, 128 << 30)
            .is_ok());
        configured["conversion_resources"]["cpus"] = serde_json::json!(3);
        let mut invalid: crate::package::ExportApproval =
            serde_json::from_value(configured).unwrap();
        assert!(invalid.resolve().is_err());
    }
    #[test]
    fn export_requires_feature_exact_catalog_and_caps_before_dispatch_then_returns_only_bound_proof(
    ) {
        for approved in [false, true] {
            let hello = export_hello();
            let (mut client, fake, _started, thread) = start_with_export_catalogs(
                hello.clone(),
                None,
                None,
                None,
                vec![],
                None,
                approved.then(|| vec![export_approval()]),
            );
            let proof = export_fixture();
            for (id, operation) in [
                (
                    1,
                    wire::Operation::QualifyExport {
                        receipt: proof.source.clone(),
                        request: export_request(),
                    },
                ),
                (
                    2,
                    wire::Operation::AdmitExport {
                        receipt: proof.source.clone(),
                        operation_id: proof.operation_id.clone(),
                        request: export_request(),
                    },
                ),
                (
                    3,
                    wire::Operation::ExportMachine {
                        receipt: proof.source.clone(),
                        operation_id: proof.operation_id.clone(),
                        request: export_request(),
                        push_token: serde_json::from_value(serde_json::json!(
                            "fixture-export-token"
                        ))
                        .unwrap(),
                    },
                ),
            ] {
                send(&mut client, request(id, operation));
                if approved {
                    assert!(matches!(
                        receive(&mut client),
                        wire::ServerMessage::Accepted { .. }
                    ));
                    let response = receive(&mut client);
                    assert!(matches!(
                        response,
                        wire::ServerMessage::Terminal {
                            outcome: wire::Outcome::Qualified | wire::Outcome::Exported { .. },
                            ..
                        }
                    ));
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
                }
            }
            let mut crossed = export_request();
            crossed.destination_sha256 = "0".repeat(64);
            send(
                &mut client,
                request(
                    4,
                    wire::Operation::QualifyExport {
                        receipt: proof.source,
                        request: crossed,
                    },
                ),
            );
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    outcome: wire::Outcome::Error {
                        code: wire::SafeCode::Unsupported,
                        ..
                    },
                    ..
                }
            ));
            assert_eq!(
                fake.calls.load(Ordering::Acquire),
                if approved { 3 } else { 0 }
            );
            send(
                &mut client,
                wire::ClientMessage::Shutdown { epoch: hello.epoch },
            );
            assert!(thread.join().unwrap().is_ok());
        }
    }
    #[test]
    fn export_inspection_and_cleanup_use_reserved_controls_without_catalog_under_busy_workers() {
        let hello = export_hello();
        let proof = export_fixture();
        let (mut client, _fake, started, thread) = start_with(hello.clone());
        for id in 1..=WORKERS as u64 {
            let mut operation = exec("hold");
            if let wire::Operation::Exec { receipt, .. } = &mut operation {
                *receipt = proof.source.clone();
            }
            let mut message = request(id, operation);
            if let wire::ClientMessage::Request { budget_ms, .. } = &mut message {
                *budget_ms = 5000;
            }
            send(&mut client, message);
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { .. }
            ));
            started.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        for (id, operation) in [
            (
                5,
                wire::Operation::InspectExport {
                    receipt: proof.source.clone(),
                    operation_id: proof.operation_id.clone(),
                    request_sha256: proof.request_sha256.clone(),
                },
            ),
            (
                6,
                wire::Operation::CleanupExportStaging {
                    receipt: proof.source.clone(),
                    operation_id: proof.operation_id.clone(),
                    request_sha256: proof.request_sha256.clone(),
                    quiesced: true,
                },
            ),
        ] {
            assert!(is_control(&operation));
            send(&mut client, request(id, operation));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Accepted { .. }
            ));
            assert!(matches!(
                receive(&mut client),
                wire::ServerMessage::Terminal {
                    outcome: wire::Outcome::ExportPresence { .. }
                        | wire::Outcome::ExportStagingCleaned { .. },
                    ..
                }
            ));
        }
        for id in 1..=WORKERS as u64 {
            send(
                &mut client,
                wire::ClientMessage::Cancel {
                    epoch: hello.epoch.clone(),
                    id,
                },
            );
        }
        send(
            &mut client,
            wire::ClientMessage::Shutdown { epoch: hello.epoch },
        );
        assert!(thread.join().unwrap().is_ok());
    }
}
