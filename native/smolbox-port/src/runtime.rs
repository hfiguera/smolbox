use crate::{adapter, output, package::Config};
use crossbeam_channel::{bounded, Receiver, Sender};
use smolbox_engine::{Cancellation, Engine};
use smolbox_protocol as wire;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const WORKERS: usize = 4;
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
    cancel: Cancellation,
    started: bool,
    deadline: Instant,
    cancellation_requested: Option<Instant>,
    operation: wire::Operation,
    upload: Option<tempfile::NamedTempFile>,
    upload_reservation: u64,
}
struct State {
    session: wire::Session,
    handles: BTreeMap<u64, Handle>,
    upload_bytes: u64,
    approved: bool,
    closing: bool,
    unavailable: bool,
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
        spawn_worker(shared.clone(), native.clone(), work.clone());
    }
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
                match handle_input(&shared, &jobs, spools.path(), input) {
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
    let rejection = if state.unavailable {
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
    );
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
            cancel: cancel.clone(),
            started: false,
            deadline,
            cancellation_requested: None,
            operation: operation.clone(),
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
                jobs.try_send(Work {
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
fn spawn_worker(shared: Arc<Shared>, native: Arc<dyn Native>, work: Receiver<Work>) {
    std::thread::spawn(move || {
        while let Ok(work) = work.recv() {
            let remaining = work.deadline.saturating_duration_since(Instant::now());
            let (should_run, unavailable) = {
                let Ok(mut state) = shared.state.lock() else {
                    shared.fatal.store(true, Ordering::Release);
                    return;
                };
                let unavailable = state.unavailable || !native.available();
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
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                native.run(
                    work.operation,
                    remaining,
                    work.cancel.clone(),
                    upload,
                    &mut |stream, bytes| shared.event(work.id, stream, bytes),
                )
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
            shared
                .state
                .lock()
                .map_err(|_| ())?
                .session
                .credit(&epoch, id, decoded_bytes, events)
                .map_err(|_| ())?;
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
        started: Sender<()>,
        calls: AtomicUsize,
        uploaded: Mutex<Vec<u8>>,
    }
    impl Native for Fake {
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
        }
    }
    fn send(client: &mut UnixStream, message: wire::ClientMessage) {
        wire::write_frame(client, &serde_json::to_value(message).unwrap()).unwrap();
    }
    fn receive(client: &mut UnixStream) -> wire::ServerMessage {
        wire::ServerMessage::decode(wire::read_frame(client).unwrap().unwrap()).unwrap()
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
            started: started_sender,
            calls: AtomicUsize::new(0),
            uploaded: Mutex::new(Vec::new()),
        });
        let native = fake.clone();
        let config = Config {
            schema: 1,
            target_id: "test".into(),
            generation: "cd".repeat(16),
            allow_initialize: false,
            package_manifest_sha256: "01".repeat(32),
            approved_artifacts: vec![],
        };
        let thread = std::thread::spawn(move || {
            serve_io(
                input,
                server,
                native,
                hello(),
                config,
                tempfile::tempdir().unwrap(),
            )
        });
        assert!(matches!(
            receive(&mut client),
            wire::ServerMessage::Hello { .. }
        ));
        send(&mut client, wire::ClientMessage::Approve { hello: hello() });
        (client, fake, started, thread)
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
            schema: 1,
            target_id: "test".into(),
            generation: "cd".repeat(16),
            allow_initialize: false,
            package_manifest_sha256: "01".repeat(32),
            approved_artifacts: vec![],
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
