//! Explicit disposal after original pre-handoff child collection. This is not
//! never-booted disposal, branch readiness or dependency/backing retirement.
use crate::{InvalidMessage, PartialBranchCollection, PartialBranchCollectionRequest};
type Result<T> = std::result::Result<T, InvalidMessage>;
use sha2::{Digest, Sha256};
fn hash(value: &impl Serialize) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}
use serde::{Deserialize, Serialize};

pub const PARTIAL_BRANCH_DISPOSAL_REQUEST_BYTES: usize = 24 * 1024;
pub const PARTIAL_BRANCH_DISPOSAL_PROOF_BYTES: usize = 48 * 1024;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposalRequest {
    pub collection_request: PartialBranchCollectionRequest,
    pub collection: PartialBranchCollection,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for PartialBranchDisposalRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposalRequest")
            .finish_non_exhaustive()
    }
}
impl PartialBranchDisposalRequest {
    pub fn digest(&self) -> Result<String> {
        hash(&(
            "smolbox-partial-branch-disposal-request-v1",
            &self.collection_request,
            &self.collection,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn validate(&self) -> Result<()> {
        self.collection_request.matches(&self.collection)?;
        let creation = &self.collection_request.creation;
        if !self.quiesced
            || crate::wire::id(&self.operation_id).is_err()
            || self.operation_id == self.collection.operation_id
            || self.operation_id == creation.child.operation_id
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|r| r.operation_id == self.operation_id)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                > PARTIAL_BRANCH_DISPOSAL_REQUEST_BYTES
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PartialBranchDisposalCompletion {
    Deleted,
    ResolvedAbsent,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchDisposal {
    pub schema: u8,
    pub completion: PartialBranchDisposalCompletion,
    pub request: PartialBranchDisposalRequest,
    pub publication: crate::BranchPublication,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release: Option<crate::BranchReleaseTransition>,
    pub disposal_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchDisposal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchDisposal")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
pub(crate) fn validate_context(
    request: &PartialBranchDisposalRequest,
    publication: &crate::BranchPublication,
    release: Option<&crate::BranchReleaseTransition>,
) -> Result<()> {
    request.validate()?;
    publication.validate()?;
    let creation = &request.collection_request.creation;
    let intent = &publication.change.child_origin.intent;
    if intent.source != creation.source
        || intent.child != creation.child
        || intent.approval != creation.approval
    {
        return Err(InvalidMessage);
    }
    if let Some(release) = release {
        release.validate()?;
        if release.change.request.operation_id == request.operation_id
            || release.previous != publication.change.child
            || release.change.binding != publication.change.child_origin
            || release.change.boot_sha256 != request.collection.boot_sha256
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|r| *r != release.change.request)
        {
            return Err(InvalidMessage);
        }
    }
    if request.collection.publication_sha256 != hash(publication)? {
        return Err(InvalidMessage);
    }
    Ok(())
}

impl PartialBranchDisposal {
    pub fn validate(&self) -> Result<()> {
        validate_context(&self.request, &self.publication, self.release.as_ref())?;
        if self.schema != 1
            || crate::wire::hex(&self.disposal_sha256, 64).is_err()
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                > PARTIAL_BRANCH_DISPOSAL_PROOF_BYTES
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
    pub fn matches_request(&self, request: &PartialBranchDisposalRequest) -> Result<()> {
        self.validate()?;
        request.validate()?;
        if self.request != *request {
            return Err(InvalidMessage);
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        hash(&(
            "smolbox-partial-branch-disposal-proof-v1",
            self.schema,
            self.completion,
            &self.request,
            &self.publication,
            &self.release,
            &self.disposal_sha256,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!("../fixtures/partial-branch-disposal-v1.json")).unwrap()
    }
    fn hello(row: &serde_json::Value, request: &PartialBranchDisposalRequest) -> Hello {
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
        hello.epoch = row["proof"]["publication"]["change"]["child_origin"]["intent"]["epoch"]
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
        hello.domain.target_id = request.collection_request.creation.source.target_id.clone();
        hello.domain.generation = request
            .collection_request
            .creation
            .source
            .domain_generation
            .clone();
        *hello
    }
    fn admitted(h: &Hello, operation: Operation) -> Session {
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
                    operation
                })
                .unwrap(),
            ServerMessage::Accepted { .. }
        ));
        session
    }
    #[test]
    fn synthetic_readers_preserve_both_completions_platforms_and_release_origins() {
        for row in rows() {
            let request: PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            proof.matches_request(&request).unwrap();
            assert!(serde_json::to_value(&request).unwrap() == row["request"]);
            assert!(serde_json::to_value(&proof).unwrap() == row["proof"]);
            let h = hello(&row, &request);
            for operation in [
                Operation::DisposePartialBranch {
                    request: Box::new(request.clone()),
                },
                Operation::ResolvePartialBranchDisposal {
                    request: Box::new(request.clone()),
                },
                Operation::QualifyPartialBranchCleanup {
                    request: Box::new(request.clone()),
                },
            ] {
                operation.validate(30_000).unwrap();
                assert!(operation.validate(30_001).is_err());
                assert!(operation.requires_branches());
                assert!(operation.receipt() == Some(&request.collection_request.creation.source));
                assert!(
                    operation.branch_approval()
                        == Some(&request.collection_request.creation.approval)
                );
                let outcome = Outcome::PartialBranchDisposed {
                    proof: Box::new(proof.clone()),
                };
                outcome.validate_for(2).unwrap();
                assert!(outcome.validate_for(1).is_err());
                let mut session = admitted(&h, operation.clone());
                assert!(session.event(1, Stream::Stdout, b"unexpected").is_err());
                assert!(session.terminal(1, Outcome::Qualified).is_err());
                session.terminal(1, outcome).unwrap();
                assert!(matches!(
                    operation.capability(),
                    Capability::Delete | Capability::Inspect
                ));
            }
        }
    }
    #[test]
    fn crossed_context_and_uncorrelated_completion_cannot_acknowledge_disposal() {
        for row in rows() {
            let request: PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposal =
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
                    submitted.operation_id = "different-disposal".into();
                    submitted.request_sha256 = submitted.digest().unwrap();
                }
                let mut session = admitted(
                    &context,
                    Operation::DisposePartialBranch {
                        request: Box::new(submitted),
                    },
                );
                assert!(session
                    .terminal(
                        1,
                        Outcome::PartialBranchDisposed {
                            proof: Box::new(proof.clone())
                        }
                    )
                    .is_err());
            }
            let mut crossed = request.clone();
            crossed.quiesced = false;
            crossed.request_sha256 = crossed.digest().unwrap();
            assert!(crossed.validate().is_err());
            crossed = request.clone();
            crossed.operation_id = crossed.collection.operation_id.clone();
            crossed.request_sha256 = crossed.digest().unwrap();
            assert!(crossed.validate().is_err());
            let mut with_extra = serde_json::to_value(&proof).unwrap();
            with_extra["backing_removed"] = serde_json::json!(true);
            assert!(serde_json::from_value::<PartialBranchDisposal>(with_extra).is_err());
            assert!(!format!("{:?}", proof).contains(&proof.proof_sha256));
            assert!(!format!("{:?}", request).contains(&request.request_sha256));
        }
    }
}
