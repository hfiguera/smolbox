//! Original-context eligibility before a fresh public cleanup grant. This never
//! creates/removes a cleanup grant, retries SDK deletion or reconstructs an owner.
use super::*;
use crate::{PartialBranchCleanupCandidate, PartialBranchCleanupState};

fn no_cleanup_record(engine: &Engine, creation: &crate::BranchCreateRequest) -> Result<()> {
    archive::unneeded::require_no_unneeded_history(engine, creation)?;
    if file(engine.domain.clone(), creation)?
        .read_record::<CleanupRecord>()?
        .is_some()
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

impl Engine {
    /// Select positive original residual eligibility or the original terminal
    /// disposal. Caller must retain its prior durable disposal request and
    /// quiescence. A candidate is no removal, SDK-entry or capacity-release grant.
    pub fn qualify_partial_branch_cleanup(
        &self,
        request: &crate::PartialBranchDisposalRequest,
        budget: &ReadBudget,
    ) -> Result<PartialBranchCleanupState> {
        validate_budget(budget)?;
        request.validate()?;
        if let Some(proof) = self.inspect_partial_branch_disposal(request, budget)? {
            let _control = self
                .jobs
                .acquire(crate::jobs::Demand::material_resolution())?;
            // Never adopt a missing public cleanup history from private files.
            no_cleanup_record(self, &request.collection_request.creation)?;
            budget.check()?;
            return Ok(PartialBranchCleanupState::Disposed {
                proof: Box::new(proof),
            });
        }
        let original = self
            .retain_branch_resolution(&request.collection_request.creation, true, budget)?
            .ok_or(Error::before(ErrorCode::State))?;
        original.qualify_partial_cleanup(self, request)
    }
}

impl RetainedBranchResolution {
    fn qualify_partial_cleanup(
        &self,
        engine: &Engine,
        request: &crate::PartialBranchDisposalRequest,
    ) -> Result<PartialBranchCleanupState> {
        self.verify_epoch(engine)?;
        let epoch = engine.collection_epoch()?;
        let result = self.qualify_partial_cleanup_checked(
            engine,
            request,
            epoch,
            |work, intent| {
                let boot = work
                    .boot
                    .as_ref()
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                if boot.partial_disposal_intent() != Some((intent, true))
                    || boot.partial_cleanup_started()
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                boot.verify_partial_disposal_owner(request, epoch, &self.budget)?;
                boot.enrollment()
                    .cloned()
                    .ok_or(Error::before(ErrorCode::Ownership))
            },
            |p, s, after| live_partial_source(engine, p, s, &self.budget, after),
        )?;
        if let PartialBranchCleanupState::Disposed { proof } = &result {
            // Source inspection cannot follow until the original transient gates
            // are positively handed off. Preserve both original provenances.
            self.finish_partial_branch_disposal(engine, proof)
                .map_err(|e| Error::uncertain(e.code))?;
        }
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(result)
    }

    // Inert models supply original opaque actor facts, never SDK manager objects.
    pub(in crate::branch::retention::resolution::partial_disposal) fn qualify_partial_cleanup_checked(
        &self,
        engine: &Engine,
        request: &crate::PartialBranchDisposalRequest,
        epoch: &crate::epoch::ActorEpoch,
        original: impl FnOnce(
            &Work,
            &PartialDisposalIntent,
        ) -> Result<Arc<crate::epoch::BootEnrollment>>,
        authority: impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
    ) -> Result<PartialBranchCleanupState> {
        validate_budget(&self.budget)?;
        request.validate()?;
        if request.collection_request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        engine.verify_database_identity()?;
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
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
        let ledger = Ledger::new(engine.domain.clone(), &self.creation)?;
        let (record, version) = ledger.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if record.intent.request != *request
            || record.intent.metadata_sha256 != entry.expected.metadata_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let enrollment = original(&work, &record.intent)?;
        no_cleanup_record(engine, &self.creation)?;
        collection(epoch, &record.intent, &enrollment, &self.budget)?;
        if let Some(proof) = record.proof {
            ledger.synchronize(&version)?;
            self.budget.check()?;
            return Ok(PartialBranchCleanupState::Disposed {
                proof: Box::new(proof),
            });
        }
        if record.stage != Stage::Entered {
            return Err(Error::before(ErrorCode::State));
        }
        engine.require_unhanded_branch_child(&self.creation.child.name)?;
        let snapshot = work
            .snapshot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        entry.ownership.intent.guard.source_root.verify()?;
        snapshot._snapshot.verify()?;
        let child = snapshot
            ._child
            .descriptor()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if Directory::capture(&entry.ownership.intent.guard.source_root)? != record.intent.source
            || Directory::capture(&snapshot._snapshot)? != record.intent.snapshot
            || snapshot._child.path() != record.intent.child.path
            || (child.dev(), child.ino()) != (record.intent.child.device, record.intent.child.inode)
            || crate::material::hash(&snapshot.source)? != record.intent.source_sha256
            || crate::identity::material_hash(&snapshot.child)?
                != record
                    .intent
                    .publication
                    .change
                    .child_origin
                    .raw_child_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        row_absent(
            &engine.binding().database,
            engine.database_identity,
            &record.intent,
            &self.budget,
        )?;
        let source =
            disposal::source_record(engine, &entry, &record.intent.publication, &self.budget)?;
        if crate::material::hash(&source)? != record.intent.source_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        authority(&record.intent.publication, &source, true)?;
        if absent(&record.intent.child.path)? {
            // Positive original absence resolves the existing disposal; it does
            // not manufacture a residual candidate or another cleanup intent.
            drop(work);
            let proof = self.finish_partial_disposal(
                engine,
                &entry,
                &record.intent,
                PartialBranchDisposalCompletion::ResolvedAbsent,
                &authority,
            )?;
            return Ok(PartialBranchCleanupState::Disposed {
                proof: Box::new(proof),
            });
        }
        let root = child_root(&record.intent)?;
        let parent = crate::export_source::Root::open(
            record
                .intent
                .child
                .path
                .parent()
                .ok_or(Error::before(ErrorCode::Ownership))?,
        )?;
        row_absent(
            &engine.binding().database,
            engine.database_identity,
            &record.intent,
            &self.budget,
        )?;
        collection(epoch, &record.intent, &enrollment, &self.budget)?;
        let after =
            disposal::source_record(engine, &entry, &record.intent.publication, &self.budget)?;
        if crate::material::hash(&after)? != record.intent.source_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        authority(&record.intent.publication, &after, true)?;
        engine.require_unhanded_branch_child(&self.creation.child.name)?;
        entry.ownership.intent.guard.source_root.verify()?;
        snapshot._snapshot.verify()?;
        root.verify()?;
        parent.verify()?;
        child_root(&record.intent)?;
        no_cleanup_record(engine, &self.creation)?;
        ledger.synchronize(&version)?;
        let candidate = PartialBranchCleanupCandidate::issue(
            request,
            &record.intent.publication,
            record.intent.release.as_ref(),
            crate::material::hash(&record.intent)?,
        )?;
        self.budget.check()?;
        Ok(PartialBranchCleanupState::Residual {
            candidate: Box::new(candidate),
        })
    }
}
