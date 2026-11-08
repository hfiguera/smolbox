//! Positive child absence under original completed branch authority. This is a
//! fresh fenced observation, never SDK deletion or backing/dependency retirement.
mod partial;
mod unbooted;
pub use partial::{
    PartialBranchChildAbsence, PartialBranchChildAbsenceRequest, PARTIAL_BRANCH_ABSENCE_BYTES,
};
pub use unbooted::{
    UnbootedBranchChildAbsence, UnbootedBranchChildAbsenceRequest, UNBOOTED_BRANCH_ABSENCE_BYTES,
};

use crate::{BranchCompletion, CreationReceipt, Engine, Error, ErrorCode, ReadBudget, Result};
use serde::{Deserialize, Serialize};

pub const BRANCH_ABSENCE_BYTES: usize = 68 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchChildAbsenceRequest {
    pub completion: BranchCompletion,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for BranchChildAbsenceRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchChildAbsenceRequest")
            .finish_non_exhaustive()
    }
}
impl BranchChildAbsenceRequest {
    pub fn validate(&self) -> Result<()> {
        self.completion.validate()?;
        let mut origin = self.completion.child.clone();
        origin.material = None;
        crate::material::check_origin(&origin, &self.child)?;
        let material = self
            .child
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        material.validate()?;
        if !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || self.operation_id
                == self
                    .completion
                    .publication
                    .change
                    .child_origin
                    .intent
                    .child
                    .operation_id
            || (material.revision == 0 && material != &crate::material::root_proof(&origin)?)
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > BRANCH_ABSENCE_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}

/// Historical positive absence of this namespace and original enrollment. It
/// neither removes a dependency nor releases any backing accounting by itself.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchChildAbsence {
    pub schema: u8,
    pub request: BranchChildAbsenceRequest,
    pub proof_sha256: String,
}
impl std::fmt::Debug for BranchChildAbsence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchChildAbsence")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl BranchChildAbsence {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        if self.schema != 1
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > BRANCH_ABSENCE_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-branch-child-absence-v1",
            self.schema,
            &self.request,
        ))
    }
    fn issue(request: BranchChildAbsenceRequest) -> Result<Self> {
        let mut result = Self {
            schema: 1,
            request,
            proof_sha256: String::new(),
        };
        result.proof_sha256 = result.digest()?;
        result.validate()?;
        Ok(result)
    }
}

struct CurrentAbsence<'a> {
    plan: &'a crate::branch_boot::Plan,
    epoch: &'a crate::epoch::ActorEpoch,
    enrollment: &'a crate::epoch::BootEnrollment,
    database: &'a std::path::Path,
    database_identity: (u64, u64),
}
impl CurrentAbsence<'_> {
    fn verify(&self, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        self.plan.validate()?;
        let child = self.plan.publication.child();
        let collection = self.epoch.collect_enrolled(&child.name, self.enrollment)?;
        if collection.intent() != self.enrollment.intent()
            || collection.child() != self.enrollment.child()
            || self.epoch.identity() != self.plan.publication.change.child_origin.intent.epoch
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let absent = crate::sdk_compat::observe_absence_budget(
            self.database,
            self.database_identity,
            &child.name,
            budget,
            || {
                crate::host::unredirected(
                    self.plan
                        .child
                        .path
                        .parent()
                        .ok_or(Error::before(ErrorCode::Ownership))?,
                )?;
                match std::fs::symlink_metadata(&self.plan.child.path) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
                    Ok(_) => Ok(false),
                    Err(_) => Err(Error::before(ErrorCode::Io)),
                }
            },
        )?;
        if !absent {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()
    }
}

