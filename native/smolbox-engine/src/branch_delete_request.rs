//! Checked original-completion boundary for held-child deletion resolution.
//! This records positive absence; it never invokes SDK shutdown/delete or cleanup.
use crate::{
    BranchCompletion, BranchDeletionResolution, CreationReceipt, Engine, Error, ErrorCode,
    ReadBudget, Result,
};
use serde::{Deserialize, Serialize};
pub const HELD_BRANCH_DELETION_REQUEST_BYTES: usize = 68 * 1024;
pub const HELD_BRANCH_DELETION_PROOF_BYTES: usize = 4096;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HeldBranchDeletionRequest {
    pub completion: BranchCompletion,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for HeldBranchDeletionRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HeldBranchDeletionRequest")
            .finish_non_exhaustive()
    }
}
impl HeldBranchDeletionRequest {
    pub fn validate(&self) -> Result<()> {
        self.completion.validate()?;
        if !self.completion.held
            || self.completion.release.is_some()
            || self.child != self.completion.child
            || !self.quiesced
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
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > HELD_BRANCH_DELETION_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-held-child-delete-request-v1",
            &self.completion,
            &self.child,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn matches(&self, proof: &BranchDeletionResolution) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if proof.child != self.child
            || proof.operation_id != self.operation_id
            || proof.request_sha256 != self.request_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Engine {
    /// Resolve only a returned original held-child delete. Requires the retained
    /// completed context, original collection, caller fencing and positive bounded
    /// absence. Never reconstructs a manager or retries SDK/filesystem mutations.
    pub fn resolve_held_branch_deletion_checked(
        &self,
        request: &HeldBranchDeletionRequest,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionResolution> {
        budget.check()?;
        request.validate()?;
        request.child.validate(self.binding())?;
        let proof = self.resolve_held_branch_deletion_with_completion(
            &request.child,
            (&request.operation_id, &request.request_sha256),
            request.quiesced,
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
            "../../smolbox-protocol/fixtures/held-branch-deletion-v1.json"
        ))
        .unwrap()
    }
    #[test]
    fn shared_held_deletion_requests_and_positive_absence_proofs_match_exact_algebra() {
        for row in rows() {
            let request: HeldBranchDeletionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchDeletionResolution =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            assert!(!format!("{request:?}").contains(&request.child.owner_token));
            assert!(!format!("{proof:?}").contains(&request.child.owner_token));
            let mut wrong = proof.clone();
            wrong.deletion_sha256 = "0".repeat(64);
            assert!(request.matches(&wrong).is_err());
            let mut wrong = proof;
            wrong.proof_sha256 = "0".repeat(64);
            assert!(request.matches(&wrong).is_err());
        }
    }
    #[test]
    fn held_root_full_completion_request_fencing_and_original_creation_id_are_checked() {
        let request: HeldBranchDeletionRequest =
            serde_json::from_value(rows()[0]["request"].clone()).unwrap();
        for mode in 0..5 {
            let mut wrong = request.clone();
            match mode {
                0 => wrong.quiesced = false,
                1 => wrong.child.owner_token = "0".repeat(64),
                2 => wrong.completion.identity_sha256 = "0".repeat(64),
                3 => {
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
            if mode != 2 && mode != 4 {
                assert!(wrong.validate().is_err());
            }
        }
        let other: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-child-absence-v1.json"
        ))
        .unwrap();
        let initial: BranchCompletion =
            serde_json::from_value(other.last().unwrap()["request"]["completion"].clone()).unwrap();
        let mut wrong = request;
        wrong.child = initial.child.clone();
        wrong.completion = initial;
        wrong.request_sha256 = wrong.digest().unwrap();
        assert!(wrong.validate().is_err());
    }
    #[test]
    fn missing_original_context_and_cancellation_cannot_change_admission_or_delete_anything() {
        let model = crate::branch_boot::tests::identity_model(true);
        let completion = BranchCompletion {
            schema: 1,
            publication: model.plan.publication.clone(),
            child: model.plan.publication.child().clone(),
            identity_sha256: model.identity_sha256.clone(),
            held: true,
            release: None,
        };
        let mut request = HeldBranchDeletionRequest {
            child: completion.child.clone(),
            completion,
            operation_id: "resolve-held-delete".into(),
            request_sha256: String::new(),
            quiesced: true,
        };
        request.request_sha256 = request.digest().unwrap();
        request.validate().unwrap();
        let cancel = crate::Cancellation::default();
        let budget = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
        let before = model.engine.jobs.counts();
        assert_eq!(
            model
                .engine
                .resolve_held_branch_deletion_checked(&request, &budget)
                .unwrap_err()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        cancel.cancel();
        assert!(model
            .engine
            .resolve_held_branch_deletion_checked(&request, &budget)
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
