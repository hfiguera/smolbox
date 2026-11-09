//! Checked original-result boundary for explicit native backing accounting.
//! Expected material heads correlate with durable caller state; absence cannot
//! prove that a supplied head previously existed. No filesystem or SDK deletion.
use crate::{
    BranchBackingRelease, BranchCompletion, CreationReceipt, Engine, Error, ErrorCode, ReadBudget,
    Result,
};
use serde::{Deserialize, Serialize};
mod partial;
mod unbooted;
pub use partial::PartialBranchBackingReleaseRequest;
pub use unbooted::UnbootedBranchBackingReleaseRequest;

pub const BRANCH_BACKING_REQUEST_BYTES: usize = 80 * 1024;
pub const BRANCH_BACKING_PROOF_BYTES: usize = 68 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchBackingReleaseRequest {
    pub completion: BranchCompletion,
    pub source: CreationReceipt,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
    pub backing_removed: bool,
}
impl std::fmt::Debug for BranchBackingReleaseRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchBackingReleaseRequest")
            .finish_non_exhaustive()
    }
}
impl BranchBackingReleaseRequest {
    pub fn validate(&self) -> Result<()> {
        self.completion.validate()?;
        for (expected, current) in [
            (&self.completion.publication.receipt, &self.source),
            (&self.completion.child, &self.child),
        ] {
            let mut origin = expected.clone();
            origin.material = None;
            crate::material::check_origin(&origin, current)?;
            let material = current
                .material
                .as_ref()
                .ok_or(Error::before(ErrorCode::Ownership))?;
            material.validate()?;
            let before = expected
                .material
                .as_ref()
                .ok_or(Error::before(ErrorCode::Ownership))?;
            if material.revision < before.revision
                || (material.revision == before.revision && material != before)
                || (material.revision == 0 && material != &crate::material::root_proof(&origin)?)
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        if !self.quiesced
            || !self.backing_removed
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id
                == self
                    .completion
                    .publication
                    .change
                    .child_origin
                    .intent
                    .child
                    .operation_id
            || self
                .completion
                .release
                .as_ref()
                .is_some_and(|release| release.change.request.operation_id == self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > BRANCH_BACKING_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-branch-backing-request-v1",
            &self.completion,
            &self.source,
            &self.child,
            &self.operation_id,
            self.quiesced,
            self.backing_removed,
        ))
    }
    pub fn matches(&self, proof: &BranchBackingRelease) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if proof.publication != self.completion.publication
            || proof.operation_id != self.operation_id
            || proof.request_sha256 != self.request_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Engine {
    /// Release only the original completed branch's charge. The caller must
    /// durably retain this exact request before dispatch and bind expected heads
    /// to its tombstones. Missing original context never permits re-enrollment.
    pub fn release_branch_backing_checked(
        &self,
        request: &BranchBackingReleaseRequest,
        budget: &ReadBudget,
    ) -> Result<BranchBackingRelease> {
        budget.check()?;
        request.validate()?;
        request.source.validate(self.binding())?;
        request.child.validate(self.binding())?;
        self.branch_retention
            .completed_context_exact(&request.completion)?;
        let proof = self.release_branch_backing_with_completion(
            &request.child,
            (&request.operation_id, &request.request_sha256),
            (request.quiesced, request.backing_removed),
            Some(&request.completion),
            budget,
        )?;
        request
            .matches(&proof)
            .map_err(|error| Error::uncertain(error.code))?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(proof)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-backing-release-v1.json"
        ))
        .unwrap()
    }
    #[test]
    fn shared_request_digest_proof_charge_and_original_result_match_exactly() {
        for row in rows() {
            let request: BranchBackingReleaseRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchBackingRelease = serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            assert!(!format!("{request:?}").contains(&request.child.owner_token));
            assert!(!format!("{proof:?}").contains(&request.child.owner_token));
            let mut wrong = proof.clone();
            wrong.native_bytes += 1;
            assert!(request.matches(&wrong).is_err());
            let mut wrong = proof.clone();
            wrong.operation_id = "different-release".into();
            assert!(request.matches(&wrong).is_err());
            let mut wrong = proof;
            wrong.proof_sha256 = "0".repeat(64);
            assert!(request.matches(&wrong).is_err());
        }
    }
    #[test]
    fn confirmations_heads_origin_completion_and_request_id_are_bound_before_entry() {
        let request: BranchBackingReleaseRequest =
            serde_json::from_value(rows()[0]["request"].clone()).unwrap();
        for mode in 0..9 {
            let mut wrong = request.clone();
            match mode {
                0 => wrong.quiesced = false,
                1 => wrong.backing_removed = false,
                2 => wrong.source.owner_token = "0".repeat(64),
                3 => wrong.child.incarnation = "0".repeat(32),
                4 => wrong.completion.identity_sha256 = "0".repeat(64),
                5 => wrong.source = wrong.completion.publication.previous.clone(),
                6 => wrong.child.material.as_mut().unwrap().chain_sha256 = "0".repeat(64),
                7 => {
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
                _ => wrong.request_sha256 = "0".repeat(64),
            }
            assert!(wrong.validate().is_err());
            wrong.request_sha256 = wrong.digest().unwrap();
            if mode != 4 && mode != 8 {
                assert!(wrong.validate().is_err());
            }
        }
        for field in ["pid", "path", "native_bytes"] {
            let mut raw = serde_json::to_value(&request).unwrap();
            raw[field] = serde_json::json!(1);
            assert!(serde_json::from_value::<BranchBackingReleaseRequest>(raw).is_err());
        }
    }
    #[test]
    fn missing_original_registry_and_canceled_budget_preserve_native_admission() {
        let model = crate::branch_boot::tests::identity_model(true);
        let completion = BranchCompletion {
            schema: 1,
            publication: model.plan.publication.clone(),
            child: model.plan.publication.child().clone(),
            identity_sha256: model.identity_sha256.clone(),
            held: true,
            release: None,
        };
        let mut request = BranchBackingReleaseRequest {
            source: completion.publication.receipt.clone(),
            child: completion.child.clone(),
            completion,
            operation_id: "release-backing".into(),
            request_sha256: String::new(),
            quiesced: true,
            backing_removed: true,
        };
        request.request_sha256 = request.digest().unwrap();
        request.validate().unwrap();
        let before = model.engine.jobs.counts();
        let cancel = crate::Cancellation::default();
        let budget = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
        let failure = model
            .engine
            .release_branch_backing_checked(&request, &budget)
            .unwrap_err();
        assert_eq!(failure.dispatch, crate::Dispatch::NotDispatched);
        cancel.cancel();
        assert!(model
            .engine
            .release_branch_backing_checked(&request, &budget)
            .is_err());
        assert_eq!(model.engine.jobs.counts(), before);
        assert!(model.plan.child.path.exists());
        assert!(model
            .engine
            .db
            .get_vm(&model.record.name)
            .unwrap()
            .is_some());
    }
}
