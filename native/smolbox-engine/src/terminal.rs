//! Transport-independent admission and evidence for an owned terminal job.
//!
//! This state carries no SDK ownership or collection authority. A future owned
//! session supervisor must hold the machine/source/domain and job leases, bound
//! its queues and invoke collection only after collecting its exact child.
use crate::{Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

pub const TERMINAL_CHUNK_BYTES: u64 = 65_536;
pub const TERMINAL_BUFFER_EVENTS: usize = 1024;
pub const TERMINAL_INPUT_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalOptions {
    pub program: String,
    pub cols: u16,
    pub rows: u16,
    pub session: Duration,
    pub idle: Duration,
    pub attach: Duration,
    pub close: Duration,
    pub max_buffer_bytes: u64,
    pub max_input_bytes: u64,
    pub total_input_bytes: u64,
}
impl TerminalOptions {
    pub fn validate(&self) -> Result<()> {
        let bounded = |d: Duration, low: u64, high: u64| {
            d >= Duration::from_millis(low)
                && d <= Duration::from_millis(high)
                && d.subsec_nanos().is_multiple_of(1_000_000)
        };
        if self.program.is_empty()
            || self.program.len() > 4096
            || self.program.contains('\0')
            || self.cols == 0
            || self.rows == 0
            || !bounded(self.session, 1000, 86_400_000)
            || !bounded(self.idle, 1000, 86_400_000)
            || self.idle > self.session
            || !bounded(self.attach, 100, 30_000)
            || !bounded(self.close, 1, 5000)
            || !(1024..=1_048_576).contains(&self.max_buffer_bytes)
            || !(1..=TERMINAL_CHUNK_BYTES).contains(&self.max_input_bytes)
            || !(1..=TERMINAL_INPUT_BYTES).contains(&self.total_input_bytes)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct TerminalIdentity {
    epoch: String,
    operation: String,
}
impl TerminalIdentity {
    pub fn new(epoch: String, operation: String) -> Result<Self> {
        if !crate::domain::valid_hex(&epoch, 32) || !crate::domain::valid_hex(&operation, 32) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self { epoch, operation })
    }
}

pub enum TerminalControl {
    Input(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Close,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalFailure {
    Protocol,
    InputLimit,
    OutputLimit,
    SessionDeadline,
    IdleDeadline,
    AttachDeadline,
    CloseDeadline,
    ConsumerLost,
    Cancelled,
    Native,
    Uncollected,
    AmbiguousExit,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerminalOutcome {
    pub observed_exit: Option<i32>,
    pub failure: Option<TerminalFailure>,
}
impl TerminalOutcome {
    pub fn confirmed_exit(&self) -> Option<u8> {
        if self.failure.is_none() {
            self.observed_exit.and_then(qualified_exit)
        } else {
            None
        }
    }
}

struct Ticket {
    sequence: u64,
    bytes: u64,
}

pub struct TerminalSession {
    identity: TerminalIdentity,
    options: TerminalOptions,
    deadline: Instant,
    attach_deadline: Instant,
    active: Instant,
    close_deadline: Option<Instant>,
    attached: bool,
    control_sequence: u64,
    output_sequence: u64,
    input_bytes: u64,
    unread_bytes: u64,
    unread: VecDeque<Ticket>,
    observed_exit: Option<i32>,
    failure: Option<TerminalFailure>,
    collected: bool,
    retired: bool,
}
impl TerminalSession {
    pub fn new(
        identity: TerminalIdentity,
        options: TerminalOptions,
        now: Instant,
        deadline: Instant,
    ) -> Result<Self> {
        options.validate()?;
        if deadline <= now {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(Self {
            identity,
            deadline: deadline.min(now + options.session),
            attach_deadline: now + options.attach,
            active: now,
            options,
            close_deadline: None,
            attached: false,
            control_sequence: 0,
            output_sequence: 0,
            input_bytes: 0,
            unread_bytes: 0,
            unread: VecDeque::new(),
            observed_exit: None,
            failure: None,
            collected: false,
            retired: false,
        })
    }

    pub fn attach(&mut self, identity: &TerminalIdentity, now: Instant) -> Result<()> {
        self.check(identity, now)?;
        if self.attached {
            return Err(Error::uncertain(ErrorCode::Conflict));
        }
        self.attached = true;
        Ok(())
    }

    /// Charge admission before forwarding. Acceptance proves neither guest input
    /// consumption nor resize application. Transport overhead can increase the
    /// charge but cannot undercount payload bytes or dimensions.
    pub fn control(
        &mut self,
        identity: &TerminalIdentity,
        sequence: u64,
        command: &TerminalControl,
        charge: u64,
        now: Instant,
    ) -> Result<()> {
        self.check(identity, now)?;
        if self.close_deadline.is_some()
            || !self.attached
            || self.control_sequence.checked_add(1) != Some(sequence)
        {
            return Err(Error::uncertain(ErrorCode::State));
        }
        let minimum = match command {
            TerminalControl::Input(bytes)
                if !bytes.is_empty() && bytes.len() as u64 <= self.options.max_input_bytes =>
            {
                bytes.len() as u64
            }
            TerminalControl::Resize { cols, rows } if *cols > 0 && *rows > 0 => 4,
            TerminalControl::Close => 0,
            _ => return Err(Error::before(ErrorCode::Validation)),
        };
        if charge < minimum {
            return Err(Error::before(ErrorCode::Validation));
        }
        let next = self
            .input_bytes
            .checked_add(charge)
            .filter(|bytes| *bytes <= self.options.total_input_bytes);
        let Some(next) = next else {
            self.fail(TerminalFailure::InputLimit);
            return Err(Error::uncertain(ErrorCode::OutputLimit));
        };
        self.input_bytes = next;
        self.control_sequence = sequence;
        self.active = now;
        if matches!(command, TerminalControl::Close) {
            self.close_deadline = Some(now + self.options.close);
        }
        Ok(())
    }

    /// Reserve one output ticket before dispatch to the bridge. Payloads live in
    /// the supervisor's separately bounded queue; this ledger retains no bytes.
    pub fn output(
        &mut self,
        identity: &TerminalIdentity,
        sequence: u64,
        bytes: u64,
        now: Instant,
    ) -> Result<()> {
        if &self.identity == identity
            && !self.retired
            && !self.collected
            && self.observed_exit.is_some()
        {
            self.fail(TerminalFailure::Protocol);
        }
        self.check(identity, now)?;
        if bytes == 0
            || bytes > TERMINAL_CHUNK_BYTES
            || self.output_sequence.checked_add(1) != Some(sequence)
        {
            self.fail(TerminalFailure::Protocol);
            return Err(Error::uncertain(ErrorCode::Validation));
        }
        if self.unread.len() >= TERMINAL_BUFFER_EVENTS
            || self.unread_bytes + bytes > self.options.max_buffer_bytes
        {
            self.fail(TerminalFailure::OutputLimit);
            return Err(Error::uncertain(ErrorCode::OutputLimit));
        }
        self.output_sequence = sequence;
        self.unread_bytes += bytes;
        self.unread.push_back(Ticket { sequence, bytes });
        self.active = now;
        Ok(())
    }

    /// Whole, ordered consumer removal restores exactly one event and its bytes.
    /// Duplicate, partial, out-of-order and foreign credit never enlarges a window.
    pub fn consumed(
        &mut self,
        identity: &TerminalIdentity,
        sequence: u64,
        bytes: u64,
    ) -> Result<()> {
        if self.retired
            || &self.identity != identity
            || !self
                .unread
                .front()
                .is_some_and(|ticket| ticket.sequence == sequence && ticket.bytes == bytes)
        {
            return Err(Error::uncertain(ErrorCode::Validation));
        }
        self.unread.pop_front();
        self.unread_bytes -= bytes;
        Ok(())
    }

    pub fn output_window(&self) -> (u64, usize) {
        if self.retired || self.collected || self.failure.is_some() || self.observed_exit.is_some()
        {
            (0, 0)
        } else {
            (
                self.options.max_buffer_bytes - self.unread_bytes,
                TERMINAL_BUFFER_EVENTS - self.unread.len(),
            )
        }
    }

    pub fn observe_exit(
        &mut self,
        identity: &TerminalIdentity,
        exit: i32,
        now: Instant,
    ) -> Result<()> {
        if self.retired
            || self.collected
            || &self.identity != identity
            || self.observed_exit.is_some()
        {
            return Err(Error::uncertain(ErrorCode::State));
        }
        self.expire(now);
        self.observed_exit = Some(exit);
        if qualified_exit(exit).is_none() {
            self.fail(TerminalFailure::AmbiguousExit);
        }
        Ok(())
    }

    pub fn expire(&mut self, now: Instant) {
        if self.retired || self.collected {
            return;
        }
        let failure = if self.close_deadline.is_some_and(|deadline| now >= deadline) {
            Some(TerminalFailure::CloseDeadline)
        } else if now >= self.deadline {
            Some(TerminalFailure::SessionDeadline)
        } else if !self.attached && now >= self.attach_deadline {
            Some(TerminalFailure::AttachDeadline)
        } else if now.saturating_duration_since(self.active) >= self.options.idle {
            Some(TerminalFailure::IdleDeadline)
        } else {
            None
        };
        if let Some(failure) = failure {
            self.fail(failure);
        }
    }

    pub fn fail(&mut self, failure: TerminalFailure) {
        if !self.collected && self.failure.is_none() {
            self.failure = Some(failure);
        }
    }
    pub fn failure(&self) -> Option<TerminalFailure> {
        self.failure
    }

    /// Only an exact owned-child collection proof permits this call. Neither a
    /// guest Exit, input EOF, deadline nor local close can call it on its own.
    pub fn collected(
        &mut self,
        identity: &TerminalIdentity,
        successful: bool,
        now: Instant,
    ) -> Result<TerminalOutcome> {
        if self.retired || self.collected || &self.identity != identity {
            return Err(Error::uncertain(ErrorCode::State));
        }
        self.expire(now);
        if !successful || self.observed_exit.is_none() {
            self.fail(TerminalFailure::Native);
        }
        self.collected = true;
        Ok(TerminalOutcome {
            observed_exit: self.observed_exit,
            failure: self.failure,
        })
    }

    pub fn retire(&mut self) {
        self.fail(TerminalFailure::ConsumerLost);
        self.retired = true;
    }

    fn check(&mut self, identity: &TerminalIdentity, now: Instant) -> Result<()> {
        if self.retired || self.collected || &self.identity != identity {
            return Err(Error::uncertain(ErrorCode::State));
        }
        self.expire(now);
        if self.failure.is_some() || self.observed_exit.is_some() {
            return Err(Error::uncertain(ErrorCode::State));
        }
        Ok(())
    }
}

fn qualified_exit(code: i32) -> Option<u8> {
    u8::try_from(code)
        .ok()
        .filter(|code| !matches!(code, 124 | 130))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn identity() -> TerminalIdentity {
        TerminalIdentity::new("ab".repeat(16), "cd".repeat(16)).unwrap()
    }
    fn options() -> TerminalOptions {
        TerminalOptions {
            program: "/bin/sh".into(),
            cols: 80,
            rows: 24,
            session: Duration::from_secs(30),
            idle: Duration::from_secs(30),
            attach: Duration::from_secs(5),
            close: Duration::from_secs(1),
            max_buffer_bytes: 1_048_576,
            max_input_bytes: 65_536,
            total_input_bytes: 1_048_576,
        }
    }
    fn session(options: TerminalOptions, now: Instant) -> TerminalSession {
        TerminalSession::new(identity(), options, now, now + Duration::from_secs(60)).unwrap()
    }

    #[test]
    fn terminal_options_preserve_public_bounds_and_reject_implicit_unbounded_inputs() {
        options().validate().unwrap();
        for case in 0..10 {
            let mut spec = options();
            match case {
                0 => spec.program.push('\0'),
                1 => spec.cols = 0,
                2 => spec.session = Duration::from_millis(999),
                3 => spec.idle = Duration::from_secs(31),
                4 => spec.attach = Duration::from_millis(99),
                5 => spec.close = Duration::from_millis(5001),
                6 => spec.max_buffer_bytes = 1_048_577,
                7 => spec.max_input_bytes = 65_537,
                8 => spec.total_input_bytes = TERMINAL_INPUT_BYTES + 1,
                _ => spec.close = Duration::from_micros(1001),
            }
            assert!(spec.validate().is_err());
        }
        assert!(TerminalIdentity::new("AB".repeat(16), "cd".repeat(16)).is_err());
        assert!(TerminalIdentity::new("ab".repeat(16), "cd".repeat(15)).is_err());
    }

    #[test]
    fn ordered_control_admission_counts_bytes_without_implying_guest_consumption() {
        let now = Instant::now();
        let mut spec = options();
        spec.total_input_bytes = 6;
        let mut state = session(spec, now);
        state.attach(&identity(), now).unwrap();
        let input = TerminalControl::Input(vec![0, 255]);
        assert!(state.control(&identity(), 1, &input, 1, now).is_err());
        state.control(&identity(), 1, &input, 2, now).unwrap();
        assert!(state.control(&identity(), 1, &input, 2, now).is_err());
        state
            .control(
                &identity(),
                2,
                &TerminalControl::Resize {
                    cols: 120,
                    rows: 40,
                },
                4,
                now,
            )
            .unwrap();
        assert_eq!(state.observed_exit, None);
        state
            .control(&identity(), 3, &TerminalControl::Close, 0, now)
            .unwrap();
        assert!(state.control(&identity(), 4, &input, 2, now).is_err());
        assert_eq!(
            state
                .collected(&identity(), true, now)
                .unwrap()
                .confirmed_exit(),
            None
        );
    }

    #[test]
    fn exact_consumption_credit_bounds_unread_output_without_a_lifetime_output_cap() {
        let now = Instant::now();
        let mut state = session(options(), now);
        state.attach(&identity(), now).unwrap();
        for sequence in 1..=1024 {
            state.output(&identity(), sequence, 32_768, now).unwrap();
            assert!(state.consumed(&identity(), sequence, 32_767).is_err());
            state.consumed(&identity(), sequence, 32_768).unwrap();
            assert!(state.consumed(&identity(), sequence, 32_768).is_err());
        }
        assert_eq!(state.output_sequence * 32_768, 32 * 1024 * 1024);
        assert_eq!(state.unread_bytes, 0);
        state.observe_exit(&identity(), 7, now).unwrap();
        assert_eq!(
            state
                .collected(&identity(), true, now)
                .unwrap()
                .confirmed_exit(),
            Some(7)
        );
    }

    #[test]
    fn tiny_events_and_slow_consumers_exhaust_distinct_bounded_windows() {
        let now = Instant::now();
        let mut state = session(options(), now);
        for sequence in 1..=TERMINAL_BUFFER_EVENTS as u64 {
            state.output(&identity(), sequence, 1, now).unwrap();
        }
        assert!(state.output(&identity(), 1025, 1, now).is_err());
        assert_eq!(state.unread_bytes, 1024);
        assert_eq!(state.failure, Some(TerminalFailure::OutputLimit));
        let mut spec = options();
        spec.max_buffer_bytes = 1024;
        let mut state = session(spec, now);
        state.output(&identity(), 1, 1024, now).unwrap();
        assert!(state.output(&identity(), 2, 1, now).is_err());
        state.observe_exit(&identity(), 7, now).unwrap();
        let outcome = state.collected(&identity(), true, now).unwrap();
        assert_eq!(outcome.observed_exit, Some(7));
        assert_eq!(outcome.confirmed_exit(), None);
    }

    #[test]
    fn foreign_retired_partial_and_out_of_order_events_cannot_restore_credit_or_reopen() {
        let now = Instant::now();
        let mut state = session(options(), now);
        let foreign = TerminalIdentity::new("ef".repeat(16), "cd".repeat(16)).unwrap();
        assert!(state.attach(&foreign, now).is_err());
        state.attach(&identity(), now).unwrap();
        assert!(state.attach(&identity(), now).is_err());
        state.output(&identity(), 1, 5, now).unwrap();
        state.output(&identity(), 2, 7, now).unwrap();
        assert!(state.consumed(&foreign, 1, 5).is_err());
        assert!(state.consumed(&identity(), 2, 7).is_err());
        assert_eq!(state.unread_bytes, 12);
        state.retire();
        assert!(state.consumed(&identity(), 1, 5).is_err());
        assert!(state.observe_exit(&identity(), 0, now).is_err());
        assert!(state.collected(&identity(), true, now).is_err());
        assert_eq!(state.observed_exit, None);
    }

    #[test]
    fn close_eof_sentinels_and_failed_collection_never_become_confirmed_exit() {
        let now = Instant::now();
        for exit in [None, Some(-1), Some(124), Some(130), Some(256)] {
            let mut state = session(options(), now);
            if let Some(exit) = exit {
                state.observe_exit(&identity(), exit, now).unwrap();
            }
            assert_eq!(
                state
                    .collected(&identity(), true, now)
                    .unwrap()
                    .confirmed_exit(),
                None
            );
        }
        let mut state = session(options(), now);
        state.observe_exit(&identity(), 7, now).unwrap();
        let outcome = state.collected(&identity(), false, now).unwrap();
        assert_eq!(outcome.observed_exit, Some(7));
        assert_eq!(outcome.confirmed_exit(), None);
        assert!(state.collected(&identity(), true, now).is_err());
    }

    #[test]
    fn deadlines_and_cancel_preserve_actual_exit_without_releasing_collection_authority() {
        let now = Instant::now();
        for reason in [
            TerminalFailure::Cancelled,
            TerminalFailure::ConsumerLost,
            TerminalFailure::Uncollected,
        ] {
            let mut state = session(options(), now);
            state.fail(reason);
            state.observe_exit(&identity(), 7, now).unwrap();
            assert!(!state.collected);
            let outcome = state.collected(&identity(), true, now).unwrap();
            assert_eq!(outcome.failure, Some(reason));
            assert_eq!(outcome.observed_exit, Some(7));
            assert_eq!(outcome.confirmed_exit(), None);
        }
        let mut state = session(options(), now);
        state.attach(&identity(), now).unwrap();
        state
            .observe_exit(&identity(), 7, now + Duration::from_secs(30))
            .unwrap();
        assert_eq!(
            state
                .collected(&identity(), true, now + Duration::from_secs(30))
                .unwrap()
                .failure,
            Some(TerminalFailure::SessionDeadline)
        );
    }

    #[test]
    fn attach_idle_close_and_outer_deadlines_are_finite_and_cannot_extend_each_other() {
        let now = Instant::now();
        let mut state = session(options(), now);
        state.expire(now + Duration::from_secs(5));
        assert_eq!(state.failure, Some(TerminalFailure::AttachDeadline));
        let mut spec = options();
        spec.idle = Duration::from_secs(1);
        let mut state = session(spec, now);
        state.attach(&identity(), now).unwrap();
        state.expire(now + Duration::from_secs(1));
        assert_eq!(state.failure, Some(TerminalFailure::IdleDeadline));
        let mut state = session(options(), now);
        state.attach(&identity(), now).unwrap();
        state
            .control(&identity(), 1, &TerminalControl::Close, 0, now)
            .unwrap();
        state.expire(now + Duration::from_secs(1));
        assert_eq!(state.failure, Some(TerminalFailure::CloseDeadline));
        let mut state =
            TerminalSession::new(identity(), options(), now, now + Duration::from_millis(50))
                .unwrap();
        state.expire(now + Duration::from_millis(50));
        assert_eq!(state.failure, Some(TerminalFailure::SessionDeadline));
    }

    #[test]
    fn output_after_exit_invalidates_completion_and_preserves_the_original_exit() {
        let now = Instant::now();
        let mut state = session(options(), now);
        state.observe_exit(&identity(), 7, now).unwrap();
        assert!(state.observe_exit(&identity(), 0, now).is_err());
        assert!(state.output(&identity(), 1, 1, now).is_err());
        let outcome = state.collected(&identity(), true, now).unwrap();
        assert_eq!(outcome.observed_exit, Some(7));
        assert_eq!(outcome.failure, Some(TerminalFailure::Protocol));
        assert_eq!(outcome.confirmed_exit(), None);
    }

    #[test]
    fn input_exhaustion_rejects_before_forwarding_and_retains_subsequent_exit_as_uncertain() {
        let now = Instant::now();
        let mut spec = options();
        spec.total_input_bytes = 1;
        let mut state = session(spec, now);
        let input = TerminalControl::Input(vec![0, 255]);
        assert!(state.control(&identity(), 1, &input, 2, now).is_err());
        state.attach(&identity(), now).unwrap();
        assert!(state.control(&identity(), 1, &input, 2, now).is_err());
        assert_eq!(state.control_sequence, 0);
        assert_eq!(state.input_bytes, 0);
        assert_eq!(state.output_window(), (0, 0));
        state.observe_exit(&identity(), 7, now).unwrap();
        let outcome = state.collected(&identity(), true, now).unwrap();
        assert_eq!(outcome.failure, Some(TerminalFailure::InputLimit));
        assert_eq!(outcome.observed_exit, Some(7));
        assert_eq!(outcome.confirmed_exit(), None);
    }

    #[test]
    fn output_window_refills_only_from_matching_consumption_and_stays_closed_after_exit() {
        let now = Instant::now();
        let mut spec = options();
        spec.max_buffer_bytes = 1024;
        let mut state = session(spec, now);
        state.output(&identity(), 1, 1024, now).unwrap();
        assert_eq!(state.output_window(), (0, 1023));
        let foreign = TerminalIdentity::new("ab".repeat(16), "ef".repeat(16)).unwrap();
        assert!(state.consumed(&foreign, 1, 1024).is_err());
        assert_eq!(state.output_window(), (0, 1023));
        state.consumed(&identity(), 1, 1024).unwrap();
        assert_eq!(state.output_window(), (1024, 1024));
        state.output(&identity(), 2, 1, now).unwrap();
        state.observe_exit(&identity(), 7, now).unwrap();
        state.consumed(&identity(), 2, 1).unwrap();
        assert_eq!(state.output_window(), (0, 0));
        assert_eq!(
            state
                .collected(&identity(), true, now)
                .unwrap()
                .confirmed_exit(),
            Some(7)
        );
    }
}
