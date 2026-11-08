//! One stdout writer, bounded by decoded bytes, encoded bytes and frame count.
//! Event capacity is checked before advancing protocol sequence/credit state.
use crossbeam_channel::{bounded, Receiver, Sender};
use smolbox_protocol::{write_frame, ServerMessage};
use std::io::Write;
use std::sync::{Arc, Mutex};

const MAX_DECODED: usize = 8 * 1024 * 1024;
const MAX_EVENT_FRAMES: usize = 4096;
const CONTROL_FRAMES: usize = 65;
const SMALL_CONTROL_BYTES: usize = 4096;
// Branch absence and backing proofs are capped at 68 KiB, plus its terminal envelope. Keep
// the existing event allowance and enough space for every outstanding control
// frame, even when all terminal replies contain the largest branch proof.
const BRANCH_CONTROL_BYTES: usize =
    if smolbox_protocol::BRANCH_ABSENCE_BYTES > smolbox_protocol::BRANCH_BACKING_PROOF_BYTES {
        smolbox_protocol::BRANCH_ABSENCE_BYTES
    } else {
        smolbox_protocol::BRANCH_BACKING_PROOF_BYTES
    } + SMALL_CONTROL_BYTES;
const CONTROL_BYTES: usize = CONTROL_FRAMES * BRANCH_CONTROL_BYTES;
const MAX_EVENT_ENCODED: usize = 12 * 1024 * 1024 - CONTROL_FRAMES * SMALL_CONTROL_BYTES;
const MAX_ENCODED: usize = MAX_EVENT_ENCODED + CONTROL_BYTES;
const EVENT_ENCODED_RESERVE: usize = 96 * 1024;

#[derive(Default)]
struct Usage {
    decoded: usize,
    encoded: usize,
    events: usize,
    controls: usize,
}
pub struct Frame {
    pub bytes: Vec<u8>,
    decoded: usize,
    control: bool,
}
pub struct Output {
    sender: Sender<Frame>,
    usage: Arc<Mutex<Usage>>,
}
impl Output {
    pub fn new() -> (Self, Receiver<Frame>) {
        let (sender, receiver) = bounded(MAX_EVENT_FRAMES + CONTROL_FRAMES);
        (
            Self {
                sender,
                usage: Arc::new(Mutex::new(Usage::default())),
            },
            receiver,
        )
    }
    /// Build is called only after capacity is secured, so rejection cannot leave
    /// a hole in the per-request sequence. Build never performs native I/O.
    pub fn send(
        &self,
        decoded: usize,
        build: impl FnOnce() -> Result<ServerMessage, ()>,
    ) -> Result<(), ()> {
        let reserve = if decoded == 0 {
            SMALL_CONTROL_BYTES
        } else {
            EVENT_ENCODED_RESERVE
        };
        self.send_reserved(decoded, reserve, || {
            let message = build()?;
            if branch_terminal(&message) {
                return Err(());
            }
            Ok(message)
        })
    }
    pub fn send_branch_terminal(
        &self,
        build: impl FnOnce() -> Result<ServerMessage, ()>,
    ) -> Result<(), ()> {
        self.send_reserved(0, BRANCH_CONTROL_BYTES, || {
            let message = build()?;
            if !branch_terminal(&message) {
                return Err(());
            }
            Ok(message)
        })
    }
    fn send_reserved(
        &self,
        decoded: usize,
        reserve: usize,
        build: impl FnOnce() -> Result<ServerMessage, ()>,
    ) -> Result<(), ()> {
        let control = decoded == 0;
        let mut usage = self.usage.lock().map_err(|_| ())?;
        let encoded_max = if control {
            MAX_ENCODED
        } else {
            MAX_EVENT_ENCODED
        };
        if usage.decoded + decoded > MAX_DECODED
            || usage.encoded + reserve > encoded_max
            || (control && usage.controls >= CONTROL_FRAMES)
            || (!control && usage.events >= MAX_EVENT_FRAMES)
        {
            return Err(());
        }
        let message = build()?;
        message.validate().map_err(|_| ())?;
        let value = serde_json::to_value(message).map_err(|_| ())?;
        let mut bytes = Vec::new();
        write_frame(&mut bytes, &value).map_err(|_| ())?;
        if bytes.len() > reserve {
            return Err(());
        }
        usage.decoded += decoded;
        usage.encoded += bytes.len();
        if control {
            usage.controls += 1;
        } else {
            usage.events += 1;
        }
        // All producers hold usage through send. Capacity includes the frame
        // currently being written, until complete() releases its accounting.
        self.sender
            .try_send(Frame {
                bytes,
                decoded,
                control,
            })
            .map_err(|_| ())
    }
    pub fn complete(&self, frame: &Frame) {
        let mut usage = self.usage.lock().unwrap_or_else(|p| p.into_inner());
        usage.decoded -= frame.decoded;
        usage.encoded -= frame.bytes.len();
        if frame.control {
            usage.controls -= 1;
        } else {
            usage.events -= 1;
        }
    }
}

