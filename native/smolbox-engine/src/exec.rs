use crate::{Dispatch, Error, ErrorCode, Result};
use smolvm::agent::ExecEvent;
use smolvm::embedded::{ExecCancel, ExecOptions};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Default)]
pub struct Cancellation {
    pub(crate) exec: ExecCancel,
}

impl Cancellation {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.exec.cancel();
    }
    pub fn is_cancelled(&self) -> bool {
        self.exec.is_cancelled()
    }
}

#[derive(Clone)]
pub struct Command {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub workdir: Option<String>,
    pub user: Option<String>,
    pub timeout: Duration,
    pub max_output_bytes: u64,
}

impl Command {
    pub(crate) fn validate(&self, image: bool) -> Result<()> {
        if self.argv.is_empty()
            || self.argv.len() > 256
            || self.env.len() > 256
            || self.argv[0].is_empty()
            || self.argv.iter().any(|s| invalid_value(s))
            || self
                .env
                .iter()
                .any(|(k, v)| invalid_scalar(k) || k.contains('=') || invalid_value(v))
            || self
                .workdir
                .as_ref()
                .is_some_and(|s| invalid_scalar(s) || !s.starts_with('/'))
            || self.user.as_ref().is_some_and(|s| invalid_scalar(s))
            || self.timeout.is_zero()
            || self.timeout > Duration::from_secs(86400)
            || self.max_output_bytes == 0
            || self.max_output_bytes > 16 * 1024 * 1024
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        validate_guest_user(self.user.as_deref(), image)?;
        // Aggregate bounds also apply before the native agent builds a request.
        let total: usize = self.argv.iter().map(String::len).sum::<usize>()
            + self
                .env
                .iter()
                .map(|(k, v)| k.len() + v.len())
                .sum::<usize>();
        if total > 128 * 1024 {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }

    pub(crate) fn options(&self) -> ExecOptions {
        ExecOptions {
            env: self.env.clone(),
            workdir: self.workdir.clone(),
            user: self.user.clone(),
            timeout: Some(self.timeout),
        }
    }
}

pub(crate) fn validate_guest_user(user: Option<&str>, image: bool) -> Result<()> {
    let Some(user) = user else { return Ok(()) };
    let parts: Vec<_> = user.split(':').collect();
    if !image
        || parts.len() > 2
        || parts.iter().any(|part| {
            part.is_empty()
                || !part.bytes().all(|byte| byte.is_ascii_digit())
                || !part.parse::<u32>().is_ok_and(|id| id != u32::MAX)
        })
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(())
}

fn invalid_scalar(value: &str) -> bool {
    value.is_empty() || invalid_value(value)
}

fn invalid_value(value: &str) -> bool {
    value.len() > 16384 || value.contains('\0')
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stream {
    Stdout,
    Stderr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub stream: Stream,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Completion {
    Exited,
    Cancelled,
    Deadline,
    OutputLimit,
    ConsumerLost,
    NativeError,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutcome {
    pub dispatch: Dispatch,
    pub completion: Completion,
    pub observed_exit: Option<i32>,
    pub running_observed: bool,
    pub output_bytes: u64,
}

impl CommandOutcome {
    pub fn success(&self) -> bool {
        self.completion == Completion::Exited && self.observed_exit == Some(0)
    }
}

pub(crate) struct Collector {
    limit: u64,
    outcome: CommandOutcome,
    stream_error: bool,
}

impl Collector {
    pub fn new(limit: u64) -> Self {
        Self {
            limit,
            stream_error: false,
            outcome: CommandOutcome {
                dispatch: Dispatch::NotDispatched,
                completion: Completion::Unknown,
                observed_exit: None,
                running_observed: false,
                output_bytes: 0,
            },
        }
    }

    pub fn event(
        &mut self,
        event: ExecEvent,
        cancel: &Cancellation,
        consumer: &mut impl FnMut(Output) -> std::result::Result<(), ()>,
    ) {
        self.mark_dispatch();
        // Preserve a real Exit even if an earlier error, output cap, or lost
        // consumer already disqualified success. Cancellation is not evidence
        // that this event can never arrive.
        if let ExecEvent::Exit(code) = event {
            if self.outcome.observed_exit.is_some() {
                self.stream_error = true;
            } else {
                self.outcome.observed_exit = Some(code);
            }
            self.outcome.running_observed = true;
            return;
        }
        if self.stream_error || self.outcome.completion != Completion::Unknown {
            return;
        }
        match event {
            ExecEvent::Stdout(bytes) => self.output(Stream::Stdout, bytes, cancel, consumer),
            ExecEvent::Stderr(bytes) => self.output(Stream::Stderr, bytes, cancel, consumer),
            ExecEvent::Exit(_) => unreachable!("Exit handled before completion guard"),
            ExecEvent::Error(_) => {
                self.stream_error = true;
                cancel.cancel();
            }
        }
    }

    pub fn mark_dispatch(&mut self) {
        self.outcome.dispatch = Dispatch::MayHaveDispatched;
    }

    fn output(
        &mut self,
        stream: Stream,
        bytes: Vec<u8>,
        cancel: &Cancellation,
        consumer: &mut impl FnMut(Output) -> std::result::Result<(), ()>,
    ) {
        // Bytes after Exit violate event ordering; preserve the Exit but do not
        // turn that invalid stream into a successful command.
        if self.outcome.observed_exit.is_some() {
            self.stream_error = true;
            cancel.cancel();
            return;
        }
        if bytes.is_empty() {
            return;
        }
        self.outcome.running_observed = true;
        for chunk in bytes.chunks(64 * 1024) {
            if chunk.len() as u64 > self.limit.saturating_sub(self.outcome.output_bytes) {
                self.outcome.completion = Completion::OutputLimit;
                cancel.cancel();
                return;
            }
            self.outcome.output_bytes += chunk.len() as u64;
            if consumer(Output {
                stream,
                bytes: chunk.to_vec(),
            })
            .is_err()
            {
                self.outcome.completion = Completion::ConsumerLost;
                cancel.cancel();
                return;
            }
        }
    }

    pub fn finish(mut self, native_ok: bool, cancelled: bool, expired: bool) -> CommandOutcome {
        if self.outcome.completion == Completion::Unknown {
            self.outcome.completion = if self.stream_error || !native_ok {
                Completion::NativeError
            } else if expired {
                Completion::Deadline
            } else if cancelled {
                Completion::Cancelled
            } else if self.outcome.observed_exit.is_some() {
                Completion::Exited
            } else {
                Completion::Unknown
            };
        }
        self.outcome
    }
}

/// Independent host deadline; guest timeout and a Rust `Ok` are not sufficient.
/// Completion wakes the timer immediately, so fast calls don't accumulate sleepers.
pub(crate) struct Deadline {
    state: Arc<(Mutex<(bool, bool)>, Condvar)>,
    thread: Option<std::thread::JoinHandle<()>>,
    expires_at: Instant,
}

impl Deadline {
    pub fn start(timeout: Duration, cancel: Cancellation) -> Self {
        let state = Arc::new((Mutex::new((false, false)), Condvar::new()));
        let timer_state = state.clone();
        let expires_at = Instant::now() + timeout;
        let thread = std::thread::spawn(move || {
            let deadline = expires_at;
            let (lock, condition) = &*timer_state;
            let mut flags = lock.lock().unwrap_or_else(|p| p.into_inner());
            while !flags.0 {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    flags.1 = true;
                    drop(flags);
                    cancel.cancel();
                    return;
                }
                flags = condition
                    .wait_timeout(flags, remaining)
                    .unwrap_or_else(|p| p.into_inner())
                    .0;
            }
        });
        Self {
            state,
            thread: Some(thread),
            expires_at,
        }
    }

    pub fn finish(mut self) -> bool {
        let expired = {
            let mut flags = self.state.0.lock().unwrap_or_else(|p| p.into_inner());
            flags.0 = true;
            self.state.1.notify_one();
            flags.1 || Instant::now() >= self.expires_at
        };
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        expired
    }
}

impl Drop for Deadline {
    fn drop(&mut self) {
        self.state.0.lock().unwrap_or_else(|p| p.into_inner()).0 = true;
        self.state.1.notify_one();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qualified_users_reject_unqualified_modes_names_and_sentinel_ids() {
        for user in ["0", "65534:65534", "4294967294:1"] {
            validate_guest_user(Some(user), true).unwrap();
            assert_eq!(
                validate_guest_user(Some(user), false).unwrap_err().dispatch,
                Dispatch::NotDispatched
            );
        }
        for user in [
            "root",
            "nobody",
            "1:nogroup",
            "1:",
            ":1",
            "1:2:3",
            "-1",
            "+1",
            "4294967295",
            "1:4294967295",
            "4294967296",
        ] {
            assert_eq!(
                validate_guest_user(Some(user), true).unwrap_err().code,
                ErrorCode::Unsupported
            );
        }
        validate_guest_user(None, false).unwrap();
    }

    #[test]
    fn native_ok_without_exit_is_unknown_and_cancel_is_not_termination() {
        assert_eq!(
            Collector::new(10).finish(true, false, false).completion,
            Completion::Unknown
        );
        let outcome = Collector::new(10).finish(true, true, false);
        assert_eq!(outcome.completion, Completion::Cancelled);
        assert_eq!(outcome.dispatch, Dispatch::NotDispatched);
        assert_eq!(outcome.observed_exit, None);
        assert!(!outcome.success());
    }

    #[test]
    fn real_exit_after_an_error_or_forwarding_failure_remains_evidence() {
        for failure in [0, 1, 2] {
            let cancel = Cancellation::new();
            let mut collector = Collector::new(1);
            match failure {
                0 => collector.event(
                    ExecEvent::Error("private diagnostic".into()),
                    &cancel,
                    &mut |_| Ok(()),
                ),
                1 => collector.event(ExecEvent::Stdout(vec![1, 2]), &cancel, &mut |_| Ok(())),
                _ => collector.event(ExecEvent::Stdout(vec![1]), &cancel, &mut |_| Err(())),
            }
            collector.event(ExecEvent::Exit(0), &cancel, &mut |_| {
                panic!("forwarded after failure")
            });
            let outcome = collector.finish(true, cancel.is_cancelled(), false);
            assert_eq!(outcome.observed_exit, Some(0));
            assert!(outcome.running_observed);
            assert!(!outcome.success());
            assert_eq!(
                outcome.completion,
                match failure {
                    0 => Completion::NativeError,
                    1 => Completion::OutputLimit,
                    _ => Completion::ConsumerLost,
                }
            );
        }
    }

    #[test]
    fn errors_and_invalid_order_disqualify_exit_zero() {
        let mut c = Collector::new(10);
        let cancel = Cancellation::new();
        c.event(ExecEvent::Exit(0), &cancel, &mut |_| Ok(()));
        c.event(
            ExecEvent::Error("private-secret/path/command".into()),
            &cancel,
            &mut |_| Ok(()),
        );
        let outcome = c.finish(true, cancel.is_cancelled(), false);
        assert_eq!(outcome.observed_exit, Some(0));
        assert!(!outcome.success());
        assert!(!format!("{outcome:?}").contains("secret"));
        let mut c = Collector::new(10);
        c.event(ExecEvent::Exit(0), &Cancellation::new(), &mut |_| Ok(()));
        c.event(
            ExecEvent::Stdout(vec![1]),
            &Cancellation::new(),
            &mut |_| Ok(()),
        );
        assert!(!c.finish(true, false, false).success());
    }

    #[test]
    fn output_chunks_preserve_stream_order_and_enforce_decoded_limit() {
        let cancel = Cancellation::new();
        let mut c = Collector::new(128 * 1024);
        let mut chunks = vec![];
        c.event(ExecEvent::Stdout(vec![1; 65537]), &cancel, &mut |o| {
            chunks.push(o);
            Ok(())
        });
        c.event(ExecEvent::Stderr(vec![2]), &cancel, &mut |o| {
            chunks.push(o);
            Ok(())
        });
        assert_eq!(
            chunks.iter().map(|o| o.bytes.len()).collect::<Vec<_>>(),
            vec![65536, 1, 1]
        );
        assert_eq!(chunks[2].stream, Stream::Stderr);
        c.event(ExecEvent::Stdout(vec![3; 65536]), &cancel, &mut |_| {
            panic!("over budget forwarded")
        });
        let outcome = c.finish(true, true, false);
        assert_eq!(outcome.completion, Completion::OutputLimit);
        assert!(cancel.is_cancelled());
        assert_eq!(outcome.observed_exit, None);
    }

    #[test]
    fn host_deadline_cancels_only_its_token_and_finished_timer_does_not_linger() {
        let ours = Cancellation::new();
        let other = Cancellation::new();
        let timer = Deadline::start(Duration::from_millis(10), ours.clone());
        std::thread::sleep(Duration::from_millis(30));
        assert!(timer.finish());
        assert!(ours.is_cancelled());
        assert!(!other.is_cancelled());
        assert!(!Deadline::start(Duration::from_secs(60), other.clone()).finish());
        assert!(!other.is_cancelled());
    }
}
