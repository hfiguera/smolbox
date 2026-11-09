//! Explicit original-context completion of an existing disposal after positive
//! absence, only for the exact enrolled cleanup whose publication never began.
//! No new cleanup/SDK grant, namespace removal or manager reconstruction.
use super::*;
use crate::PartialBranchDisposalCleanupRequest;
use std::os::unix::fs::MetadataExt;

impl RetainedBranchResolution {
    pub(super) fn resolve_unattempted_cleanup_absence(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalCleanupRequest,
    ) -> Result<Option<PartialBranchDisposal>> {
        self.verify_epoch(engine)?;
        self.unattempted_cleanup_absence_checked(
            engine,
            request,
            engine.collection_epoch()?,
            |work, intent| self.original_partial_handoff(work, intent, engine.collection_epoch()?),
            |publication, source, after| {
                live_partial_source(engine, publication, source, &self.budget, after)
            },
        )
    }

    pub(in crate::branch::retention::resolution::partial_disposal) fn unattempted_cleanup_absence_checked(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalCleanupRequest,
        epoch: &crate::epoch::ActorEpoch,
        original: impl Fn(
            &Work,
            &PartialDisposalIntent,
        ) -> Result<(Arc<crate::epoch::BootEnrollment>, CleanupHandoff)>,
        authority: impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
    ) -> Result<Option<PartialBranchDisposal>> {
        validate_budget(&self.budget)?;
        request.validate()?;
        if request.disposal_request.collection_request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // Source/snapshot descriptors remain charged to the retained work.
        // Journal, actor and SQLite readers are sequential, preserving one
        // ordinary observer beside this material control.
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        engine.verify_database_identity()?;
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
        let (record, _) = ledger.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if record.intent.request != request.disposal_request
            || record.intent.metadata_sha256 != entry.expected.metadata_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if record.proof.is_some() {
            return Ok(None);
        }
        if record.stage != Stage::Entered {
            return Err(Error::before(ErrorCode::State));
        }
        // Hold the original work lock across both observations and publication.
        // Never infer an unused grant from a missing file or a bare namespace.
        if !verify_unused_original(
            engine,
            request,
            &record.intent,
            &work,
            epoch,
            &self.budget,
            &original,
        )? {
            return Ok(None);
        }
        verify_retained_roots(&entry, &work, &record.intent)?;
        self.partial_disposal_absence_checked_work(
            engine,
            &entry,
            &work,
            &record.intent,
            &authority,
        )?;
        if !verify_unused_original(
            engine,
            request,
            &record.intent,
            &work,
            epoch,
            &self.budget,
            &original,
        )? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        verify_original(engine, &entry, &self.creation)?;
        verify_retained_roots(&entry, &work, &record.intent)?;
        self.partial_disposal_absence_checked_work(
            engine,
            &entry,
            &work,
            &record.intent,
            &authority,
        )?;
        // A callback can observe changing private state; recheck the exact cache
        // and history immediately before the existing protected publication.
        if !verify_unused_original(
            engine,
            request,
            &record.intent,
            &work,
            epoch,
            &self.budget,
            &original,
        )? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        verify_original(engine, &entry, &self.creation)?;
        verify_retained_roots(&entry, &work, &record.intent)?;
        self.publish_partial_disposal(
            engine,
            &record.intent,
            PartialBranchDisposalCompletion::ResolvedAbsent,
        )
        .map(Some)
        .map_err(|e| Error::uncertain(e.code))
    }
}

fn verify_unused_original(
    engine: &Engine,
    request: &PartialBranchDisposalCleanupRequest,
    intent: &PartialDisposalIntent,
    work: &Work,
    epoch: &crate::epoch::ActorEpoch,
    budget: &ReadBudget,
    original: &impl Fn(
        &Work,
        &PartialDisposalIntent,
    ) -> Result<(Arc<crate::epoch::BootEnrollment>, CleanupHandoff)>,
) -> Result<bool> {
    let (enrollment, cleanup) = original(work, intent)?;
    if !matches!(cleanup, CleanupHandoff::EnrolledUnattempted { .. }) {
        return Ok(false);
    }
    if !cleanup.permits(request)? {
        return Ok(false);
    }
    unneeded::require_no_unneeded_history(
        engine,
        &request.disposal_request.collection_request.creation,
    )?;
    let file = super::super::residual::file(
        engine.domain.clone(),
        &request.disposal_request.collection_request.creation,
    )?;
    match std::fs::symlink_metadata(file.path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        _ => return Err(Error::before(ErrorCode::Ownership)),
    }
    super::super::residual::collection(epoch, intent, &enrollment, budget)?;
    Ok(true)
}
fn verify_retained_roots(entry: &Entry, work: &Work, intent: &PartialDisposalIntent) -> Result<()> {
    entry.ownership.intent.guard.source_root.verify()?;
    let snapshot = work
        .snapshot
        .as_ref()
        .ok_or(Error::before(ErrorCode::Ownership))?;
    snapshot._snapshot.verify()?;
    let child = snapshot
        ._child
        .descriptor()
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    if Directory::capture(&entry.ownership.intent.guard.source_root)? != intent.source
        || Directory::capture(&snapshot._snapshot)? != intent.snapshot
        || snapshot._child.path() != intent.child.path
        || (child.dev(), child.ino()) != (intent.child.device, intent.child.inode)
        || crate::material::hash(&snapshot.source)? != intent.source_sha256
        || crate::identity::material_hash(&snapshot.child)?
            != intent.publication.change.child_origin.raw_child_sha256
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
