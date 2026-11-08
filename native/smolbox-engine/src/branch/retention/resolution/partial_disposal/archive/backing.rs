//! Explicit original partial-child accounting closure. No SDK mutation, path
//! cleanup, reconstructed manager or ordinary boot-completion surrogate.
use super::*;
use crate::branch::retention::backing::Ledger as BackingLedger;
use crate::{BranchBackingRelease, PartialBranchBackingReleaseRequest};

pub(in crate::branch::retention::resolution::partial_disposal) fn collected(
    epoch: &crate::epoch::ActorEpoch,
    record: &Record,
    enrollment: &crate::epoch::BootEnrollment,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check()?;
    let intent = &record.intent.publication.change.child_origin.intent;
    if !epoch.quiescent_for(&intent.source.name)?
        || !crate::epoch::gone(crate::OwnerIdentity {
            pid: intent.source_pid.0,
            birth: intent.source_pid.1,
            uid: unsafe { libc::geteuid() },
        })?
    {
        return Err(Error::before(ErrorCode::Conflict));
    }
    absence::collected(epoch, record, enrollment, budget)
}

fn absent(
    record: &Record,
    database: &std::path::Path,
    identity: (u64, u64),
    budget: &ReadBudget,
) -> Result<()> {
    let creation = &record.intent.request.collection_request.creation;
    for (name, directory) in [
        (&creation.source.name, &record.intent.source.path),
        (&creation.child.name, &record.intent.child.path),
    ] {
        budget.check()?;
        if !crate::sdk_compat::observe_absence_budget(database, identity, name, budget, || {
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
        })? {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    budget.check()
}

impl Engine {
    /// Release only this original collected/disposed pre-handoff child's native
    /// backing charge after explicit host removal confirmation and collected
    /// source/child absence. The caller must first durably bind this request to
    /// its tombstones. Expected material heads correlate with that caller, never
    /// grant namespace adoption or attest to history inferred from absence.
    pub fn release_partial_branch_backing_checked(
        &self,
        request: &PartialBranchBackingReleaseRequest,
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
        let proof =
            self.release_partial_backing(request, budget, move |record, enrollment, b| {
                collected(&epoch, record, enrollment, b)
            })?;
        request
            .matches(&proof)
            .map_err(|error| Error::uncertain(error.code))?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(proof)
    }

    // Private models supply the same collector with an inert original epoch.
    // The owned accounting worker retains both gates/control through return.
    pub(in crate::branch::retention::resolution::partial_disposal) fn release_partial_backing(
        &self,
        request: &PartialBranchBackingReleaseRequest,
        budget: &ReadBudget,
        collection: impl Fn(&Record, &crate::epoch::BootEnrollment, &ReadBudget) -> Result<()>
            + Send
            + 'static,
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
        let (record, enrollment) = self.partial_disposal_context(&request.disposal)?;
        if self.vm_directory(&request.source.name) != record.intent.source.path
            || self.vm_directory(&request.child.name) != record.intent.child.path
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let source_gate = self.observation_gate(&request.source.name)?;
        let child_gate = self.observation_gate(&request.child.name)?;
        let gates = crate::gate::lock_pair(
            (&request.source.name, &source_gate),
            (&request.child.name, &child_gate),
        )
        .map_err(|()| Error::before(ErrorCode::Conflict))?;
        // Actual Engine ownership maps are checked under the paired gates. The
        // worker consumes this candidacy only for a first release. A historical
        // acknowledgement must leave any newly owned namespace occupant alone.
        // Never use runtime.pid's unbudgeted persisted-row fallback here.
        let unowned = self
            .require_unhanded_branch_child(&request.source.name)
            .and_then(|()| self.require_unhanded_branch_child(&request.child.name));
        let registry = self.branch_retention.clone();
        let runtime = self.runtime.clone();
        let domain = self.domain.clone();
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
                    .partial_disposed
                    .try_lock()
                    .map_err(|_| Error::before(ErrorCode::Conflict))?;
                let mut matching = disposed
                    .values_mut()
                    .filter(|entry| entry.proof == request.disposal);
                let entry = matching.next().ok_or(Error::before(ErrorCode::Ownership))?;
                if matching.next().is_some() || !Arc::ptr_eq(&entry.enrollment, &enrollment) {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let current = entry.record_for(&runtime, &domain)?;
                if current.intent != record.intent {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let context_sha256 = crate::material::hash(&(
                    "smolbox-original-partial-branch-backing-v1",
                    &entry.proof,
                    &record.intent,
                    enrollment.intent(),
                    enrollment.child(),
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
                BackingLedger::new(domain.clone(), &proof.publication, context_sha256)?.release(
                    &proof,
                    &mut entry.backing,
                    &work_budget,
                    || {
                        unowned?;
                        for _ in 0..2 {
                            collection(&record, &enrollment, &work_budget)?;
                            absent(&record, &database, identity, &work_budget)?;
                        }
                        let ledger = Ledger::new(
                            domain,
                            &record.intent.request.collection_request.creation,
                        )?;
                        let (current, version) =
                            ledger.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
                        if current.intent != record.intent
                            || current.proof != record.proof
                            || current.stage != record.stage
                        {
                            return Err(Error::before(ErrorCode::Ownership));
                        }
                        ledger.synchronize(&version)?;
                        work_budget.check()
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
