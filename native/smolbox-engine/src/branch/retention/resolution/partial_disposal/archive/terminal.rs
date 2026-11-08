//! Select an already terminal original disposal first. A separate original-
//! context absence completion may precede handoff for an exact unused enrollment.
//! Terminal selection itself never derives authority from empty namespaces.
use super::*;
use crate::PartialBranchDisposalCleanupRequest;

impl RetainedBranchResolution {
    pub(super) fn recover_unneeded_partial_handoff(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalCleanupRequest,
    ) -> Result<Option<PartialBranchDisposal>> {
        self.verify_epoch(engine)?;
        let epoch = engine.collection_epoch()?;
        let proof = self.unneeded_terminal_checked(engine, request, epoch, |work, intent| {
            self.original_partial_handoff(work, intent, epoch)
        })?;
        let proof = match proof {
            Some(proof) => proof,
            None => match self.resolve_unattempted_cleanup_absence(engine, request)? {
                Some(proof) => proof,
                None => return Ok(None),
            },
        };
        // Revalidate original owner/cache facts at handoff, after the selection
        // control has retired. Never stack two control reservations.
        self.archive_partial_checked(engine, &proof, |work, intent| {
            let (enrollment, cleanup) = self.original_partial_handoff(work, intent, epoch)?;
            if !cleanup.permits(request)? {
                return Err(Error::before(ErrorCode::State));
            }
            Ok((enrollment, cleanup))
        })
        .map(Some)
    }

    pub(in crate::branch::retention::resolution::partial_disposal) fn unneeded_terminal_checked(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalCleanupRequest,
        epoch: &crate::epoch::ActorEpoch,
        original: impl FnOnce(
            &Work,
            &PartialDisposalIntent,
        ) -> Result<(Arc<crate::epoch::BootEnrollment>, CleanupHandoff)>,
    ) -> Result<Option<PartialBranchDisposal>> {
        validate_budget(&self.budget)?;
        request.validate()?;
        if request.disposal_request.collection_request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
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
        let Some(proof) = record.proof.as_ref() else {
            return Ok(None);
        };
        let (enrollment, cleanup) = original(&work, &record.intent)?;
        if !cleanup.permits(request)? {
            return Ok(None);
        }
        unneeded::require_no_unneeded_file(engine.domain.clone(), &self.creation)?;
        let cleanup_file = super::super::residual::file(engine.domain.clone(), &self.creation)?;
        match std::fs::symlink_metadata(&cleanup_file.path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            _ => return Err(Error::before(ErrorCode::Ownership)),
        }
        super::super::residual::collection(epoch, &record.intent, &enrollment, &self.budget)?;
        self.budget.check()?;
        Ok(Some(proof.clone()))
    }
}

#[cfg(test)]
mod tests;
