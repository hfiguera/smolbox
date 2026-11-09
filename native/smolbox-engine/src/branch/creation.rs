//! One original branch creation workflow. A completed result is historical
//! evidence, never permission to replay entered work or reconstruct a manager.
use super::*;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchCreateRequest {
    pub source: CreationReceipt,
    pub child: BranchChildIntent,
    pub approval: BranchApproval,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_release: Option<crate::BranchReleaseRequest>,
}
impl std::fmt::Debug for BranchCreateRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchCreateRequest")
            .field("held", &self.child.hold)
            .finish_non_exhaustive()
    }
}
impl BranchCreateRequest {
    pub(super) fn validate(&self, engine: &Engine) -> Result<()> {
        self.source.validate(engine.binding())?;
        self.validate_declaration()
    }
    pub(crate) fn validate_declaration(&self) -> Result<()> {
        self.child.validate(&self.source)?;
        self.approval.validate()?;
        let material = self
            .source
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Validation))?;
        material.validate()?;
        if self.child.owner_token == self.source.owner_token
            || (material.revision == 0 && material.record_sha256 != self.source.material_sha256)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        match (self.child.hold, &self.initial_release) {
            (true, None) => Ok(()),
            (false, Some(request)) => {
                request.validate()?;
                if request.operation_id == self.child.operation_id {
                    return Err(Error::before(ErrorCode::Validation));
                }
                Ok(())
            }
            _ => Err(Error::before(ErrorCode::Validation)),
        }
    }
    pub(super) fn matches(&self, completion: &crate::BranchCompletion) -> Result<()> {
        completion.validate()?;
        let intent = &completion.publication.change.child_origin.intent;
        if completion.publication.previous != self.source
            || intent.child != self.child
            || intent.approval != self.approval
            || completion.held != self.child.hold
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        match (&self.initial_release, &completion.release) {
            (None, None) => Ok(()),
            (Some(expected), Some(actual))
                if actual.change.mode == crate::branch_release::Mode::Initial
                    && actual.change.request == *expected =>
            {
                Ok(())
            }
            _ => Err(Error::before(ErrorCode::Conflict)),
        }
    }
}
// Only the registry supplies production candidates; tests use private result
// models without constructing a native manager or granting ownership.
pub(super) fn select_completion<'a>(
    request: &BranchCreateRequest,
    candidates: impl IntoIterator<Item = &'a crate::BranchCompletion>,
    budget: &ReadBudget,
) -> Result<Option<crate::BranchCompletion>> {
    let mut found = None;
    let mut origin = request.source.clone();
    origin.material = None;
    for candidate in candidates {
        budget.check()?;
        let intent = &candidate.publication.change.child_origin.intent;
        let collision = intent.child.name == request.child.name
            || (intent.child.operation_id == request.child.operation_id
                && crate::material::check_origin(&origin, &intent.source).is_ok());
        if !collision {
            continue;
        }
        request.matches(candidate)?;
        if found.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        found = Some(candidate.clone());
    }
    budget.check()?;
    Ok(found)
}
impl Engine {
    /// Original completed creation only. None proves no absence and grants no
    /// retry, child authority or capacity release. Never reads mutable SDK rows.
    pub fn inspect_branch_completion(
        &self,
        request: &BranchCreateRequest,
        budget: &ReadBudget,
    ) -> Result<Option<crate::BranchCompletion>> {
        budget.check()?;
        request.validate(self)?;
        self.domain.verify()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let completed = self.branch_retention.completed_results(request, budget)?;
        self.domain.verify()?;
        budget.check()?;
        Ok(completed)
    }
    /// Create and hand off exactly one owned branch using the retained engine
    /// workflow. The bridge must reserve public child-plus-extra capacity before
    /// calling this; native backing admission never replaces that reservation.
    pub fn create_branch(
        &self,
        request: &BranchCreateRequest,
        budget: &ReadBudget,
    ) -> Result<crate::BranchCompletion> {
        if let Some(completed) = self.inspect_branch_completion(request, budget)? {
            return Ok(completed);
        }
        let prepared = self.prepare_initial_branch(
            &request.source,
            &request.child,
            &request.approval,
            budget,
        )?;
        // After intent publication even a failed acknowledgement must preserve
        // uncertainty. Original protected pending state/gates exclude replay.
        let finish = || -> Result<crate::BranchCompletion> {
            let retained = prepared
                .persist_intent(self)?
                .prepare_sdk_worker(self)?
                .retain_creation(self, request)?;
            retained.prepare_fork(self)?;
            // Initialization publishes material and boots only this original
            // retained child. It never falls back to a convenience SDK fork.
            retained.initialize_child(self)?;
            if let Some(release) = &request.initial_release {
                retained.release_child(self, release)?;
            }
            let completed = retained.finish_child(self)?;
            request.matches(&completed)?;
            budget.check()?;
            Ok(completed)
        };
        finish().map_err(|e| Error::uncertain(e.code))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch_boot::tests::{identity_model, IdentityModel};
    use std::time::Duration;

    fn budget() -> ReadBudget {
        ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
    }
    fn model(hold: bool) -> (IdentityModel, BranchCreateRequest, crate::BranchCompletion) {
        let model = identity_model(hold);
        let intent = &model.plan.publication.change.child_origin.intent;
        let request = BranchCreateRequest {
            source: intent.source.clone(),
            child: intent.child.clone(),
            approval: intent.approval.clone(),
            initial_release: if hold {
                None
            } else {
                Some(crate::BranchReleaseRequest {
                    operation_id: "initial-release".into(),
                    request_sha256: "d".repeat(64),
                })
            },
        };
        request.validate(&model.engine).unwrap();
        // Typed completed-result model only. No agent exchange or SDK dispatch.
        let release = request.initial_release.as_ref().map(|release| {
            crate::branch_release::Intent::issue(
                &model.plan.publication,
                &model.record,
                &model.enrollment,
                &model.identity_sha256,
                release,
            )
            .unwrap()
            .transition
        });
        let result = crate::BranchCompletion {
            schema: 1,
            publication: model.plan.publication.clone(),
            child: release.as_ref().map_or_else(
                || model.plan.publication.child().clone(),
                |release| release.receipt.clone(),
            ),
            identity_sha256: model.identity_sha256.clone(),
            held: hold,
            release,
        };
        result.validate().unwrap();
        (model, request, result)
    }
    #[test]
    fn creation_freezes_exact_hold_or_distinct_initial_activation_before_any_admission() {
        for hold in [false, true] {
            let (model, request, _) = model(hold);
            let counts = model.engine.jobs.counts();
            let release = crate::BranchReleaseRequest {
                operation_id: "initial-release".into(),
                request_sha256: "d".repeat(64),
            };
            let mut crossed = request.clone();
            crossed.initial_release = if hold { Some(release.clone()) } else { None };
            assert!(model.engine.create_branch(&crossed, &budget()).is_err());
            crossed = request.clone();
            crossed.child.owner_token = crossed.source.owner_token.clone();
            assert!(model.engine.create_branch(&crossed, &budget()).is_err());
            crossed = request.clone();
            crossed.source.material = None;
            assert!(model.engine.create_branch(&crossed, &budget()).is_err());
            crossed = request.clone();
            crossed.child.hold = false;
            crossed.initial_release = Some(crate::BranchReleaseRequest {
                operation_id: crossed.child.operation_id.clone(),
                ..release
            });
            assert!(model.engine.create_branch(&crossed, &budget()).is_err());
            assert_eq!(model.engine.jobs.counts(), counts);
        }
    }
    #[test]
    fn completed_lookup_preserves_held_and_initially_released_creation_kinds() {
        for hold in [false, true] {
            let (_model, request, completed) = model(hold);
            let actual = select_completion(&request, [&completed], &budget())
                .unwrap()
                .unwrap();
            assert_eq!(actual, completed);
            assert_eq!(actual.held, hold);
            assert_eq!(actual.release.is_none(), hold);
            if let Some(release) = actual.release {
                assert!(release.change.mode == crate::branch_release::Mode::Initial);
                assert_ne!(release.previous, release.receipt);
            }
        }
    }
    #[test]
    fn result_correlation_rejects_changed_source_child_policy_or_activation_without_replay() {
        let (model, request, completed) = model(false);
        for field in 0..8 {
            let mut changed = request.clone();
            match field {
                0 => changed.source = completed.publication.receipt.clone(),
                1 => changed.child.owner_token = "e".repeat(64),
                2 => changed.child.incarnation = "f".repeat(32),
                3 => changed.child.hold = true,
                4 => changed.approval.resources.disk_gb += 1,
                5 => changed.approval.host_overhead_mb += 1,
                6 => changed.initial_release.as_mut().unwrap().request_sha256 = "e".repeat(64),
                _ => {
                    changed.initial_release.as_mut().unwrap().operation_id =
                        "another-release".into()
                }
            }
            assert!(select_completion(&changed, [&completed], &budget()).is_err());
        }
        let mut unknown = request;
        unknown.child.name = "another-leaf".into();
        unknown.child.operation_id = "new-operation".into();
        unknown.validate(&model.engine).unwrap();
        assert!(select_completion(&unknown, [&completed], &budget())
            .unwrap()
            .is_none());
    }
    #[test]
    fn duplicate_or_corrupt_completion_cannot_supply_an_arbitrary_original_result() {
        let (_model, request, completed) = model(true);
        assert!(select_completion(&request, [&completed, &completed], &budget()).is_err());
        let mut corrupt = completed;
        corrupt.identity_sha256 = "invalid".into();
        assert!(select_completion(&request, [&corrupt], &budget()).is_err());
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(select_completion(&request, [], &cancelled).is_err());
    }
    #[test]
    fn empty_original_registry_lookup_is_readonly_during_quarantine_and_never_proves_absence() {
        let (model, request, _) = model(true);
        let pool = &model.engine.jobs;
        let mut creation = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
        creation.promote_branch_preparation().unwrap();
        creation.promote_branch_backing(7 << 30).unwrap();
        let backing = creation.handoff_branch().unwrap();
        drop(creation);
        let work = pool.acquire(crate::jobs::Demand::branch_delete()).unwrap();
        let observer = pool
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        pool.quarantine(); // Counter model only, not a live owner failure.
        let counts = pool.counts();
        let source =
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap();
        assert!(model
            .engine
            .inspect_branch_completion(&request, &budget())
            .unwrap()
            .is_none());
        assert_eq!(pool.counts(), counts);
        assert!(model.plan.child.path.exists());
        assert_eq!(
            std::fs::read(model.plan.source.path.join("smolbox.material-v2.json")).unwrap(),
            source
        );
        assert!(!pool.available());
        drop((work, observer, backing)); // Pure bookkeeping teardown.
    }
    #[test]
    fn cancellation_or_unowned_current_source_cannot_start_creation_or_change_material() {
        let (model, request, _) = model(true);
        let source_path = model.plan.source.path.join("smolbox.material-v2.json");
        let child_path = model.plan.child.path.join("smolbox.material-v2.json");
        let before = (
            std::fs::read(&source_path).unwrap(),
            std::fs::read(&child_path).unwrap(),
        );
        let counts = model.engine.jobs.counts();
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(model.engine.create_branch(&request, &cancelled).is_err());
        // The private model has no actual original source manager/enrollment.
        let failure = model.engine.create_branch(&request, &budget()).unwrap_err();
        assert_eq!(failure.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(model.engine.jobs.counts(), counts);
        assert_eq!(
            (
                std::fs::read(source_path).unwrap(),
                std::fs::read(child_path).unwrap()
            ),
            before
        );
        assert!(model
            .engine
            .inspect_branch_completion(&request, &budget())
            .unwrap()
            .is_none());
    }
}
