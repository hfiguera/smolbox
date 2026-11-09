//! Bounded original-result backing acknowledgement; no deletion authority.
use crate::{BranchApproval, BranchCompletion, BranchPublication, InvalidMessage, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
pub const BRANCH_BACKING_REQUEST_BYTES: usize = 80 * 1024;
pub const BRANCH_BACKING_PROOF_BYTES: usize = 68 * 1024;
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
pub struct BranchBackingReleaseRequest {
    pub completion: BranchCompletion,
    pub source: Receipt,
    pub child: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
    pub backing_removed: bool,
}
impl BranchBackingReleaseRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.completion.validate()?;
        for (expected, current) in [
            (&self.completion.publication.receipt, &self.source),
            (&self.completion.child, &self.child),
        ] {
            current.validate_for(2)?;
            check(origin(expected) == origin(current))?;
            let before = expected.material.as_ref().ok_or(InvalidMessage)?;
            let material = current.material.as_ref().ok_or(InvalidMessage)?;
            check(
                material.revision >= before.revision
                    && (material.revision != before.revision || material == before),
            )?;
            if material.revision == 0 {
                check(
                    material.chain_sha256
                        == hash(&("smolbox-material-origin-v2", origin(current)))?,
                )?;
            }
        }
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.request_sha256, 64)?;
        check(
            self.quiesced
                && self.backing_removed
                && self.operation_id
                    != self
                        .completion
                        .publication
                        .change
                        .child_origin
                        .intent
                        .child
                        .operation_id
                && !self.completion.release.as_ref().is_some_and(|release| {
                    release.change.request.operation_id == self.operation_id
                })
                && self.request_sha256 == self.digest()?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= BRANCH_BACKING_REQUEST_BYTES,
        )
    }
    fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-branch-backing-request-v1",
            &self.completion,
            &self.source,
            &self.child,
            &self.operation_id,
            self.quiesced,
            self.backing_removed,
        ))
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
    pub fn matches(&self, proof: &BranchBackingRelease) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        check(
            proof.publication == self.completion.publication
                && proof.operation_id == self.operation_id
                && proof.request_sha256 == self.request_sha256,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchBackingRelease {
    pub schema: u8,
    pub publication: BranchPublication,
    pub operation_id: String,
    pub request_sha256: String,
    pub native_bytes: u64,
    pub proof_sha256: String,
}
impl BranchBackingRelease {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.publication.validate()?;
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.request_sha256, 64)?;
        let plan = &self.publication.change.child_origin.intent.plan;
        let bytes = plan
            .ordinary_child
            .disk_gb
            .checked_add(plan.minimum_extra_disk_gb)
            .and_then(|gib| gib.checked_mul(1 << 30))
            .ok_or(InvalidMessage)?;
        check(
            self.schema == 1
                && self.native_bytes == bytes
                && self.proof_sha256
                    == hash(&(
                        "smolbox-branch-backing-release-v1",
                        self.schema,
                        &self.publication,
                        &self.operation_id,
                        &self.request_sha256,
                        self.native_bytes,
                    ))?
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                    <= BRANCH_BACKING_PROOF_BYTES,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!("../fixtures/branch-backing-release-v1.json")).unwrap()
    }
    fn hello(request: &BranchBackingReleaseRequest) -> Hello {
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
            let request: BranchBackingReleaseRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchBackingRelease = serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            let op = Operation::ReleaseBranchBacking {
                request: Box::new(request.clone()),
            };
            op.validate(30000).unwrap();
            assert!(op.validate(30001).is_err());
            assert!(op.requires_branches() && op.capability() == Capability::Inspect);
            assert!(op.branch_approval() == Some(request.approval()));
            let result = Outcome::BranchBackingReleased {
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
            assert!(changed.validate().is_err());
            changed.request_sha256 = changed.digest().unwrap();
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
            let request: BranchBackingReleaseRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchBackingRelease = serde_json::from_value(row["proof"].clone()).unwrap();
            let op = Operation::ReleaseBranchBacking {
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
                    Outcome::BranchBackingReleased {
                        proof: Box::new(proof),
                    },
                )
                .unwrap();
        }
    }
    #[test]
    fn host_confirmation_heads_and_native_charge_cannot_be_substituted() {
        let row = rows().remove(0);
        let request: BranchBackingReleaseRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: BranchBackingRelease = serde_json::from_value(row["proof"].clone()).unwrap();
        for mode in 0..5 {
            let mut wrong = request.clone();
            match mode {
                0 => wrong.backing_removed = false,
                1 => wrong.quiesced = false,
                2 => wrong.source = wrong.completion.publication.previous.clone(),
                3 => wrong.child.owner_token = "0".repeat(64),
                _ => {
                    wrong.operation_id = wrong
                        .completion
                        .publication
                        .change
                        .child_origin
                        .intent
                        .child
                        .operation_id
                        .clone()
                }
            }
            wrong.request_sha256 = wrong.digest().unwrap();
            assert!(wrong.validate().is_err());
        }
        let mut wrong = proof;
        wrong.native_bytes += 1;
        assert!(request.matches(&wrong).is_err());
    }
    #[test]
    fn backing_reply_has_required_exact_nonnullable_proof_and_no_caller_selected_paths() {
        let row = rows().remove(0);
        let mut encoded = row["request"].clone();
        encoded["path"] = serde_json::json!("/foreign");
        assert!(serde_json::from_value::<BranchBackingReleaseRequest>(encoded).is_err());
        for outcome in [
            serde_json::json!({"result":"branch_backing_released"}),
            serde_json::json!({"result":"branch_backing_released","proof":null}),
        ] {
            assert!(serde_json::from_value::<Outcome>(outcome).is_err());
        }
    }
}
