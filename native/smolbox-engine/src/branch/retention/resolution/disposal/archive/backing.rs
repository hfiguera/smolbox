//! Explicit accounting retirement, with no SDK cleanup or invented boot owner.
use super::*;
use crate::branch::retention::backing::Ledger as BackingLedger;
use crate::{BranchBackingRelease, UnbootedBranchBackingReleaseRequest};

pub(in crate::branch::retention::resolution::disposal) fn collected(
    epoch: &crate::epoch::ActorEpoch,
    record: &Record,
) -> Result<()> {
    let intent = &record.intent.publication.change.child_origin.intent;
    if epoch.identity() != intent.epoch
        || !epoch.quiescent_for(&intent.source.name)?
        || !epoch.quiescent_for(&intent.child.name)?
        || !crate::epoch::gone(crate::OwnerIdentity {
            pid: intent.source_pid.0,
            birth: intent.source_pid.1,
            uid: unsafe { libc::geteuid() },
        })?
    {
        return Err(Error::before(ErrorCode::Conflict));
    }
    Ok(())
}
fn absent(
    record: &Record,
    runtime: &smolvm::embedded::EmbeddedRuntime,
    database: &std::path::Path,
    identity: (u64, u64),
    budget: &ReadBudget,
) -> Result<()> {
    let intent = &record.intent;
    for (name, directory) in [
        (&intent.creation.source.name, &intent.source.path),
        (&intent.creation.child.name, &intent.child.path),
    ] {
        budget.check()?;
        if runtime.pid(name).is_some()
            || !crate::sdk_compat::observe_absence_budget(database, identity, name, budget, || {
                crate::host::unredirected(
                    directory
                        .parent()
                        .ok_or(Error::before(ErrorCode::Ownership))?,
                )?;
                Ok(matches!(std::fs::symlink_metadata(directory), Err(error)
                    if error.kind() == std::io::ErrorKind::NotFound))
            })?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    budget.check()
}
impl Engine {
    /// Retire only the original disposed child's native backing charge after
    /// explicit host removal confirmation and collected source/child absence.
    /// The caller must durably bind this exact request to its tombstones first.
    /// No SDK mutation, filesystem cleanup, manager or boot enrollment occurs.
    pub fn release_unbooted_branch_backing_checked(
        &self,
        request: &UnbootedBranchBackingReleaseRequest,
        budget: &ReadBudget,
    ) -> Result<BranchBackingRelease> {
        validate_budget(budget)?;
        request.validate()?;
        let epoch = self.collection_epoch()?.clone();
        if !epoch.bound_to(self.binding())
            || epoch.identity()
                != request
                    .disposal
                    .publication
                    .change
                    .child_origin
                    .intent
                    .epoch
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let proof = self
            .release_unbooted_backing(request, budget, move |record| collected(&epoch, record))?;
        request
            .matches(&proof)
            .map_err(|error| Error::uncertain(error.code))?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(proof)
    }
    // The production wrapper supplies original actor-collection authority;
    // private tests supply inert facts and never enroll a VM or SDK owner.
    pub(in crate::branch::retention::resolution::disposal) fn release_unbooted_backing(
        &self,
        request: &UnbootedBranchBackingReleaseRequest,
        budget: &ReadBudget,
        source_collected: impl FnOnce(&Record) -> Result<()> + Send + 'static,
    ) -> Result<BranchBackingRelease> {
        validate_budget(budget)?;
        request.validate()?;
        request.source.validate(self.binding())?;
        request.child.validate(self.binding())?;
        self.verify_database_identity()?;
        self.domain.verify()?;
        let control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        {
            let disposed = self
                .branch_retention
                .disposed
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            let mut matches = disposed
                .values()
                .filter(|entry| entry.proof == request.disposal);
            let entry = matches.next().ok_or(Error::before(ErrorCode::Ownership))?;
            if matches.next().is_some()
                || !Arc::ptr_eq(&entry.runtime, &self.runtime)
                || !Arc::ptr_eq(&entry.domain, &self.domain)
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        let source_gate = self.observation_gate(&request.source.name)?;
        let child_gate = self.observation_gate(&request.child.name)?;
        let gates = crate::gate::lock_pair(
            (&request.source.name, &source_gate),
            (&request.child.name, &child_gate),
        )
        .map_err(|()| Error::before(ErrorCode::Conflict))?;
        // Only a new retirement needs current child candidacy. Historical
        // acknowledgement must preserve any newly owned namespace occupant.
        let child_unstarted = self.branch_child_unstarted(&request.child.name);
        let registry = self.branch_retention.clone();
        let domain = self.domain.clone();
        let runtime = self.runtime.clone();
        let database = self.binding().database.clone();
        let identity = self.database_identity;
        let request = request.clone();
        let work_budget = budget.clone();
        let proof = crate::oci_start::observe_owned(
            self.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _control = control;
                let _gates = gates;
                let mut disposed = registry
                    .disposed
                    .try_lock()
                    .map_err(|_| Error::before(ErrorCode::Conflict))?;
                let mut matches = disposed
                    .values_mut()
                    .filter(|entry| entry.proof == request.disposal);
                let entry = matches.next().ok_or(Error::before(ErrorCode::Ownership))?;
                if matches.next().is_some() {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let record = entry.record(&runtime, &domain)?;
                let context_sha256 = crate::material::hash(&(
                    "smolbox-original-unbooted-branch-backing-v1",
                    &entry.proof,
                    &record.intent,
                ))?;
                let mut proof = BranchBackingRelease {
                    schema: 1,
                    publication: entry.proof.publication.clone(),
                    operation_id: request.operation_id,
                    request_sha256: request.request_sha256,
                    native_bytes: entry
                        .proof
                        .publication
                        .change
                        .child_origin
                        .intent
                        .plan
                        .preparation_disk_bytes()?,
                    proof_sha256: String::new(),
                };
                proof.proof_sha256 = proof.digest()?;
                BackingLedger::new(domain, &proof.publication, context_sha256)?.release(
                    &proof,
                    &mut entry.backing,
                    &work_budget,
                    || {
                        child_unstarted?;
                        source_collected(&record)?;
                        absent(&record, &runtime, &database, identity, &work_budget)
                    },
                )
            },
        )
        .map_err(|error| Error::uncertain(error.code))?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(proof)
    }
}
