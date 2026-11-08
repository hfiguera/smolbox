//! Bounded, four-byte big-endian framing for the embedded Port protocol.
//!
//! This crate owns wire validation, not machine lifecycle or command semantics.

use serde_json::Value;
use std::io::{self, Read, Write};

mod exports;
pub use exports::{
    ExportLimits, ExportPublication, ExportPublicationIdentity, ExportRequest, ExportStageCleanup,
};
mod capture;
mod capture_abort_source;
pub use capture_abort_source::{CaptureAbortSourceQualification, CaptureAbortSourceState};
mod capture_staging;
pub use capture_staging::CaptureStagingCleanupReceipt;
mod capture_resolution;
pub use capture_resolution::{
    CaptureResolutionChange, CaptureResolutionTransition, CAPTURE_RESOLUTION_METADATA_BYTES,
};
mod command_payload;
pub use capture::{
    CaptureArtifact, CaptureChange, CaptureIntent, CaptureRequest, CaptureTransition,
};
mod creation_payload;
pub use command_payload::COMMAND_PAYLOAD_BYTES;
mod growth;
mod volume;
pub use volume::*;
mod json;
pub use growth::{DiskSizes, GrowDisks, GrowthChange, GrowthTransition};
mod terminal;
mod wire;
pub use creation_payload::{MAX_CREATION_CHUNKS, MAX_CREATION_PAYLOAD};
pub use terminal::{TerminalAction, TerminalLimits, TerminalSpec};
pub use wire::*;
mod session;
pub use session::Session;

/// Maximum encoded JSON frame, excluding its four-byte header.
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;
/// Maximum JSON nesting accepted before domain decoding.
pub const MAX_JSON_DEPTH: usize = 16;
/// Maximum elements in a wire collection.
pub const MAX_COLLECTION_ENTRIES: usize = 256;
/// Maximum scalar string, allowing a base64-encoded 64 KiB output chunk.
pub const MAX_STRING_BYTES: usize = 128 * 1024;

