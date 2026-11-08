//! Exact authority for retained native staging cleanup; never artifact success.
use crate::{CaptureRequest, InvalidMessage, Receipt};
use serde::{Deserialize, Serialize};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureStagingCleanupReceipt {
    pub schema: u8,
    pub previous: Receipt,
    pub operation_id: String,
    pub request: CaptureRequest,
    pub stage_sha256: String,
}
impl CaptureStagingCleanupReceipt {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.previous.validate_for(2)?;
        self.request.validate()?;
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.stage_sha256, 64)?;
        check(self.schema == 1 && self.previous.material.is_some())
    }
    pub fn matches(
        &self,
        previous: &Receipt,
        id: &str,
        request: &CaptureRequest,
    ) -> Result<(), InvalidMessage> {
        self.validate()?;
        check(self.previous == *previous && self.operation_id == id && self.request == *request)
    }
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

    fn proof() -> CaptureStagingCleanupReceipt {
        let proofs: Vec<CaptureResolutionTransition> =
            serde_json::from_str(include_str!("../fixtures/capture-resolutions-v1.json")).unwrap();
        CaptureStagingCleanupReceipt {
            schema: 1,
            previous: proofs[0].previous.clone(),
            operation_id: proofs[0].change.intent.operation_id.clone(),
            request: proofs[0].change.intent.request.clone(),
            stage_sha256: "d".repeat(64),
        }
    }

    #[test]
    fn cleanup_authority_is_exact_and_never_a_material_transition() {
        let proof = proof();
        proof
            .matches(&proof.previous, &proof.operation_id, &proof.request)
            .unwrap();
        assert!(proof
            .matches(&proof.previous, "foreign", &proof.request)
            .is_err());
        let value = serde_json::to_value(&proof).unwrap();
        assert!(serde_json::from_value::<CaptureTransition>(value.clone()).is_err());
        assert!(serde_json::from_value::<CaptureResolutionTransition>(value.clone()).is_err());
        for field in [
            "schema",
            "previous",
            "operation_id",
            "request",
            "stage_sha256",
        ] {
            let mut changed = value.clone();
            changed.as_object_mut().unwrap().remove(field);
            assert!(serde_json::from_value::<CaptureStagingCleanupReceipt>(changed).is_err());
        }
        let mut changed = value;
        changed["artifact"] = serde_json::json!({});
        assert!(serde_json::from_value::<CaptureStagingCleanupReceipt>(changed).is_err());
        let mut changed = proof.clone();
        changed.previous.material = None;
        assert!(changed.validate().is_err());
        changed = proof;
        changed.stage_sha256 = "A".repeat(64);
        assert!(changed.validate().is_err());
    }

    #[test]
    fn cleanup_session_requires_capability_quiescence_and_exact_zero_output_reply() {
        let proof = proof();
        for abort in [false, true] {
            let operation = Operation::CleanupCaptureStaging {
                receipt: proof.previous.clone(),
                operation_id: proof.operation_id.clone(),
                request: proof.request.clone(),
                quiesced: true,
            };
            let operation = if abort {
                Operation::AbortCaptureStaging {
                    receipt: proof.previous.clone(),
                    operation_id: proof.operation_id.clone(),
                    request: proof.request.clone(),
                    quiesced: true,
                }
            } else {
                operation
            };
            let reply = |proof| {
                if abort {
                    Outcome::CaptureStagingAborted {
                        cleanup: Box::new(proof),
                    }
                } else {
                    Outcome::CaptureStagingCleaned {
                        cleanup: Box::new(proof),
                    }
                }
            };
            assert!(operation.validate(30000).is_ok());
            assert!(operation.validate(30001).is_err());
            let mut invalid = operation.clone();
            if let Operation::CleanupCaptureStaging { quiesced, .. }
            | Operation::AbortCaptureStaging { quiesced, .. } = &mut invalid
            {
                *quiesced = false;
            }
            assert!(invalid.validate(1000).is_err());
            let mut missing = serde_json::to_value(&operation).unwrap();
            missing.as_object_mut().unwrap().remove("quiesced");
            assert!(serde_json::from_value::<Operation>(missing).is_err());
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
                    .terminal(1, Outcome::CapturePresence { transition: None })
                    .is_err());
                let crossed = if abort {
                    Outcome::CaptureStagingCleaned {
                        cleanup: Box::new(proof.clone()),
                    }
                } else {
                    Outcome::CaptureStagingAborted {
                        cleanup: Box::new(proof.clone()),
                    }
                };
                assert!(session.terminal(1, crossed).is_err());
                let mut wrong = proof.clone();
                wrong.operation_id = "foreign".into();
                assert!(session.terminal(1, reply(wrong)).is_err());
                assert!(session.terminal(1, reply(proof.clone())).is_ok());
            }
            assert!(reply(proof.clone()).validate_for(1).is_err());
        }
    }
}
