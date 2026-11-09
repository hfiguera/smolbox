//! Terminal handoff after positively collected pre-handoff disposal. Keep the
//! original acknowledgement, runtime/domain and backing; release only transient
//! work and gates. No completed child or never-booted proof is manufactured.
use super::*;
use std::os::unix::fs::MetadataExt;
pub(super) mod absence;
pub(super) mod backing;
mod terminal;
pub(super) mod unneeded;
mod unused_absence;

pub(in crate::branch::retention) enum CleanupHandoff {
    Unavailable,
    NeverEnrolled,
    EnrolledUnattempted { request_sha256: String },
}
impl CleanupHandoff {
    fn permits(&self, request: &crate::PartialBranchDisposalCleanupRequest) -> Result<bool> {
        match self {
            Self::Unavailable => Ok(false),
            Self::NeverEnrolled => Ok(true),
            Self::EnrolledUnattempted { request_sha256 }
                if *request_sha256 == request.request_sha256 =>
            {
                Ok(true)
            }
            Self::EnrolledUnattempted { .. } => Err(Error::before(ErrorCode::Conflict)),
        }
    }
}

pub(in crate::branch::retention) struct DisposedPartialChild {
    proof: PartialBranchDisposal,
    runtime: Arc<smolvm::embedded::EmbeddedRuntime>,
    domain: Arc<crate::domain::DomainGuard>,
    // Keep the original opaque actor token for later explicit child-absence or
    // backing closeout. Historical proof reads do not re-observe that actor.
    enrollment: Arc<crate::epoch::BootEnrollment>,
    // Positive original cache provenance captured at handoff. Missing files
    // or an empty SDK namespace cannot manufacture an unused cleanup fact.
    cleanup: CleanupHandoff,
    unneeded: Option<unneeded::RetainedUnneeded>,
    pub(in crate::branch::retention) backing: crate::jobs::BranchBackingLease,
    pub(in crate::branch::retention) jobs: crate::jobs::JobPool,
}
impl DisposedPartialChild {
    fn saved(&self, engine: &Engine) -> Result<PartialBranchDisposal> {
        self.record(engine)?;
        Ok(self.proof.clone())
    }
    fn record(&self, engine: &Engine) -> Result<Record> {
        self.record_for(&engine.runtime, &engine.domain)
    }
    fn record_for(
        &self,
        runtime: &Arc<smolvm::embedded::EmbeddedRuntime>,
        domain: &Arc<crate::domain::DomainGuard>,
    ) -> Result<Record> {
        if !Arc::ptr_eq(&self.runtime, runtime) || !Arc::ptr_eq(&self.domain, domain) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let ledger = Ledger::new(
            self.domain.clone(),
            &self.proof.request.collection_request.creation,
        )?;
        let (record, version) = ledger.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if record.proof.as_ref() != Some(&self.proof) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        ledger.synchronize(&version)?;
        Ok(record)
    }
}
impl RetainedBranchResolution {
    /// Hand off only the original collected and durably disposed job. This
    /// releases transient work/source gates before fresh public observation,
    /// retaining dependency/backing history independently of those gates.
    pub fn finish_partial_branch_disposal(
        &self,
        engine: &Engine,
        proof: &PartialBranchDisposal,
    ) -> Result<PartialBranchDisposal> {
        let epoch = engine.collection_epoch()?;
        if !epoch.bound_to(engine.binding())
            || epoch.identity() != proof.publication.change.child_origin.intent.epoch
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.archive_partial_checked(engine, proof, |work, intent| {
            self.original_partial_handoff(work, intent, epoch)
        })
    }

