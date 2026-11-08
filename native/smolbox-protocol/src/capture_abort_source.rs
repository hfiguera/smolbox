//! Unchanged pre-entry source authority, distinct from material advancement.
use crate::{CaptureIntent, CaptureRequest, CaptureStagingCleanupReceipt, InvalidMessage, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureAbortSourceState {
    Running,
    Stopped,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureAbortSourceQualification {
    pub schema: u8,
    pub cleanup: CaptureStagingCleanupReceipt,
    pub intent: CaptureIntent,
    pub state: CaptureAbortSourceState,
    pub record_sha256: String,
    pub proof_sha256: String,
}
impl CaptureAbortSourceQualification {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.cleanup.validate()?;
        let intent = &self.intent;
        intent.request.validate()?;
        intent.previous.validate()?;
        crate::wire::id(&intent.operation_id)?;
        for digest in [
            &intent.immutable_sha256,
            &intent.growth_immutable_sha256,
            &self.proof_sha256,
        ] {
            crate::wire::hex(digest, 64)?;
        }
        if let Some(head) = &intent.previous_head {
            crate::wire::hex(head, 32)?;
        }
        let before = self
            .cleanup
            .previous
            .material
            .as_ref()
            .ok_or(InvalidMessage)?;
        let mut origin = self.cleanup.previous.clone();
        origin.material = None;
        check(
            self.schema == 1
                && intent.source_pid.0 > 0
                && intent.source_pid.1 > 0
                && **before == intent.previous
                && self.cleanup.operation_id == intent.operation_id
                && self.cleanup.request == intent.request
                && self.record_sha256 == before.record_sha256,
        )?;
        if before.revision == 0 {
            check(before.chain_sha256 == hash(&("smolbox-material-origin-v2", &origin))?)?;
        }
        check(self.proof_sha256 == self.digest()?)
    }
    fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-preentry-aborted-source-v1",
            &self.cleanup,
            &self.intent,
            self.state,
            &self.record_sha256,
        ))
    }
    pub fn matches(
        &self,
        previous: &Receipt,
        id: &str,
        request: &CaptureRequest,
    ) -> Result<(), InvalidMessage> {
        self.validate()?;
        self.cleanup.matches(previous, id, request)
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
    use crate::*;
    fn proofs() -> Vec<CaptureAbortSourceQualification> {
        serde_json::from_str(include_str!("../fixtures/capture-abort-sources-v1.json")).unwrap()
    }
    #[test]
    fn shared_aborted_source_proofs_bind_unchanged_material_and_original_intent() {
        for proof in proofs() {
            proof
                .matches(
                    &proof.cleanup.previous,
                    &proof.cleanup.operation_id,
                    &proof.cleanup.request,
                )
                .unwrap();
            let value = serde_json::to_value(&proof).unwrap();
            assert!(serde_json::from_value::<CaptureTransition>(value.clone()).is_err());
            assert!(serde_json::from_value::<CaptureResolutionTransition>(value.clone()).is_err());
            assert!(serde_json::from_value::<CaptureStagingCleanupReceipt>(value.clone()).is_err());
            for path in [
                vec!["intent", "previous_head"],
                vec!["intent", "source_pid"],
                vec!["state"],
                vec!["proof_sha256"],
            ] {
                let mut missing = value.clone();
                let (last, parents) = path.split_last().unwrap();
                let mut parent = &mut missing;
                for key in parents {
                    parent = &mut parent[*key];
                }
                parent.as_object_mut().unwrap().remove(*last);
                assert!(
                    serde_json::from_value::<CaptureAbortSourceQualification>(missing).is_err()
                );
            }
            let mut changed = proof.clone();
            changed.intent.source_pid.1 += 1;
            assert!(changed.validate().is_err());
            changed = proof.clone();
            changed.record_sha256 = "f".repeat(64);
            changed.proof_sha256 = changed.digest().unwrap();
            assert!(changed.validate().is_err());
            changed = proof.clone();
            changed.cleanup.operation_id = "foreign".into();
            changed.proof_sha256 = changed.digest().unwrap();
            assert!(changed.validate().is_err());
            assert!(proof
                .matches(&proof.cleanup.previous, "foreign", &proof.cleanup.request)
                .is_err());
        }
    }
    #[test]
    fn aborted_source_control_requires_feature_quiescence_and_exact_nonstreaming_reply() {
        let proof = proofs().remove(0);
        let ServerMessage::Hello { hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        let mut hello = *hello;
        hello.domain.target_id = proof.cleanup.previous.target_id.clone();
        hello.domain.generation = proof.cleanup.previous.domain_generation.clone();
        let operation = Operation::QualifyAbortedCaptureSource {
            receipt: proof.cleanup.previous.clone(),
            operation_id: proof.cleanup.operation_id.clone(),
            request: proof.cleanup.request.clone(),
            quiesced: true,
        };
        assert!(operation.validate(30000).is_ok());
        assert!(operation.validate(30001).is_err());
        let mut invalid = operation.clone();
        if let Operation::QualifyAbortedCaptureSource { quiesced, .. } = &mut invalid {
            *quiesced = false;
        }
        assert!(invalid.validate(1000).is_err());
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
            let response = session
                .admit(ClientMessage::Request {
                    epoch: hello.epoch.clone(),
                    id: 1,
                    budget_ms: 1000,
                    initial_credit: 0,
                    initial_event_credit: 0,
                    operation: operation.clone(),
                })
                .unwrap();
            if !enabled {
                assert!(matches!(
                    response,
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
            assert!(matches!(response, ServerMessage::Accepted { .. }));
            assert!(session.event(1, Stream::Checkpoint, b"artifact").is_err());
            assert!(session
                .terminal(
                    1,
                    Outcome::CaptureStagingAborted {
                        cleanup: Box::new(proof.cleanup.clone())
                    }
                )
                .is_err());
            let crossed = proofs().remove(1);
            let mut crossed = crossed;
            crossed.cleanup.operation_id = "foreign".into();
            crossed.intent.operation_id = "foreign".into();
            crossed.proof_sha256 = crossed.digest().unwrap();
            assert!(session
                .terminal(
                    1,
                    Outcome::AbortedCaptureSourceQualified {
                        qualification: Box::new(crossed)
                    }
                )
                .is_err());
            let outcome = Outcome::AbortedCaptureSourceQualified {
                qualification: Box::new(proof.clone()),
            };
            assert!(outcome.validate_for(1).is_err());
            assert!(session.terminal(1, outcome).is_ok());
        }
    }
}
