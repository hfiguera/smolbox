//! Original collected pre-handoff disposal. SDK entry is one-shot; uncertainty
//! retains original work, source dependency and backing until explicit closeout.
use super::*;
use crate::branch_boot::Directory;
use crate::{PartialBranchDisposal, PartialBranchDisposalCompletion, PartialBranchDisposalRequest};
pub(in crate::branch::retention) mod archive;
mod ledger;
mod residual;
mod sdk_entry;
pub(in crate::branch::retention) use ledger::Intent as PartialDisposalIntent;
use ledger::{Ledger, Record, Stage};
pub(in crate::branch::retention) use residual::RetainedCleanup;
pub(in crate::branch::retention) use sdk_entry::RetainedSdkEntry;
#[cfg(test)]
pub(in crate::branch::retention) mod tests;

// SDK entry is one-shot even when the SDK returned an error before removing
// anything. A published primary is only context, never SDK-entry authority.
// Namespace absence cannot create a missing original grant/history.
enum Selected {
    Fresh,
    Historical(PartialBranchDisposal),
    Observe(PartialDisposalIntent),
    Published(PartialDisposalIntent),
    Synchronize(PartialDisposalIntent),
}
fn select_disposal(
    cached: Option<(&PartialDisposalIntent, bool)>,
    saved: Option<&Record>,
    request: &PartialBranchDisposalRequest,
    observe_only: bool,
) -> Result<Selected> {
    match (cached, saved) {
        (Some((intent, published)), Some(record)) => {
            if intent.request != *request {
                return Err(Error::before(ErrorCode::Conflict));
            }
            if record.intent != *intent {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if !published {
                if record.stage == Stage::Entered && record.proof.is_none() {
                    return Ok(Selected::Synchronize(intent.clone()));
                }
                return Err(Error::before(ErrorCode::Ownership));
            }
            if let Some(proof) = &record.proof {
                return Ok(Selected::Historical(proof.clone()));
            }
            if observe_only {
                return Ok(Selected::Observe(intent.clone()));
            }
            Ok(Selected::Published(intent.clone()))
        }
        (Some((intent, published)), None) => {
            if published || intent.request != *request {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if observe_only {
                return Err(Error::before(ErrorCode::State));
            }
            Ok(Selected::Fresh)
        }
        (None, Some(_)) => Err(Error::before(ErrorCode::Ownership)),
        (None, None) if observe_only => Err(Error::before(ErrorCode::State)),
        (None, None) => Ok(Selected::Fresh),
    }
}

impl RetainedBranchResolution {
    /// Dispose only this original pre-handoff child after its exact acknowledged
    /// collection. Caller quiescence, current epoch and original manager remain
    /// mandatory. Entry is one-shot; unknown/partial removal retains all work,
    /// source dependency and backing. Use the separate observer after uncertainty.
    pub fn dispose_partial_child(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalRequest,
    ) -> Result<PartialBranchDisposal> {
        self.verify_epoch(engine)?;
        let epoch = engine.collection_epoch()?.clone();
        let jobs = engine.jobs.clone();
        let runtime = engine.runtime.clone();
        self.partial_dispose_checked(
            engine,
            request,
            &epoch,
            false,
            |p, s, after| live_partial_source(engine, p, s, &self.budget, after),
            |application| {
                crate::oci_start::observe_owned(
                    jobs,
                    self.budget.deadline,
                    self.budget.cancel.clone(),
                    move || {
                        application.run(|name, path| {
                            if smolvm::agent::vm_data_dir(name) != path {
                                return Err(Error::before(ErrorCode::Ownership));
                            }
                            runtime
                                .delete_machine(name)
                                .map_err(|_| Error::uncertain(ErrorCode::Native))
                        })
                    },
                )
            },
        )
    }
    /// Observe an existing entered disposal only. Never repeats SDK deletion or
    /// infers original authority from empty inventory or caller-supplied paths.
    pub fn resolve_partial_disposal(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalRequest,
    ) -> Result<PartialBranchDisposal> {
        self.verify_epoch(engine)?;
        self.partial_dispose_checked(
            engine,
            request,
            engine.collection_epoch()?,
            true,
            |p, s, after| live_partial_source(engine, p, s, &self.budget, after),
            |_| Err(Error::before(ErrorCode::State)),
        )
    }
    fn partial_dispose_checked(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalRequest,
        epoch: &crate::epoch::ActorEpoch,
        observe_only: bool,
        authority: impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
        dispatch: impl FnOnce(Application) -> Result<()>,
    ) -> Result<PartialBranchDisposal> {
        validate_budget(&self.budget)?;
        request.validate()?;
        if request.collection_request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        engine.verify_database_identity()?;
        let control = engine
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
        engine.require_unhanded_branch_child(&self.creation.child.name)?;
        let mut work = entry
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
        let boot = work
            .boot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        boot.verify_partial_disposal_owner(request, epoch, &self.budget)?;
        if boot.partial_cleanup_started() {
            return Err(Error::before(ErrorCode::State));
        }
        let ledger = Ledger::new(engine.domain.clone(), &self.creation)?;
        let saved = ledger.read()?;
        let selected = select_disposal(
            boot.partial_disposal_intent(),
            saved.as_ref().map(|(r, _)| r),
            request,
            observe_only,
        )?;
        let intent = match selected {
            Selected::Historical(proof) => {
                ledger
                    .synchronize(&saved.as_ref().ok_or(Error::before(ErrorCode::Ownership))?.1)?;
                self.budget.check()?;
                return Ok(proof);
            }
            Selected::Observe(intent) => {
                // Legacy primary Entered cannot prove SDK entry unstarted.
                // Without the original new cached grant only positive absence
                // may resolve; no cache or sidecar is reconstructed here.
                if boot.partial_disposal_sdk_entry().is_none() {
                    drop(work);
                    return self.finish_partial_disposal(
                        engine,
                        &entry,
                        &intent,
                        PartialBranchDisposalCompletion::ResolvedAbsent,
                        &authority,
                    );
                }
                intent
            }
            Selected::Published(intent) => intent,
            Selected::Synchronize(intent) => {
                // A visible file is not authority. Rebuild the full original
                // context read-only and require its exact unchanged before-row,
                // live source, roots, lifecycle and opaque collected owner.
                let current = self
                    .partial_disposal_intent(engine, &entry, &work, request, epoch, &authority)?;
                if current != intent {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                work.boot
                    .as_mut()
                    .ok_or(Error::before(ErrorCode::Ownership))?
                    .recover_partial_disposal_publication(
                        engine.domain.clone(),
                        &intent,
                        &self.budget,
                    )?;
                intent
            }
            Selected::Fresh => {
                let intent = self
                    .partial_disposal_intent(engine, &entry, &work, request, epoch, &authority)?;
                let boot = work
                    .boot
                    .as_mut()
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                boot.retain_partial_disposal(intent.clone())?;
                ledger
                    .write(
                        &Record {
                            schema: 1,
                            intent: intent.clone(),
                            stage: Stage::Entered,
                            proof: None,
                        },
                        None,
                    )
                    .map_err(|e| Error::uncertain(e.code))?;
                let (entered, version) = ledger
                    .read()?
                    .ok_or(Error::uncertain(ErrorCode::Ownership))?;
                if entered.intent != intent
                    || entered.stage != Stage::Entered
                    || entered.proof.is_some()
                {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                ledger
                    .synchronize(&version)
                    .map_err(|e| Error::uncertain(e.code))?;
                boot.partial_disposal_published()?;
                intent
            }
        };
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        if !observe_only {
            let source =
                disposal::source_record(engine, &entry, &intent.publication, &self.budget)?;
            if crate::material::hash(&source)? != intent.source_sha256 {
                return Err(Error::before(ErrorCode::Ownership));
            }
            authority(&intent.publication, &source, false)?;
        }
        let boot = work
            .boot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let sdk_entry = boot
            .partial_disposal_sdk_entry()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let enrollment = boot
            .enrollment()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .clone();
        let plan = boot.partial_disposal_plan().clone();
        let active = Arc::new(());
        work.worker = Arc::downgrade(&active);
        let application = Application {
            sdk_entry,
            entry: entry.clone(),
            enrollment,
            plan,
            intent: intent.clone(),
            epoch: epoch.clone(),
            domain: engine.domain.clone(),
            db: engine.db.clone(),
            database: engine.binding().database.clone(),
            identity: engine.database_identity,
            budget: self.budget.clone(),
            _active: active,
            _control: control,
        };
        drop(work);
        if observe_only {
            let unentered = application.qualify_unentered();
            if unentered.is_ok() {
                let source =
                    disposal::source_record(engine, &entry, &intent.publication, &self.budget)?;
                if crate::material::hash(&source)? != intent.source_sha256 {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                authority(&intent.publication, &source, false)
                    .map_err(|e| Error::uncertain(e.code))?;
                self.budget.check()?;
                // The public caller may offer only the same saved action. The
                // native application rechecks both grants before first entry.
                return Err(Error::before(ErrorCode::State));
            }
            drop(application);
            return self.finish_partial_disposal(
                engine,
                &entry,
                &intent,
                PartialBranchDisposalCompletion::ResolvedAbsent,
                &authority,
            );
        }
        dispatch(application).map_err(|e| Error::uncertain(e.code))?;
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        self.finish_partial_disposal(
            engine,
            &entry,
            &intent,
            PartialBranchDisposalCompletion::Deleted,
            &authority,
        )
    }
    fn finish_partial_disposal(
        &self,
        engine: &Engine,
        entry: &Entry,
        intent: &PartialDisposalIntent,
        completion: PartialBranchDisposalCompletion,
        authority: &impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
    ) -> Result<PartialBranchDisposal> {
        self.partial_disposal_absence(engine, entry, intent, authority)
            .map_err(|e| Error::uncertain(e.code))?;
        self.publish_partial_disposal(engine, intent, completion)
            .map_err(|e| Error::uncertain(e.code))
    }
    fn publish_partial_disposal(
        &self,
        engine: &Engine,
        intent: &PartialDisposalIntent,
        completion: PartialBranchDisposalCompletion,
    ) -> Result<PartialBranchDisposal> {
        self.budget.check()?;
        let ledger = Ledger::new(engine.domain.clone(), &self.creation)?;
        let (record, version) = ledger
            .read()?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if record.intent != *intent || record.stage != Stage::Entered || record.proof.is_some() {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let proof = intent.proof(completion)?;
        let stage = if completion == PartialBranchDisposalCompletion::Deleted {
            Stage::Deleted
        } else {
            Stage::ResolvedAbsent
        };
        ledger
            .write(
                &Record {
                    schema: 1,
                    intent: intent.clone(),
                    stage,
                    proof: Some(proof.clone()),
                },
                Some(version),
            )
            .map_err(|e| Error::uncertain(e.code))?;
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }

    fn partial_disposal_intent(
        &self,
        engine: &Engine,
        entry: &Entry,
        work: &Work,
        request: &PartialBranchDisposalRequest,
        epoch: &crate::epoch::ActorEpoch,
        authority: &impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
    ) -> Result<PartialDisposalIntent> {
        let snapshot = work
            .snapshot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        snapshot._child.verify()?;
        snapshot._snapshot.verify()?;
        let publication =
            crate::material::MaterialJournal::at(entry.ownership.intent.guard.source_root.path())
                .completed_branch_publication(
                    &self.creation.source,
                    &self.creation.child.operation_id,
                    &entry.ownership.intent.intent.request_sha256,
                )?
                .ok_or(Error::before(ErrorCode::Ownership))?;
        if publication.change.child_origin.raw_child_sha256
            != crate::identity::material_hash(&snapshot.child)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let row = engine
            .observation_record(&self.creation.child.name, &self.budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let release = work
            .boot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .qualify_partial_disposal(request, epoch, &self.budget, &row)?;
        crate::machine::verify_branch_marker(publication.child(), snapshot._child.path())?;
        crate::material::MaterialJournal::at(snapshot._child.path())
            .verify_branch_child(publication.child(), &row)?;
        // The collected child can have extracted its own bare pack during boot.
        // The original manager and collection proof above establish that its
        // process is gone even if the SDK row still records the old PID.
        crate::sdk_compat::stopped_branch_deletion_cache(snapshot._child.path())?;
        if !crate::sdk_compat::source_dependents(
            &engine.binding().database,
            engine.database_identity,
            &self.creation.child.name,
            &self.budget,
        )?
        .is_empty()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let source = disposal::source_record(engine, entry, &publication, &self.budget)?;
        authority(&publication, &source, false)?;
        let mut stopped = row.clone();
        stopped.state = smolvm::config::RecordState::Stopped;
        stopped.pid = None;
        stopped.pid_start_time = None;
        let result = PartialDisposalIntent {
            request: request.clone(),
            publication,
            release,
            metadata_sha256: entry.expected.metadata_sha256.clone(),
            source: Directory::capture(&entry.ownership.intent.guard.source_root)?,
            child: Directory::capture(&snapshot._child)?,
            snapshot: Directory::capture(&snapshot._snapshot)?,
            source_sha256: crate::material::hash(&source)?,
            before_sha256: crate::material::hash(&row)?,
            stopped_sha256: crate::material::hash(&stopped)?,
        };
        result.validate()?;
        self.budget.check()?;
        Ok(result)
    }
    fn partial_disposal_absence(
        &self,
        engine: &Engine,
        entry: &Entry,
        intent: &PartialDisposalIntent,
        authority: &impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
    ) -> Result<()> {
        self.budget.check()?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.partial_disposal_absence_checked_work(engine, entry, &work, intent, authority)
    }
    fn partial_disposal_absence_checked_work(
        &self,
        engine: &Engine,
        entry: &Entry,
        work: &Work,
        intent: &PartialDisposalIntent,
        authority: &impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
    ) -> Result<()> {
        self.budget.check()?;
        if work.worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::State));
        }
        work.snapshot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            ._snapshot
            .verify()?;
        engine.require_unhanded_branch_child(&self.creation.child.name)?;
        if !crate::sdk_compat::observe_absence_budget(
            &engine.binding().database,
            engine.database_identity,
            &self.creation.child.name,
            &self.budget,
            || {
                Ok(matches!(std::fs::symlink_metadata(&intent.child.path),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound))
            },
        )? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let source = disposal::source_record(engine, entry, &intent.publication, &self.budget)?;
        if crate::material::hash(&source)? != intent.source_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        authority(&intent.publication, &source, true)?;
        self.budget.check()
    }
}
fn live_partial_source(
    engine: &Engine,
    publication: &crate::BranchPublication,
    source: &smolvm::config::VmRecord,
    budget: &ReadBudget,
    after: bool,
) -> Result<()> {
    let child = &publication.child().name;
    // Only this original collected child may have an entered release journal.
    // The original lifecycle/material qualification happens before this source
    // callback, while every other sibling retains ordinary strict validation.
    let authority = engine.branch_disposal_source_authority(
        &publication.receipt,
        child,
        publication.change.child_origin.intent.source_pid,
        source,
        budget,
    )?;
    if !authority.running()
        || (!after
            && !crate::sdk_compat::source_dependents(
                &engine.binding().database,
                engine.database_identity,
                &publication.receipt.name,
                budget,
            )?
            .contains(child))
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

struct Application {
    sdk_entry: Arc<Mutex<RetainedSdkEntry>>,
    enrollment: Arc<crate::epoch::BootEnrollment>,
    plan: crate::branch_boot::Plan,
    entry: Arc<Entry>,
    intent: PartialDisposalIntent,
    epoch: crate::epoch::ActorEpoch,
    domain: Arc<crate::domain::DomainGuard>,
    db: smolvm::db::SmolvmDb,
    database: std::path::PathBuf,
    identity: (u64, u64),
    budget: ReadBudget,
    _active: Arc<()>,
    _control: crate::jobs::JobLease,
}
impl Application {
    fn run(self, delete: impl FnOnce(&str, &std::path::Path) -> Result<()>) -> Result<()> {
        self.budget.check()?;
        let work = self
            .entry
            .work
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        self.qualify_context(&work)?;
        let mut entry = self
            .sdk_entry
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        entry.prepare(self.domain.clone(), &self.intent, &self.budget)?;
        self.stopped()?;
        self.budget.check()?;
        entry.enter(self.domain.clone(), &self.intent, &self.budget)?;
        delete(&self.intent.head().name, &self.intent.child.path)
            .map_err(|e| Error::uncertain(e.code))?;
        self.budget.check().map_err(|e| Error::uncertain(e.code))
    }
    fn qualify_unentered(&self) -> Result<()> {
        let work = self
            .entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.qualify_context(&work)?;
        self.sdk_entry
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .prepare(self.domain.clone(), &self.intent, &self.budget)
    }
    fn qualify_context(&self, work: &Work) -> Result<()> {
        self.budget.check()?;
        // The private application owns the exact enrollment captured while the
        // original manager and collection fence were qualified. No row/PID can
        // mint this opaque token; the retained entry keeps its original manager.
        if self.entry.ownership.creation.as_ref()
            != Some(&self.intent.request.collection_request.creation)
            || self.entry.expected.metadata_sha256 != self.intent.metadata_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let collected = self
            .epoch
            .collect_enrolled(&self.intent.head().name, &self.enrollment)?;
        if crate::PartialBranchCollection::issue(
            &self.intent.request.collection_request,
            &self.plan.publication,
            &collected,
        )? != self.intent.request.collection
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let ledger = Ledger::new(
            self.domain.clone(),
            &self.intent.request.collection_request.creation,
        )?;
        let (saved, version) = ledger.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if saved.intent != self.intent || saved.stage != Stage::Entered || saved.proof.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        ledger.synchronize(&version)?;
        self.entry.ownership.intent.guard.source_root.verify()?;
        let snapshot = work
            .snapshot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        snapshot._child.verify()?;
        snapshot._snapshot.verify()?;
        crate::sdk_compat::stopped_branch_deletion_cache(snapshot._child.path())?;
        let source = crate::sdk_compat::observe_record(
            &self.database,
            self.identity,
            &self.intent.publication.receipt.name,
            &self.budget,
        )?
        .ok_or(Error::before(ErrorCode::Ownership))?;
        if crate::material::hash(&source)? != self.intent.source_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.plan.verify()?;
        let row = crate::sdk_compat::observe_record(
            &self.database,
            self.identity,
            &self.intent.head().name,
            &self.budget,
        )?
        .ok_or(Error::before(ErrorCode::Ownership))?;
        let row_sha256 = crate::material::hash(&row)?;
        if !self.intent.head().matches(&row)?
            || (row_sha256 != self.intent.before_sha256 && row_sha256 != self.intent.stopped_sha256)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let release = crate::branch_boot::Lifecycle::at(&self.plan.child.path)
            .partial_disposal_release(
                &self.plan,
                &self.intent.request.collection_request,
                &self.intent.request.collection,
                &self.enrollment,
                &row,
            )?;
        if release != self.intent.release {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.budget.check()
    }
    fn stopped(&self) -> Result<()> {
        let name = &self.intent.head().name;
        let row =
            crate::sdk_compat::observe_record(&self.database, self.identity, name, &self.budget)?
                .ok_or(Error::before(ErrorCode::Ownership))?;
        if !self.intent.head().matches(&row)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let before = crate::material::hash(&row)?;
        if before == self.intent.stopped_sha256 {
            return Ok(());
        }
        if before != self.intent.before_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut changed = false;
        self.db
            .update_vm(name, |row| {
                if crate::material::hash(row).ok().as_ref() == Some(&before) {
                    row.state = smolvm::config::RecordState::Stopped;
                    row.pid = None;
                    row.pid_start_time = None;
                    changed = true;
                }
            })
            .map_err(|_| Error::uncertain(ErrorCode::Database))?;
        let after =
            crate::sdk_compat::observe_record(&self.database, self.identity, name, &self.budget)?
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if !changed || crate::material::hash(&after)? != self.intent.stopped_sha256 {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    }
}