    fn original_partial_handoff(
        &self,
        work: &Work,
        intent: &PartialDisposalIntent,
        epoch: &crate::epoch::ActorEpoch,
    ) -> Result<(Arc<crate::epoch::BootEnrollment>, CleanupHandoff)> {
        let boot = work
            .boot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if boot.partial_disposal_intent() != Some((intent, true))
            || boot.partial_disposal_plan().publication != intent.publication
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        boot.verify_partial_disposal_owner(&intent.request, epoch, &self.budget)?;
        let enrollment = boot
            .enrollment()
            .cloned()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        Ok((enrollment, boot.partial_cleanup_handoff()?))
    }
    // The production wrapper supplies original-manager/enrollment facts. Inert
    // tests supply actor projections and never construct an SDK manager.
    pub(super) fn archive_partial_checked(
        &self,
        engine: &Engine,
        proof: &PartialBranchDisposal,
        collection: impl FnOnce(
            &Work,
            &PartialDisposalIntent,
        ) -> Result<(Arc<crate::epoch::BootEnrollment>, CleanupHandoff)>,
    ) -> Result<PartialBranchDisposal> {
        validate_budget(&self.budget)?;
        proof.validate()?;
        if proof.request.collection_request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        engine.verify_database_identity()?;
        let registry = self
            .original
            .registry
            .upgrade()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !Arc::ptr_eq(&registry, &engine.branch_retention)
            || !Arc::ptr_eq(&registry.domain, &engine.domain)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        registry.domain.verify()?;
        {
            let disposed = registry
                .partial_disposed
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if let Some(child) = disposed.get(&self.original.key) {
                if child.proof != *proof {
                    return Err(Error::before(ErrorCode::Conflict));
                }
                let saved = child.saved(engine)?;
                self.budget.check()?;
                return Ok(saved);
            }
        }
        let mut entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
        engine.require_unhanded_branch_child(&self.creation.child.name)?;
        let mut entries = registry
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut disposed = registry
            .partial_disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if Arc::strong_count(&entry) != 2
            || Arc::strong_count(&entry.ownership) != 1
            || !entries
                .get(&self.original.key)
                .is_some_and(|stored| Arc::ptr_eq(stored, &entry))
            || disposed.contains_key(&self.original.key)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
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
        let ledger = Ledger::new(registry.domain.clone(), &self.creation)?;
        let (record, version) = ledger.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if record.proof.as_ref() != Some(proof)
            || record.intent.metadata_sha256 != entry.expected.metadata_sha256
            || record.intent.source
                != Directory::capture(&entry.ownership.intent.guard.source_root)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let snapshot = work
            .snapshot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        snapshot._snapshot.verify()?;
        let child_info = snapshot
            ._child
            .descriptor()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        // The child directory was positively removed. Compare its retained
        // locator instead of reopening it or adopting a new occupant.
        if record.intent.child.path != snapshot._child.path()
            || (record.intent.child.device, record.intent.child.inode)
                != (child_info.dev(), child_info.ino())
            || record.intent.snapshot != Directory::capture(&snapshot._snapshot)?
            || record.intent.source_sha256 != crate::material::hash(&snapshot.source)?
            || proof.publication.change.child_origin.raw_child_sha256
                != crate::identity::material_hash(&snapshot.child)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let (enrollment, cleanup) = collection(&work, &record.intent)?;
        ledger.synchronize(&version)?;
        entry
            .ownership
            .intent
            .guard
            ._job
            .check_disposed_branch_handoff()?;
        self.budget.check()?;
        drop(work);
        drop(entries.remove(&self.original.key));
        let converted = Arc::get_mut(&mut entry)
            .and_then(|unique| Arc::get_mut(&mut unique.ownership))
            .ok_or(Error::before(ErrorCode::Conflict))
            .and_then(|ownership| ownership.intent.guard._job.handoff_disposed_branch());
        let backing = match converted {
            Ok(backing) => backing,
            Err(error) => {
                entries.insert(self.original.key.clone(), entry);
                return Err(error);
            }
        };
        disposed.insert(
            self.original.key.clone(),
            DisposedPartialChild {
                proof: proof.clone(),
                runtime: entry.ownership.intent.guard._runtime.clone(),
                domain: registry.domain.clone(),
                enrollment,
                cleanup,
                unneeded: None,
                backing,
                jobs: entry.ownership.jobs.clone(),
            },
        );
        // Original manager is already positively collected. Source publication,
        // snapshot, dependency history and backing remain; only transient
        // original job owners/spools/gates retire here.
        drop(entry);
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof.clone())
    }
}
impl Engine {
    /// Exact acknowledgement from this original runtime/domain's terminal
    /// archive. No current namespace observation, SDK replay or charge release.
    /// A missing archive proves neither absence nor authority to adopt a child.
    pub fn inspect_partial_branch_disposal(
        &self,
        request: &PartialBranchDisposalRequest,
        budget: &ReadBudget,
    ) -> Result<Option<PartialBranchDisposal>> {
        validate_budget(budget)?;
        request.validate()?;
        let creation = &request.collection_request.creation;
        creation.validate(self)?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        self.verify_database_identity()?;
        self.domain.verify()?;
        let disposed = self
            .branch_retention
            .partial_disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut result = None;
        for child in disposed.values() {
            budget.check()?;
            let original = &child.proof.request.collection_request.creation;
            if original.child.name != creation.child.name
                && !(original.source.name == creation.source.name
                    && original.child.operation_id == creation.child.operation_id)
            {
                continue;
            }
            if child.proof.request != *request || result.is_some() {
                return Err(Error::before(ErrorCode::Ownership));
            }
            result = Some(child.saved(self)?);
        }
        budget.check()?;
        Ok(result)
    }
}
