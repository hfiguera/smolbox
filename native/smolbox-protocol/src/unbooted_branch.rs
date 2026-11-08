//! Correlation for original unbooted disposal; hashes grant no SDK ownership.
use crate::{
    BranchBackingRelease, BranchCreateRequest, BranchPublication, InvalidMessage, Receipt,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
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
pub struct UnbootedBranchDisposalCandidate {
    pub schema: u8,
    pub creation: BranchCreateRequest,
    pub publication: BranchPublication,
    pub preparation_sha256: String,
    pub proof_sha256: String,
}
impl UnbootedBranchDisposalCandidate {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.creation.validate()?;
        self.publication.validate()?;
        crate::wire::hex(&self.preparation_sha256, 64)?;
        let intent = &self.publication.change.child_origin.intent;
        check(
            self.schema == 1
                && intent.source == self.creation.source
                && intent.child == self.creation.child
                && intent.approval == self.creation.approval
                && serde_json::to_vec(&self.creation)
                    .map_err(|_| InvalidMessage)?
                    .len()
                    <= 16 * 1024
                && self.proof_sha256
                    == hash(&(
                        "smolbox-original-unbooted-disposal-candidate-v1",
                        self.schema,
                        &self.creation,
                        &self.publication,
                        &self.preparation_sha256,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() <= 32 * 1024,
        )
    }
    pub fn matches(&self, creation: &BranchCreateRequest) -> Result<(), InvalidMessage> {
        creation.validate()?;
        self.validate()?;
        check(self.creation == *creation)
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchDisposalIntent {
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl UnbootedBranchDisposalIntent {
    pub fn validate(&self, creation: &BranchCreateRequest) -> Result<(), InvalidMessage> {
        creation.validate()?;
        crate::wire::id(&self.operation_id)?;
        check(
            self.quiesced
                && self.operation_id != creation.child.operation_id
                && creation
                    .initial_release
                    .as_ref()
                    .is_none_or(|r| r.operation_id != self.operation_id)
                && self.request_sha256
                    == hash(&(
                        "smolbox-unbooted-branch-disposal-request-v1",
                        creation,
                        &self.operation_id,
                        self.quiesced,
                    ))?
                && serde_json::to_vec(creation)
                    .map_err(|_| InvalidMessage)?
                    .len()
                    <= 16 * 1024,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchDisposalRequest {
    pub creation: BranchCreateRequest,
    pub request: UnbootedBranchDisposalIntent,
}
impl UnbootedBranchDisposalRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.request.validate(&self.creation)?;
        check(serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() <= 20 * 1024)
    }
    pub fn matches(&self, proof: &UnbootedBranchDisposal) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        check(proof.creation == self.creation && proof.request == self.request)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UnbootedBranchDisposalCompletion {
    Deleted,
    ResolvedAbsent,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchDisposal {
    pub schema: u8,
    pub completion: UnbootedBranchDisposalCompletion,
    pub creation: BranchCreateRequest,
    pub request: UnbootedBranchDisposalIntent,
    pub publication: BranchPublication,
    pub disposal_sha256: String,
    pub proof_sha256: String,
}
impl UnbootedBranchDisposal {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.request.validate(&self.creation)?;
        self.publication.validate()?;
        crate::wire::hex(&self.disposal_sha256, 64)?;
        let intent = &self.publication.change.child_origin.intent;
        check(
            self.schema == 1
                && intent.source == self.creation.source
                && intent.child == self.creation.child
                && intent.approval == self.creation.approval
                && self.proof_sha256
                    == hash(&(
                        "smolbox-unbooted-branch-disposal-proof-v1",
                        self.schema,
                        self.completion,
                        &self.creation,
                        &self.request,
                        &self.publication,
                        &self.disposal_sha256,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() <= 32 * 1024,
        )
    }
}
fn origin(receipt: &Receipt) -> Receipt {
    let mut value = receipt.clone();
    value.material = None;
    value
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchBackingReleaseRequest {
    pub disposal: UnbootedBranchDisposal,
    pub source: Receipt,
    pub child: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
    pub backing_removed: bool,
}
impl UnbootedBranchBackingReleaseRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.disposal.validate()?;
        self.source.validate_for(2)?;
        let before = self
            .disposal
            .publication
            .receipt
            .material
            .as_ref()
            .ok_or(InvalidMessage)?;
        let head = self.source.material.as_ref().ok_or(InvalidMessage)?;
        crate::wire::id(&self.operation_id)?;
        let creation = &self.disposal.creation;
        check(
            origin(&self.source) == origin(&self.disposal.publication.receipt)
                && self.child == self.disposal.publication.change.child
                && head.revision >= before.revision
                && (head.revision != before.revision || head == before)
                && (head.revision != 0
                    || head.chain_sha256
                        == hash(&("smolbox-material-origin-v2", origin(&self.source)))?)
                && self.quiesced
                && self.backing_removed
                && self.operation_id != creation.child.operation_id
                && self.operation_id != self.disposal.request.operation_id
                && creation
                    .initial_release
                    .as_ref()
                    .is_none_or(|r| r.operation_id != self.operation_id)
                && self.request_sha256
                    == hash(&(
                        "smolbox-unbooted-branch-backing-request-v1",
                        &self.disposal,
                        &self.source,
                        &self.child,
                        &self.operation_id,
                        self.quiesced,
                        self.backing_removed,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= crate::BRANCH_BACKING_REQUEST_BYTES,
        )
    }
    pub fn matches(&self, proof: &BranchBackingRelease) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        check(
            proof.publication == self.disposal.publication
                && proof.operation_id == self.operation_id
                && proof.request_sha256 == self.request_sha256,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!("../fixtures/unbooted-branch-disposal-v1.json")).unwrap()
    }
    fn hello(proof: &UnbootedBranchDisposal) -> Hello {
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
        hello.domain.target_id = proof.creation.source.target_id.clone();
        hello.domain.generation = proof.creation.source.domain_generation.clone();
        hello.package.platform = proof.publication.change.platform.clone();
        hello.package.architecture = if hello.package.platform == "macos" {
            "aarch64"
        } else {
            "x86_64"
        }
        .into();
        *hello
    }
    fn admit(session: &mut Session, h: &Hello, operation: Operation) -> ServerMessage {
        session
            .admit(ClientMessage::Request {
                epoch: h.epoch.clone(),
                id: 1,
                budget_ms: 30000,
                initial_credit: 1024,
                initial_event_credit: 1,
                operation,
            })
            .unwrap()
    }
    fn operations(row: &serde_json::Value) -> [Operation; 3] {
        let request: UnbootedBranchDisposalRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        [
            Operation::DisposeUnbootedBranch {
                request: Box::new(request.clone()),
            },
            Operation::ResolveUnbootedBranchDisposal {
                request: Box::new(request),
            },
            Operation::ReleaseUnbootedBranchBacking {
                request: Box::new(serde_json::from_value(row["backing_request"].clone()).unwrap()),
            },
        ]
    }
    #[test]
    fn shared_readers_keep_exact_native_provenance_creation_and_backing_request() {
        for row in rows() {
            let request: UnbootedBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: UnbootedBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            let backing: UnbootedBranchBackingReleaseRequest =
                serde_json::from_value(row["backing_request"].clone()).unwrap();
            let result: BranchBackingRelease =
                serde_json::from_value(row["backing_proof"].clone()).unwrap();
            backing.matches(&result).unwrap();
            for op in operations(&row) {
                op.validate(30000).unwrap();
                assert!(op.validate(30001).is_err());
                assert!(op.requires_branches());
                assert!(op.branch_approval() == Some(&request.creation.approval));
            }
            let result = Outcome::UnbootedBranchDisposed {
                proof: Box::new(proof),
            };
            result.validate_for(2).unwrap();
            assert!(result.validate_for(1).is_err());
        }
    }
    #[test]
    fn session_requires_approval_capability_domain_platform_zero_output_and_exact_result() {
        for row in rows() {
            let proof: UnbootedBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            for (index, operation) in operations(&row).into_iter().enumerate() {
                let h = hello(&proof);
                for rejection in 0..3 {
                    let mut wrong = h.clone();
                    match rejection {
                        0 => {
                            wrong
                                .sdk
                                .as_mut()
                                .unwrap()
                                .feature_versions
                                .remove("branches");
                        }
                        1 => wrong.domain.generation = "0".repeat(32),
                        _ => wrong
                            .capabilities
                            .retain(|value| *value != operation.capability()),
                    }
                    let mut session = Session::new(wrong.clone()).unwrap();
                    session.approve(&wrong).unwrap();
                    assert!(matches!(
                        admit(&mut session, &wrong, operation.clone()),
                        ServerMessage::Terminal {
                            outcome: Outcome::Error {
                                dispatch: Dispatch::NotDispatched,
                                ..
                            },
                            ..
                        }
                    ));
                }
                let mut foreign = h.clone();
                foreign.package.platform = if h.package.platform == "macos" {
                    "linux"
                } else {
                    "macos"
                }
                .into();
                foreign.package.architecture = if foreign.package.platform == "macos" {
                    "aarch64"
                } else {
                    "x86_64"
                }
                .into();
                let mut other = Session::new(foreign.clone()).unwrap();
                other.approve(&foreign).unwrap();
                if index == 2 {
                    assert!(matches!(
                        admit(&mut other, &foreign, operation.clone()),
                        ServerMessage::Terminal {
                            outcome: Outcome::Error {
                                dispatch: Dispatch::NotDispatched,
                                ..
                            },
                            ..
                        }
                    ));
                } else {
                    assert!(matches!(
                        admit(&mut other, &foreign, operation.clone()),
                        ServerMessage::Accepted { .. }
                    ));
                    assert!(other
                        .terminal(
                            1,
                            Outcome::UnbootedBranchDisposed {
                                proof: Box::new(proof.clone())
                            }
                        )
                        .is_err());
                }
                let mut session = Session::new(h.clone()).unwrap();
                session.approve(&h).unwrap();
                assert!(matches!(
                    admit(&mut session, &h, operation),
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
                let result = if index == 2 {
                    Outcome::BranchBackingReleased {
                        proof: Box::new(
                            serde_json::from_value(row["backing_proof"].clone()).unwrap(),
                        ),
                    }
                } else {
                    Outcome::UnbootedBranchDisposed {
                        proof: Box::new(proof.clone()),
                    }
                };
                session.terminal(1, result).unwrap();
            }
        }
    }
    #[test]
    fn changed_intent_creation_provenance_and_unknown_fields_cannot_cross_reader_boundaries() {
        for row in rows() {
            let original: UnbootedBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: UnbootedBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            for case in 0..4 {
                let mut changed = original.clone();
                match case {
                    0 => changed.request.quiesced = false,
                    1 => changed.request.operation_id = changed.creation.child.operation_id.clone(),
                    2 => changed.creation.source.material = None,
                    _ => changed.request.request_sha256 = "0".repeat(64),
                }
                assert!(changed.validate().is_err());
                assert!(changed.matches(&proof).is_err());
            }
            let mut crossed = proof.clone();
            crossed.completion = if proof.completion == UnbootedBranchDisposalCompletion::Deleted {
                UnbootedBranchDisposalCompletion::ResolvedAbsent
            } else {
                UnbootedBranchDisposalCompletion::Deleted
            };
            assert!(crossed.validate().is_err());
            for key in ["pid", "path", "completion", "native_bytes"] {
                let mut wrong = row["request"].clone();
                wrong[key] = serde_json::json!(1);
                assert!(serde_json::from_value::<UnbootedBranchDisposalRequest>(wrong).is_err());
            }
            let mut wrong = row["proof"].clone();
            wrong.as_object_mut().unwrap().remove("completion");
            assert!(serde_json::from_value::<UnbootedBranchDisposal>(wrong).is_err());
        }
    }
}

#[cfg(test)]
mod candidate_tests;
