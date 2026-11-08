//! Separate original-child collection control; never deletion or capacity proof.
use crate::{BranchApproval, BranchCompletion, BranchReleaseTransition, InvalidMessage, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
pub const BRANCH_DELETION_COLLECTION_REQUEST_BYTES: usize = 132 * 1024;
pub const BRANCH_DELETION_COLLECTION_PROOF_BYTES: usize = 4096;
const REQUEST_BYTES: usize = BRANCH_DELETION_COLLECTION_REQUEST_BYTES;
const PROOF_BYTES: usize = BRANCH_DELETION_COLLECTION_PROOF_BYTES;
fn hash(value: &impl Serialize) -> Result<String, InvalidMessage> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}
fn valid_id(value: &str) -> bool {
    crate::wire::id(value).is_ok()
}
fn valid_hex(value: &str, count: usize) -> bool {
    crate::wire::hex(value, count).is_ok()
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchDeletionCollectionRequest {
    pub completion: BranchCompletion,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release: Option<BranchReleaseTransition>,
    pub child: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for BranchDeletionCollectionRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchDeletionCollectionRequest")
            .finish_non_exhaustive()
    }
}
impl BranchDeletionCollectionRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.completion.validate()?;
        match &self.release {
            None if self.completion.held && self.child == self.completion.child => (),
            Some(release) => {
                release.validate()?;
                if release.previous != self.completion.publication.change.child
                    || release.change.binding != self.completion.publication.change.child_origin
                    || release.change.identity_sha256 != self.completion.identity_sha256
                    || (!self.completion.held && self.completion.release.as_ref() != Some(release))
                    || self.child != release.receipt
                    || self.operation_id == release.change.request.operation_id
                {
                    return Err(InvalidMessage);
                }
            }
            _ => return Err(InvalidMessage),
        }
        if !self.quiesced
            || !valid_id(&self.operation_id)
            || self.operation_id
                == self
                    .completion
                    .publication
                    .change
                    .child_origin
                    .intent
                    .child
                    .operation_id
            || !valid_hex(&self.request_sha256, 64)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() > REQUEST_BYTES
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
    /// Stable request digest; the digest field itself is excluded.
    pub fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-original-child-delete-collection-request-v1",
            &self.completion,
            &self.release,
            &self.child,
            &self.operation_id,
            self.quiesced,
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
    pub fn matches(&self, proof: &BranchDeletionCollection) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        if proof.grant()? != Grant::new(self, &proof.deletion_sha256)? {
            return Err(InvalidMessage);
        }
        Ok(())
    }
}

/// Historical original-child collection only. It gives no readiness, stopped-row,
/// SDK deletion, namespace absence, dependency or backing-retirement authority.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchDeletionCollection {
    pub schema: u8,
    pub child: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub completion_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_sha256: Option<String>,
    pub deletion_sha256: String,
    pub collection_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for BranchDeletionCollection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchDeletionCollection")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl BranchDeletionCollection {
    fn grant(&self) -> Result<Grant, InvalidMessage> {
        let grant = Grant {
            child: self.child.clone(),
            operation_id: self.operation_id.clone(),
            request_sha256: self.request_sha256.clone(),
            completion_sha256: self.completion_sha256.clone(),
            release_sha256: self.release_sha256.clone(),
            deletion_sha256: self.deletion_sha256.clone(),
        };
        grant.validate()?;
        Ok(grant)
    }
    fn digest(&self) -> Result<String, InvalidMessage> {
        hash(&(
            "smolbox-original-child-delete-collection-proof-v1",
            self.schema,
            self.grant()?,
            &self.collection_sha256,
        ))
    }
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        if self.schema != 1
            || !valid_hex(&self.collection_sha256, 64)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() > PROOF_BYTES
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Grant {
    child: Receipt,
    operation_id: String,
    request_sha256: String,
    completion_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    release_sha256: Option<String>,
    deletion_sha256: String,
}
impl Grant {
    fn new(
        request: &BranchDeletionCollectionRequest,
        deletion_sha256: &str,
    ) -> Result<Self, InvalidMessage> {
        let grant = Self {
            child: request.child.clone(),
            operation_id: request.operation_id.clone(),
            request_sha256: request.request_sha256.clone(),
            completion_sha256: hash(&request.completion)?,
            release_sha256: request.release.as_ref().map(hash).transpose()?,
            deletion_sha256: deletion_sha256.into(),
        };
        grant.validate()?;
        Ok(grant)
    }
    fn validate(&self) -> Result<(), InvalidMessage> {
        self.child.validate_for(2)?;
        let material = self.child.material.as_ref().ok_or(InvalidMessage)?;
        material.validate()?;
        if material.revision != u32::from(self.release_sha256.is_some())
            || !valid_id(&self.child.target_id)
            || !valid_id(&self.child.name)
            || !valid_hex(&self.child.domain_generation, 32)
            || !valid_hex(&self.child.owner_token, 64)
            || !valid_hex(&self.child.incarnation, 32)
            || !valid_hex(&self.child.material_sha256, 64)
            || !valid_id(&self.operation_id)
            || [
                &self.request_sha256,
                &self.completion_sha256,
                &self.deletion_sha256,
            ]
            .iter()
            .any(|value| !valid_hex(value, 64))
            || self
                .release_sha256
                .as_ref()
                .is_some_and(|value| !valid_hex(value, 64))
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
            "../fixtures/branch-deletion-collection-v1.json"
        ))
        .unwrap()
    }
    fn hello(request: &BranchDeletionCollectionRequest) -> Hello {
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
            let request: BranchDeletionCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchDeletionCollection =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            let op = Operation::CollectBranchDeletion {
                request: Box::new(request.clone()),
            };
            op.validate(30000).unwrap();
            assert!(op.validate(30001).is_err());
            assert!(op.requires_branches() && op.capability() == Capability::Delete);
            assert!(op.branch_approval() == Some(request.approval()));
            let result = Outcome::BranchDeletionCollected {
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
            let request: BranchDeletionCollectionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchDeletionCollection =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let op = Operation::CollectBranchDeletion {
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
                    Outcome::BranchDeletionCollected {
                        proof: Box::new(proof),
                    },
                )
                .unwrap();
        }
    }
    #[test]
    fn resolved_reply_has_required_exact_nonnullable_proof_and_no_caller_selected_paths() {
        let row = rows().remove(0);
        let mut encoded = row["request"].clone();
        encoded["path"] = serde_json::json!("/foreign");
        assert!(serde_json::from_value::<BranchDeletionCollectionRequest>(encoded).is_err());
        for outcome in [
            serde_json::json!({"result":"branch_deletion_collected"}),
            serde_json::json!({"result":"branch_deletion_collected","proof":null}),
        ] {
            assert!(serde_json::from_value::<Outcome>(outcome).is_err());
        }
    }
}