impl Engine {
    /// Fenced observation of an original completed child. It requires exact
    /// retained result/context, both original gates, original boot collection,
    /// current epoch quiescence and bounded SDK row/reservation/directory absence.
    /// No SDK mutation, ownership reconstruction, cache retirement or accounting
    /// release is performed. Repeated requests always recheck current absence.
    pub fn qualify_branch_child_absence(
        &self,
        request: &BranchChildAbsenceRequest,
        budget: &ReadBudget,
    ) -> Result<BranchChildAbsence> {
        budget.check()?;
        request.validate()?;
        request.child.validate(self.binding())?;
        self.domain.verify()?;
        self.verify_database_identity()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self
            .branch_retention
            .completed_context_exact(&request.completion)?;
        let source_name = &context.plan.publication.previous.name;
        let source_gate = self.observation_gate(source_name)?;
        let child_gate = self.observation_gate(&request.child.name)?;
        let _gates = crate::gate::lock_pair(
            (source_name, &source_gate),
            (&request.child.name, &child_gate),
        )
        .map_err(|()| Error::before(ErrorCode::Conflict))?;
        let epoch = self.collection_epoch()?;
        if !epoch.bound_to(self.binding())
            || self.runtime_pid(&request.child.name).is_some()
            || context._runtime.pid(&request.child.name).is_some()
            || self.owned_manager_busy(&request.child.name)?
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let absence = CurrentAbsence {
            plan: &context.plan,
            epoch,
            enrollment: &context.enrollment,
            database: &self.binding().database,
            database_identity: self.database_identity,
        };
        absence.verify(budget)?;
        let proof = BranchChildAbsence::issue(request.clone())?;
        absence.verify(budget)?;
        self.domain.verify()?;
        self.verify_database_identity()?;
        budget.check()?;
        Ok(proof)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch_boot::tests::{identity_model, IdentityModel};
    use std::time::Duration;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-child-absence-v1.json"
        ))
        .unwrap()
    }
    fn budget() -> ReadBudget {
        ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap()
    }
    fn absent<'a>(
        model: &'a IdentityModel,
        epoch: &'a crate::epoch::ActorEpoch,
    ) -> CurrentAbsence<'a> {
        CurrentAbsence {
            plan: &model.plan,
            epoch,
            enrollment: &model.enrollment,
            database: &model.engine.binding().database,
            database_identity: model.engine.database_identity,
        }
    }
    #[test]
    fn shared_held_initial_and_explicit_release_fixtures_have_exact_engine_algebra() {
        for row in rows() {
            let request: BranchChildAbsenceRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: BranchChildAbsence = serde_json::from_value(row["proof"].clone()).unwrap();
            request.validate().unwrap();
            proof.validate().unwrap();
            assert!(proof == BranchChildAbsence::issue(request.clone()).unwrap());
            assert!(!format!("{proof:?}").contains(&request.child.owner_token));
            for field in ["proof_sha256", "schema"] {
                let mut changed = row["proof"].clone();
                changed[field] = if field == "schema" {
                    serde_json::json!(2)
                } else {
                    serde_json::json!("0".repeat(64))
                };
                let changed: BranchChildAbsence = serde_json::from_value(changed).unwrap();
                assert!(changed.validate().is_err());
            }
        }
    }
    #[test]
    fn different_origin_unfenced_request_reused_creation_id_and_invalid_root_reject() {
        let request: BranchChildAbsenceRequest =
            serde_json::from_value(rows()[0]["request"].clone()).unwrap();
        let mut changed = request.clone();
        changed.child.owner_token = "0".repeat(64);
        assert!(changed.validate().is_err());
        let mut changed = request.clone();
        changed.quiesced = false;
        assert!(changed.validate().is_err());
        let mut changed = request.clone();
        changed.operation_id = changed
            .completion
            .publication
            .change
            .child_origin
            .intent
            .child
            .operation_id
            .clone();
        assert!(changed.validate().is_err());
        let mut changed = request.clone();
        changed.child.material.as_mut().unwrap().chain_sha256 = "0".repeat(64);
        assert!(changed.validate().is_err());
        let mut changed = request.clone();
        changed.child.material = None;
        assert!(changed.validate().is_err());
        let mut encoded = serde_json::to_value(request).unwrap();
        encoded["path"] = serde_json::json!("/foreign");
        assert!(serde_json::from_value::<BranchChildAbsenceRequest>(encoded).is_err());
    }
    #[test]
    fn namespace_absence_requires_original_epoch_collection_and_rows_reservations_and_directory() {
        let model = identity_model(true);
        assert!(absent(&model, &model.actors).verify(&budget()).is_err());
        model.engine.db.remove_vm(&model.record.name).unwrap();
        assert!(absent(&model, &model.actors).verify(&budget()).is_err());
        // Entirely synthetic private storage; no SDK/guest has been dispatched.
        std::fs::remove_dir_all(&model.plan.child.path).unwrap();
        absent(&model, &model.actors).verify(&budget()).unwrap();
        assert!(model
            .engine
            .db
            .reserve_vm_create(&model.record.name, "synthetic-reservation")
            .unwrap());
        assert!(absent(&model, &model.actors).verify(&budget()).is_err());
        model
            .engine
            .db
            .release_vm_create_reservation(&model.record.name, "synthetic-reservation")
            .unwrap();
        absent(&model, &model.actors).verify(&budget()).unwrap();
        let other = identity_model(true);
        assert!(absent(&model, &other.actors).verify(&budget()).is_err());
        std::fs::create_dir(&model.plan.child.path).unwrap();
        assert!(absent(&model, &model.actors).verify(&budget()).is_err());
        std::fs::remove_dir(&model.plan.child.path).unwrap();
        std::os::unix::fs::symlink("missing-target", &model.plan.child.path).unwrap();
        assert!(absent(&model, &model.actors).verify(&budget()).is_err());
    }
    #[test]
    fn cancellation_keeps_original_budget_and_no_registry_result_can_be_manufactured_from_fixture()
    {
        let model = identity_model(true);
        let request = BranchChildAbsenceRequest {
            completion: BranchCompletion {
                schema: 1,
                publication: model.plan.publication.clone(),
                child: model.plan.publication.child().clone(),
                identity_sha256: model.identity_sha256.clone(),
                held: true,
                release: None,
            },
            child: model.plan.publication.child().clone(),
            operation_id: "retire-child".into(),
            request_sha256: "d".repeat(64),
            quiesced: true,
        };
        request.validate().unwrap();
        request.child.validate(model.engine.binding()).unwrap();
        let before = model.engine.jobs.counts();
        assert!(model
            .engine
            .qualify_branch_child_absence(&request, &budget())
            .is_err());
        let cancel = crate::Cancellation::default();
        let work = ReadBudget::new(Duration::from_secs(30), cancel.clone()).unwrap();
        cancel.cancel();
        assert!(absent(&model, &model.actors).verify(&work).is_err());
        assert_eq!(model.engine.jobs.counts(), before);
        assert!(model
            .engine
            .db
            .get_vm(&model.record.name)
            .unwrap()
            .is_some());
        assert!(model.plan.child.path.exists());
    }
}
