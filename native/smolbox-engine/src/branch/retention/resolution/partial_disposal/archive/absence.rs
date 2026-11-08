//! Fresh read-only absence from the exact original terminal archive. Disposal
//! history alone proves no current namespace absence or dependency retirement.
use super::*;
use crate::{PartialBranchChildAbsence, PartialBranchChildAbsenceRequest, PartialBranchCollection};

pub(in crate::branch::retention::resolution::partial_disposal) fn collected(
    epoch: &crate::epoch::ActorEpoch,
    record: &Record,
    enrollment: &crate::epoch::BootEnrollment,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check()?;
    let request = &record.intent.request;
    let name = &request.collection_request.creation.child.name;
    if epoch.identity() != record.intent.publication.change.child_origin.intent.epoch
        || !epoch.quiescent_for(name)?
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let collection = epoch.collect_enrolled(name, enrollment)?;
    if PartialBranchCollection::issue(
        &request.collection_request,
        &record.intent.publication,
        &collection,
    )? != request.collection
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    budget.check()
}

fn absent(engine: &Engine, record: &Record, budget: &ReadBudget) -> Result<()> {
    budget.check()?;
    let name = &record.intent.request.collection_request.creation.child.name;
    let directory = &record.intent.child.path;
    // Actual SmolBox ownership maps exclude a new handle/manager/boot. SDK
    // inventory is observed only through the bounded read-only schema adapter,
    // never through runtime.pid's unbudgeted persisted-row fallback.
    engine.require_unhanded_branch_child(name)?;
    if engine.vm_directory(name) != *directory
        || !crate::sdk_compat::observe_absence_budget(
            &engine.binding().database,
            engine.database_identity,
            name,
            budget,
            || {
                crate::host::unredirected(
                    directory
                        .parent()
                        .ok_or(Error::before(ErrorCode::Ownership))?,
                )?;
                match std::fs::symlink_metadata(directory) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
                    Ok(_) => Ok(false),
                    Err(_) => Err(Error::before(ErrorCode::Io)),
                }
            },
        )?
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    budget.check()
}

impl Engine {
    /// Observe fresh absence of this original collected/disposed pre-handoff
    /// child. The same archive/runtime/domain/ledger and opaque enrollment are
    /// required. The source may keep running. No SDK mutation, namespace cleanup,
    /// source dependency retirement or backing release occurs here.
    pub fn qualify_partial_branch_child_absence(
        &self,
        request: &PartialBranchChildAbsenceRequest,
        budget: &ReadBudget,
    ) -> Result<PartialBranchChildAbsence> {
        validate_budget(budget)?;
        request.validate()?;
        let epoch = self.collection_epoch()?;
        if !epoch.bound_to(self.binding()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.qualify_partial_child_absence(request, budget, |record, enrollment| {
            collected(epoch, record, enrollment, budget)
        })
    }

    // Private models use the same actor collector with an inert original epoch.
    // No manager is constructed or reconstructed from rows, names or paths.
    pub(in crate::branch::retention::resolution::partial_disposal) fn qualify_partial_child_absence(
        &self,
        request: &PartialBranchChildAbsenceRequest,
        budget: &ReadBudget,
        collection: impl Fn(&Record, &Arc<crate::epoch::BootEnrollment>) -> Result<()>,
    ) -> Result<PartialBranchChildAbsence> {
        validate_budget(budget)?;
        request.validate()?;
        request
            .disposal
            .request
            .collection_request
            .creation
            .source
            .validate(self.binding())?;
        self.verify_database_identity()?;
        self.domain.verify()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let (record, enrollment) = self.partial_disposal_context(&request.disposal)?;
        let source = &record
            .intent
            .request
            .collection_request
            .creation
            .source
            .name;
        let child = &record.intent.request.collection_request.creation.child.name;
        let source_gate = self.observation_gate(source)?;
        let child_gate = self.observation_gate(child)?;
        let _gates = crate::gate::lock_pair((source, &source_gate), (child, &child_gate))
            .map_err(|()| Error::before(ErrorCode::Conflict))?;
        collection(&record, &enrollment)?;
        absent(self, &record, budget)?;
        let proof = PartialBranchChildAbsence::issue(request.clone())?;
        collection(&record, &enrollment)?;
        absent(self, &record, budget)?;
        let (current, original) = self.partial_disposal_context(&request.disposal)?;
        if !Arc::ptr_eq(&original, &enrollment) || current.intent != record.intent {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.verify_database_identity()?;
        self.domain.verify()?;
        budget.check()?;
        Ok(proof)
    }

    pub(super) fn partial_disposal_context(
        &self,
        proof: &PartialBranchDisposal,
    ) -> Result<(Record, Arc<crate::epoch::BootEnrollment>)> {
        let disposed = self
            .branch_retention
            .partial_disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut matching = disposed.values().filter(|child| child.proof == *proof);
        let child = matching.next().ok_or(Error::before(ErrorCode::Ownership))?;
        if matching.next().is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok((child.record(self)?, child.enrollment.clone()))
    }
}
