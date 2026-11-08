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
}

pub struct Session {
    hello: Hello,
    approved: bool,
    last_request: u64,
    pending: BTreeMap<u64, Pending>,
}
impl Session {
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
        check(id > self.last_request)?;
        self.last_request = id;
        let code = if rejection.is_some() {
            rejection
        } else if !self.hello.capabilities.contains(&operation.capability()) {
            Some(SafeCode::Unsupported)
        } else if operation
            .receipt()
            .is_some_and(|r| !r.matches_domain(&self.hello.domain))
        {
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
                operation,
                sequence: 0,
                credit: initial_credit,
                event_credit: initial_event_credit,
                outstanding_events: VecDeque::new(),
                unacknowledged: 0,
                output_bytes: 0,
                upload_bytes: 0,
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
            while remaining > 0 {
                let front = outstanding.front_mut().ok_or(InvalidMessage)?;
                let consumed = remaining.min(*front);
                remaining -= consumed;
                *front -= consumed;
                if *front == 0 {
                    outstanding.pop_front();
                    retired += 1;
                }
            }
            check(events == retired && pending.event_credit + events <= INITIAL_CREDIT_EVENTS)?;
            pending.outstanding_events = outstanding;
            pending.event_credit += events;
            pending.unacknowledged -= bytes;
            pending.credit += bytes;
        }
        Ok(())
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
            Operation::Exec { command, .. }
                if matches!(stream, Stream::Stdout | Stream::Stderr) =>
            {
                command.max_output_bytes
            }
            Operation::ReadFile { options, .. } if stream == Stream::File => options.max_bytes,
            _ => return Err(InvalidMessage),
        };
        let length = bytes.len() as u64;
        check(length <= pending.credit && length <= limit.saturating_sub(pending.output_bytes))?;
        check(pending.event_credit > 0)?;
        check(pending.sequence < MAX_EVENTS_PER_REQUEST)?; // Leave room for terminal.
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
        outcome.validate()?;
        let pending = self.pending.get(&id).ok_or(InvalidMessage)?;
        match (&pending.operation, &outcome) {
            (Operation::QualifyCreation { .. }, Outcome::Qualified) => {}
            (Operation::InspectCreation { .. }, Outcome::CreationPresence { .. }) => {}
            (_, Outcome::Error { dispatch, .. }) => {
                check(*dispatch != Dispatch::NotDispatched || pending.output_bytes == 0)?
            }
            (Operation::Create { create }, Outcome::Created { receipt }) => {
                check(
                    receipt.matches_domain(&self.hello.domain)
                        && receipt.name == create.name
                        && receipt.owner_token == create.owner_token
                        && receipt.incarnation == create.incarnation,
                )?;
            }
            (
                Operation::Inspect { .. }
                | Operation::Start { .. }
                | Operation::Stop { .. }
                | Operation::Delete { .. },
                Outcome::Observed { .. },
            ) => {}
            (
                Operation::Exec { command, .. },
                Outcome::Command {
                    completion,
                    output_bytes,
                    dispatch,
                    ..
                },
            ) => {
                check(
                    *output_bytes >= pending.output_bytes
                        && *output_bytes <= command.max_output_bytes,
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
