//! Explicit continuation of the original verified row/material publication.
//! No SDK fork, boot, initialization, activation or deletion is repeated.
use super::*;

impl RetainedBranchResolution {
    /// Finish only the exact original collected publication with this control's
    /// finite deadline. Original snapshot, worker output, source/child gates,
    /// current rows and protected pending publication still have to qualify.
    /// In a later inactive phase, return only its already recorded publication
    /// without changing that phase or entering the publisher again.
    /// The returned publication grants no child readiness or capacity release.
    pub fn publish_collected_material(&self, engine: &Engine) -> Result<crate::BranchPublication> {
        self.publish_checked(engine, |original, budget| {
            original.publish_material_with_budget(engine, budget)
        })
    }
    fn publish_checked(
        &self,
        engine: &Engine,
        publish: impl FnOnce(
            &RetainedBranchPreparation,
            &ReadBudget,
        ) -> Result<crate::BranchPublication>,
    ) -> Result<crate::BranchPublication> {
        validate_budget(&self.budget)?;
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        self.verify_epoch(engine)?;
        let publication = if matches!(
            self.state_checked(engine)?,
            BranchPreparationState::Collected | BranchPreparationState::MaterialPublished
        ) {
            publish(&self.original, &self.budget)?
        } else {
            self.recorded_material(engine)?
        };
        self.creation
            .matches_publication(&publication)
            .map_err(|error| Error::uncertain(error.code))?;
        self.budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(publication)
    }

    // Boot or explicit collection may advance the original job before its
    // material acknowledgement reaches the public store. Only read the exact
    // synchronized publication in these later phases. Calling the publisher
    // would either reject the phase or regress it to Published; it must never
    // reconstruct material, reenter SDK work, or grant lifecycle ownership.
    fn recorded_material(&self, engine: &Engine) -> Result<crate::BranchPublication> {
        let entry = self.original.entry(engine)?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if !matches!(
            work.phase,
            Phase::BootEntered
                | Phase::Booted
                | Phase::IdentityEntered
                | Phase::IdentityReady
                | Phase::ReleaseEntered
                | Phase::Released
        ) {
            return Err(Error::before(ErrorCode::State));
        }
        self.budget.check()?;
        let root = &entry.ownership.intent.guard.source_root;
        root.verify()?;
        let publication = crate::material::MaterialJournal::at(root.path())
            .completed_branch_publication(
                &self.creation.source,
                &self.creation.child.operation_id,
                &entry.ownership.intent.intent.request_sha256,
            )?
            .ok_or(Error::before(ErrorCode::State))?;
        self.budget.check()?;
        Ok(publication)
    }
}

#[cfg(test)]
mod tests;
