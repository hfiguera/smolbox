//! Explicit original ready-result handoff. No SDK boot, initialization or agent
//! release is replayed, and a completed result never reconstructs manager ownership.
use super::*;

impl RetainedBranchResolution {
    /// Finish only already completed original initialization/release, with this
    /// token's captured finite budget. Original manager, enrollment, source/child
    /// gates and protected lifecycle must all still qualify. Transient work may
    /// retire; persistent branch backing stays charged.
    pub fn finish_ready_child(&self, engine: &Engine) -> Result<crate::BranchCompletion> {
        validate_budget(&self.budget)?;
        if let Some(completed) = self.original.completed(engine)? {
            self.creation.matches(&completed)?;
            return Ok(completed);
        }
        self.verify_epoch(engine)?;
        self.state_checked(engine)?;
        self.finish_ready_checked(engine)
    }

    fn finish_ready_checked(&self, engine: &Engine) -> Result<crate::BranchCompletion> {
        validate_budget(&self.budget)?;
        {
            let entry = self.original.entry(engine)?;
            verify_original(engine, &entry, &self.creation)?;
            let work = entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if !super::super::boot::handoff_ready(&work, true) {
                return Err(Error::before(ErrorCode::State));
            }
        }
        let completed = self
            .original
            .finish_child_under(engine, &self.budget, true)
            .map_err(|error| Error::uncertain(error.code))?;
        self.creation
            .matches(&completed)
            .map_err(|error| Error::uncertain(error.code))?;
        self.budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(completed)
    }
}
impl Engine {
    /// Explicitly qualify an original ready result under caller fencing and a
    /// fresh finite deadline. Historical completion returns without SDK work.
    /// None means no retained original; it never proves absence or grants replay.
    /// Earlier partial phases require their separate original-context operations.
    pub fn resolve_ready_branch_completion(
        &self,
        creation: &BranchCreateRequest,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<Option<crate::BranchCompletion>> {
        validate_budget(budget)?;
        creation.validate(self)?;
        validate_creation(creation)?;
        if !quiesced {
            return Err(Error::before(ErrorCode::Validation));
        }
        if let Some(completed) = self.inspect_branch_completion(creation, budget)? {
            return Ok(Some(completed));
        }
        let Some(original) = self.retain_branch_resolution(creation, true, budget)? else {
            return Ok(None);
        };
        original.finish_ready_child(self).map(Some)
    }
}

#[cfg(test)]
mod tests;
