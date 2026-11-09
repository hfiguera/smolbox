//! Distinct grants for SDK deletion continuation and filesystem-only residual cleanup.
use crate::{BranchApproval, BranchCompletion, BranchDeletionResolution, InvalidMessage, Receipt};
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
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HeldBranchDeletionAction {
    Continue,
    Cleanup,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HeldBranchDeletionActionRequest {
    pub action: HeldBranchDeletionAction,
    pub completion: BranchCompletion,
    pub child: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl HeldBranchDeletionActionRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.completion.validate()?;
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.request_sha256, 64)?;
        check(
            self.completion.held
                && self.completion.release.is_none()
                && self.child == self.completion.child
                && self.quiesced
                && self.operation_id
                    != self
                        .completion
                        .publication
                        .change
                        .child_origin
                        .intent
                        .child
                        .operation_id
                && self.request_sha256 == self.digest()?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= crate::HELD_BRANCH_DELETION_REQUEST_BYTES,
        )
    }
    fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-held-child-delete-action-v1",
            self.action,
            &self.completion,
            &self.child,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn require_action(&self, action: HeldBranchDeletionAction) -> Result<(), InvalidMessage> {
        self.validate()?;
        check(self.action == action)
    }
    pub fn approval(&self) -> &BranchApproval {
        &self
            .completion
            .publication
            .change
            .child_origin
            .intent
            .approval
    }
    pub fn matches_continuation(
        &self,
        proof: &BranchDeletionContinuation,
    ) -> Result<(), InvalidMessage> {
        self.require_action(HeldBranchDeletionAction::Continue)?;
        proof.validate()?;
        check(
            proof.child == self.child
                && proof.operation_id == self.operation_id
                && proof.request_sha256 == self.request_sha256,
        )
    }
    pub fn matches_cleanup(&self, proof: &BranchDeletionResolution) -> Result<(), InvalidMessage> {
        self.require_action(HeldBranchDeletionAction::Cleanup)?;
        proof.validate()?;
        check(
            proof.child == self.child
                && proof.operation_id == self.operation_id
                && proof.request_sha256 == self.request_sha256,
        )
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchDeletionContinuation {
    pub schema: u8,
    pub child: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub deletion_sha256: String,
    pub proof_sha256: String,
}
impl BranchDeletionContinuation {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.child.validate_for(2)?;
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.request_sha256, 64)?;
        crate::wire::hex(&self.deletion_sha256, 64)?;
        let mut origin = self.child.clone();
        origin.material = None;
        let material = self.child.material.as_ref().ok_or(InvalidMessage)?;
        check(
            self.schema == 1
                && material.revision == 0
                && material.chain_sha256 == hash(&("smolbox-material-origin-v2", origin))?
                && self.proof_sha256
                    == hash(&(
                        "smolbox-held-child-delete-continuation-proof-v1",
                        self.schema,
                        &self.child,
                        &self.operation_id,
                        &self.request_sha256,
                        &self.deletion_sha256,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= crate::HELD_BRANCH_DELETION_PROOF_BYTES,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!(
            "../fixtures/held-branch-deletion-action-v1.json"
        ))
        .unwrap()
    }
    fn operation(request: &HeldBranchDeletionActionRequest) -> Operation {
        match request.action {
            HeldBranchDeletionAction::Continue => Operation::ContinueHeldBranchDeletion {
                request: Box::new(request.clone()),
            },
            HeldBranchDeletionAction::Cleanup => Operation::CleanupHeldBranchDeletion {
                request: Box::new(request.clone()),
            },
        }
    }
    fn outcome(row: &serde_json::Value) -> Outcome {
        if row["request"]["action"] == "continue" {
            Outcome::HeldBranchDeletionContinued {
                proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
            }
        } else {
            Outcome::HeldBranchDeletionCleaned {
                proof: Box::new(serde_json::from_value(row["proof"].clone()).unwrap()),
            }
        }
    }
    fn hello(request: &HeldBranchDeletionActionRequest) -> Hello {
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
        hello.package.platform = request.completion.publication.change.platform.clone();
        hello.package.architecture = if hello.package.platform == "macos" {
            "aarch64"
        } else {
            "x86_64"
        }
        .into();
        hello.domain.target_id = request.child.target_id.clone();
        hello.domain.generation = request.child.domain_generation.clone();
        *hello
    }
    fn admit(session: &mut Session, hello: &Hello, operation: Operation) -> ServerMessage {
        session
            .admit(ClientMessage::Request {
                epoch: hello.epoch.clone(),
                id: 1,
                budget_ms: 30000,
                initial_credit: 1024,
                initial_event_credit: 1,
                operation,
            })
            .unwrap()
    }
    #[test]
    fn action_and_proof_kinds_are_bound_to_exact_completion_and_separate_digest_domains() {
        for row in rows() {
            let request: HeldBranchDeletionActionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            request.validate().unwrap();
            let op = operation(&request);
            op.validate(30000).unwrap();
            assert!(op.validate(30001).is_err());
            assert!(op.requires_branches() && op.capability() == Capability::Delete);
            assert!(op.branch_approval() == Some(request.approval()));
            let result = outcome(&row);
            result.validate_for(2).unwrap();
            assert!(result.validate_for(1).is_err());
            match &result {
                Outcome::HeldBranchDeletionContinued { proof } => {
                    request.matches_continuation(proof).unwrap();
                    let wrong: BranchDeletionResolution =
                        serde_json::from_value(row["proof"].clone()).unwrap();
                    assert!(wrong.validate().is_err());
                }
                Outcome::HeldBranchDeletionCleaned { proof } => {
                    request.matches_cleanup(proof).unwrap();
                    let wrong: BranchDeletionContinuation =
                        serde_json::from_value(row["proof"].clone()).unwrap();
                    assert!(wrong.validate().is_err());
                }
                _ => panic!("fixture result"),
            }
            let mut other = request.clone();
            other.action = if request.action == HeldBranchDeletionAction::Continue {
                HeldBranchDeletionAction::Cleanup
            } else {
                HeldBranchDeletionAction::Continue
            };
            assert!(other.validate().is_err());
            other.request_sha256 = other.digest().unwrap();
            other.validate().unwrap();
            let mut wrong_op = serde_json::to_value(op).unwrap();
            wrong_op["request"] = serde_json::to_value(other).unwrap();
            assert!(serde_json::from_value::<Operation>(wrong_op)
                .unwrap()
                .validate(1000)
                .is_err());
            for field in ["path", "pid", "backing_removed"] {
                let mut wrong = row["request"].clone();
                wrong[field] = serde_json::json!(true);
                assert!(serde_json::from_value::<HeldBranchDeletionActionRequest>(wrong).is_err());
            }
        }
    }
    #[test]
    fn session_requires_enabled_same_platform_domain_and_exact_nonstreaming_outcome() {
        for row in rows() {
            let request: HeldBranchDeletionActionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let good = hello(&request);
            for mode in 0..4 {
                let mut h = good.clone();
                match mode {
                    0 => {
                        h.sdk.as_mut().unwrap().feature_versions.remove("branches");
                    }
                    1 => {
                        h.package.platform = if h.package.platform == "macos" {
                            "linux"
                        } else {
                            "macos"
                        }
                        .into();
                        h.package.architecture = if h.package.platform == "macos" {
                            "aarch64"
                        } else {
                            "x86_64"
                        }
                        .into();
                    }
                    2 => h.domain.generation = "0".repeat(32),
                    _ => h
                        .capabilities
                        .retain(|capability| *capability != Capability::Delete),
                }
                let mut session = Session::new(h.clone()).unwrap();
                session.approve(&h).unwrap();
                assert!(matches!(
                    admit(&mut session, &h, operation(&request)),
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
                admit(&mut session, &good, operation(&request)),
                ServerMessage::Accepted { .. }
            ));
            for stream in [
                Stream::Stdout,
                Stream::Stderr,
                Stream::File,
                Stream::Checkpoint,
                Stream::Log,
                Stream::Terminal,
            ] {
                assert!(session.event(1, stream, b"extra").is_err());
            }
            assert!(session.terminal(1, Outcome::Qualified).is_err());
            let observed: BranchDeletionResolution = serde_json::from_value(
                serde_json::from_str::<Vec<serde_json::Value>>(include_str!(
                    "../fixtures/held-branch-deletion-v1.json"
                ))
                .unwrap()[0]["proof"]
                    .clone(),
            )
            .unwrap();
            assert!(session
                .terminal(
                    1,
                    Outcome::HeldBranchDeletionResolved {
                        proof: Box::new(observed)
                    }
                )
                .is_err());
            let mut changed = request.clone();
            changed.operation_id = "different-accepted-action".into();
            changed.request_sha256 = changed.digest().unwrap();
            let mut mismatch = Session::new(good.clone()).unwrap();
            mismatch.approve(&good).unwrap();
            admit(&mut mismatch, &good, operation(&changed));
            assert!(mismatch.terminal(1, outcome(&row)).is_err());
            session.terminal(1, outcome(&row)).unwrap();
        }
    }
    #[test]
    fn held_root_fencing_and_required_proof_reject_released_and_bare_substitutions() {
        for row in rows() {
            let request: HeldBranchDeletionActionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            for mode in 0..5 {
                let mut bad = request.clone();
                match mode {
                    0 => bad.quiesced = false,
                    1 => bad.child.owner_token = "0".repeat(64),
                    2 => bad.child.material = None,
                    3 => {
                        bad.operation_id = bad
                            .completion
                            .publication
                            .change
                            .child_origin
                            .intent
                            .child
                            .operation_id
                            .clone()
                    }
                    _ => bad.request_sha256 = "0".repeat(64),
                }
                if mode != 4 {
                    bad.request_sha256 = bad.digest().unwrap();
                }
                assert!(bad.validate().is_err());
            }
            let released: Vec<serde_json::Value> =
                serde_json::from_str(include_str!("../fixtures/branch-child-absence-v1.json"))
                    .unwrap();
            for foreign in released.into_iter().filter(|r| r["mode"] != "held") {
                let mut bad = request.clone();
                bad.completion =
                    serde_json::from_value(foreign["request"]["completion"].clone()).unwrap();
                bad.child = serde_json::from_value(foreign["request"]["child"].clone()).unwrap();
                bad.request_sha256 = bad.digest().unwrap();
                assert!(bad.validate().is_err());
            }
        }
        for kind in [
            "held_branch_deletion_continued",
            "held_branch_deletion_cleaned",
        ] {
            for value in [
                serde_json::json!({"result":kind}),
                serde_json::json!({"result":kind,"proof":null}),
            ] {
                assert!(serde_json::from_value::<Outcome>(value).is_err());
            }
        }
    }
}
