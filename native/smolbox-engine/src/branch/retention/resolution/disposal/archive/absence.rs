//! Fresh read-only child namespace checks from the original disposed archive.
use super::*;
use crate::{UnbootedBranchChildAbsence, UnbootedBranchChildAbsenceRequest};

pub(in crate::branch::retention::resolution::disposal) fn collected(
    epoch: &crate::epoch::ActorEpoch,
    record: &Record,
) -> Result<()> {
    let intent = &record.intent.publication.change.child_origin.intent;
    if epoch.identity() != intent.epoch || !epoch.quiescent_for(&intent.child.name)? {
        return Err(Error::before(ErrorCode::Conflict));
    }
    Ok(())
}
fn absent(engine: &Engine, record: &Record, budget: &ReadBudget) -> Result<()> {
    budget.check()?;
    let name = &record.intent.creation.child.name;
    let directory = &record.intent.child.path;
    if engine.runtime_pid(name).is_some()
        || engine.runtime.pid(name).is_some()
        || engine.owned_manager_busy(name)?
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
    /// Fresh absence of the original disposed, never-booted child. The source
    /// may remain running; no source collection, SDK mutation or charge release
    /// is performed. Original archive/domain/runtime/ledger and epoch are required.
    pub fn qualify_unbooted_branch_child_absence(
        &self,
        request: &UnbootedBranchChildAbsenceRequest,
        budget: &ReadBudget,
    ) -> Result<UnbootedBranchChildAbsence> {
        validate_budget(budget)?;
        request.validate()?;
        let epoch = self.collection_epoch()?;
        if !epoch.bound_to(self.binding()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.qualify_unbooted_child_absence(request, budget, |record| collected(epoch, record))
    }
    // Private models supply inert epoch facts. Production always uses the actual
    // original actor epoch, without enrolling or reconstructing a child manager.
    pub(in crate::branch::retention::resolution::disposal) fn qualify_unbooted_child_absence(
        &self,
        request: &UnbootedBranchChildAbsenceRequest,
        budget: &ReadBudget,
        collection: impl Fn(&Record) -> Result<()>,
    ) -> Result<UnbootedBranchChildAbsence> {
        validate_budget(budget)?;
        request.validate()?;
        request.disposal.creation.source.validate(self.binding())?;
        self.verify_database_identity()?;
        self.domain.verify()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let record = self.original_disposal_record(request)?;
        let source = &record.intent.creation.source.name;
        let child = &record.intent.creation.child.name;
        let source_gate = self.observation_gate(source)?;
        let child_gate = self.observation_gate(child)?;
        let _gates = crate::gate::lock_pair((source, &source_gate), (child, &child_gate))
            .map_err(|()| Error::before(ErrorCode::Conflict))?;
        collection(&record)?;
        absent(self, &record, budget)?;
        let proof = UnbootedBranchChildAbsence::issue(request.clone())?;
        collection(&record)?;
        absent(self, &record, budget)?;
        self.original_disposal_record(request)?;
        self.verify_database_identity()?;
        self.domain.verify()?;
        budget.check()?;
        Ok(proof)
    }
    fn original_disposal_record(
        &self,
        request: &UnbootedBranchChildAbsenceRequest,
    ) -> Result<Record> {
        let disposed = self
            .branch_retention
            .disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut matches = disposed
            .values()
            .filter(|child| child.proof == request.disposal);
        let child = matches.next().ok_or(Error::before(ErrorCode::Ownership))?;
        if matches.next().is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        child.record(&self.runtime, &self.domain)
    }
}