/// Read one frame; only EOF before any header bytes is a clean channel close.
///
/// The length is checked before allocating the frame body. Partial headers and
/// bodies are errors, never empty messages or successful operation completion.
pub fn read_frame(reader: &mut impl Read) -> io::Result<Option<Value>> {
    let mut header = [0_u8; 4];
    loop {
        match reader.read(&mut header[..1]) {
            Ok(0) => return Ok(None),
            Ok(_) => break,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    reader.read_exact(&mut header[1..])?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_FRAME_BYTES {
        return Err(invalid_frame());
    }
    let mut body = vec![0_u8; length];
    reader.read_exact(&mut body)?;
    let value = serde_json::from_slice::<json::StrictValue>(&body)
        .map_err(|_| invalid_frame())?
        .0;
    validate_json(&value, 0)?;
    Ok(Some(value))
}

/// Serialize and write a complete frame, checking limits before emitting bytes.
/// A caller must serialize concurrent writes through one channel owner.
pub fn write_frame(writer: &mut impl Write, value: &Value) -> io::Result<()> {
    validate_json(value, 0)?;
    let mut body = CappedBuffer(Vec::new());
    serde_json::to_writer(&mut body, value).map_err(|_| invalid_frame())?;
    let body = body.0;
    writer.write_all(&(body.len() as u32).to_be_bytes())?;
    writer.write_all(&body)?;
    writer.flush()
}

fn validate_json(value: &Value, depth: usize) -> io::Result<()> {
    if depth > MAX_JSON_DEPTH {
        return Err(invalid_frame());
    }
    match value {
        Value::Array(values) => {
            if values.len() > MAX_COLLECTION_ENTRIES {
                return Err(invalid_frame());
            }
            for value in values {
                validate_json(value, depth + 1)?;
            }
        }
        Value::Object(values) => {
            if values.len() > MAX_COLLECTION_ENTRIES {
                return Err(invalid_frame());
            }
            for (key, value) in values {
                if key.len() > 128 {
                    return Err(invalid_frame());
                }
                validate_json(value, depth + 1)?;
            }
        }
        Value::String(value) if value.len() > MAX_STRING_BYTES => return Err(invalid_frame()),
        _ => {}
    }
    Ok(())
}

fn invalid_frame() -> io::Error {
    // Do not include a decoder error or source bytes in logs crossing the bridge.
    io::Error::new(io::ErrorKind::InvalidData, "invalid Port protocol frame")
}

struct CappedBuffer(Vec<u8>);

impl Write for CappedBuffer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_FRAME_BYTES - self.0.len() {
            return Err(invalid_frame());
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Cursor;

    #[test]
    fn checkpointable_creation_marker_omits_legacy_default_rejects_false_and_requires_feature() {
        let mut operation = Operation::QualifyCreation {
            artifact: Artifact {
                path: "/approved.smolmachine".into(),
                sha256: "a".repeat(64),
                max_bytes: 1024,
                guest_platform: "linux/arm64".into(),
            },
            resources: Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 1,
                overlay_gib: 1,
            },
            user: None,
            features: None,
            checkpointable: None,
        };
        let legacy = serde_json::to_value(&operation).unwrap();
        assert!(legacy.get("checkpointable").is_none());
        assert!(operation.validate(1000).is_ok());
        if let Operation::QualifyCreation { checkpointable, .. } = &mut operation {
            *checkpointable = Some(false);
        }
        assert!(operation.validate(1000).is_err());
        if let Operation::QualifyCreation { checkpointable, .. } = &mut operation {
            *checkpointable = Some(true);
        }
        assert!(operation.requires_checkpoints());
        assert!(operation.validate(1000).is_ok());
        let mut nullable = legacy;
        nullable["checkpointable"] = serde_json::Value::Null;
        assert!(serde_json::from_value::<Operation>(nullable).is_err());
        let ServerMessage::Hello { hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        let mut session = Session::new(*hello.clone()).ok().unwrap();
        session.approve(&hello).ok().unwrap();
        assert!(matches!(
            session.admit(ClientMessage::Request {
                epoch: hello.epoch.clone(),
                id: 1,
                budget_ms: 1000,
                initial_credit: 0,
                initial_event_credit: 0,
                operation
            }),
            Ok(ServerMessage::Terminal {
                outcome: Outcome::Error {
                    code: SafeCode::Unsupported,
                    dispatch: Dispatch::NotDispatched
                },
                ..
            })
        ));
    }

    #[test]
    fn checkpoint_start_and_preflight_require_new_feature_and_preflight_running_evidence() {
        let ServerMessage::Hello { hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        let mut hello = *hello;
        let ServerMessage::Terminal {
            outcome: Outcome::Created { receipt },
            ..
        } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/created-v2.json")).unwrap(),
        )
        .unwrap()
        else {
            unreachable!()
        };
        let operations = [
            Operation::StartCheckpointable {
                receipt: receipt.clone(),
            },
            Operation::CheckpointPreflight { receipt },
        ];
        for enabled in [false, true] {
            if enabled {
                hello
                    .sdk
                    .as_mut()
                    .unwrap()
                    .feature_versions
                    .insert("checkpoints".into(), 1);
            }
            let mut session = Session::new(hello.clone()).ok().unwrap();
            session.approve(&hello).ok().unwrap();
            for (i, operation) in operations.iter().enumerate() {
                let request = ClientMessage::Request {
                    epoch: hello.epoch.clone(),
                    id: i as u64 + 1,
                    budget_ms: 1000,
                    initial_credit: 0,
                    initial_event_credit: 0,
                    operation: operation.clone(),
                };
                let reply = session.admit(request).ok().unwrap();
                if enabled {
                    assert!(matches!(reply, ServerMessage::Accepted { .. }));
                } else {
                    assert!(matches!(
                        reply,
                        ServerMessage::Terminal {
                            outcome: Outcome::Error {
                                code: SafeCode::Unsupported,
                                dispatch: Dispatch::NotDispatched
                            },
                            ..
                        }
                    ));
                }
            }
            if enabled {
                let observed = |state, pid_identity| Outcome::Observed {
                    observation: Observation {
                        state,
                        resources: Some(Resources {
                            cpus: 1,
                            memory_mib: 256,
                            storage_gib: 1,
                            overlay_gib: 1,
                        }),
                        pid_identity,
                        configuration: None,
                    },
                };
                assert!(session
                    .terminal(2, observed(ObservedState::Stopped, None))
                    .is_err());
                assert!(session
                    .terminal(2, observed(ObservedState::Running, Some((123, 456))))
                    .is_ok());
                assert!(session
                    .terminal(1, observed(ObservedState::Running, Some((123, 456))))
                    .is_ok());
            }
        }
        assert!(operations[1].validate(30001).is_err());
        assert!(operations[0].validate(86400000).is_ok());
    }

    #[test]
    fn checkpoint_requests_are_path_free_feature_gated_and_receipt_correlated() {
        let ServerMessage::Hello { hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        let mut hello = *hello;
        let create = CheckpointCreate {
            checkpointable: None,
            name: "owned".into(),
            owner_token: "67".repeat(32),
            incarnation: "89".repeat(16),
            source: CheckpointIdentity {
                kind: "checkpoint".into(),
                id: "idle-v1".into(),
                sha256: "a".repeat(64),
                architecture: "aarch64".into(),
            },
            resources: Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: Default::default(),
        };
        let operations = [
            Operation::QualifyCheckpointCreation {
                checkpointable: None,
                source: create.source.clone(),
                resources: create.resources.clone(),
            },
            Operation::CreateCheckpoint {
                create: create.clone(),
            },
            Operation::InspectCheckpointCreation {
                create: create.clone(),
            },
        ];
        for operation in &operations {
            assert!(operation.validate(1000).is_ok());
            let mut value = serde_json::to_value(operation).unwrap();
            if let Some(create) = value.get_mut("create") {
                create["source"]["path"] = json!("/caller/input");
            } else {
                value["source"]["path"] = json!("/caller/input");
            }
            assert!(serde_json::from_value::<Operation>(value).is_err());
        }
        let request = |id, operation| ClientMessage::Request {
            epoch: hello.epoch.clone(),
            id,
            budget_ms: 1000,
            initial_credit: 0,
            initial_event_credit: 0,
            operation,
        };
        let mut session = Session::new(hello.clone()).ok().unwrap();
        session.approve(&hello).ok().unwrap();
        for (i, operation) in operations.iter().enumerate() {
            assert!(matches!(
                session.admit(request(i as u64 + 1, operation.clone())),
                Ok(ServerMessage::Terminal {
                    outcome: Outcome::Error {
                        code: SafeCode::Unsupported,
                        dispatch: Dispatch::NotDispatched
                    },
                    ..
                })
            ));
        }
        hello
            .sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("checkpoints".into(), 1);
        let mut session = Session::new(hello.clone()).ok().unwrap();
        session.approve(&hello).ok().unwrap();
        // Requests retain the same epoch after changing only feature policy.
        for (i, operation) in operations.iter().enumerate() {
            let request = ClientMessage::Request {
                epoch: hello.epoch.clone(),
                id: i as u64 + 1,
                budget_ms: 1000,
                initial_credit: 0,
                initial_event_credit: 0,
                operation: operation.clone(),
            };
            assert!(matches!(
                session.admit(request),
                Ok(ServerMessage::Accepted { .. })
            ));
        }
        assert!(session.terminal(1, Outcome::Qualified).is_ok());
        assert!(session
            .terminal(
                3,
                Outcome::CreationPresence {
                    presence: CreationPresence::Unverified
                }
            )
            .is_ok());
        let ServerMessage::Terminal {
            outcome: Outcome::Created { receipt },
            ..
        } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/created-v2.json")).unwrap(),
        )
        .unwrap()
        else {
            unreachable!()
        };
        let mut crossed = receipt.clone();
        crossed.incarnation = "a".repeat(32);
        assert!(session
            .terminal(2, Outcome::Created { receipt: crossed })
            .is_err());
        assert!(session.terminal(2, Outcome::Created { receipt }).is_ok());
        assert!(operations[2].validate(30001).is_err());
    }

    #[test]
    fn unavailable_notice_has_only_a_valid_epoch_and_cannot_carry_result_authority() {
        assert!(
            ServerMessage::decode(json!({"type":"unavailable","epoch":"ab".repeat(16)})).is_ok()
        );
        for invalid in [
            json!({"type":"unavailable","epoch":"short"}),
            json!({"type":"unavailable","epoch":"ab".repeat(16),"id":1}),
            json!({"type":"unavailable","epoch":"ab".repeat(16),"receipt":{}}),
        ] {
            assert!(ServerMessage::decode(invalid).is_err());
        }
    }

    struct OneByteReader(Cursor<Vec<u8>>);

    impl Read for OneByteReader {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let size = buffer.len().min(1);
            self.0.read(&mut buffer[..size])
        }
    }

    #[test]
    fn fragmented_and_concatenated_frames_preserve_message_boundaries() {
        let messages = [
            json!({"type": "request", "id": 1}),
            json!({"type": "cancel", "id": 1}),
        ];
        let mut bytes = Vec::new();
        for message in &messages {
            write_frame(&mut bytes, message).unwrap();
        }
        let mut reader = OneByteReader(Cursor::new(bytes));
        for message in messages {
            assert_eq!(read_frame(&mut reader).unwrap(), Some(message));
        }
        assert!(read_frame(&mut reader).unwrap().is_none());
    }

    #[test]
    fn duplicate_keys_at_any_depth_are_invalid_and_redacted() {
        for body in [
            r#"{"id":1,"id":2}"#,
            r#"{"receipt":{"owner":"secret","owner":"other"}}"#,
        ] {
            let mut bytes = (body.len() as u32).to_be_bytes().to_vec();
            bytes.extend_from_slice(body.as_bytes());
            let error = read_frame(&mut Cursor::new(bytes)).unwrap_err();
            assert_eq!(error.to_string(), "invalid Port protocol frame");
        }
    }

    #[test]
    fn invalid_lengths_are_rejected_without_reading_or_allocating_the_body() {
        for length in [0_u32, (MAX_FRAME_BYTES + 1) as u32, u32::MAX] {
            let mut reader = Cursor::new(length.to_be_bytes());
            assert_eq!(
                read_frame(&mut reader).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
            assert_eq!(reader.position(), 4);
        }
    }

    #[test]
    fn partial_headers_and_bodies_are_not_clean_eof() {
        for bytes in [vec![0], vec![0, 0, 0], vec![0, 0, 0, 2, b'{']] {
            assert_eq!(
                read_frame(&mut Cursor::new(bytes)).unwrap_err().kind(),
                io::ErrorKind::UnexpectedEof
            );
        }
    }

    #[test]
    fn invalid_json_and_wire_collections_are_redacted_and_bounded() {
        for body in [b"secret-password".as_slice(), b"\xff", b"{} trailing"] {
            let mut bytes = (body.len() as u32).to_be_bytes().to_vec();
            bytes.extend(body);
            let error = read_frame(&mut Cursor::new(bytes)).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidData);
            assert_eq!(error.to_string(), "invalid Port protocol frame");
        }
        let mut deep = Value::Null;
        for _ in 0..=MAX_JSON_DEPTH {
            deep = json!([deep]);
        }
        for invalid in [
            deep,
            json!(vec![0; MAX_COLLECTION_ENTRIES + 1]),
            json!("x".repeat(MAX_STRING_BYTES + 1)),
        ] {
            let mut output = Vec::new();
            assert!(write_frame(&mut output, &invalid).is_err());
            assert!(output.is_empty());
        }
    }

    #[test]
    fn oversized_outbound_frames_emit_no_partial_header() {
        let value = json!(vec!["x".repeat(MAX_STRING_BYTES); 9]);
        let mut output = Vec::new();
        assert!(write_frame(&mut output, &value).is_err());
        assert!(output.is_empty());
    }
}
