//! Explicit original-child collection before branch readiness/handoff. This
//! proof grants no SDK deletion, source cleanup or reservation release.
use crate::{BranchCreateRequest, InvalidMessage};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
fn hash(value: &impl Serialize) -> Result<String, InvalidMessage> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}

/// Ephemeral eligibility only; never collection or serialized ownership.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchCollectionCandidate {
    pub schema: u8,
    pub creation_sha256: String,
    pub operation_id: String,
    pub request_sha256: String,
    pub epoch: String,
    pub platform: String,
}
impl std::fmt::Debug for PartialBranchCollectionCandidate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchCollectionCandidate")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchCollectionCandidate {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        if self.schema != 1
            || crate::wire::hex(&self.creation_sha256, 64).is_err()
            || crate::wire::id(&self.operation_id).is_err()
            || crate::wire::hex(&self.request_sha256, 64).is_err()
            || crate::wire::hex(&self.epoch, 32).is_err()
            || !matches!(self.platform.as_str(), "linux" | "macos")
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() > 4096
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
    pub fn matches(&self, request: &PartialBranchCollectionRequest) -> Result<(), InvalidMessage> {
        self.validate()?;
        request.validate()?;
        if self.creation_sha256 != hash(&request.creation)?
            || self.operation_id != request.operation_id
            || self.request_sha256 != request.request_sha256
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchCollectionRequest {
    pub creation: BranchCreateRequest,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for PartialBranchCollectionRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchCollectionRequest")
            .finish_non_exhaustive()
    }
}
impl PartialBranchCollectionRequest {
    pub fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-partial-branch-collection-request-v1",
            &self.creation,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.creation.validate()?;
        if serde_json::to_vec(&self.creation)
            .map_err(|_| InvalidMessage)?
            .len()
            > 16 * 1024
        {
            return Err(InvalidMessage);
        }
        if !self.quiesced
            || crate::wire::id(&self.operation_id).is_err()
            || self.operation_id == self.creation.child.operation_id
            || self
                .creation
                .initial_release
                .as_ref()
                .is_some_and(|r| r.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() > 20 * 1024
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
    pub fn matches(&self, proof: &PartialBranchCollection) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        if proof.creation_sha256 != hash(&self.creation)?
            || proof.operation_id != self.operation_id
            || proof.request_sha256 != self.request_sha256
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchCollection {
    pub schema: u8,
    pub creation_sha256: String,
    pub publication_sha256: String,
    pub operation_id: String,
    pub request_sha256: String,
    pub boot_sha256: String,
    pub collection_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchCollection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchCollection")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchCollection {
    fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-partial-branch-collection-proof-v1",
            self.schema,
            &self.creation_sha256,
            &self.publication_sha256,
            &self.operation_id,
            &self.request_sha256,
            &self.boot_sha256,
            &self.collection_sha256,
        ))
    }
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        if self.schema != 1
            || crate::wire::id(&self.operation_id).is_err()
            || [
                &self.creation_sha256,
                &self.publication_sha256,
                &self.request_sha256,
                &self.boot_sha256,
                &self.collection_sha256,
            ]
            .into_iter()
            .any(|s| crate::wire::hex(s, 64).is_err())
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() > 4096
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!(
            "../fixtures/partial-branch-collection-v1.json"
        ))
        .unwrap()
    }
    fn hello(row: &serde_json::Value, request: &PartialBranchCollectionRequest) -> Hello {
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
        hello.package.platform = row["platform"].as_str().unwrap().into();
        hello.package.architecture = if hello.package.platform == "macos" {
            "aarch64"
        } else {
            "x86_64"
        }
        .into();
        hello.domain.target_id = request.creation.source.target_id.clone();
        hello.domain.generation = request.creation.source.domain_generation.clone();
        *hello
    }
    fn admit(
        session: &mut Session,
        hello: &Hello,
        request: &PartialBranchCollectionRequest,
    ) -> ServerMessage {
        session.approve(hello).unwrap();
        session
            .admit(ClientMessage::Request {
                epoch: hello.epoch.clone(),
                id: 1,
                budget_ms: 30000,
                initial_credit: 1024,
                initial_event_credit: 1,
                operation: Operation::CollectPartialBranch {
                    request: Box::new(request.clone()),
                },
            })
            .unwrap()
    }
    #[test]
    fn candidate_requires_negotiated_feature_and_exact_request_epoch_platform_without_output() {
        let candidates: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../fixtures/partial-branch-collection-candidate-v1.json"
        ))
        .unwrap();
        for row in candidates {
            let request: PartialBranchCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let candidate: PartialBranchCollectionCandidate =
                serde_json::from_value(row["candidate"].clone()).unwrap();
            candidate.matches(&request).unwrap();
            let operation = Operation::InspectPartialBranchCollection {
                request: Box::new(request.clone()),
            };
            operation.validate(30000).unwrap();
            assert!(operation.validate(30001).is_err());
            assert!(operation.requires_branches() && operation.capability() == Capability::Inspect);
            assert!(operation.receipt() == Some(&request.creation.source));
            assert!(operation.branch_approval() == Some(&request.creation.approval));
            for variant in 0..5 {
                let mut hello = hello(&row, &request);
                if variant != 0 {
                    hello
                        .sdk
                        .as_mut()
                        .unwrap()
                        .feature_versions
                        .insert("partial_collection_preflight".into(), 1);
                }
                let mut session = Session::new(hello.clone()).unwrap();
                session.approve(&hello).unwrap();
                let admitted = session
                    .admit(ClientMessage::Request {
                        epoch: hello.epoch.clone(),
                        id: 1,
                        budget_ms: 30000,
                        initial_credit: 1024,
                        initial_event_credit: 1,
                        operation: operation.clone(),
                    })
                    .unwrap();
                if variant == 0 {
                    assert!(matches!(
                        admitted,
                        ServerMessage::Terminal {
                            outcome: Outcome::Error {
                                code: crate::SafeCode::Unsupported,
                                ..
                            },
                            ..
                        }
                    ));
                    continue;
                }
                assert!(matches!(admitted, ServerMessage::Accepted { .. }));
                assert!(session.event(1, Stream::Stdout, b"unexpected").is_err());
                let mut value = candidate.clone();
                if variant == 2 {
                    value.epoch = "f".repeat(32);
                }
                if variant == 3 {
                    value.platform = if value.platform == "linux" {
                        "macos"
                    } else {
                        "linux"
                    }
                    .into();
                }
                if variant == 4 {
                    value.request_sha256 = "0".repeat(64);
                }
                let outcome = Outcome::PartialBranchCollectionCandidate {
                    candidate: Box::new(value),
                };
                outcome.validate_for(2).unwrap();
                assert!(outcome.validate_for(1).is_err());
                assert_eq!(session.terminal(1, outcome).is_ok(), variant == 1);
            }
        }
    }

    #[test]
    fn canonical_partial_collection_has_distinct_full_request_and_required_zero_output_result() {
        for row in rows() {
            let request: PartialBranchCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchCollection =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            let operation = Operation::CollectPartialBranch {
                request: Box::new(request.clone()),
            };
            operation.validate(30000).unwrap();
            assert!(operation.validate(30001).is_err());
            assert!(operation.requires_branches() && operation.capability() == Capability::Delete);
            assert!(operation.receipt() == Some(&request.creation.source));
            assert!(operation.branch_approval() == Some(&request.creation.approval));
            let outcome = Outcome::PartialBranchCollected {
                proof: Box::new(proof.clone()),
                platform: row["platform"].as_str().unwrap().into(),
            };
            outcome.validate_for(2).unwrap();
            assert!(outcome.validate_for(1).is_err());
            let hello = hello(&row, &request);
            let mut session = Session::new(hello.clone()).unwrap();
            assert!(matches!(
                admit(&mut session, &hello, &request),
                ServerMessage::Accepted { .. }
            ));
            session.terminal(1, outcome).unwrap();
            let mut crossed = request.clone();
            crossed.operation_id = "different-collection".into();
            crossed.request_sha256 = crossed.digest().unwrap();
            crossed.validate().unwrap();
            assert!(crossed.matches(&proof).is_err());
            let mut bad = request.clone();
            bad.quiesced = false;
            bad.request_sha256 = bad.digest().unwrap();
            assert!(bad.validate().is_err());
            let mut bad = request;
            bad.operation_id = bad.creation.child.operation_id.clone();
            bad.request_sha256 = bad.digest().unwrap();
            assert!(bad.validate().is_err());
        }
    }
    #[test]
    fn foreign_platform_feature_domain_and_output_cannot_supply_partial_collection() {
        for row in rows() {
            let request: PartialBranchCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchCollection =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let hello = hello(&row, &request);
            for platform in [
                "foreign",
                if hello.package.platform == "linux" {
                    "macos"
                } else {
                    "linux"
                },
            ] {
                let mut session = Session::new(hello.clone()).unwrap();
                admit(&mut session, &hello, &request);
                assert!(session
                    .terminal(
                        1,
                        Outcome::PartialBranchCollected {
                            proof: Box::new(proof.clone()),
                            platform: platform.into()
                        }
                    )
                    .is_err());
            }
            let mut crossed = hello.clone();
            crossed.domain.generation = "0".repeat(32);
            let mut session = Session::new(crossed.clone()).unwrap();
            assert!(!matches!(
                admit(&mut session, &crossed, &request),
                ServerMessage::Accepted { .. }
            ));
            let mut disabled = hello.clone();
            disabled
                .sdk
                .as_mut()
                .unwrap()
                .feature_versions
                .remove("branches");
            let mut session = Session::new(disabled.clone()).unwrap();
            assert!(!matches!(
                admit(&mut session, &disabled, &request),
                ServerMessage::Accepted { .. }
            ));
            let mut session = Session::new(hello.clone()).unwrap();
            admit(&mut session, &hello, &request);
            assert!(session.event(1, Stream::Stdout, b"x").is_err());
            assert!(session.terminal(1, Outcome::Qualified).is_err());
            assert!(session
                .terminal(
                    1,
                    Outcome::PartialBranchCollected {
                        proof: Box::new(proof),
                        platform: hello.package.platform
                    }
                )
                .is_ok());
        }
    }
}
