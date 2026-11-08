//! Buffered foreground jobs on an already receipt-verified running agent.
use crate::transfer_supervisor::RunResult;
use crate::{
    Cancellation, CommandOutcome, Completion, CreationReceipt, Dispatch, Engine, Error, ErrorCode,
    Output, Result, Stream,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::io::{Read, Seek, SeekFrom, Write};
use std::time::{Duration, Instant};

pub const COMMAND_METADATA_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BufferedCommand {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub workdir: Option<String>,
    pub user: Option<String>,
    pub stdin: Option<String>,
    pub timeout: Duration,
    pub max_output_bytes: u64,
}
impl BufferedCommand {
    pub(crate) fn validate(&self, image: bool) -> Result<()> {
        let text = |s: &str, n: usize| s.len() <= n && !s.contains('\0');
        if self.argv.is_empty()
            || self.argv.len() > 256
            || self.argv[0].is_empty()
            || self.argv.iter().any(|s| !text(s, 16384))
            || self.argv.iter().map(String::len).sum::<usize>() > 65536
            || self.env.len() > 64
            || self
                .env
                .iter()
                .any(|(k, v)| !text(k, 128) || !name(k) || !text(v, 8192))
            || self
                .env
                .iter()
                .map(|(k, _)| k)
                .collect::<BTreeSet<_>>()
                .len()
                != self.env.len()
            || self.workdir.as_ref().is_some_and(|s| {
                !text(s, 4096) || !s.starts_with('/') || s.split('/').any(|p| p == "..")
            })
            || self
                .user
                .as_ref()
                .is_some_and(|s| s.is_empty() || !text(s, 128))
            || self.stdin.as_ref().is_some_and(|s| s.len() > 65536)
            || self.timeout.is_zero()
            || self.timeout > Duration::from_secs(86400)
            || self.max_output_bytes == 0
            || self.max_output_bytes > 16 * 1024 * 1024
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        crate::exec::validate_guest_user(self.user.as_deref(), image)
    }
}
fn name(s: &str) -> bool {
    let mut bytes = s.bytes();
    bytes
        .next()
        .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ImageContext {
    image: String,
    overlay: Option<String>,
    mounts: Vec<(String, String, bool)>,
    unprivileged: bool,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Metadata {
    pub command: BufferedCommand,
    image: Option<ImageContext>,
    deadline_ns: u64,
    background: bool,
}
impl Metadata {
    pub(crate) fn execute_streaming(
        &self,
        client: &mut smolvm::agent::AgentClient,
        mut callback: impl FnMut(smolvm::agent::ExecEvent),
    ) -> Result<()> {
        self.validate()?;
        if self.background || self.command.stdin.is_some() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let remaining = Duration::from_nanos(self.deadline_ns.saturating_sub(monotonic_ns()?));
        if remaining.is_zero() {
            return Err(Error::before(ErrorCode::State));
        }
        let c = &self.command;
        use smolvm_protocol::{AgentRequest, AgentResponse};
        let request = match &self.image {
            None => AgentRequest::VmExec {
                command: c.argv.clone(),
                env: c.env.clone(),
                workdir: c.workdir.clone(),
                timeout_ms: Some(remaining.as_millis() as u64),
                interactive: true,
                tty: false,
                background: false,
                stdin_data: None,
            },
            Some(image) => {
                let mut config = smolvm::agent::RunConfig::new(&image.image, c.argv.clone())
                    .with_env(c.env.clone())
                    .with_workdir(c.workdir.clone())
                    .with_user(c.user.clone())
                    .with_mounts(image.mounts.clone())
                    .with_timeout(Some(remaining));
                config.persistent_overlay_id = image.overlay.clone();
                config.unprivileged = image.unprivileged;
                AgentRequest::Run {
                    image: config.image,
                    command: config.command,
                    env: config.env,
                    workdir: config.workdir,
                    user: config.user,
                    mounts: config.mounts,
                    timeout_ms: Some(remaining.as_millis() as u64),
                    interactive: true,
                    tty: false,
                    detached: false,
                    unprivileged: config.unprivileged,
                    persistent_overlay_id: config.persistent_overlay_id,
                    stdin_data: None,
                    background: false,
                    s3_volumes: config.s3_volumes,
                    stop_vm_on_exit: false,
                }
            }
        };
        let _read_guard = client
            .set_extended_read_timeout(remaining)
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        // These are public clean-SDK APIs/types. The convenience collector has
        // an internal 11-MiB cap; explicit typed collection preserves SmolBox's
        // existing 16-MiB total without patching it or raising SDK frame limits.
        client
            .send_raw(&request)
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        if !matches!(client.recv_raw(), Ok(AgentResponse::Started)) {
            return Err(Error::uncertain(ErrorCode::Native));
        }
        for _ in 0..65537 {
            if monotonic_ns()? >= self.deadline_ns {
                return Err(Error::uncertain(ErrorCode::Native));
            }
            match client.recv_raw() {
                Ok(AgentResponse::Stdout { data }) => {
                    callback(smolvm::agent::ExecEvent::Stdout(data))
                }
                Ok(AgentResponse::Stderr { data }) => {
                    callback(smolvm::agent::ExecEvent::Stderr(data))
                }
                Ok(AgentResponse::Exited { exit_code, .. }) => {
                    callback(smolvm::agent::ExecEvent::Exit(exit_code));
                    return Ok(());
                }
                Ok(AgentResponse::Error { .. }) | Err(_) => {
                    callback(smolvm::agent::ExecEvent::Error(
                        "native stream failure".into(),
                    ));
                    return Err(Error::uncertain(ErrorCode::Native));
                }
                _ => {}
            }
        }
        Err(Error::uncertain(ErrorCode::Native))
    }
    pub(crate) fn new(
        record: &smolvm::config::VmRecord,
        command: BufferedCommand,
        expires: Instant,
    ) -> Result<Self> {
        if !record.remote_volumes.is_empty() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let image = record.image.as_ref().map(|image| {
            let config = smolvm::agent::RunConfig::new(image, command.argv.clone())
                .in_machine(record, &record.name, &command.env)
                .with_mounts(smolvm::workload::record_mounts_to_bindings(record));
            ImageContext {
                image: config.image,
                overlay: config.persistent_overlay_id,
                mounts: config.mounts,
                unprivileged: config.unprivileged,
            }
        });
        let now = monotonic_ns()?;
        let remaining = expires.saturating_duration_since(Instant::now());
        Ok(Self {
            command,
            image,
            deadline_ns: now.saturating_add(remaining.as_nanos() as u64),
            background: false,
        })
    }
    pub(crate) fn background(
        record: &smolvm::config::VmRecord,
        command: BufferedCommand,
        expires: Instant,
    ) -> Result<Self> {
        let mut metadata = Self::new(record, command, expires)?;
        metadata.background = true;
        metadata.validate()?;
        Ok(metadata)
    }
    pub(crate) fn validate(&self) -> Result<()> {
        self.command.validate(self.image.is_some())?;
        if self.background && (self.image.is_none() || self.command.stdin.is_some()) {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        if self.image.as_ref().is_some_and(|image| {
            image.image.is_empty()
                || image.image.len() > 16384
                || image.image.contains('\0')
                || image.mounts.len() > 64
                || image
                    .overlay
                    .as_ref()
                    .is_some_and(|s| s.len() > 16384 || s.contains('\0'))
                || image.mounts.iter().any(|(tag, path, _)| {
                    tag.is_empty()
                        || tag.len() > 4096
                        || tag.contains('\0')
                        || path.len() > 4096
                        || !path.starts_with('/')
                        || path.contains('\0')
                })
        }) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub(crate) fn terminal(
        &self,
        options: &crate::TerminalOptions,
    ) -> Result<(smolvm::agent::RunConfig, Instant)> {
        self.validate()?;
        options.validate()?;
        if self.background
            || self.command.stdin.is_some()
            || !self.command.env.is_empty()
            || self.command.argv != [options.program.clone()]
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let image = self
            .image
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let anchor = Instant::now();
        let remaining = Duration::from_nanos(self.deadline_ns.saturating_sub(monotonic_ns()?));
        if remaining.is_zero() {
            return Err(Error::before(ErrorCode::State));
        }
        let mut config = smolvm::agent::RunConfig::new(&image.image, self.command.argv.clone())
            .with_user(self.command.user.clone())
            .with_workdir(self.command.workdir.clone())
            .with_mounts(image.mounts.clone());
        config.persistent_overlay_id = image.overlay.clone();
        config.unprivileged = image.unprivileged;
        Ok((config, anchor + remaining))
    }
    pub(crate) fn execute(
        &self,
        client: &mut smolvm::agent::AgentClient,
    ) -> Result<(i32, Vec<u8>, Vec<u8>)> {
        self.validate()?;
        if self.background {
            return Err(Error::before(ErrorCode::Validation));
        }
        let remaining = Duration::from_nanos(self.deadline_ns.saturating_sub(monotonic_ns()?));
        if remaining.is_zero() {
            return Err(Error::before(ErrorCode::State));
        }
        let c = &self.command;
        let result = match &self.image {
            None => client.vm_exec(
                c.argv.clone(),
                c.env.clone(),
                c.workdir.clone(),
                Some(remaining),
                c.stdin.clone(),
            ),
            Some(image) => {
                let mut config = smolvm::agent::RunConfig::new(&image.image, c.argv.clone())
                    .with_env(c.env.clone())
                    .with_workdir(c.workdir.clone())
                    .with_user(c.user.clone())
                    .with_mounts(image.mounts.clone())
                    .with_timeout(Some(remaining))
                    .with_stdin(c.stdin.clone());
                config.persistent_overlay_id = image.overlay.clone();
                config.unprivileged = image.unprivileged;
                client.run_non_interactive(config)
            }
        };
        result.map_err(|_| Error::uncertain(ErrorCode::Native))
    }

    fn execute_background(&self, client: &mut smolvm::agent::AgentClient) -> Result<u32> {
        self.validate()?;
        if !self.background {
            return Err(Error::before(ErrorCode::Validation));
        }
        let remaining = Duration::from_nanos(self.deadline_ns.saturating_sub(monotonic_ns()?));
        if remaining.is_zero() {
            return Err(Error::before(ErrorCode::State));
        }
        let image = self
            .image
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let c = &self.command;
        let mut config = smolvm::agent::RunConfig::new(&image.image, c.argv.clone())
            .with_env(c.env.clone())
            .with_workdir(c.workdir.clone())
            .with_user(c.user.clone())
            .with_mounts(image.mounts.clone());
        config.persistent_overlay_id = image.overlay.clone();
        config.unprivileged = image.unprivileged;
        let _read_guard = client
            .set_extended_read_timeout(remaining)
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        // The host observation deadline does not become a guest lifetime timeout.
        client
            .run_background(config)
            .map_err(|_| Error::uncertain(ErrorCode::Native))
    }
}
pub(crate) fn monotonic_ns() -> Result<u64> {
    let mut value = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut value) } != 0
        || value.tv_sec < 0
        || value.tv_nsec < 0
    {
        return Err(Error::before(ErrorCode::Io));
    }
    Ok((value.tv_sec as u64)
        .saturating_mul(1_000_000_000)
        .saturating_add(value.tv_nsec as u64))
}

impl Engine {
    pub fn exec_buffered(
        &self,
        receipt: &CreationReceipt,
        command: BufferedCommand,
        cancel: Cancellation,
        mut consumer: impl FnMut(Output) -> std::result::Result<(), ()>,
    ) -> Result<CommandOutcome> {
        let expires = Instant::now()
            .checked_add(command.timeout)
            .ok_or(Error::before(ErrorCode::Validation))?;
        let record = self.record(receipt)?;
        command.validate(record.image.is_some())?;
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source = self.source_lease(receipt)?;
        if self.inspect(receipt)?.state != crate::ObservedState::Running {
            return Err(Error::before(ErrorCode::State));
        }
        let mut outcome = CommandOutcome {
            dispatch: Dispatch::NotDispatched,
            completion: Completion::Cancelled,
            observed_exit: None,
            running_observed: true,
            output_bytes: 0,
        };
        if cancel.is_cancelled() || Instant::now() >= expires {
            if !cancel.is_cancelled() {
                outcome.completion = Completion::Deadline
            }
            return Ok(outcome);
        }
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let metadata = Metadata::new(&record, command, expires)?;
        metadata.validate()?;
        let bytes =
            serde_json::to_vec(&metadata).map_err(|_| Error::before(ErrorCode::Validation))?;
        let prepared = supervisor.prepare_command(
            &self.transfer_directory()?,
            self.vm_directory(&receipt.name).join("agent.sock"),
            &bytes,
            metadata.command.max_output_bytes,
        )?;
        let result = supervisor.run(
            prepared,
            Box::new((machine, source, self.domain.clone())),
            expires,
            &cancel,
        )?;
        let collected = match result {
            RunResult::Retained(file) => {
                outcome.dispatch = file.dispatch;
                outcome.completion = completion(file.completion);
                return Ok(outcome);
            }
            RunResult::Collected(collected) => collected,
        };
        outcome.dispatch = collected.outcome.dispatch;
        outcome.completion = completion(collected.outcome.completion);
        let mut collected = collected;
        if let Some(proof) = collected.command.as_ref() {
            outcome.observed_exit = Some(proof.exit_code);
            collected.prepared.spool.verify()?;
            if collected
                .prepared
                .spool
                .file
                .metadata()
                .map_err(|_| Error::uncertain(ErrorCode::Io))?
                .len()
                != proof.stdout + proof.stderr
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            collected
                .prepared
                .spool
                .file
                .seek(SeekFrom::Start(0))
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
            for (stream, total) in [
                (Stream::Stdout, proof.stdout),
                (Stream::Stderr, proof.stderr),
            ] {
                let mut left = total;
                while left > 0 {
                    if cancel.is_cancelled() || Instant::now() >= expires {
                        outcome.completion = if cancel.is_cancelled() {
                            Completion::Cancelled
                        } else {
                            Completion::Deadline
                        };
                        return Ok(outcome);
                    }
                    let mut chunk = vec![0; left.min(65536) as usize];
                    collected
                        .prepared
                        .spool
                        .file
                        .read_exact(&mut chunk)
                        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    let size = chunk.len() as u64;
                    if consumer(Output {
                        stream,
                        bytes: chunk,
                    })
                    .is_err()
                    {
                        outcome.completion = Completion::ConsumerLost;
                        return Ok(outcome);
                    }
                    outcome.output_bytes += size;
                    left -= size;
                }
            }
        }
        Ok(outcome)
    }
}

fn completion(value: crate::FileCompletion) -> Completion {
    match value {
        crate::FileCompletion::Completed => Completion::Exited,
        crate::FileCompletion::Cancelled => Completion::Cancelled,
        crate::FileCompletion::Deadline => Completion::Deadline,
        crate::FileCompletion::NativeError => Completion::NativeError,
        crate::FileCompletion::ConsumerLost => Completion::ConsumerLost,
        crate::FileCompletion::OutputLimit => Completion::OutputLimit,
    }
}

pub(crate) fn run(
    request: &crate::transfer_worker::Request,
    reference: &crate::transfer_worker::Blob,
    mut output: std::fs::File,
) -> Result<crate::transfer_worker::Event> {
    let metadata: Metadata = reference.read(request.owner, COMMAND_METADATA_BYTES)?;
    metadata.validate()?;
    if metadata.background
        != matches!(
            request.kind,
            crate::transfer_worker::Kind::Background { .. }
        )
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut client = crate::agent_io::BoundedAgent::connect(&request.socket, request.max_bytes)?;
    if metadata.background {
        return Ok(match metadata.execute_background(&mut client.client) {
            Ok(pid)
                if pid > 0
                    && format!("pid={pid}\n").len() as u64 <= metadata.command.max_output_bytes =>
            {
                crate::transfer_worker::Event::Launched { pid }
            }
            Ok(pid) if pid > 0 => crate::transfer_worker::Event::Limited { bytes: 0 },
            _ if client.limited() => crate::transfer_worker::Event::Limited { bytes: 0 },
            _ => crate::transfer_worker::Event::Failed { bytes: 0 },
        });
    }
    let result = metadata.execute(&mut client.client);
    let (exit, stdout, stderr) = match result {
        Ok(value) => value,
        Err(_) => {
            return Ok(if client.limited() {
                crate::transfer_worker::Event::Limited { bytes: 0 }
            } else {
                crate::transfer_worker::Event::Failed { bytes: 0 }
            })
        }
    };
    let limited = stdout.len() as u64 + stderr.len() as u64 > request.max_bytes;
    let out = stdout.len().min(request.max_bytes as usize);
    let err = stderr.len().min(request.max_bytes as usize - out);
    output
        .write_all(&stdout[..out])
        .and_then(|()| output.write_all(&stderr[..err]))
        .and_then(|()| output.flush())
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    Ok(crate::transfer_worker::Event::CommandCompleted {
        exit_code: exit,
        stdout: out as u64,
        stderr: err as u64,
        limited,
    })
}

pub struct LaunchOutcome {
    pub transfer: crate::FileOutcome,
    pub pid: Option<u32>,
}

impl Engine {
    pub fn exec_background(
        &self,
        receipt: &CreationReceipt,
        command: BufferedCommand,
        cancel: Cancellation,
    ) -> Result<LaunchOutcome> {
        let expires = Instant::now()
            .checked_add(command.timeout)
            .ok_or(Error::before(ErrorCode::Validation))?;
        let record = self.record(receipt)?;
        command.validate(record.image.is_some())?;
        let metadata = Metadata::background(&record, command, expires)?;
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
        // Reserve the worker before connecting to an agent. No guest command,
        // container or auxiliary VM is created by preparation or observation.
        let prepared = supervisor.prepare_background(
            &self.transfer_directory()?,
            self.vm_directory(&receipt.name).join("agent.sock"),
            &bytes,
            metadata.command.max_output_bytes.min(64),
        )?;
        if self.inspect(receipt)?.state != crate::ObservedState::Running {
            return Err(Error::before(ErrorCode::State));
        }
        if cancel.is_cancelled() || Instant::now() >= expires {
            return Ok(LaunchOutcome {
                transfer: crate::FileOutcome {
                    completion: if cancel.is_cancelled() {
                        crate::FileCompletion::Cancelled
                    } else {
                        crate::FileCompletion::Deadline
                    },
                    dispatch: Dispatch::NotDispatched,
                    observed_bytes: 0,
                    native_acknowledged: false,
                },
                pid: None,
            });
        }
        match supervisor.run(
            prepared,
            Box::new((machine, source, self.domain.clone())),
            expires,
            &cancel,
        )? {
            RunResult::Retained(transfer) => Ok(LaunchOutcome {
                transfer,
                pid: None,
            }),
            RunResult::Collected(collected) => {
                collected.prepared.spool.verify()?;
                if collected
                    .prepared
                    .spool
                    .file
                    .metadata()
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?
                    .len()
                    != 0
                {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                Ok(LaunchOutcome {
                    pid: if collected.outcome.success() {
                        collected.launched
                    } else {
                        None
                    },
                    transfer: collected.outcome,
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_metadata_binds_single_program_and_image_context_without_guest_lifetime_authority() {
        let mut record =
            smolvm::config::VmRecord::new("owned".into(), 1, 512, vec![], vec![], false);
        let command = BufferedCommand {
            argv: vec!["/bin/sh".into()],
            env: vec![],
            workdir: Some("/workspace".into()),
            user: None,
            stdin: None,
            timeout: Duration::from_secs(30),
            max_output_bytes: 1024,
        };
        let options = crate::TerminalOptions {
            program: "/bin/sh".into(),
            cols: 80,
            rows: 24,
            session: Duration::from_secs(30),
            idle: Duration::from_secs(30),
            attach: Duration::from_secs(5),
            close: Duration::from_secs(1),
            max_buffer_bytes: 1024,
            max_input_bytes: 65536,
            total_input_bytes: 1048576,
        };
        let until = Instant::now() + Duration::from_secs(5);
        assert!(Metadata::new(&record, command.clone(), until)
            .unwrap()
            .terminal(&options)
            .is_err());
        record.image = Some("local-dir:/fixture".into());
        let metadata = Metadata::new(&record, command, until).unwrap();
        let (config, deadline) = metadata.terminal(&options).unwrap();
        assert!(config.timeout.is_none() && config.stdin.is_none() && !config.stop_vm_on_exit);
        assert!(deadline <= until + Duration::from_millis(1));
        for mode in 0..3 {
            let mut altered = metadata.clone();
            match mode {
                0 => altered.command.argv.push("argument".into()),
                1 => altered.command.env.push(("PRIVATE".into(), "value".into())),
                _ => altered.command.stdin = Some("input".into()),
            }
            assert!(altered.terminal(&options).is_err());
        }
    }

    #[test]
    fn background_metadata_rejects_bare_guests_and_stdin_without_connecting_an_agent() {
        let mut record =
            smolvm::config::VmRecord::new("owned".into(), 1, 512, vec![], vec![], false);
        let mut command = BufferedCommand {
            argv: vec!["/bin/sleep".into(), "600".into()],
            env: vec![],
            workdir: None,
            user: None,
            stdin: None,
            timeout: Duration::from_secs(1),
            max_output_bytes: 128,
        };
        let expires = Instant::now() + Duration::from_secs(1);
        assert!(Metadata::background(&record, command.clone(), expires).is_err());
        record.image = Some("local-dir:/fixture".into());
        assert!(Metadata::background(&record, command.clone(), expires).is_ok());
        command.stdin = Some("forbidden".into());
        assert!(Metadata::background(&record, command, expires).is_err());
    }
}
