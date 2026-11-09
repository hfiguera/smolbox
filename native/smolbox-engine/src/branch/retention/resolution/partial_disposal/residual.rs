//! Original collected-child residual removal only. SDK deletion never repeats.
//! Protected cached grants and original directory descriptors survive partial IO.
mod qualification;
use super::ledger::{ProtectedRecord, Version};
use super::*;
use crate::{PartialBranchDisposalCleanup, PartialBranchDisposalCleanupRequest};
use serde::{Deserialize, Serialize};
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;

pub(in crate::branch::retention) struct RetainedCleanup {
    request: PartialBranchDisposalCleanupRequest,
    attempted: bool,
    published: bool,
}
impl RetainedCleanup {
    pub(in crate::branch::retention) fn new(
        request: &PartialBranchDisposalCleanupRequest,
    ) -> Result<Self> {
        request.validate()?;
        Ok(Self {
            request: request.clone(),
            attempted: false,
            published: false,
        })
    }
    pub(in crate::branch::retention) fn handoff(
        cached: &Arc<Mutex<Self>>,
    ) -> Result<archive::CleanupHandoff> {
        let state = cached
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        state.request.validate()?;
        if state.attempted || state.published {
            return Ok(archive::CleanupHandoff::Unavailable);
        }
        // No active application may retain this original unattempted grant
        // after its owner is retired. A missing file is not this cache fact.
        if Arc::strong_count(cached) != 1 {
            return Err(Error::before(ErrorCode::Conflict));
        }
        Ok(archive::CleanupHandoff::EnrolledUnattempted {
            request_sha256: state.request.request_sha256.clone(),
        })
    }
    pub(in crate::branch::retention) fn matches(
        &self,
        request: &PartialBranchDisposalCleanupRequest,
    ) -> Result<()> {
        if self.request != *request {
            return Err(Error::before(ErrorCode::Conflict));
        }
        Ok(())
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum CleanupStage {
    Cleaning,
    Cleaned,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CleanupRecord {
    schema: u8,
    intent: PartialDisposalIntent,
    request: PartialBranchDisposalCleanupRequest,
    parent: Directory,
    stage: CleanupStage,
    proof: Option<PartialBranchDisposalCleanup>,
}
pub(in crate::branch::retention::resolution::partial_disposal) fn file(
    domain: Arc<crate::domain::DomainGuard>,
    request: &crate::BranchCreateRequest,
) -> Result<Ledger> {
    let mut ledger = Ledger::new(domain, request)?;
    ledger.path = ledger.path.with_extension("cleanup.json");
    Ok(ledger)
}
fn matches_intent(
    request: &PartialBranchDisposalCleanupRequest,
    intent: &PartialDisposalIntent,
) -> Result<()> {
    request.validate()?;
    intent.validate()?;
    if request.disposal_request != intent.request
        || intent
            .release
            .as_ref()
            .is_some_and(|r| r.change.request.operation_id == request.operation_id)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
impl ProtectedRecord for CleanupRecord {
    const MAX_BYTES: u64 = 256 * 1024;
    fn validate_for(&self, ledger: &Ledger) -> Result<()> {
        matches_intent(&self.request, &self.intent)?;
        if self.schema != 1
            || self.parent.inode == 0
            || Some(self.parent.path.as_path()) != self.intent.child.path.parent()
            || file(
                ledger.domain.clone(),
                &self.intent.request.collection_request.creation,
            )?
            .path
                != ledger.path
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match (self.stage, &self.proof) {
            (CleanupStage::Cleaning, None) => Ok(()),
            (CleanupStage::Cleaned, Some(proof)) => {
                self.request.matches(proof)?;
                if proof.disposal
                    != self
                        .intent
                        .proof(PartialBranchDisposalCompletion::ResolvedAbsent)?
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                Ok(())
            }
            _ => Err(Error::before(ErrorCode::Ownership)),
        }
    }
}
pub(in crate::branch::retention::resolution::partial_disposal) fn collection(
    epoch: &crate::epoch::ActorEpoch,
    intent: &PartialDisposalIntent,
    enrollment: &crate::epoch::BootEnrollment,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check()?;
    if epoch.identity() != intent.publication.change.child_origin.intent.epoch {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let collected = epoch.collect_enrolled(&intent.head().name, enrollment)?;
    if crate::PartialBranchCollection::issue(
        &intent.request.collection_request,
        &intent.publication,
        &collected,
    )? != intent.request.collection
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    budget.check()
}
fn row_absent(
    database: &std::path::Path,
    identity: (u64, u64),
    intent: &PartialDisposalIntent,
    budget: &ReadBudget,
) -> Result<()> {
    if !crate::sdk_compat::observe_absence_budget(
        database,
        identity,
        &intent.head().name,
        budget,
        || Ok(true),
    )? {
        return Err(Error::before(ErrorCode::Ownership));
    }
    budget.check()
}
fn source_unchanged(
    database: &std::path::Path,
    identity: (u64, u64),
    intent: &PartialDisposalIntent,
    budget: &ReadBudget,
) -> Result<()> {
    let source = crate::sdk_compat::observe_record(
        database,
        identity,
        &intent.publication.receipt.name,
        budget,
    )?
    .ok_or(Error::before(ErrorCode::Ownership))?;
    if crate::material::hash(&source)? != intent.source_sha256 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    budget.check()
}
fn child_root(intent: &PartialDisposalIntent) -> Result<crate::export_source::Root> {
    let root = crate::export_source::Root::open(&intent.child.path)?;
    if Directory::capture(&root)? != intent.child {
        return Err(Error::before(ErrorCode::Ownership));
    }
    crate::sdk_compat::branch_deletion_cache(root.path())?;
    Ok(root)
}
fn absent(path: &std::path::Path) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Ok(_) => Ok(false),
        Err(_) => Err(Error::before(ErrorCode::Io)),
    }
}
fn acknowledge(
    ledger: &Ledger,
    record: CleanupRecord,
    version: Version,
    disposal: PartialBranchDisposal,
    budget: &ReadBudget,
) -> Result<PartialBranchDisposalCleanup> {
    let proof = PartialBranchDisposalCleanup::issue(&record.request, disposal)?;
    if record.proof.as_ref().is_some_and(|old| *old != proof) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    if record.proof.is_none() {
        let complete = CleanupRecord {
            stage: CleanupStage::Cleaned,
            proof: Some(proof.clone()),
            ..record
        };
        budget.check()?;
        ledger
            .write_record(&complete, Some(version))
            .map_err(|e| Error::uncertain(e.code))?;
    }
    let (saved, version) = ledger
        .read_record::<CleanupRecord>()?
        .ok_or(Error::before(ErrorCode::Ownership))?;
    if saved.proof.as_ref() != Some(&proof) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    ledger.synchronize_record::<CleanupRecord>(&version)?;
    budget.check().map_err(|e| Error::uncertain(e.code))?;
    Ok(proof)
}

impl RetainedBranchResolution {
    /// Remove only this original collected child's residual directory after a
    /// prior disposal grant and positive SDK row/reservation absence. This never
    /// retries SDK deletion, reconstructs a manager or retires public capacity.
    pub fn cleanup_partial_disposal(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalCleanupRequest,
    ) -> Result<PartialBranchDisposalCleanup> {
        validate_budget(&self.budget)?;
        request.validate()?;
        if request.disposal_request.collection_request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(proof) = engine.inspect_partial_disposal_cleanup(request, &self.budget)? {
            return Ok(proof);
        }
        self.verify_epoch(engine)?;
        let epoch = engine.collection_epoch()?.clone();
        self.cleanup_partial_checked(
            engine,
            request,
            &epoch,
            |work, intent| {
                let boot = work
                    .boot
                    .as_mut()
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                if boot.partial_disposal_intent() != Some((intent, true)) {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                boot.verify_partial_disposal_owner(&intent.request, &epoch, &self.budget)?;
                let enrollment = boot
                    .enrollment()
                    .cloned()
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                let cached = boot.retain_partial_cleanup(request)?;
                Ok((enrollment, cached))
            },
            |p, s, after| live_partial_source(engine, p, s, &self.budget, after),
            |application| {
                crate::oci_start::observe_owned(
                    engine.jobs.clone(),
                    self.budget.deadline,
                    self.budget.cancel.clone(),
                    move || application.run(crate::VOLUME_DELETE_ENTRIES),
                )
            },
        )
    }
    // Inert models supply only original actor/cache facts, never an SDK manager.
    pub(in crate::branch::retention::resolution::partial_disposal) fn cleanup_partial_checked(
        &self,
        engine: &Engine,
        request: &PartialBranchDisposalCleanupRequest,
        epoch: &crate::epoch::ActorEpoch,
        original: impl FnOnce(
            &mut Work,
            &PartialDisposalIntent,
        ) -> Result<(
            Arc<crate::epoch::BootEnrollment>,
            Arc<Mutex<RetainedCleanup>>,
        )>,
        authority: impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
        dispatch: impl FnOnce(CleanupApplication) -> Result<()>,
    ) -> Result<PartialBranchDisposalCleanup> {
        validate_budget(&self.budget)?;
        request.validate()?;
        if request.disposal_request.collection_request.creation != self.creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        engine.verify_database_identity()?;
        let control = engine
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
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
        let main = Ledger::new(engine.domain.clone(), &self.creation)?;
        let (record, main_version) = main.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        matches_intent(request, &record.intent)?;
        archive::unneeded::require_no_unneeded_history(engine, &self.creation)?;
        let (enrollment, cached) = original(&mut work, &record.intent)?;
        let ledger = file(engine.domain.clone(), &self.creation)?;
        {
            let state = cached
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            state.matches(request)?;
            if let Some(disposal) = record.proof {
                if !state.published {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let (cleanup, version) = ledger
                    .read_record::<CleanupRecord>()?
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                if cleanup.request != *request || cleanup.intent != record.intent {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                main.synchronize(&main_version)?;
                return acknowledge(&ledger, cleanup, version, disposal, &self.budget);
            }
        }
        if record.stage != Stage::Entered {
            return Err(Error::before(ErrorCode::State));
        }
        engine.require_unhanded_branch_child(&self.creation.child.name)?;
        collection(epoch, &record.intent, &enrollment, &self.budget)?;
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
        main.synchronize(&main_version)?;
        let active = Arc::new(());
        work.worker = Arc::downgrade(&active);
        let application = CleanupApplication {
            entry: entry.clone(),
            enrollment,
            cached,
            intent: record.intent.clone(),
            request: request.clone(),
            epoch: epoch.clone(),
            domain: engine.domain.clone(),
            database: engine.binding().database.clone(),
            identity: engine.database_identity,
            budget: self.budget.clone(),
            _active: active,
            _control: control,
        };
        drop(work);
        dispatch(application).map_err(|e| Error::uncertain(e.code))?;
        let disposal = self.finish_partial_disposal(
            engine,
            &entry,
            &record.intent,
            PartialBranchDisposalCompletion::ResolvedAbsent,
            &authority,
        )?;
        let (cleanup, version) = ledger
            .read_record::<CleanupRecord>()?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if cleanup.intent != record.intent || cleanup.request != *request {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        acknowledge(&ledger, cleanup, version, disposal, &self.budget)
            .map_err(|e| Error::uncertain(e.code))
    }
}

pub(in crate::branch::retention::resolution::partial_disposal) struct CleanupApplication {
    entry: Arc<Entry>,
    enrollment: Arc<crate::epoch::BootEnrollment>,
    cached: Arc<Mutex<RetainedCleanup>>,
    intent: PartialDisposalIntent,
    request: PartialBranchDisposalCleanupRequest,
    epoch: crate::epoch::ActorEpoch,
    domain: Arc<crate::domain::DomainGuard>,
    database: std::path::PathBuf,
    identity: (u64, u64),
    budget: ReadBudget,
    _active: Arc<()>,
    _control: crate::jobs::JobLease,
}
impl CleanupApplication {
    pub(in crate::branch::retention::resolution::partial_disposal) fn run(
        self,
        maximum: usize,
    ) -> Result<()> {
        self.budget.check()?;
        let work = self
            .entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut state = self
            .cached
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        state.matches(&self.request)?;
        if self.entry.ownership.creation.as_ref()
            != Some(&self.intent.request.collection_request.creation)
            || self.entry.expected.metadata_sha256 != self.intent.metadata_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.entry.ownership.intent.guard.source_root.verify()?;
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
        if snapshot._child.path() != self.intent.child.path
            || (child.dev(), child.ino()) != (self.intent.child.device, self.intent.child.inode)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let main = Ledger::new(
            self.domain.clone(),
            &self.intent.request.collection_request.creation,
        )?;
        let (pending, version) = main.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if pending.intent != self.intent
            || pending.stage != Stage::Entered
            || pending.proof.is_some()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        main.synchronize(&version)?;
        archive::unneeded::require_no_unneeded_file(
            self.domain.clone(),
            &self.intent.request.collection_request.creation,
        )?;
        collection(&self.epoch, &self.intent, &self.enrollment, &self.budget)?;
        row_absent(&self.database, self.identity, &self.intent, &self.budget)?;
        source_unchanged(&self.database, self.identity, &self.intent, &self.budget)?;
        let parent = crate::export_source::Root::open(
            self.intent
                .child
                .path
                .parent()
                .ok_or(Error::before(ErrorCode::Ownership))?,
        )?;
        let parent_identity = Directory::capture(&parent)?;
        let ledger = file(
            self.domain.clone(),
            &self.intent.request.collection_request.creation,
        )?;
        match ledger.read_record::<CleanupRecord>()? {
            Some((record, version)) => {
                if !state.attempted
                    || record.intent != self.intent
                    || record.request != self.request
                    || record.parent != parent_identity
                    || record.stage != CleanupStage::Cleaning
                    || record.proof.is_some()
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                ledger.synchronize_record::<CleanupRecord>(&version)?;
            }
            None => {
                if state.published {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                child_root(&self.intent)?; // Absence cannot mint a missing cleanup grant.
                let record = CleanupRecord {
                    schema: 1,
                    intent: self.intent.clone(),
                    request: self.request.clone(),
                    parent: parent_identity,
                    stage: CleanupStage::Cleaning,
                    proof: None,
                };
                state.attempted = true;
                self.budget.check()?;
                ledger
                    .write_record(&record, None)
                    .map_err(|e| Error::uncertain(e.code))?;
                let (_, version) = ledger
                    .read_record::<CleanupRecord>()?
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                ledger.synchronize_record::<CleanupRecord>(&version)?;
            }
        }
        state.published = true;
        if !absent(&self.intent.child.path)? {
            let root = child_root(&self.intent)?;
            crate::volumes::remove_owned_tree(root.descriptor(), &self.budget, maximum)?;
            root.descriptor()
                .sync_all()
                .map_err(|_| Error::before(ErrorCode::Io))?;
            root.verify()?;
            parent.verify()?;
            child_root(&self.intent)?;
            row_absent(&self.database, self.identity, &self.intent, &self.budget)?;
            source_unchanged(&self.database, self.identity, &self.intent, &self.budget)?;
            collection(&self.epoch, &self.intent, &self.enrollment, &self.budget)?;
            let name = std::ffi::CString::new(smolvm::agent::vm_dir_hash(&self.intent.head().name))
                .map_err(|_| Error::before(ErrorCode::Ownership))?;
            self.budget.check()?;
            if unsafe {
                libc::unlinkat(
                    parent.descriptor().as_raw_fd(),
                    name.as_ptr(),
                    libc::AT_REMOVEDIR,
                )
            } != 0
            {
                return Err(Error::before(ErrorCode::Io));
            }
        }
        parent
            .descriptor()
            .sync_all()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        parent.verify()?;
        collection(&self.epoch, &self.intent, &self.enrollment, &self.budget)?;
        if !crate::sdk_compat::observe_absence_budget(
            &self.database,
            self.identity,
            &self.intent.head().name,
            &self.budget,
            || absent(&self.intent.child.path),
        )? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        source_unchanged(&self.database, self.identity, &self.intent, &self.budget)
    }
}

impl Engine {
    /// Exact original-archive cleanup acknowledgement, without new namespace
    /// observation, removal or SDK replay. A missing grant remains unavailable.
    pub fn inspect_partial_disposal_cleanup(
        &self,
        request: &PartialBranchDisposalCleanupRequest,
        budget: &ReadBudget,
    ) -> Result<Option<PartialBranchDisposalCleanup>> {
        validate_budget(budget)?;
        request.validate()?;
        let Some(disposal) =
            self.inspect_partial_branch_disposal(&request.disposal_request, budget)?
        else {
            return Ok(None);
        };
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let ledger = file(
            self.domain.clone(),
            &request.disposal_request.collection_request.creation,
        )?;
        let (record, version) = ledger
            .read_record::<CleanupRecord>()?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if record.request != *request
            || disposal
                != record
                    .intent
                    .proof(PartialBranchDisposalCompletion::ResolvedAbsent)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        acknowledge(&ledger, record, version, disposal, budget).map(Some)
    }
}

#[cfg(test)]
mod handoff_tests {
    use super::*;
    use crate::branch::retention::resolution::partial_disposal::tests::Model;

    #[test]
    fn attempted_or_published_cleanup_cannot_be_downgraded_to_unused_by_missing_receipts() {
        for (attempted, published) in [(true, false), (false, true), (true, true)] {
            let model = Model::new(1);
            let mut request = PartialBranchDisposalCleanupRequest {
                disposal_request: model.intent.request.clone(),
                operation_id: "used-handoff-model".into(),
                request_sha256: String::new(),
                quiesced: true,
            };
            request.request_sha256 = request.digest().unwrap();
            let cached = Arc::new(Mutex::new(RetainedCleanup::new(&request).unwrap()));
            {
                let mut state = cached.lock().unwrap();
                state.attempted = attempted;
                state.published = published;
            }
            assert!(matches!(
                RetainedCleanup::handoff(&cached).unwrap(),
                archive::CleanupHandoff::Unavailable
            ));
            assert!(!file(
                model.original.engine.domain.clone(),
                &request.disposal_request.collection_request.creation
            )
            .unwrap()
            .path
            .exists());
        }
    }
}
