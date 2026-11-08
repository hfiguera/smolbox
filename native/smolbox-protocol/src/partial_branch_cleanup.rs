//! Explicit original partial-disposal residual cleanup, never SDK delete retry,
//! initialization completion or dependency/backing retirement.
use crate::{InvalidMessage, PartialBranchDisposal, PartialBranchDisposalRequest};
type Result<T> = std::result::Result<T, InvalidMessage>;
use sha2::{Digest, Sha256};
fn hash(value: &impl Serialize) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}
use serde::{Deserialize, Serialize};
pub const PARTIAL_BRANCH_CLEANUP_REQUEST_BYTES: usize = 28 * 1024;
pub const PARTIAL_BRANCH_CLEANUP_PROOF_BYTES: usize = 80 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposalCleanupRequest {
    pub disposal_request: PartialBranchDisposalRequest,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for PartialBranchDisposalCleanupRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposalCleanupRequest")
            .finish_non_exhaustive()
    }
}
impl PartialBranchDisposalCleanupRequest {
    pub fn validate(&self) -> Result<()> {
        self.disposal_request.validate()?;
        let creation = &self.disposal_request.collection_request.creation;
        if !self.quiesced
            || crate::wire::id(&self.operation_id).is_err()
            || self.operation_id == self.disposal_request.operation_id
            || self.operation_id == self.disposal_request.collection_request.operation_id
            || self.operation_id == creation.child.operation_id
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|r| r.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                > PARTIAL_BRANCH_CLEANUP_REQUEST_BYTES
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        hash(&(
            "smolbox-partial-branch-disposal-cleanup-request-v1",
            &self.disposal_request,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn matches(&self, proof: &PartialBranchDisposalCleanup) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if proof.request != *self {
            return Err(InvalidMessage);
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposalCleanup {
    pub schema: u8,
    pub request: PartialBranchDisposalCleanupRequest,
    pub disposal: PartialBranchDisposal,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchDisposalCleanup {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposalCleanup")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchDisposalCleanup {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        self.disposal.validate()?;
        if self.schema != 1
            || self.disposal.request != self.request.disposal_request
            || self.disposal.completion != crate::PartialBranchDisposalCompletion::ResolvedAbsent
            || self
                .disposal
                .release
                .as_ref()
                .is_some_and(|r| r.change.request.operation_id == self.request.operation_id)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                > PARTIAL_BRANCH_CLEANUP_PROOF_BYTES
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        hash(&(
            "smolbox-partial-branch-disposal-cleanup-v1",
            self.schema,
            &self.request,
            &self.disposal,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!(
            "../fixtures/partial-branch-disposal-cleanup-v1.json"
        ))
        .unwrap()
    }
    fn hello(row: &serde_json::Value, request: &PartialBranchDisposalCleanupRequest) -> Hello {
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
        hello.epoch = row["proof"]["disposal"]["publication"]["change"]["child_origin"]["intent"]
            ["epoch"]
            .as_str()
            .unwrap()
            .into();
        hello.package.platform = row["platform"].as_str().unwrap().into();
        hello.package.architecture = if hello.package.platform == "macos" {
            "aarch64"
        } else {
            "x86_64"
        }
        .into();
        hello.domain.target_id = request
            .disposal_request
            .collection_request
            .creation
            .source
            .target_id
            .clone();
        hello.domain.generation = request
            .disposal_request
            .collection_request
            .creation
            .source
            .domain_generation
            .clone();
        *hello
    }
    fn operation(request: &PartialBranchDisposalCleanupRequest) -> Operation {
        Operation::CleanupPartialBranchDisposal {
            request: Box::new(request.clone()),
        }
    }
    fn admitted(h: &Hello, request: &PartialBranchDisposalCleanupRequest) -> Session {
        let mut session = Session::new(h.clone()).unwrap();
        session.approve(h).unwrap();
        assert!(matches!(
            session
                .admit(ClientMessage::Request {
                    epoch: h.epoch.clone(),
                    id: 1,
                    budget_ms: 30_000,
                    initial_credit: 1024,
                    initial_event_credit: 1,
                    operation: operation(request),
                })
                .unwrap(),
            ServerMessage::Accepted { .. }
        ));
        session
    }
    #[test]
    fn synthetic_codec_preserves_resolved_absence_platforms_and_release_origins() {
        assert_eq!(PARTIAL_BRANCH_CLEANUP_REQUEST_BYTES, 28 * 1024);
        assert_eq!(PARTIAL_BRANCH_CLEANUP_PROOF_BYTES, 80 * 1024);
        for row in rows() {
            let request: PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposalCleanup =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            assert_eq!(serde_json::to_value(&request).unwrap(), row["request"]);
            assert_eq!(serde_json::to_value(&proof).unwrap(), row["proof"]);
            let op = operation(&request);
            op.validate(30_000).unwrap();
            assert!(op.validate(30_001).is_err());
            assert!(op.requires_branches());
            assert!(op.partial_disposal_request().is_none());
            assert!(op.capability() == Capability::Delete);
            assert!(
                op.receipt() == Some(&request.disposal_request.collection_request.creation.source)
            );
            assert!(
                op.branch_approval()
                    == Some(
                        &request
                            .disposal_request
                            .collection_request
                            .creation
                            .approval
                    )
            );
            let outcome = Outcome::PartialBranchDisposalCleaned {
                proof: Box::new(proof.clone()),
            };
            outcome.validate_for(2).unwrap();
            assert!(outcome.validate_for(1).is_err());
            let h = hello(&row, &request);
            let mut session = admitted(&h, &request);
            assert!(session.event(1, Stream::Stdout, b"unexpected").is_err());
            assert!(session.terminal(1, Outcome::Qualified).is_err());
            assert!(session
                .terminal(
                    1,
                    Outcome::PartialBranchDisposed {
                        proof: Box::new(proof.disposal)
                    }
                )
                .is_err());
            session.terminal(1, outcome).unwrap();
        }
    }
    #[test]
    fn full_request_platform_and_original_epoch_are_required_for_acknowledgement() {
        for row in rows() {
            let request: PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposalCleanup =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let h = hello(&row, &request);
            for field in ["platform", "epoch", "request"] {
                let mut context = h.clone();
                let mut submitted = request.clone();
                if field == "platform" {
                    context.package.platform = if h.package.platform == "macos" {
                        "linux"
                    } else {
                        "macos"
                    }
                    .into();
                    context.package.architecture = if context.package.platform == "macos" {
                        "aarch64"
                    } else {
                        "x86_64"
                    }
                    .into();
                }
                if field == "epoch" {
                    context.epoch = "0".repeat(32);
                }
                if field == "request" {
                    submitted.operation_id = "different-cleanup".into();
                    submitted.request_sha256 = submitted.digest().unwrap();
                }
                assert!(admitted(&context, &submitted)
                    .terminal(
                        1,
                        Outcome::PartialBranchDisposalCleaned {
                            proof: Box::new(proof.clone())
                        }
                    )
                    .is_err());
            }
        }
    }
    #[test]
    fn cleanup_requires_distinct_action_quiescence_strict_schema_and_matching_original_disposal() {
        for row in rows() {
            let request: PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposalCleanup =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let creation = &request.disposal_request.collection_request.creation;
            let mut actions = vec![
                request.disposal_request.operation_id.clone(),
                request
                    .disposal_request
                    .collection_request
                    .operation_id
                    .clone(),
                creation.child.operation_id.clone(),
            ];
            if let Some(initial) = &creation.initial_release {
                actions.push(initial.operation_id.clone());
            }
            for action in actions {
                let mut changed = request.clone();
                changed.operation_id = action;
                changed.request_sha256 = changed.digest().unwrap();
                assert!(changed.validate().is_err());
            }
            let mut changed = request.clone();
            changed.quiesced = false;
            changed.request_sha256 = changed.digest().unwrap();
            assert!(changed.validate().is_err());
            let mut changed = proof.clone();
            changed.request.operation_id = "other-cleanup".into();
            changed.request.request_sha256 = changed.request.digest().unwrap();
            changed.proof_sha256 = changed.digest().unwrap();
            changed.validate().unwrap();
            assert!(request.matches(&changed).is_err());
            let mut changed = proof.clone();
            changed.disposal.request.operation_id = "other-disposal".into();
            changed.proof_sha256 = changed.digest().unwrap();
            assert!(changed.validate().is_err());
            let mut extra = row["request"].clone();
            extra["backing_removed"] = serde_json::json!(true);
            assert!(serde_json::from_value::<PartialBranchDisposalCleanupRequest>(extra).is_err());
            let mut extra = row["proof"].clone();
            extra["deleted"] = serde_json::json!(true);
            assert!(serde_json::from_value::<PartialBranchDisposalCleanup>(extra).is_err());
            assert!(!format!("{request:?}").contains(&request.request_sha256));
            assert!(!format!("{proof:?}").contains(&proof.proof_sha256));
        }
    }
    #[test]
    fn even_rehashed_sdk_deleted_provenance_or_reused_explicit_release_is_not_cleanup() {
        for row in rows() {
            let proof: PartialBranchDisposalCleanup =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let mut changed = proof.clone();
            changed.disposal.completion = PartialBranchDisposalCompletion::Deleted;
            changed.disposal.proof_sha256 = hash(&(
                "smolbox-partial-branch-disposal-proof-v1",
                changed.disposal.schema,
                changed.disposal.completion,
                &changed.disposal.request,
                &changed.disposal.publication,
                &changed.disposal.release,
                &changed.disposal.disposal_sha256,
            ))
            .unwrap();
            changed.disposal.validate().unwrap();
            changed.proof_sha256 = changed.digest().unwrap();
            assert!(changed.validate().is_err());
            if let Some(release) = &proof.disposal.release {
                let mut changed = proof.clone();
                changed.request.operation_id = release.change.request.operation_id.clone();
                changed.request.request_sha256 = changed.request.digest().unwrap();
                changed.proof_sha256 = changed.digest().unwrap();
                assert!(changed.validate().is_err());
            }
        }
    }
}
