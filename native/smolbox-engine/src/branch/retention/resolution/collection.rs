//! Explicit bounded original child collection before lifecycle handoff.
use super::*;
use crate::{PartialBranchCollection, PartialBranchCollectionRequest};

impl RetainedBranchResolution {
    /// Read-only admission for a prospective original-child collection. This
    /// retains no request, collects no child and releases no reservation.
    pub fn inspect_partial_collection(
        &self,
        engine: &Engine,
        request: &PartialBranchCollectionRequest,
    ) -> Result<crate::PartialBranchCollectionCandidate> {
        validate_budget(&self.budget)?;
        request.validate()?;
        if request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.verify_epoch(engine)?;
        engine.binding().validate()?;
        engine.verify_database_identity()?;
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
        let epoch = engine.collection_epoch()?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        require_collectible(&work)?;
        let boot = work
            .boot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        engine.require_original_branch_handle(boot.collection_handle())?;
        let enrollment = boot
            .enrollment()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !enrollment
            .intent()
            .matches_epoch(&self.creation.child.name, epoch)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.budget.check()?;
        let platform = boot.inspect_partial_collection(request)?;
        let result = crate::PartialBranchCollectionCandidate::issue(
            request,
            &entry.ownership.intent.intent.epoch,
            platform,
        )?;
        self.budget.check()?;
        Ok(result)
    }
    /// Caller-fenced cleanup of this original job's enrolled child only. No SDK
    /// row changes, initialization, deletion, source cleanup or allowance release.
    pub fn collect_partial_child(
        &self,
        engine: &Engine,
        request: &PartialBranchCollectionRequest,
    ) -> Result<PartialBranchCollection> {
        validate_budget(&self.budget)?;
        request.validate()?;
        if request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.verify_epoch(engine)?;
        engine.binding().validate()?;
        engine.verify_database_identity()?;
        // The retained preparation already charges 24 descriptors. Four more
        // cover sequential database/journal/actor IO, leaving one observer.
        let control = engine
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
        let epoch = engine.collection_epoch()?.clone();
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        require_collectible(&work)?;
        let boot = work
            .boot
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let handle = boot.collection_handle().clone();
        engine.require_original_branch_handle(&handle)?;
        let enrolled = boot
            .enrollment()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !enrolled
            .intent()
            .matches_epoch(&self.creation.child.name, &epoch)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.budget.check()?;
        boot.prepare_partial_collection(request)?;
        let active = Arc::new(());
        work.worker = Arc::downgrade(&active);
        drop(work);
        let retained = entry.clone();
        let budget = self.budget.clone();
        let database = engine.binding().database.clone();
        let database_identity = engine.database_identity;
        let result = crate::oci_start::observe_owned(
            engine.jobs.clone(),
            self.budget.deadline,
            self.budget.cancel.clone(),
            move || {
                let _active = active;
                let _control = control;
                budget.check()?;
                crate::sdk_compat::validate_database_budget(&database, database_identity, &budget)?;
                let work = retained
                    .work
                    .lock()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                work.boot
                    .as_ref()
                    .ok_or(Error::uncertain(ErrorCode::Ownership))?
                    .collect_partial_child(&epoch, &budget)
            },
        )
        .map_err(|e| Error::uncertain(e.code))?;
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        request
            .matches(&result)
            .map_err(|e| Error::uncertain(e.code))?;
        engine
            .retire_collected_branch_handle(&handle)
            .map_err(|e| Error::uncertain(e.code))?;
        Ok(result)
    }
}

// The candidate and actual collection share the original-work boundary. The
// latter still rechecks enrollment and publishes its own protected fence.
fn require_collectible(work: &Work) -> Result<()> {
    if work.worker.upgrade().is_some()
        || work.prepared.is_some()
        || work.collected.is_some()
        || !matches!(
            work.phase,
            Phase::BootEntered
                | Phase::Booted
                | Phase::IdentityEntered
                | Phase::IdentityReady
                | Phase::ReleaseEntered
                | Phase::Released
        )
    {
        return Err(Error::before(ErrorCode::State));
    }
    Ok(())
}
