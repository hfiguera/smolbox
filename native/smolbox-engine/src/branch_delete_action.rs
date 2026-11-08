//! Explicit fenced actions after original held-child collection. These cannot
//! be substituted for observational resolution, SDK replay or ownership recovery.
use crate::{
    BranchCompletion, BranchDeletionContinuation, BranchDeletionResolution, CreationReceipt,
    Engine, Error, ErrorCode, ReadBudget, Result,
};
use serde::{Deserialize, Serialize};
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
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for HeldBranchDeletionActionRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HeldBranchDeletionActionRequest")
            .field("action", &self.action)
            .finish_non_exhaustive()
    }
}
impl HeldBranchDeletionActionRequest {
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
                > crate::HELD_BRANCH_DELETION_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-held-child-delete-action-v1",
            self.action,
            &self.completion,
            &self.child,
            &self.operation_id,
            self.quiesced,
        ))
    }
    pub fn require_action(&self, action: HeldBranchDeletionAction) -> Result<()> {
        self.validate()?;
        if self.action != action {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn matches_continuation(&self, proof: &BranchDeletionContinuation) -> Result<()> {
        self.require_action(HeldBranchDeletionAction::Continue)?;
        proof.validate()?;
        if proof.child != self.child
            || proof.operation_id != self.operation_id
            || proof.request_sha256 != self.request_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub fn matches_cleanup(&self, proof: &BranchDeletionResolution) -> Result<()> {
        self.require_action(HeldBranchDeletionAction::Cleanup)?;
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
    /// Complete only the as-yet-unentered SDK delete step after original
    /// collection. Entered Deleting state never replays. No dependency/backing release.
    pub fn continue_held_branch_deletion_checked(
        &self,
        request: &HeldBranchDeletionActionRequest,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionContinuation> {
        budget.check()?;
        request.require_action(HeldBranchDeletionAction::Continue)?;
        request.child.validate(self.binding())?;
        let observation = self.continue_held_branch_deletion_with_completion(
            &request.child,
            (&request.operation_id, &request.request_sha256),
            request.quiesced,
            Some(&request.completion),
            budget,
        )?;
        if observation.state != crate::ObservedState::Missing {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let proof = self
            .held_branch_deletion_continuation_result(
                &request.child,
                (&request.operation_id, &request.request_sha256),
                &request.completion,
                budget,
            )
            .map_err(|error| Error::uncertain(error.code))?;
        request
            .matches_continuation(&proof)
            .map_err(|error| Error::uncertain(error.code))?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(proof)
    }
    /// Remove only original collected-child residuals after SDK row/reservation
    /// absence. No SDK shutdown/delete, process reconstruction or backing release.
    pub fn cleanup_held_branch_deletion_checked(
        &self,
        request: &HeldBranchDeletionActionRequest,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionResolution> {
        budget.check()?;
        request.require_action(HeldBranchDeletionAction::Cleanup)?;
        request.child.validate(self.binding())?;
        let proof = self.cleanup_held_branch_deletion_with_completion(
            &request.child,
            (&request.operation_id, &request.request_sha256),
            request.quiesced,
            Some(&request.completion),
            budget,
        )?;
        request
            .matches_cleanup(&proof)
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
            "../../smolbox-protocol/fixtures/held-branch-deletion-action-v1.json"
        ))
        .unwrap()
    }
    #[test]
    fn shared_actions_bind_distinct_request_and_proof_domains_without_exposing_authority() {
        for row in rows() {
            let request: HeldBranchDeletionActionRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            request.validate().unwrap();
            assert!(!format!("{request:?}").contains(&request.child.owner_token));
            match request.action {
                HeldBranchDeletionAction::Continue => {
                    let proof: BranchDeletionContinuation =
                        serde_json::from_value(row["proof"].clone()).unwrap();
                    request.matches_continuation(&proof).unwrap();
                    assert!(!format!("{proof:?}").contains(&request.child.owner_token));
                    let crossed: BranchDeletionResolution =
                        serde_json::from_value(row["proof"].clone()).unwrap();
                    assert!(crossed.validate().is_err());
                    assert!(request.matches_cleanup(&crossed).is_err());
                }
                HeldBranchDeletionAction::Cleanup => {
                    let proof: BranchDeletionResolution =
                        serde_json::from_value(row["proof"].clone()).unwrap();
                    request.matches_cleanup(&proof).unwrap();
                    let crossed: BranchDeletionContinuation =
                        serde_json::from_value(row["proof"].clone()).unwrap();
                    assert!(crossed.validate().is_err());
                    assert!(request.matches_continuation(&crossed).is_err());
                }
            }
            let mut switched = request.clone();
            switched.action = match request.action {
                HeldBranchDeletionAction::Continue => HeldBranchDeletionAction::Cleanup,
                HeldBranchDeletionAction::Cleanup => HeldBranchDeletionAction::Continue,
            };
            assert!(switched.validate().is_err());
            switched.request_sha256 = switched.digest().unwrap();
            switched.validate().unwrap();
            assert!(switched.require_action(request.action).is_err());
            let mut observational = serde_json::to_value(&request).unwrap();
            observational.as_object_mut().unwrap().remove("action");
            let observational: crate::HeldBranchDeletionRequest =
                serde_json::from_value(observational).unwrap();
            assert!(observational.validate().is_err());
            for mode in 0..4 {
                let mut bad = request.clone();
                match mode {
                    0 => bad.quiesced = false,
                    1 => bad.child.owner_token = "0".repeat(64),
                    2 => bad.child.material = None,
                    _ => {
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
                }
                bad.request_sha256 = bad.digest().unwrap();
                assert!(bad.validate().is_err());
            }
        }
    }
    #[test]
    fn checked_actions_reject_missing_original_context_and_cancellation_before_mutation() {
        // Private identity/row model only; no live manager, process or SDK action.
        let model = crate::branch_boot::tests::identity_model(true);
        let completion = BranchCompletion {
            schema: 1,
            publication: model.plan.publication.clone(),
            child: model.plan.publication.child().clone(),
            identity_sha256: model.identity_sha256.clone(),
            held: true,
            release: None,
        };
        let before = model.engine.jobs.counts();
        for action in [
            HeldBranchDeletionAction::Continue,
            HeldBranchDeletionAction::Cleanup,
        ] {
            let mut request = HeldBranchDeletionActionRequest {
                action,
                child: completion.child.clone(),
                completion: completion.clone(),
                operation_id: "explicit-delete-action".into(),
                request_sha256: String::new(),
                quiesced: true,
            };
            request.request_sha256 = request.digest().unwrap();
            request.validate().unwrap();
            let cancel = crate::Cancellation::default();
            let budget = ReadBudget::new(Duration::from_secs(5), cancel.clone()).unwrap();
            for cancelled in [false, true] {
                if cancelled {
                    cancel.cancel();
                }
                let result = match action {
                    HeldBranchDeletionAction::Continue => model
                        .engine
                        .continue_held_branch_deletion_checked(&request, &budget)
                        .map(|_| ()),
                    HeldBranchDeletionAction::Cleanup => model
                        .engine
                        .cleanup_held_branch_deletion_checked(&request, &budget)
                        .map(|_| ()),
                };
                assert_eq!(result.unwrap_err().dispatch, crate::Dispatch::NotDispatched);
                assert_eq!(model.engine.jobs.counts(), before);
                assert!(model.plan.child.path.exists());
                assert_eq!(
                    crate::material::hash(&model.engine.record(&request.child).unwrap()).unwrap(),
                    crate::material::hash(&model.record).unwrap()
                );
            }
        }
    }
}
