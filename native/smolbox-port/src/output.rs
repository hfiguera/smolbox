//! One stdout writer, bounded by decoded bytes, encoded bytes and frame count.
//! Event capacity is checked before advancing protocol sequence/credit state.
use crossbeam_channel::{bounded, Receiver, Sender};
use smolbox_protocol::{write_frame, ServerMessage};
use std::io::Write;
use std::sync::{Arc, Mutex};

const MAX_DECODED: usize = 8 * 1024 * 1024;
const MAX_ENCODED: usize = 12 * 1024 * 1024;
const MAX_EVENT_FRAMES: usize = 4096;
const CONTROL_FRAMES: usize = 65;
const CONTROL_BYTES: usize = CONTROL_FRAMES * 4096;
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
        let control = decoded == 0;
        let mut usage = self.usage.lock().map_err(|_| ())?;
        let reserve = if control { 4096 } else { EVENT_ENCODED_RESERVE };
        let encoded_max = if control {
            MAX_ENCODED
        } else {
            MAX_ENCODED - CONTROL_BYTES
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
}
