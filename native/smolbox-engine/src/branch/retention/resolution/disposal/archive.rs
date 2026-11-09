//! Terminal original-job handoff, distinct from guest completion or backing
//! release. The already synchronized disposal ledger remains acknowledgement
//! authority; the archive retains the same runtime/domain and persistent charge.
use super::*;
pub(super) mod absence;
pub(super) mod backing;

pub(in crate::branch::retention) struct DisposedChild {
    proof: UnbootedBranchDisposal,
    runtime: Arc<smolvm::embedded::EmbeddedRuntime>,
    domain: Arc<crate::domain::DomainGuard>,
    pub(in crate::branch::retention) backing: crate::jobs::BranchBackingLease,
    pub(in crate::branch::retention) jobs: crate::jobs::JobPool,
}
impl DisposedChild {
    fn saved(&self, engine: &Engine) -> Result<UnbootedBranchDisposal> {
        self.record(&engine.runtime, &engine.domain)?;
        Ok(self.proof.clone())
    }
    fn record(
        &self,
        runtime: &Arc<smolvm::embedded::EmbeddedRuntime>,
        domain: &Arc<crate::domain::DomainGuard>,
    ) -> Result<Record> {
        if !Arc::ptr_eq(&self.runtime, runtime) || !Arc::ptr_eq(&self.domain, domain) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let ledger = Ledger::new(self.domain.clone(), &self.proof.creation)?;
        let (record, version) = ledger.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if record.proof.as_ref() != Some(&self.proof) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        ledger.synchronize(&version)?;
        Ok(record)
    }
}
impl RetainedBranchResolution {
    /// Retire transient work/gates only after exact durable unbooted disposal.
    /// Retains native backing and the original SDK runtime/domain independently.
    /// Repeated acknowledgement performs no SDK call, deletion or re-enrollment.
    pub fn finish_unbooted_disposal(
        &self,
        engine: &Engine,
        proof: &UnbootedBranchDisposal,
    ) -> Result<UnbootedBranchDisposal> {
        if engine.observation_epoch().as_deref()
            != Some(&proof.publication.change.child_origin.intent.epoch)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.archive_checked(engine, proof)
    }
    pub(super) fn archive_checked(
        &self,
        engine: &Engine,
        proof: &UnbootedBranchDisposal,
    ) -> Result<UnbootedBranchDisposal> {
        validate_budget(&self.budget)?;
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        proof.validate()?;
        if proof.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
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
                .disposed
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
        let mut entries = registry
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut disposed = registry
            .disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if Arc::strong_count(&entry) != 2
            || !entries
                .get(&self.original.key)
                .is_some_and(|stored| Arc::ptr_eq(stored, &entry))
            || disposed.contains_key(&self.original.key)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.phase != Phase::Disposed
            || work.boot.is_some()
            || work.prepared.is_some()
            || work.worker.upgrade().is_some()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let snapshot = work
            .snapshot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let expected = intent(&entry, snapshot, &proof.publication, &proof.request)?;
        let ledger = Ledger::new(registry.domain.clone(), &self.creation)?;
        let (record, version) = ledger.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if record.intent != expected || record.proof.as_ref() != Some(proof) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        ledger.synchronize(&version)?;
        entry
            .ownership
            .intent
            .guard
            ._job
            .check_disposed_branch_handoff()?;
        self.budget.check()?;
        // The synchronized disposal now carries the original preparation and
        // publication evidence. Collected IPC output still retains its worker's
        // ownership lease; retire only those spools before requiring unique
        // ownership for the accounting transfer. The entry, gates, snapshot and
        // full job charge remain retained if a different owner blocks handoff.
        drop(work.collected.take());
        if Arc::strong_count(&entry.ownership) != 1 {
            return Err(Error::before(ErrorCode::Conflict));
        }
        drop(work);
        // No further native effect occurs. Conversion either retains the whole
        // original entry or transfers every backing byte to its archive owner.
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
            DisposedChild {
                proof: proof.clone(),
                runtime: entry.ownership.intent.guard._runtime.clone(),
                domain: registry.domain.clone(),
                backing,
                jobs: entry.ownership.jobs.clone(),
            },
        );
        // Drops only original collected spools, pinned roots and machine gates.
        // The source snapshot/journal and backing charge are not removed.
        drop(entry);
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof.clone())
    }
}
impl Engine {
    /// Exact historical acknowledgement from this original owner's disposed
    /// archive. A missing result proves no absence and grants no replay or
    /// backing release.
    /// Does not inspect current source/child paths or reconstruct an SDK owner.
    pub fn inspect_unbooted_branch_disposal(
        &self,
        creation: &BranchCreateRequest,
        request: &UnbootedBranchDisposalRequest,
        budget: &ReadBudget,
    ) -> Result<Option<UnbootedBranchDisposal>> {
        validate_budget(budget)?;
        creation.validate(self)?;
        request.validate(creation)?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        self.verify_database_identity()?;
        self.domain.verify()?;
        let disposed = self
            .branch_retention
            .disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut result = None;
        for child in disposed.values() {
            budget.check()?;
            let original = &child.proof.creation;
            let same_source = original.source.name == creation.source.name;
            if original.child.name != creation.child.name
                && !(same_source && original.child.operation_id == creation.child.operation_id)
            {
                continue;
            }
            if original != creation || child.proof.request != *request || result.is_some() {
                return Err(Error::before(ErrorCode::Ownership));
            }
            result = Some(child.saved(self)?);
        }
        budget.check()?;
        Ok(result)
    }
}
