//! Bounded prepared-only retirement. These hashes correlate messages; only the
//! engine's protected unentered declaration can produce native retirement.
use crate::{BranchCreateRequest, BranchIntent, InvalidMessage};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
pub const PREPARED_BRANCH_RETIREMENT_BYTES: usize = 16 * 1024;
fn check(value: bool) -> Result<(), InvalidMessage> {
    if value {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}
fn hash(value: &impl Serialize) -> Result<String, InvalidMessage> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedBranchRetirementRequest {
    pub creation: BranchCreateRequest,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl PreparedBranchRetirementRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.creation.validate()?;
        check(
            self.quiesced
                && self.request_sha256 == self.digest()?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= PREPARED_BRANCH_RETIREMENT_BYTES,
        )
    }
    fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-prepared-branch-retirement-request-v1",
            &self.creation,
            self.quiesced,
        ))
    }
    pub fn matches(&self, proof: &PreparedBranchRetirement) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        let intent = &proof.retirement.intent;
        check(
            proof.request_sha256 == self.request_sha256
                && intent.source == self.creation.source
                && intent.child == self.creation.child
                && intent.approval == self.creation.approval,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InitialBranchRetirement {
    pub schema: u8,
    pub intent: BranchIntent,
    pub proof_sha256: String,
}
impl InitialBranchRetirement {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.intent.validate()?;
        check(
            self.schema == 1
                && self.proof_sha256
                    == hash(&("smolbox-initial-branch-retirement-v1", &self.intent))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= PREPARED_BRANCH_RETIREMENT_BYTES,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedBranchRetirement {
    pub schema: u8,
    pub request_sha256: String,
    pub retirement: InitialBranchRetirement,
    pub proof_sha256: String,
}
impl PreparedBranchRetirement {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.retirement.validate()?;
        crate::wire::hex(&self.request_sha256, 64)?;
        check(
            self.schema == 1
                && self.proof_sha256
                    == hash(&(
                        "smolbox-prepared-branch-retirement-proof-v1",
                        self.schema,
                        &self.request_sha256,
                        &self.retirement,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= PREPARED_BRANCH_RETIREMENT_BYTES,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!(
            "../fixtures/prepared-branch-retirement-v1.json"
        ))
        .unwrap()
    }
    fn hello(request: &PreparedBranchRetirementRequest) -> Hello {
        let ServerMessage::Hello { mut hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            panic!("hello")
        };
        hello
            .sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("branches".into(), 1);
        hello.domain.target_id = request.creation.source.target_id.clone();
        hello.domain.generation = request.creation.source.domain_generation.clone();
        *hello
    }
    fn admit(
        session: &mut Session,
        h: &Hello,
        request: &PreparedBranchRetirementRequest,
    ) -> ServerMessage {
        session
            .admit(ClientMessage::Request {
                epoch: h.epoch.clone(),
                id: 1,
                budget_ms: 30000,
                initial_credit: 1024,
                initial_event_credit: 1,
                operation: Operation::RetirePreparedBranch {
                    request: Box::new(request.clone()),
                },
            })
            .unwrap()
    }
    fn proof_digest(proof: &PreparedBranchRetirement) -> String {
        hash(&(
            "smolbox-prepared-branch-retirement-proof-v1",
            proof.schema,
            &proof.request_sha256,
            &proof.retirement,
        ))
        .unwrap()
    }
    #[test]
    fn synthetic_retirement_readers_require_both_native_declaration_and_host_correlation() {
        for row in rows() {
            let request: PreparedBranchRetirementRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PreparedBranchRetirement =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            let op = Operation::RetirePreparedBranch {
                request: Box::new(request.clone()),
            };
            op.validate(30000).unwrap();
            assert!(op.validate(30001).is_err());
            assert!(op.requires_branches() && op.capability() == Capability::Inspect);
            assert!(op.branch_approval() == Some(&request.creation.approval));
            assert!(op.receipt() == Some(&request.creation.source));
            let result = Outcome::PreparedBranchRetired {
                proof: Box::new(proof.clone()),
            };
            result.validate_for(2).unwrap();
            assert!(result.validate_for(1).is_err());
            for mode in 0..3 {
                let mut changed = request.clone();
                match mode {
                    0 => changed.creation.approval.id = "different-policy".into(),
                    1 => changed.creation.child.name = "different-child".into(),
                    _ => changed.creation.source.domain_generation = "0".repeat(32),
                }
                changed.request_sha256 = changed.digest().unwrap();
                changed.validate().unwrap();
                let mut rebound = proof.clone();
                rebound.request_sha256 = changed.request_sha256.clone();
                rebound.proof_sha256 = proof_digest(&rebound);
                rebound.validate().unwrap();
                assert!(changed.matches(&rebound).is_err());
            }
            let mut changed = proof;
            changed.retirement.proof_sha256 = "0".repeat(64);
            changed.proof_sha256 = proof_digest(&changed);
            assert!(changed.validate().is_err());
        }
    }
    #[test]
    fn session_requires_feature_inspect_domain_and_a_required_zero_output_matching_result() {
        for row in rows() {
            let request: PreparedBranchRetirementRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PreparedBranchRetirement =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let good = hello(&request);
            for mode in 0..3 {
                let mut h = good.clone();
                match mode {
                    0 => {
                        h.sdk.as_mut().unwrap().feature_versions.remove("branches");
                    }
                    1 => h.domain.generation = "0".repeat(32),
                    _ => h.capabilities.retain(|value| *value != Capability::Inspect),
                }
                let mut session = Session::new(h.clone()).unwrap();
                session.approve(&h).unwrap();
                assert!(matches!(
                    admit(&mut session, &h, &request),
                    ServerMessage::Terminal {
                        outcome: Outcome::Error {
                            dispatch: Dispatch::NotDispatched,
                            ..
                        },
                        ..
                    }
                ));
            }
            let mut session = Session::new(good.clone()).unwrap();
            session.approve(&good).unwrap();
            assert!(matches!(
                admit(&mut session, &good, &request),
                ServerMessage::Accepted { .. }
            ));
            for stream in [
                Stream::Stdout,
                Stream::Stderr,
                Stream::File,
                Stream::Checkpoint,
                Stream::Terminal,
                Stream::Log,
            ] {
                assert!(session.event(1, stream, b"extra").is_err());
            }
            assert!(session.terminal(1, Outcome::Qualified).is_err());
            let mut wrong = proof.clone();
            wrong.request_sha256 = "0".repeat(64);
            wrong.proof_sha256 = proof_digest(&wrong);
            assert!(session
                .terminal(
                    1,
                    Outcome::PreparedBranchRetired {
                        proof: Box::new(wrong)
                    }
                )
                .is_err());
            session
                .terminal(
                    1,
                    Outcome::PreparedBranchRetired {
                        proof: Box::new(proof),
                    },
                )
                .unwrap();
        }
    }
    #[test]
    fn fencing_creation_mode_unknown_fields_and_nullable_evidence_cannot_substitute() {
        for row in rows() {
            let request: PreparedBranchRetirementRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for mode in 0..4 {
                let mut changed = request.clone();
                match mode {
                    0 => changed.quiesced = false,
                    1 => {
                        changed.creation.child.owner_token =
                            changed.creation.source.owner_token.clone()
                    }
                    2 => changed.creation.source.material = None,
                    _ => {
                        changed.creation.initial_release = if changed.creation.child.hold {
                            Some(BranchReleaseRequest {
                                operation_id: "unused-release".into(),
                                request_sha256: "d".repeat(64),
                            })
                        } else {
                            None
                        }
                    }
                }
                changed.request_sha256 = changed.digest().unwrap();
                assert!(changed.validate().is_err());
            }
            for field in ["pid", "path", "native_digest", "backing_removed"] {
                let mut changed = row["request"].clone();
                changed[field] = serde_json::json!(true);
                assert!(
                    serde_json::from_value::<PreparedBranchRetirementRequest>(changed).is_err()
                );
            }
        }
        for result in [
            serde_json::json!({"result":"prepared_branch_retired"}),
            serde_json::json!({"result":"prepared_branch_retired","proof":null}),
        ] {
            assert!(serde_json::from_value::<Outcome>(result).is_err());
        }
    }
}
