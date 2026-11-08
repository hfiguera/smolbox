//! Acknowledgement that an accepted cleanup is unnecessary after original
//! disposal. This is not residual removal, SDK-entry or dependency-release proof.
use crate::{InvalidMessage, PartialBranchDisposal, PartialBranchDisposalCleanupRequest};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
type Result<T> = std::result::Result<T, InvalidMessage>;
fn hash(value: &impl Serialize) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}

pub const PARTIAL_BRANCH_UNNEEDED_CLEANUP_PROOF_BYTES: usize = 80 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposalCleanupUnneeded {
    pub schema: u8,
    pub request: PartialBranchDisposalCleanupRequest,
    pub disposal: PartialBranchDisposal,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchDisposalCleanupUnneeded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposalCleanupUnneeded")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchDisposalCleanupUnneeded {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        self.disposal.validate()?;
        if self.schema != 1
            || self.disposal.request != self.request.disposal_request
            || self.disposal.release.as_ref().is_some_and(|release| {
                release.change.request.operation_id == self.request.operation_id
            })
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                > PARTIAL_BRANCH_UNNEEDED_CLEANUP_PROOF_BYTES
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        hash(&(
            "smolbox-partial-branch-disposal-cleanup-unneeded-v1",
            self.schema,
            &self.request,
            &self.disposal,
        ))
    }
    pub fn matches_request(&self, request: &PartialBranchDisposalCleanupRequest) -> Result<()> {
        self.validate()?;
        request.validate()?;
        if self.request != *request {
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
            "../fixtures/partial-branch-cleanup-unneeded-v1.json"
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
        hello
            .sdk
            .as_mut()
            .unwrap()
            .feature_versions
            .insert("partial_cleanup_resolution".into(), 1);
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
        Operation::ResolvePartialBranchCleanup {
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
    fn synthetic_codec_preserves_both_terminal_provenances_platforms_and_release_origins() {
        assert_eq!(PARTIAL_BRANCH_CLEANUP_REQUEST_BYTES, 28 * 1024);
        assert_eq!(PARTIAL_BRANCH_UNNEEDED_CLEANUP_PROOF_BYTES, 80 * 1024);
        for row in rows() {
            let request: PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposalCleanupUnneeded =
                serde_json::from_value(row["proof"].clone()).unwrap();
            proof.matches_request(&request).unwrap();
            assert_eq!(serde_json::to_value(&request).unwrap(), row["request"]);
            assert_eq!(serde_json::to_value(&proof).unwrap(), row["proof"]);
            let op = operation(&request);
            op.validate(30_000).unwrap();
            assert!(op.validate(30_001).is_err());
            assert!(op.requires_branches());
            assert!(op.partial_disposal_request().is_none());
            assert!(op.capability() == Capability::Inspect);
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
            let outcome = Outcome::PartialBranchCleanupUnneeded {
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
            let proof: PartialBranchDisposalCleanupUnneeded =
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
                        Outcome::PartialBranchCleanupUnneeded {
                            proof: Box::new(proof.clone())
                        }
                    )
                    .is_err());
            }
        }
    }
    #[test]
    fn resolution_requires_distinct_action_quiescence_strict_schema_and_matching_original_disposal()
    {
        for row in rows() {
            let request: PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposalCleanupUnneeded =
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
            assert!(changed.matches_request(&request).is_err());
            let mut changed = proof.clone();
            changed.disposal.request.operation_id = "other-disposal".into();
            changed.proof_sha256 = changed.digest().unwrap();
            assert!(changed.validate().is_err());
            let mut extra = row["request"].clone();
            extra["backing_removed"] = serde_json::json!(true);
            assert!(serde_json::from_value::<PartialBranchDisposalCleanupRequest>(extra).is_err());
            let mut extra = row["proof"].clone();
            extra["deleted"] = serde_json::json!(true);
            assert!(serde_json::from_value::<PartialBranchDisposalCleanupUnneeded>(extra).is_err());
            assert!(!format!("{request:?}").contains(&request.request_sha256));
            assert!(!format!("{proof:?}").contains(&proof.proof_sha256));
        }
    }
    #[test]
    fn unneeded_acknowledgement_cannot_be_consumed_by_old_removal_operation_or_proof() {
        for row in rows() {
            let request: PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposalCleanupUnneeded =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let removal: crate::PartialBranchDisposalCleanup =
                serde_json::from_value(row["proof"].clone()).unwrap();
            assert!(removal.validate().is_err());
            let h = hello(&row, &request);
            let mut session = Session::new(h.clone()).unwrap();
            session.approve(&h).unwrap();
            session
                .admit(ClientMessage::Request {
                    epoch: h.epoch.clone(),
                    id: 1,
                    budget_ms: 1000,
                    initial_credit: 1024,
                    initial_event_credit: 1,
                    operation: Operation::CleanupPartialBranchDisposal {
                        request: Box::new(request),
                    },
                })
                .unwrap();
            assert!(session
                .terminal(
                    1,
                    Outcome::PartialBranchCleanupUnneeded {
                        proof: Box::new(proof)
                    }
                )
                .is_err());
        }
    }
    #[test]
    fn missing_resolution_feature_or_branch_dependency_never_admits_new_opcode() {
        for row in rows() {
            let request: PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let mut h = hello(&row, &request);
            h.sdk
                .as_mut()
                .unwrap()
                .feature_versions
                .remove("partial_cleanup_resolution");
            let mut session = Session::new(h.clone()).unwrap();
            session.approve(&h).unwrap();
            assert!(matches!(
                session
                    .admit(ClientMessage::Request {
                        epoch: h.epoch.clone(),
                        id: 1,
                        budget_ms: 1000,
                        initial_credit: 1024,
                        initial_event_credit: 1,
                        operation: operation(&request),
                    })
                    .unwrap(),
                ServerMessage::Terminal {
                    outcome: Outcome::Error {
                        code: SafeCode::Unsupported,
                        dispatch: Dispatch::NotDispatched
                    },
                    ..
                }
            ));
            h.sdk
                .as_mut()
                .unwrap()
                .feature_versions
                .insert("partial_cleanup_resolution".into(), 1);
            h.sdk.as_mut().unwrap().feature_versions.remove("branches");
            assert!(h.validate().is_err());
        }
    }
}
