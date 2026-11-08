//! Helper-side protocol state. Native work and channel queues live elsewhere.
//! State transitions never dispatch native work by themselves.
use crate::*;
use std::collections::{BTreeMap, VecDeque};

struct Pending {
    operation: Operation,
    sequence: u64,
    credit: u64,
    event_credit: u64,
    outstanding_events: VecDeque<u64>,
    unacknowledged: u64,
    output_bytes: u64,
    upload_bytes: u64,
    terminal_control: u64,
    terminal_opened: bool,
    terminal_attached: bool,
    terminal_closed: bool,
    terminal_input: u64,
}

pub struct Session {
    hello: Hello,
    approved: bool,
    last_request: u64,
    pending: BTreeMap<u64, Pending>,
}
impl Session {
    pub fn protocol_major(&self) -> u16 {
        self.hello.major
    }
    pub fn new(hello: Hello) -> Result<Self, InvalidMessage> {
        hello.validate()?;
        Ok(Self {
            hello,
            approved: false,
            last_request: 0,
            pending: BTreeMap::new(),
        })
    }
    pub fn approve(&mut self, hello: &Hello) -> Result<(), InvalidMessage> {
        check(!self.approved)?;
        self.hello.approve(hello)?;
        self.approved = true;
        Ok(())
    }
    /// IDs strictly increase, including rejected requests. This bounds duplicate
    /// detection without retaining an ever-growing table of completed IDs.
    /// An accepted response means scheduling only; it contains no dispatch or
    /// running evidence. The caller must enqueue it before any worker can emit.
    pub fn admit(&mut self, message: ClientMessage) -> Result<ServerMessage, InvalidMessage> {
        self.admit_with_policy(message, None)
    }
    /// Additional package/catalog policy, evaluated before native work admission.
    pub fn admit_with_policy(
        &mut self,
        message: ClientMessage,
        rejection: Option<SafeCode>,
    ) -> Result<ServerMessage, InvalidMessage> {
        message.validate()?;
        let ClientMessage::Request {
            epoch,
            id,
            budget_ms: _,
            initial_credit,
            initial_event_credit,
            operation,
        } = message
        else {
            return Err(InvalidMessage);
        };
        self.channel(&epoch)?;
        if let Operation::TerminalOpen { terminal, .. } = &operation {
            check(initial_credit <= terminal.max_buffer_bytes)?;
        }
        check(id > self.last_request)?;
        self.last_request = id;
        let code =
            if rejection.is_some() {
                rejection
            } else if !self.hello.capabilities.contains(&operation.capability())
                || (operation.requires_remote_source()
                    && (self.hello.major != 2
                        || self.hello.sdk.as_ref().is_none_or(|sdk| {
                            sdk.feature_versions.get("remote_sources") != Some(&1)
                        })))
                || operation
                    .creation_features()
                    .is_some_and(|features| !features.approved(&self.hello))
            {
                Some(SafeCode::Unsupported)
            } else if operation.receipt().is_some_and(|r| {
                !r.matches_domain(&self.hello.domain) || r.validate_for(self.hello.major).is_err()
            }) {
                Some(SafeCode::Ownership)
            } else if self.pending.len() >= MAX_IN_FLIGHT {
                Some(SafeCode::Overload)
            } else {
                None
            };
        if let Some(code) = code {
            return Ok(ServerMessage::Terminal {
                epoch,
                id,
                sequence: 0,
                outcome: Outcome::Error {
                    code,
                    dispatch: Dispatch::NotDispatched,
                },
            });
        }
        self.pending.insert(
            id,
            Pending {
                operation: operation.sanitized(),
                sequence: 0,
                credit: initial_credit,
                event_credit: initial_event_credit,
                outstanding_events: VecDeque::new(),
                unacknowledged: 0,
                output_bytes: 0,
                upload_bytes: 0,
                terminal_control: 0,
                terminal_opened: false,
                terminal_attached: false,
                terminal_closed: false,
                terminal_input: 0,
            },
        );
        Ok(ServerMessage::Accepted {
            epoch,
            id,
            sequence: 0,
        })
    }
    /// Late control for a completed request is an ordinary completion race.
    /// Unknown future IDs, a wrong epoch, or control before approval is fatal.
    pub fn cancel(&self, epoch: &str, id: u64) -> Result<bool, InvalidMessage> {
        ClientMessage::Cancel {
            epoch: epoch.into(),
            id,
        }
        .validate()?;
        self.channel(epoch)?;
        check(id <= self.last_request)?;
        Ok(self.pending.contains_key(&id))
    }
    pub fn credit(
        &mut self,
        epoch: &str,
        id: u64,
        bytes: u64,
        events: u64,
    ) -> Result<(), InvalidMessage> {
        ClientMessage::Credit {
            epoch: epoch.into(),
            id,
            decoded_bytes: bytes,
            events,
        }
        .validate()?;
        self.channel(epoch)?;
        check(id <= self.last_request)?;
        if let Some(pending) = self.pending.get_mut(&id) {
            check(
                bytes <= pending.unacknowledged && pending.credit + bytes <= INITIAL_CREDIT_BYTES,
            )?;
            // Partial byte consumption does not retire a message. Validate the
            // exact number of fully consumed events before changing either window.
            let mut outstanding = pending.outstanding_events.clone();
            let mut remaining = bytes;
            let mut retired = 0;
            let mut partial = false;
            while remaining > 0 {
                let front = outstanding.front_mut().ok_or(InvalidMessage)?;
                let consumed = remaining.min(*front);
                partial |= consumed < *front;
                remaining -= consumed;
                *front -= consumed;
                if *front == 0 {
                    outstanding.pop_front();
                    retired += 1;
                }
            }
            check(events == retired && pending.event_credit + events <= INITIAL_CREDIT_EVENTS)?;
            check(!matches!(pending.operation, Operation::TerminalOpen { .. }) || !partial)?;
            pending.outstanding_events = outstanding;
            pending.event_credit += events;
            pending.unacknowledged -= bytes;
            pending.credit += bytes;
        }
        Ok(())
    }
    pub fn terminal_opened(&mut self, id: u64) -> Result<ServerMessage, InvalidMessage> {
        let pending = self.pending.get_mut(&id).ok_or(InvalidMessage)?;
        check(
            matches!(pending.operation, Operation::TerminalOpen { .. }) && !pending.terminal_opened,
        )?;
        pending.sequence += 1;
        pending.terminal_opened = true;
        Ok(ServerMessage::TerminalOpened {
            epoch: self.hello.epoch.clone(),
            id,
            sequence: pending.sequence,
        })
    }
    pub fn terminal_control(
        &mut self,
        epoch: &str,
        id: u64,
        sequence: u64,
        control: &TerminalAction,
    ) -> Result<bool, InvalidMessage> {
        ClientMessage::TerminalControl {
            epoch: epoch.into(),
            id,
            sequence,
            control: control.clone(),
        }
        .validate()?;
        self.channel(epoch)?;
        check(id <= self.last_request)?;
        let Some(pending) = self.pending.get_mut(&id) else {
            return Ok(false);
        };
        let Operation::TerminalOpen { terminal, .. } = &pending.operation else {
            return Err(InvalidMessage);
        };
        check(
            pending.terminal_opened
                && !pending.terminal_closed
                && pending.terminal_control.checked_add(1) == Some(sequence),
        )?;
        let charge = match control {
            TerminalAction::Attach => {
                check(!pending.terminal_attached)?;
                0
            }
            TerminalAction::Input { data_base64 } => {
                check(pending.terminal_attached)?;
                let n = decode_chunk(data_base64)?.len() as u64;
                check(n <= terminal.max_input_bytes)?;
                n
            }
            TerminalAction::Resize { .. } => {
                check(pending.terminal_attached)?;
                4
            }
            TerminalAction::Close => {
                check(pending.terminal_attached)?;
                0
            }
        };
        check(charge <= terminal.total_input_bytes - pending.terminal_input)?;
        pending.terminal_input += charge;
        pending.terminal_control = sequence;
        pending.terminal_attached |= matches!(control, TerminalAction::Attach);
        pending.terminal_closed |= matches!(control, TerminalAction::Close);
        Ok(true)
    }
    /// The helper spools each returned upload chunk to an owned capped file. It
    /// must not call native write until upload_complete, and must cancel on a
    /// spool error. Offset checks reject duplicate, reordered and excess bytes.
    pub fn upload(
        &mut self,
        epoch: &str,
        id: u64,
        offset: u64,
        encoded: &str,
    ) -> Result<Vec<u8>, InvalidMessage> {
        self.channel(epoch)?;
        let data = decode_chunk(encoded)?;
        check(!data.is_empty())?;
        let pending = self.pending.get_mut(&id).ok_or(InvalidMessage)?;
        let Operation::WriteFile { total_bytes, .. } = pending.operation else {
            return Err(InvalidMessage);
        };
        check(
            offset == pending.upload_bytes
                && data.len() as u64 <= total_bytes.saturating_sub(offset),
        )?;
        pending.upload_bytes += data.len() as u64;
        Ok(data)
    }
    pub fn upload_complete(&self, id: u64) -> Result<bool, InvalidMessage> {
        let pending = self.pending.get(&id).ok_or(InvalidMessage)?;
        match pending.operation {
            Operation::WriteFile { total_bytes, .. } => Ok(pending.upload_bytes == total_bytes),
            _ => Err(InvalidMessage),
        }
    }
    /// Credit exhaustion fails immediately. No guest socket waits for new
    /// credit; the helper must cancel this operation and preserve its evidence.
    pub fn event(
        &mut self,
        id: u64,
        stream: Stream,
        bytes: &[u8],
    ) -> Result<ServerMessage, InvalidMessage> {
        let encoded = encode_chunk(bytes)?;
        let pending = self.pending.get_mut(&id).ok_or(InvalidMessage)?;
        let limit = match &pending.operation {
            Operation::TerminalOpen { .. }
                if stream == Stream::Terminal && pending.terminal_opened =>
            {
                MAX_SAFE_INTEGER
            }
            Operation::Logs { max_bytes, .. } if stream == Stream::Log => *max_bytes + 30000,
            Operation::Exec { command, .. }
                if matches!(stream, Stream::Stdout | Stream::Stderr) =>
            {
                command.max_output_bytes
            }
            Operation::ReadFile { options, .. } if stream == Stream::File => options.max_bytes,
            Operation::ExecBuffered { command, .. } | Operation::ExecStream { command, .. }
                if matches!(stream, Stream::Stdout | Stream::Stderr) =>
            {
                command.max_output_bytes
            }
            Operation::ListImages { .. } if stream == Stream::File => 8 * 1024 * 1024,
            Operation::List if stream == Stream::File => 4 * 1024 * 1024,
            _ => return Err(InvalidMessage),
        };
        let length = bytes.len() as u64;
        check(length <= pending.credit && length <= limit.saturating_sub(pending.output_bytes))?;
        check(pending.event_credit > 0)?;
        check(
            pending.sequence
                < if matches!(pending.operation, Operation::TerminalOpen { .. }) {
                    MAX_SAFE_INTEGER - 1
                } else {
                    MAX_EVENTS_PER_REQUEST
                },
        )?; // Leave room for terminal.
        pending.sequence += 1;
        pending.credit -= length;
        pending.event_credit -= 1;
        pending.outstanding_events.push_back(length);
        pending.unacknowledged += length;
        pending.output_bytes += length;
        Ok(ServerMessage::Event {
            epoch: self.hello.epoch.clone(),
            id,
            sequence: pending.sequence,
            event: Event {
                stream,
                data_base64: encoded,
            },
        })
    }
    pub fn terminal(&mut self, id: u64, outcome: Outcome) -> Result<ServerMessage, InvalidMessage> {
        outcome.validate_for(self.hello.major)?;
        let pending = self.pending.get(&id).ok_or(InvalidMessage)?;
        match (&pending.operation, &outcome) {
            (
                Operation::ExpandDisks {
                    receipt,
                    operation_id,
                    request,
                    previous,
                },
                Outcome::Grown { transition, .. },
            ) => {
                check(pending.output_bytes == 0)?;
                transition.matches(receipt, operation_id, *request, *previous)?;
            }
            (
                Operation::QualifyGrowth {
                    receipt,
                    operation_id,
                    request,
                    previous,
                    quiesced: true,
                },
                Outcome::GrowthQualified { transition, .. },
            ) => {
                check(pending.output_bytes == 0)?;
                transition.matches(receipt, operation_id, *request, *previous)?;
            }
            (
                Operation::InspectGrowth {
                    receipt,
                    operation_id,
                    request,
                    previous,
                },
                Outcome::GrowthPresence { transition },
            ) => {
                check(pending.output_bytes == 0)?;
                if let Some(transition) = transition {
                    transition.matches(receipt, operation_id, *request, *previous)?;
                }
            }
            (
                Operation::TerminalOpen { .. },
                Outcome::Terminal {
                    completion,
                    dispatch,
                    output_bytes,
                    ..
                },
            ) => {
                check(*output_bytes >= pending.output_bytes)?;
                check(*dispatch != Dispatch::NotDispatched || pending.output_bytes == 0)?;
                if *completion == Completion::Exited {
                    check(pending.terminal_opened && *output_bytes == pending.output_bytes)?;
                }
            }
            (
                Operation::Logs { max_bytes, .. },
                Outcome::Logs {
                    completion,
                    bytes,
                    wire_bytes,
                    ..
                },
            ) => {
                check(*bytes <= *max_bytes && *wire_bytes == pending.output_bytes)?;
                check(
                    *completion != Completion::Completed
                        || !matches!(pending.operation, Operation::Logs { follow: true, .. }),
                )?;
            }
            (Operation::ExecBackground { command, .. }, Outcome::Launched { pid }) => {
                check(
                    pending.output_bytes == 0
                        && format!("pid={pid}\n").len() as u64 <= command.max_output_bytes,
                )?;
            }
            (Operation::Health, Outcome::Health { .. })
            | (Operation::Capacity, Outcome::Capacity { .. })
            | (Operation::Metrics, Outcome::Metrics { .. })
            | (Operation::Readiness, Outcome::Ready)
            | (Operation::Measurements { .. }, Outcome::Measurements { .. }) => {
                check(pending.output_bytes == 0)?;
            }
            (
                Operation::PrepareArtifact { source, .. },
                Outcome::PreparedArtifact {
                    source: observed, ..
                },
            ) => {
                check(pending.output_bytes == 0 && source == observed)?;
            }
            (Operation::PullImage { source, .. }, Outcome::Pulled { image }) => {
                check(pending.output_bytes == 0)?;
                image.matches(source)?;
            }
            (Operation::ListImages { .. }, Outcome::Images { bytes, .. }) => {
                check(*bytes == pending.output_bytes)?;
            }
            (Operation::List, Outcome::Inventory { bytes, .. }) => {
                check(*bytes == pending.output_bytes)?;
            }
            (
                Operation::QualifyCreation { .. }
                | Operation::QualifyOciCreation { .. }
                | Operation::QualifyRegistryCreation { .. },
                Outcome::Qualified,
            ) => {}
            (
                Operation::InspectCreation { .. }
                | Operation::InspectOciCreation { .. }
                | Operation::InspectRegistryCreation { .. },
                Outcome::CreationPresence { .. },
            ) => {}
            (_, Outcome::Error { dispatch, .. }) => {
                check(*dispatch != Dispatch::NotDispatched || pending.output_bytes == 0)?
            }
            (Operation::Create { create }, Outcome::Created { receipt }) => {
                receipt.validate_for(self.hello.major)?;
                check(
                    receipt.matches_domain(&self.hello.domain)
                        && receipt.name == create.name
                        && receipt.owner_token == create.owner_token
                        && receipt.incarnation == create.incarnation,
                )?;
            }
            (Operation::CreateRegistryPrepared { create, .. }, Outcome::Created { receipt }) => {
                check(pending.output_bytes == 0)?;
                receipt.validate_for(2)?;
                check(
                    receipt.matches_domain(&self.hello.domain)
                        && receipt.name == create.name
                        && receipt.owner_token == create.owner_token
                        && receipt.incarnation == create.incarnation,
                )?;
            }
            (Operation::CreateOci { create }, Outcome::Created { receipt }) => {
                check(pending.output_bytes == 0)?;
                receipt.validate_for(2)?;
                check(
                    receipt.matches_domain(&self.hello.domain)
                        && receipt.name == create.name
                        && receipt.owner_token == create.owner_token
                        && receipt.incarnation == create.incarnation,
                )?;
            }
            (
                Operation::StartOci { .. }
                | Operation::Inspect { .. }
                | Operation::Start { .. }
                | Operation::Stop { .. }
                | Operation::Delete { .. },
                Outcome::Observed { .. },
            ) => {}
            (
                operation,
                Outcome::Command {
                    completion,
                    output_bytes,
                    dispatch,
                    ..
                },
            ) if operation.command_limit().is_some() => {
                check(
                    *output_bytes >= pending.output_bytes
                        && *output_bytes <= operation.command_limit().unwrap(),
                )?;
                check(*dispatch != Dispatch::NotDispatched || pending.output_bytes == 0)?;
                if *completion == Completion::Exited {
                    check(*output_bytes == pending.output_bytes)?;
                }
            }
            (
                Operation::ReadFile { options, .. },
                Outcome::File {
                    completion,
                    observed_bytes,
                    ..
                },
            ) => {
                check(
                    *observed_bytes >= pending.output_bytes && *observed_bytes <= options.max_bytes,
                )?;
                if *completion == Completion::Completed {
                    check(*observed_bytes == pending.output_bytes)?;
                }
            }
            (
                Operation::WriteFile { total_bytes, .. },
                Outcome::File {
                    completion,
                    observed_bytes,
                    ..
                },
            ) => {
                check(*observed_bytes <= *total_bytes)?;
                if *completion == Completion::Completed {
                    check(pending.upload_bytes == *total_bytes && *observed_bytes == *total_bytes)?;
                }
            }
            _ => return Err(InvalidMessage),
        }
        let sequence = pending.sequence + 1;
        self.pending.remove(&id);
        Ok(ServerMessage::Terminal {
            epoch: self.hello.epoch.clone(),
            id,
            sequence,
            outcome,
        })
    }
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }
    pub fn check_epoch(&self, epoch: &str) -> Result<(), InvalidMessage> {
        self.channel(epoch)
    }
    pub fn available_credit(&self, id: u64) -> Result<u64, InvalidMessage> {
        self.pending
            .get(&id)
            .map(|pending| pending.credit)
            .ok_or(InvalidMessage)
    }
    pub fn available_event_credit(&self, id: u64) -> Result<u64, InvalidMessage> {
        self.pending
            .get(&id)
            .map(|pending| pending.event_credit)
            .ok_or(InvalidMessage)
    }
    fn channel(&self, epoch: &str) -> Result<(), InvalidMessage> {
        check(self.approved && epoch == self.hello.epoch)
    }
}
fn check(condition: bool) -> Result<(), InvalidMessage> {
    if condition {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}
