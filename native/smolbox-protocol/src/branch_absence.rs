//! Bounded original-branch child absence correlation. These values never enroll
//! an SDK manager, prove backing removal or authorize automatic deletion.
use crate::{BranchApproval, BranchCompletion, InvalidMessage, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const BRANCH_ABSENCE_BYTES: usize = 68 * 1024;
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
fn origin(receipt: &Receipt) -> Receipt {
    let mut value = receipt.clone();
    value.material = None;
    value
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchChildAbsenceRequest {
    pub completion: BranchCompletion,
    pub child: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl BranchChildAbsenceRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.completion.validate()?;
        self.child.validate_for(2)?;
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.request_sha256, 64)?;
        check(
            self.quiesced
                && origin(&self.child) == origin(&self.completion.child)
                && self.operation_id
                    != self
                        .completion
                        .publication
                        .change
                        .child_origin
                        .intent
                        .child
                        .operation_id,
        )?;
        let material = self.child.material.as_ref().ok_or(InvalidMessage)?;
        if material.revision == 0 {
            check(
                material.chain_sha256
                    == hash(&("smolbox-material-origin-v2", origin(&self.child)))?,
            )?;
        }
        check(serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() <= BRANCH_ABSENCE_BYTES)
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
    pub fn matches(&self, proof: &BranchChildAbsence) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        check(proof.request == *self)
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchChildAbsence {
    pub schema: u8,
    pub request: BranchChildAbsenceRequest,
    pub proof_sha256: String,
}
impl BranchChildAbsence {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.request.validate()?;
        check(
            self.schema == 1
                && self.proof_sha256
                    == hash(&(
                        "smolbox-branch-child-absence-v1",
                        self.schema,
                        &self.request,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= BRANCH_ABSENCE_BYTES,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!("../fixtures/branch-child-absence-v1.json")).unwrap()
    }
    fn hello(request: &BranchChildAbsenceRequest) -> Hello {
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
    fn exact_fixtures_bind_original_completion_current_child_fencing_request_and_read_budget() {
        for row in rows() {
            let request: BranchChildAbsenceRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchChildAbsence = serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            let op = Operation::QualifyBranchChildAbsence {
                request: Box::new(request.clone()),
            };
            op.validate(30000).unwrap();
            assert!(op.validate(30001).is_err());
            assert!(op.requires_branches() && op.capability() == Capability::Inspect);
            assert!(op.branch_approval() == Some(request.approval()));
            let result = Outcome::BranchChildAbsent {
                proof: Box::new(proof.clone()),
            };
            result.validate_for(2).unwrap();
            assert!(result.validate_for(1).is_err());
            let mut changed = request.clone();
            changed.quiesced = false;
            assert!(changed.validate().is_err());
            let mut changed = request.clone();
            changed.child.owner_token = "0".repeat(64);
            assert!(changed.validate().is_err());
            let mut changed = request.clone();
            changed.operation_id = "another-observation".into();
            changed.validate().unwrap();
            assert!(changed.matches(&proof).is_err());
            let mut changed = request;
            changed.completion.identity_sha256 = "0".repeat(64);
            assert!(changed.matches(&proof).is_err());
        }
    }
    #[test]
    fn session_rejects_disabled_foreign_platform_and_domain_before_entry_and_zero_output_correlation(
    ) {
        for row in rows() {
            let request: BranchChildAbsenceRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchChildAbsence = serde_json::from_value(row["proof"].clone()).unwrap();
            let op = Operation::QualifyBranchChildAbsence {
                request: Box::new(request.clone()),
            };
            let good = hello(&request);
            for mode in 0..3 {
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
                    _ => {
                        h.domain.generation = "0".repeat(32);
                    }
                }
                let mut session = Session::new(h.clone()).unwrap();
                session.approve(&h).unwrap();
                assert!(matches!(
                    admit(&mut session, &h, op.clone()),
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
                admit(&mut session, &good, op),
                ServerMessage::Accepted { .. }
            ));
            assert!(session.event(1, Stream::Stdout, b"extra").is_err());
            assert!(session.terminal(1, Outcome::Qualified).is_err());
            session
                .terminal(
                    1,
                    Outcome::BranchChildAbsent {
                        proof: Box::new(proof),
                    },
                )
                .unwrap();
        }
    }
    #[test]
    fn absent_reply_has_required_exact_nonnullable_proof_and_no_caller_selected_paths() {
        let row = rows().remove(0);
        let mut encoded = row["request"].clone();
        encoded["path"] = serde_json::json!("/foreign");
        assert!(serde_json::from_value::<BranchChildAbsenceRequest>(encoded).is_err());
        for outcome in [
            serde_json::json!({"result":"branch_child_absent"}),
            serde_json::json!({"result":"branch_child_absent","proof":null}),
        ] {
            assert!(serde_json::from_value::<Outcome>(outcome).is_err());
        }
    }
}