fn branch_terminal(message: &ServerMessage) -> bool {
    matches!(
        message,
        ServerMessage::Terminal {
            outcome: smolbox_protocol::Outcome::BranchCreated { .. }
                | smolbox_protocol::Outcome::BranchCompletionPresence { .. }
                | smolbox_protocol::Outcome::HeldBranchReleased { .. }
                | smolbox_protocol::Outcome::HeldBranchReleasePresence { .. }
                | smolbox_protocol::Outcome::UnbootedBranchChildAbsent { .. }
                | smolbox_protocol::Outcome::BranchChildAbsent { .. }
                | smolbox_protocol::Outcome::BranchBackingReleased { .. }
                | smolbox_protocol::Outcome::PreparedBranchRetired { .. }
                | smolbox_protocol::Outcome::UnbootedBranchDisposalCandidate { .. }
                | smolbox_protocol::Outcome::UnbootedBranchDisposed { .. }
                | smolbox_protocol::Outcome::ReleasedBranchDeletionContinued { .. }
                | smolbox_protocol::Outcome::BranchDeletionCollected { .. }
                | smolbox_protocol::Outcome::ReleasedBranchDeletionCleaned { .. }
                | smolbox_protocol::Outcome::ReleasedBranchDeletionResolved { .. }
                | smolbox_protocol::Outcome::HeldBranchDeletionResolved { .. }
                | smolbox_protocol::Outcome::HeldBranchDeletionContinued { .. }
                | smolbox_protocol::Outcome::HeldBranchDeletionCleaned { .. },
            ..
        }
    )
}
pub fn write(writer: &mut impl Write, frame: &Frame) -> std::io::Result<()> {
    writer.write_all(&frame.bytes)?;
    writer.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use smolbox_protocol::{encode_chunk, Event, Stream};
    fn event() -> ServerMessage {
        ServerMessage::Event {
            epoch: "ab".repeat(16),
            id: 1,
            sequence: 1,
            event: Event {
                stream: Stream::Stdout,
                data_base64: encode_chunk(b"a").unwrap(),
            },
        }
    }
    fn accepted() -> ServerMessage {
        ServerMessage::Accepted {
            epoch: "ab".repeat(16),
            id: 1,
            sequence: 0,
        }
    }
    #[test]
    fn stalled_writer_bounds_frames_and_preserves_control_capacity() {
        let (output, receiver) = Output::new();
        for _ in 0..MAX_EVENT_FRAMES {
            output.send(1, || Ok(event())).unwrap();
        }
        assert!(output
            .send(1, || panic!("sequence advanced without capacity"))
            .is_err());
        for _ in 0..CONTROL_FRAMES {
            output.send(0, || Ok(accepted())).unwrap();
        }
        assert!(output.send(0, || panic!("unbounded control")).is_err());
        let frame = receiver.recv().unwrap();
        assert!(output
            .send(1, || panic!("in-progress write released early"))
            .is_err());
        output.complete(&frame);
        output.send(1, || Ok(event())).unwrap();
    }
    #[test]
    fn decoded_bytes_and_encoded_storage_are_both_accounted() {
        let (output, receiver) = Output::new();
        for _ in 0..128 {
            output
                .send(65536, || {
                    Ok(ServerMessage::Event {
                        epoch: "ab".repeat(16),
                        id: 1,
                        sequence: 1,
                        event: Event {
                            stream: Stream::Stdout,
                            data_base64: encode_chunk(&vec![0; 65536]).unwrap(),
                        },
                    })
                })
                .unwrap();
        }
        assert!(output.send(1, || panic!("decoded budget ignored")).is_err());
        let frame = receiver.recv().unwrap();
        output.complete(&frame);
        output.send(1, || Ok(event())).unwrap();
    }
    #[test]
    fn absence_proofs_have_a_finite_terminal_allowance_and_leave_both_observers() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-child-absence-v1.json"
        ))
        .unwrap();
        for row in rows {
            let proof: smolbox_protocol::BranchChildAbsence =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let message = || ServerMessage::Terminal {
                epoch: "ab".repeat(16),
                id: 1,
                sequence: 1,
                outcome: smolbox_protocol::Outcome::BranchChildAbsent {
                    proof: Box::new(proof.clone()),
                },
            };
            let (output, receiver) = Output::new();
            assert!(output.send(0, || Ok(message())).is_err());
            for _ in 0..CONTROL_FRAMES - 2 {
                output.send_branch_terminal(|| Ok(message())).unwrap();
            }
            output.send(0, || Ok(accepted())).unwrap();
            output.send(0, || Ok(accepted())).unwrap();
            assert!(output.send_branch_terminal(|| Ok(message())).is_err());
            while let Ok(frame) = receiver.try_recv() {
                output.complete(&frame);
            }
            output.send_branch_terminal(|| Ok(message())).unwrap();
        }
    }

    #[test]
    fn backing_proofs_have_a_finite_terminal_allowance_and_leave_both_observers() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-backing-release-v1.json"
        ))
        .unwrap();
        for row in rows {
            let proof: smolbox_protocol::BranchBackingRelease =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let message = || ServerMessage::Terminal {
                epoch: "ab".repeat(16),
                id: 1,
                sequence: 1,
                outcome: smolbox_protocol::Outcome::BranchBackingReleased {
                    proof: Box::new(proof.clone()),
                },
            };
            let (output, receiver) = Output::new();
            assert!(output.send(0, || Ok(message())).is_err());
            for _ in 0..CONTROL_FRAMES - 2 {
                output.send_branch_terminal(|| Ok(message())).unwrap();
            }
            output.send(0, || Ok(accepted())).unwrap();
            output.send(0, || Ok(accepted())).unwrap();
            assert!(output.send_branch_terminal(|| Ok(message())).is_err());
            while let Ok(frame) = receiver.try_recv() {
                output.complete(&frame);
            }
            output.send_branch_terminal(|| Ok(message())).unwrap();
        }
    }

    #[test]
    fn prepared_and_held_deletion_proofs_have_finite_terminal_allowance_and_leave_both_observers() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/held-branch-deletion-v1.json"
        ))
        .unwrap();
        let actions: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/held-branch-deletion-action-v1.json"
        ))
        .unwrap();
        let prepared: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/prepared-branch-retirement-v1.json"
        ))
        .unwrap();
        let outcomes = rows
            .into_iter()
            .map(
                |row| smolbox_protocol::Outcome::HeldBranchDeletionResolved {
                    proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                },
            )
            .chain(actions.into_iter().map(|row| {
                if row["request"]["action"] == "continue" {
                    smolbox_protocol::Outcome::HeldBranchDeletionContinued {
                        proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                    }
                } else {
                    smolbox_protocol::Outcome::HeldBranchDeletionCleaned {
                        proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
                    }
                }
            }));
        let outcomes = outcomes.chain(prepared.into_iter().map(|row| {
            smolbox_protocol::Outcome::PreparedBranchRetired {
                proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
            }
        }));
        let released: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/released-branch-deletion-v1.json"
        ))
        .unwrap();
        let outcomes = outcomes.chain(released.into_iter().map(|row| {
            smolbox_protocol::Outcome::ReleasedBranchDeletionResolved {
                proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
            }
        }));
        let continued: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/released-branch-deletion-continuation-v1.json"
        ))
        .unwrap();
        let outcomes = outcomes.chain(continued.into_iter().map(|row| {
            smolbox_protocol::Outcome::ReleasedBranchDeletionContinued {
                proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
            }
        }));
        let cleaned: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/released-branch-deletion-cleanup-v1.json"
        ))
        .unwrap();
        let outcomes = outcomes.chain(cleaned.into_iter().map(|row| {
            smolbox_protocol::Outcome::ReleasedBranchDeletionCleaned {
                proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
            }
        }));
        let collected: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-deletion-collection-v1.json"
        ))
        .unwrap();
        let outcomes = outcomes.chain(collected.into_iter().map(|row| {
            smolbox_protocol::Outcome::BranchDeletionCollected {
                proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
            }
        }));
        for outcome in outcomes {
            let message = || ServerMessage::Terminal {
                epoch: "ab".repeat(16),
                id: 1,
                sequence: 1,
                outcome: outcome.clone(),
            };
            let (output, receiver) = Output::new();
            assert!(output.send(0, || Ok(message())).is_err());
            for _ in 0..CONTROL_FRAMES - 2 {
                output.send_branch_terminal(|| Ok(message())).unwrap();
            }
            output.send(0, || Ok(accepted())).unwrap();
            output.send(0, || Ok(accepted())).unwrap();
            assert!(output.send_branch_terminal(|| Ok(message())).is_err());
            while let Ok(frame) = receiver.try_recv() {
                output.complete(&frame);
            }
            output.send_branch_terminal(|| Ok(message())).unwrap();
        }
    }

    #[test]
    fn unbooted_disposal_requires_branch_reservations_and_preserves_stalled_control_capacity() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/unbooted-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let proof: smolbox_protocol::UnbootedBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let message = || ServerMessage::Terminal {
                epoch: "ab".repeat(16),
                id: 1,
                sequence: 1,
                outcome: smolbox_protocol::Outcome::UnbootedBranchDisposed {
                    proof: Box::new(proof.clone()),
                },
            };
            let (output, receiver) = Output::new();
            assert!(output.send(0, || Ok(message())).is_err());
            for _ in 0..CONTROL_FRAMES - 2 {
                output.send_branch_terminal(|| Ok(message())).unwrap();
            }
            output.send(0, || Ok(accepted())).unwrap();
            output.send(0, || Ok(accepted())).unwrap();
            assert!(output.send_branch_terminal(|| Ok(message())).is_err());
            while let Ok(frame) = receiver.try_recv() {
                output.complete(&frame);
            }
            output.send_branch_terminal(|| Ok(message())).unwrap();
        }
    }
    #[test]
    fn explicit_release_proofs_use_only_bounded_branch_control_reservations() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-held-release-v1.json"
        ))
        .unwrap();
        for row in rows {
            for qualify in [false, true] {
                let transition: smolbox_protocol::BranchReleaseTransition =
                    serde_json::from_value(row["transition"].clone()).unwrap();
                let message = || ServerMessage::Terminal {
                    epoch: "ab".repeat(16),
                    id: 1,
                    sequence: 1,
                    outcome: if qualify {
                        smolbox_protocol::Outcome::HeldBranchReleasePresence {
                            transition: Some(Box::new(transition.clone())),
                        }
                    } else {
                        smolbox_protocol::Outcome::HeldBranchReleased {
                            transition: Box::new(transition.clone()),
                        }
                    },
                };
                let (output, receiver) = Output::new();
                assert!(output.send(0, || Ok(message())).is_err());
                for _ in 0..CONTROL_FRAMES - 2 {
                    output.send_branch_terminal(|| Ok(message())).unwrap();
                }
                output.send(0, || Ok(accepted())).unwrap();
                output.send(0, || Ok(accepted())).unwrap();
                assert!(output.send_branch_terminal(|| Ok(message())).is_err());
                while let Ok(frame) = receiver.try_recv() {
                    output.complete(&frame);
                }
                output.send_branch_terminal(|| Ok(message())).unwrap();
            }
        }
    }
    #[test]
    fn branch_proofs_preserve_bounded_control_space_under_a_stalled_writer() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-creation-v1.json"
        ))
        .unwrap();
        let branch = || ServerMessage::Terminal {
            epoch: "ab".repeat(16),
            id: 1,
            sequence: 1,
            outcome: smolbox_protocol::Outcome::BranchCreated {
                completion: Box::new(
                    serde_json::from_value(rows[1]["completion"].clone()).unwrap(),
                ),
            },
        };
        let (output, receiver) = Output::new();
        // The ordinary control route must not gain an unbounded proof payload.
        assert!(output.send(0, || Ok(branch())).is_err());
        assert!(output.send_branch_terminal(|| Ok(accepted())).is_err());
        // Fill the unchanged event byte allowance with maximum-size chunks.
        while output
            .send(65536, || {
                Ok(ServerMessage::Event {
                    epoch: "ab".repeat(16),
                    id: 1,
                    sequence: 1,
                    event: Event {
                        stream: Stream::Stdout,
                        data_base64: encode_chunk(&vec![0; 65536]).unwrap(),
                    },
                })
            })
            .is_ok()
        {}
        for _ in 0..CONTROL_FRAMES - 2 {
            output.send_branch_terminal(|| Ok(branch())).unwrap();
        }
        // Two ordinary observer replies still fit alongside the large proofs.
        output.send(0, || Ok(accepted())).unwrap();
        output.send(0, || Ok(accepted())).unwrap();
        assert!(output
            .send_branch_terminal(|| panic!("sequence advanced without capacity"))
            .is_err());
        while let Ok(frame) = receiver.try_recv() {
            output.complete(&frame);
        }
        assert_eq!(output.usage.lock().unwrap().encoded, 0);
        output.send_branch_terminal(|| Ok(branch())).unwrap();
    }
}
