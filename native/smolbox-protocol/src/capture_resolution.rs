//! Source-only capture resolution is distinct from successful artifact capture.
use crate::{CaptureIntent, CaptureRequest, InvalidMessage, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Feature-version-1 resolution admits one finite journal/control parser.
pub const CAPTURE_RESOLUTION_METADATA_BYTES: u64 = 32 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureResolutionChange {
    pub intent: CaptureIntent,
    #[serde(deserialize_with = "crate::wire::required_nullable")]
    pub checkpoint_head: Option<String>,
    pub growth_immutable_sha256: String,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureResolutionTransition {
    pub schema: u8,
    pub previous: Receipt,
    pub receipt: Receipt,
    pub change: CaptureResolutionChange,
}
impl CaptureResolutionTransition {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.previous.validate_for(2)?;
        self.receipt.validate_for(2)?;
        let intent = &self.change.intent;
        intent.request.validate()?;
        intent.previous.validate()?;
        crate::wire::id(&intent.operation_id)?;
        for digest in [
            &intent.immutable_sha256,
            &intent.growth_immutable_sha256,
            &self.change.growth_immutable_sha256,
        ] {
            crate::wire::hex(digest, 64)?;
        }
        for head in [&intent.previous_head, &self.change.checkpoint_head]
            .into_iter()
            .flatten()
        {
            crate::wire::hex(head, 32)?;
        }
        check(
            intent.source_pid.0 > 0
                && intent.source_pid.1 > 0
                && (intent.previous_head.is_none() || self.change.checkpoint_head.is_some()),
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
                    "smolbox-quiesced-capture-resolution-v1",
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
    use crate::*;

    fn proofs() -> Vec<CaptureResolutionTransition> {
        serde_json::from_str(include_str!("../fixtures/capture-resolutions-v1.json")).unwrap()
    }

    #[test]
    fn resolution_validators_require_exact_shape_head_proof_and_original_intent() {
        for proof in proofs() {
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
            let mut changed = proof.clone();
            changed.change.intent.source_pid.1 += 1;
            assert!(changed.validate().is_err());
            let value = serde_json::to_value(&proof).unwrap();
            assert!(serde_json::from_value::<CaptureTransition>(value.clone()).is_err());
            for path in [
                vec!["change", "checkpoint_head"],
                vec!["change", "intent", "previous_head"],
                vec!["previous", "material"],
            ] {
                let mut changed = value.clone();
                let (last, parents) = path.split_last().unwrap();
                let mut parent = &mut changed;
                for key in parents {
                    parent = &mut parent[*key];
                }
                parent.as_object_mut().unwrap().remove(*last);
                assert!(
                    serde_json::from_value::<CaptureResolutionTransition>(changed)
                        .map_or(true, |decoded| decoded.validate().is_err())
                );
            }
            let mut changed = value;
            changed["change"]["artifact"] = serde_json::json!({});
            assert!(serde_json::from_value::<CaptureResolutionTransition>(changed).is_err());
        }
        assert!(Outcome::CaptureResolved {
            transition: Box::new(proofs()[0].clone())
        }
        .validate_for(1)
        .is_err());
        assert!(Outcome::CaptureResolutionPresence { transition: None }
            .validate_for(2)
            .is_ok());
        assert!(serde_json::from_value::<Outcome>(
            serde_json::json!({"result":"capture_resolution_presence"})
        )
        .is_err());
    }

    #[test]
    fn resolution_sessions_require_feature_quiescence_zero_output_and_exact_reply_kind() {
        let proofs = proofs();
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
        let operation = Operation::ResolveCapture {
            receipt: proof.previous.clone(),
            operation_id: proof.change.intent.operation_id.clone(),
            request: proof.change.intent.request.clone(),
            quiesced: true,
        };
        let mut not_quiesced = operation.clone();
        if let Operation::ResolveCapture { quiesced, .. } = &mut not_quiesced {
            *quiesced = false;
        }
        assert!(not_quiesced.validate(1000).is_err());
        assert!(operation.validate(30001).is_err());
        let mut encoded = serde_json::to_value(&operation).unwrap();
        encoded.as_object_mut().unwrap().remove("quiesced");
        assert!(serde_json::from_value::<Operation>(encoded).is_err());
        for enabled in [false, true] {
            if enabled {
                hello
                    .sdk
                    .as_mut()
                    .unwrap()
                    .feature_versions
                    .insert("checkpoints".into(), 1);
            }
            for resolve in [false, true] {
                let mut session = Session::new(hello.clone()).unwrap();
                session.approve(&hello).unwrap();
                let selected = if resolve {
                    operation.clone()
                } else {
                    Operation::InspectCaptureResolution {
                        receipt: proof.previous.clone(),
                        operation_id: proof.change.intent.operation_id.clone(),
                        request: proof.change.intent.request.clone(),
                    }
                };
                let response = session
                    .admit(ClientMessage::Request {
                        epoch: hello.epoch.clone(),
                        id: 1,
                        budget_ms: 1000,
                        initial_credit: 0,
                        initial_event_credit: 0,
                        operation: selected,
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
                let reply = |proof: CaptureResolutionTransition| {
                    if resolve {
                        Outcome::CaptureResolved {
                            transition: Box::new(proof),
                        }
                    } else {
                        Outcome::CaptureResolutionPresence {
                            transition: Some(Box::new(proof)),
                        }
                    }
                };
                assert!(session.terminal(1, reply(proofs[1].clone())).is_err());
                assert!(session.terminal(1, reply(proof.clone())).is_ok());
            }
        }
    }
}
