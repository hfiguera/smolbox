//! Positive original residual eligibility, never a removal or disposal grant.
use crate::{InvalidMessage, PartialBranchDisposalRequest};
type Result<T> = std::result::Result<T, InvalidMessage>;
use sha2::{Digest, Sha256};
fn hash(value: &impl Serialize) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}
use serde::{Deserialize, Serialize};
pub const PARTIAL_BRANCH_CLEANUP_CANDIDATE_BYTES: usize = 48 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialBranchCleanupCandidate {
    pub schema: u8,
    pub request: PartialBranchDisposalRequest,
    pub publication: crate::BranchPublication,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release: Option<crate::BranchReleaseTransition>,
    pub disposal_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PartialBranchCleanupCandidate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PartialBranchCleanupCandidate")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PartialBranchCleanupCandidate {
    pub fn validate(&self) -> Result<()> {
        crate::partial_branch_disposal::validate_context(
            &self.request,
            &self.publication,
            self.release.as_ref(),
        )?;
        if self.schema != 1
            || crate::wire::hex(&self.disposal_sha256, 64).is_err()
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len()
                > PARTIAL_BRANCH_CLEANUP_CANDIDATE_BYTES
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
            "smolbox-partial-branch-cleanup-candidate-v1",
            self.schema,
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
        serde_json::from_str(include_str!(
            "../fixtures/partial-branch-cleanup-candidate-v1.json"
        ))
        .unwrap()
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
        hello.epoch = row["candidate"]["publication"]["change"]["child_origin"]["intent"]["epoch"]
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
    fn operation(request: &PartialBranchDisposalRequest) -> Operation {
        Operation::QualifyPartialBranchCleanup {
            request: Box::new(request.clone()),
        }
    }
    fn admitted(hello: &Hello, request: &PartialBranchDisposalRequest) -> Session {
        let mut session = Session::new(hello.clone()).unwrap();
        session.approve(hello).unwrap();
        assert!(matches!(
            session
                .admit(ClientMessage::Request {
                    epoch: hello.epoch.clone(),
                    id: 1,
                    budget_ms: 30000,
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
    fn synthetic_candidates_bind_original_disposal_platform_epoch_zero_output_and_finite_control() {
        for row in rows() {
            let request: PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let candidate: PartialBranchCleanupCandidate =
                serde_json::from_value(row["candidate"].clone()).unwrap();
            candidate.matches_request(&request).unwrap();
            assert_eq!(serde_json::to_value(&candidate).unwrap(), row["candidate"]);
            let op = operation(&request);
            op.validate(30000).unwrap();
            assert!(op.validate(30001).is_err() && op.requires_branches());
            assert!(op.partial_disposal_request().is_none());
            assert!(op.capability() == Capability::Inspect);
            assert!(op.receipt() == Some(&request.collection_request.creation.source));
            assert!(op.branch_approval() == Some(&request.collection_request.creation.approval));
            let outcome = Outcome::PartialBranchCleanupCandidate {
                candidate: Box::new(candidate.clone()),
            };
            outcome.validate_for(2).unwrap();
            assert!(outcome.validate_for(1).is_err());
            let hello = hello(&row, &request);
            let mut session = admitted(&hello, &request);
            assert!(session.event(1, Stream::Stdout, b"unexpected").is_err());
            assert!(session.terminal(1, Outcome::Qualified).is_err());
            session.terminal(1, outcome).unwrap();
        }
    }
    #[test]
    fn crossed_context_and_valid_distinct_requests_cannot_acknowledge_residual_eligibility() {
        for row in rows() {
            let request: PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let candidate: PartialBranchCleanupCandidate =
                serde_json::from_value(row["candidate"].clone()).unwrap();
            let h = hello(&row, &request);
            for field in ["epoch", "platform", "request"] {
                let mut h = h.clone();
                let mut submitted = request.clone();
                if field == "epoch" {
                    h.epoch = "0".repeat(32);
                }
                if field == "platform" {
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
                if field == "request" {
                    submitted.operation_id = "other-disposal".into();
                    submitted.request_sha256 = submitted.digest().unwrap();
                }
                assert!(admitted(&h, &submitted)
                    .terminal(
                        1,
                        Outcome::PartialBranchCleanupCandidate {
                            candidate: Box::new(candidate.clone())
                        }
                    )
                    .is_err());
            }
            assert!(!format!("{candidate:?}").contains(&candidate.proof_sha256));
            let mut altered = row["candidate"].clone();
            altered["completion"] = serde_json::json!("resolved_absent");
            assert!(serde_json::from_value::<PartialBranchCleanupCandidate>(altered).is_err());
            assert!(
                serde_json::from_value::<PartialBranchDisposal>(row["candidate"].clone()).is_err()
            );
        }
    }
}
