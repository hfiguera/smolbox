//! Correlated capture history, never native mutation authority.
use crate::{InvalidMessage, MaterialProof, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureRequest {
    pub max_bytes: u64,
    pub idle: bool,
}
impl CaptureRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        check(self.idle && (1..=64 * 1024 * 1024 * 1024).contains(&self.max_bytes))
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureArtifact {
    pub sha256: String,
    pub size_bytes: u64,
    pub head: String,
    #[serde(deserialize_with = "crate::wire::required_nullable")]
    pub parent: Option<String>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureIntent {
    pub operation_id: String,
    pub request: CaptureRequest,
    pub previous: MaterialProof,
    pub immutable_sha256: String,
    #[serde(deserialize_with = "crate::wire::required_nullable")]
    pub previous_head: Option<String>,
    pub source_pid: (i32, u64),
    pub growth_immutable_sha256: String,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureChange {
    pub intent: CaptureIntent,
    pub artifact: CaptureArtifact,
    pub growth_immutable_sha256: String,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureTransition {
    pub schema: u8,
    pub previous: Receipt,
    pub receipt: Receipt,
    pub change: CaptureChange,
}
impl CaptureTransition {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.previous.validate_for(2)?;
        self.receipt.validate_for(2)?;
        let intent = &self.change.intent;
        let artifact = &self.change.artifact;
        intent.request.validate()?;
        intent.previous.validate()?;
        crate::wire::id(&intent.operation_id)?;
        for digest in [
            &intent.immutable_sha256,
            &intent.growth_immutable_sha256,
            &self.change.growth_immutable_sha256,
            &artifact.sha256,
        ] {
            crate::wire::hex(digest, 64)?;
        }
        crate::wire::hex(&artifact.head, 32)?;
        if let Some(parent) = &intent.previous_head {
            crate::wire::hex(parent, 32)?;
        }
        check(
            artifact.parent == intent.previous_head
                && artifact.parent.as_ref() != Some(&artifact.head)
                && artifact.size_bytes > 0
                && artifact.size_bytes <= intent.request.max_bytes
                && intent.source_pid.0 > 0
                && intent.source_pid.1 > 0,
        )?;
        let before = self.previous.material.as_ref().ok_or(InvalidMessage)?;
        let after = self.receipt.material.as_ref().ok_or(InvalidMessage)?;
        let mut origin = self.previous.clone();
        origin.material = None;
        let mut supplied = self.receipt.clone();
        supplied.material = None;
        check(self.schema == 1 && origin == supplied && **before == intent.previous)?;
        if before.revision == 0 {
            check(before.chain_sha256 == hash(&("smolbox-material-origin-v2", &origin))?)?;
        }
        check(
            before.revision < 1024
                && after.revision == before.revision + 1
                && after.operation_id.as_deref() == Some(&intent.operation_id)
                && after.request_sha256.as_deref() == Some(&hash(&intent.request)?),
        )?;
        check(
            after.chain_sha256
                == hash(&(
                    "smolbox-checkpoint-capture-transition-v1",
                    &self.change,
                    &after.record_sha256,
                ))?,
        )
    }
    pub fn matches(
        &self,
        previous: &Receipt,
        id: &str,
        request: &CaptureRequest,
    ) -> Result<(), InvalidMessage> {
        self.validate()?;
        check(
            self.previous == *previous
                && self.change.intent.operation_id == id
                && self.change.intent.request == *request,
        )
    }
}
fn hash(value: &impl Serialize) -> Result<String, InvalidMessage> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}
fn check(value: bool) -> Result<(), InvalidMessage> {
    if value {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checkpoint_stream_has_distinct_credit_bounds_exact_completion_and_extended_sequences() {
        use crate::*;
        let proofs: Vec<CaptureTransition> =
            serde_json::from_str(include_str!("../fixtures/capture-transitions-v1.json")).unwrap();
        let proof = &proofs[0];
        let ServerMessage::Hello { hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        let mut hello = *hello;
        hello.domain.target_id = proof.previous.target_id.clone();
        hello.domain.generation = proof.previous.domain_generation.clone();
        let operation = Operation::CaptureCheckpoint {
            receipt: proof.previous.clone(),
            operation_id: "capture-1".into(),
            request: proof.change.intent.request.clone(),
            chunk_bytes: Some(256),
        };
        assert!(operation.requires_checkpoints());
        for enabled in [false, true] {
            if enabled {
                hello
                    .sdk
                    .as_mut()
                    .unwrap()
                    .feature_versions
                    .insert("checkpoints".into(), 1);
            }
            let mut session = Session::new(hello.clone()).unwrap();
            session.approve(&hello).unwrap();
            let reply = session
                .admit(ClientMessage::Request {
                    epoch: hello.epoch.clone(),
                    id: 1,
                    budget_ms: 600_000,
                    initial_credit: 512,
                    initial_event_credit: 1,
                    operation: operation.clone(),
                })
                .unwrap();
            if !enabled {
                assert!(matches!(
                    reply,
                    ServerMessage::Terminal {
                        outcome: Outcome::Error {
                            code: SafeCode::Unsupported,
                            ..
                        },
                        ..
                    }
                ));
                continue;
            }
            assert!(matches!(reply, ServerMessage::Accepted { .. }));
            assert!(session.event(1, Stream::File, &[99; 512]).is_err());
            assert!(session.event(1, Stream::Checkpoint, &[99; 257]).is_err());
            session.event(1, Stream::Checkpoint, &[99; 256]).unwrap();
            session.credit(&hello.epoch, 1, 256, 1).unwrap();
            session.event(1, Stream::Checkpoint, &[99; 256]).unwrap();
            assert!(session.event(1, Stream::Checkpoint, &[99]).is_err());
            assert!(session
                .terminal(
                    1,
                    Outcome::Captured {
                        transition: Box::new(proofs[1].clone())
                    }
                )
                .is_err());
            session
                .terminal(
                    1,
                    Outcome::Captured {
                        transition: Box::new(proof.clone()),
                    },
                )
                .unwrap();
        }
        let event = |stream, sequence| ServerMessage::Event {
            epoch: hello.epoch.clone(),
            id: 1,
            sequence,
            event: Event {
                stream,
                data_base64: encode_chunk(&[99]).unwrap(),
            },
        };
        assert!(event(Stream::Checkpoint, MAX_EVENTS_PER_REQUEST + 1)
            .validate()
            .is_ok());
        assert!(event(Stream::File, MAX_EVENTS_PER_REQUEST + 1)
            .validate()
            .is_err());
        assert!(event(Stream::Checkpoint, MAX_CAPTURE_EVENTS + 1)
            .validate()
            .is_err());
    }

    #[test]
    fn capture_lookup_is_feature_gated_and_only_accepts_exact_correlated_history() {
        use crate::*;
        let proofs: Vec<CaptureTransition> =
            serde_json::from_str(include_str!("../fixtures/capture-transitions-v1.json")).unwrap();
        let proof = proofs[0].clone();
        let ServerMessage::Hello { hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        let mut hello = *hello;
        hello.domain.target_id = proof.previous.target_id.clone();
        hello.domain.generation = proof.previous.domain_generation.clone();
        for enabled in [false, true] {
            if enabled {
                hello
                    .sdk
                    .as_mut()
                    .unwrap()
                    .feature_versions
                    .insert("checkpoints".into(), 1);
            }
            let mut session = Session::new(hello.clone()).unwrap();
            session.approve(&hello).unwrap();
            let operation = Operation::InspectCapture {
                receipt: proof.previous.clone(),
                operation_id: "capture-1".into(),
                request: proof.change.intent.request.clone(),
            };
            assert!(operation.requires_checkpoints());
            assert!(operation.validate(30001).is_err());
            let reply = session
                .admit(ClientMessage::Request {
                    epoch: hello.epoch.clone(),
                    id: 1,
                    budget_ms: 1000,
                    initial_credit: 0,
                    initial_event_credit: 0,
                    operation,
                })
                .unwrap();
            if !enabled {
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
                continue;
            }
            assert!(matches!(reply, ServerMessage::Accepted { .. }));
            assert!(session
                .terminal(
                    1,
                    Outcome::CapturePresence {
                        transition: Some(Box::new(proofs[1].clone()))
                    }
                )
                .is_err());
            assert!(session
                .terminal(
                    1,
                    Outcome::CapturePresence {
                        transition: Some(Box::new(proof.clone()))
                    }
                )
                .is_ok());
        }
        assert!(Outcome::CapturePresence { transition: None }
            .validate_for(1)
            .is_err());
        assert!(serde_json::from_value::<Outcome>(
            serde_json::json!({"result":"capture_presence"})
        )
        .is_err());
    }

    #[test]
    fn shared_capture_proofs_validate_exact_hashes_parent_bounds_and_correlation() {
        let transitions: Vec<CaptureTransition> =
            serde_json::from_str(include_str!("../fixtures/capture-transitions-v1.json")).unwrap();
        for proof in &transitions {
            proof.validate().unwrap();
            proof
                .matches(
                    &proof.previous,
                    &proof.change.intent.operation_id,
                    &proof.change.intent.request,
                )
                .unwrap();
            assert!(proof
                .matches(&proof.previous, "foreign", &proof.change.intent.request)
                .is_err());
            let mut altered = proof.clone();
            altered.change.intent.source_pid.1 += 1;
            assert!(altered.validate().is_err());
            let mut altered = proof.clone();
            altered.change.artifact.parent = Some(altered.change.artifact.head.clone());
            assert!(altered.validate().is_err());
            let mut altered = proof.clone();
            altered.change.artifact.size_bytes = altered.change.intent.request.max_bytes + 1;
            assert!(altered.validate().is_err());
            let mut altered = proof.clone();
            altered.change.growth_immutable_sha256 = "f".repeat(64);
            assert!(altered.validate().is_err());
            let mut value = serde_json::to_value(proof).unwrap();
            value["change"]["artifact"]
                .as_object_mut()
                .unwrap()
                .remove("parent");
            assert!(serde_json::from_value::<CaptureTransition>(value).is_err());
        }
        assert!(transitions[1]
            .matches(
                &transitions[0].previous,
                "capture-2",
                &transitions[1].change.intent.request
            )
            .is_err());
    }
}
