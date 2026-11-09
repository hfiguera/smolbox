//! Original branch owner and worker retention. Collected preparation is not
//! source publication, child ownership, a booted VMM or public branch success.
use super::*;
use crate::transfer_supervisor::{Collected, Prepared, RunResult};
use std::collections::BTreeMap;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::sync::{Mutex, Weak};
mod backing;
mod boot;
mod resolution;
pub use backing::BranchBackingRelease;
pub use boot::{BranchBootIdentity, BranchGuestIdentity};
pub use resolution::{
    RetainedBranchResolution, UnbootedBranchDisposal, UnbootedBranchDisposalCandidate,
    UnbootedBranchDisposalCompletion, UnbootedBranchDisposalRequest,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BranchPreparationState {
    Prepared,
    Preparing,
    Collected,
    Unresolved,
    MaterialPublished,
    Disposing,
    Disposed,
    Booting,
    Booted,
    Initializing,
    IdentityReady,
    Releasing,
    Released,
    Held,
    Ready,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Prepared,
    Entered,
    Verified,
    Published,
    DisposalEntered,
    Disposed,
    BootEntered,
    Booted,
    IdentityEntered,
    IdentityReady,
    ReleaseEntered,
    Released,
}
struct Ownership {
    intent: PreparedBranchIntent,
    creation: Option<BranchCreateRequest>,
    jobs: crate::jobs::JobPool,
}
struct Work {
    prepared: Option<Prepared>,
    collected: Option<Box<Collected>>,
    phase: Phase,
    worker: Weak<()>,
    snapshot: Option<VerifiedSnapshot>,
    boot: Option<boot::OwnedBoot>,
}
struct Entry {
    ownership: Arc<Ownership>,
    expected: crate::branch_worker::Expected,
    borrower: Mutex<Weak<()>>,
    work: Mutex<Work>,
}
struct VerifiedSnapshot {
    before: smolvm::config::VmRecord,
    source: smolvm::config::VmRecord,
    child: smolvm::config::VmRecord,
    _snapshot: crate::export_source::Root,
    _child: crate::export_source::Root,
}
pub(crate) struct Registry {
    entries: Mutex<BTreeMap<String, Arc<Entry>>>,
    completed: Mutex<BTreeMap<String, CompletedChild>>,
    disposed: Mutex<BTreeMap<String, resolution::disposal::DisposedChild>>,
    partial_disposed:
        Mutex<BTreeMap<String, resolution::partial_disposal::archive::DisposedPartialChild>>,
    domain: Arc<crate::domain::DomainGuard>,
}
struct CompletedChild {
    borrower: Weak<()>,
    result: crate::BranchCompletion,
    _context: Arc<crate::branch_owned::Context>,
    _backing: crate::jobs::BranchBackingLease,
    jobs: crate::jobs::JobPool,
}
/// Original retained preparation only. This token exposes no PID, SDK handle,
/// receipt or caller-selected path. Dropping it never retires an entered fork.
pub struct RetainedBranchPreparation {
    registry: Weak<Registry>,
    key: String,
    borrower: Arc<()>,
}
impl std::fmt::Debug for RetainedBranchPreparation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RetainedBranchPreparation")
            .finish_non_exhaustive()
    }
}
impl Registry {
    pub(super) fn completed_results(
        &self,
        request: &BranchCreateRequest,
        budget: &ReadBudget,
    ) -> Result<Option<crate::BranchCompletion>> {
        self.domain.verify()?;
        let completed = self
            .completed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        super::creation::select_completion(
            request,
            completed.values().map(|child| &child.result),
            budget,
        )
    }
    pub(crate) fn completed_context(
        &self,
        receipt: &CreationReceipt,
    ) -> Result<Option<Arc<crate::branch_owned::Context>>> {
        let completed = self
            .completed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut matching = completed.values().filter(|child| {
            let mut origin = child.result.child.clone();
            origin.material = None;
            crate::material::check_origin(&origin, receipt).is_ok()
        });
        let result = matching.next().map(|child| child._context.clone());
        if matching.next().is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(result)
    }

    pub(crate) fn completed_context_exact(
        &self,
        expected: &crate::BranchCompletion,
    ) -> Result<Arc<crate::branch_owned::Context>> {
        self.domain.verify()?;
        expected.validate()?;
        let completed = self
            .completed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut matching = completed.values().filter(|entry| entry.result == *expected);
        let result = matching.next().ok_or(Error::before(ErrorCode::Ownership))?;
        if result.borrower.upgrade().is_some() || matching.next().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        Ok(result._context.clone())
    }
    pub(crate) fn new(domain: Arc<crate::domain::DomainGuard>) -> Arc<Self> {
        Arc::new(Self {
            entries: Mutex::new(BTreeMap::new()),
            completed: Mutex::new(BTreeMap::new()),
            disposed: Mutex::new(BTreeMap::new()),
            partial_disposed: Mutex::new(BTreeMap::new()),
            domain,
        })
    }
    pub(crate) fn insert(
        self: &Arc<Self>,
        mut input: PreparedBranchWorker,
        engine: &Engine,
        creation: Option<BranchCreateRequest>,
    ) -> Result<RetainedBranchPreparation> {
        if let Some(request) = &creation {
            request.validate(engine)?;
        }
        input
            .intent
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?
            .recheck(engine)?;
        self.insert_with_creation_checked(&mut input, creation)
    }
    pub(crate) fn retire_prepared(
        &self,
        engine: &Engine,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        budget: &ReadBudget,
    ) -> Result<Option<InitialBranchRetirement>> {
        let entry = self
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .values()
            .find(|entry| {
                let intent = &entry.ownership.intent.intent;
                intent.source == *source
                    && intent.child.operation_id == operation
                    && intent.request_sha256 == request
            })
            .cloned();
        let Some(entry) = entry else {
            return Ok(None);
        };
        let borrower = entry
            .borrower
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if borrower.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        self.retire_entry(engine, &entry, budget).map(Some)
    }
    fn retire_entry(
        &self,
        engine: &Engine,
        entry: &Arc<Entry>,
        budget: &ReadBudget,
    ) -> Result<InitialBranchRetirement> {
        budget.check()?;
        engine.verify_database_identity()?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.phase != Phase::Prepared || work.worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::State));
        }
        work.prepared
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?
            .verify_unentered_branch()?;
        let original = &entry.ownership.intent;
        original.guard.source_root.verify()?;
        self.domain.verify()?;
        require_marker(engine, &original.intent.source)?;
        let journal = crate::material::MaterialJournal::at(original.guard.source_root.path());
        let proof = match journal.retired_initial_branch(
            &original.intent.source,
            &original.intent.child.operation_id,
            &original.intent.request_sha256,
        )? {
            Some(proof) => proof,
            None => original.retire_prepared(engine, budget)?,
        };
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        original
            .guard
            .source_root
            .verify()
            .map_err(|e| Error::uncertain(e.code))?;
        self.domain.verify().map_err(|e| Error::uncertain(e.code))?;
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        let key = &entry.expected.metadata_sha256;
        if !entries
            .get(key)
            .is_some_and(|stored| Arc::ptr_eq(stored, entry))
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        entries.remove(key);
        Ok(proof)
    }
    // Production callers must first recheck the original live engine authority.
    // Kept separate so non-VM state/lease models never fabricate live enrollment.
    fn insert_with_creation_checked(
        self: &Arc<Self>,
        input: &mut PreparedBranchWorker,
        creation: Option<BranchCreateRequest>,
    ) -> Result<RetainedBranchPreparation> {
        self.domain.verify()?;
        let intent = input
            .intent
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?;
        if !Arc::ptr_eq(&self.domain, &intent.guard.domain) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(request) = &creation {
            resolution::validate_creation(request)?;
            intent.intent.matches_creation(request)?;
        }
        let prepared = input
            .prepared
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?;
        prepared.verify_unentered_branch()?;
        let crate::transfer_worker::Kind::BranchPrepare { metadata, expected } =
            &prepared.request.kind
        else {
            return Err(Error::before(ErrorCode::Validation));
        };
        let selected: crate::branch_worker::Metadata =
            metadata.read(prepared.request.owner, crate::branch_worker::METADATA_BYTES)?;
        if *expected != input.expected
            || selected.grant.intent != intent.intent
            || selected.source_directory != intent.guard.source_root.path()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut entries = self
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let completed = self
            .completed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let disposed = self
            .disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let partial_disposed = self
            .partial_disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if entries.len() >= crate::JOB_WORK_SLOTS
            || entries.contains_key(&input.expected.metadata_sha256)
            || completed
                .len()
                .saturating_add(disposed.len())
                .saturating_add(partial_disposed.len())
                >= (crate::jobs::BRANCH_BACKING_METADATA_BYTES
                    / crate::jobs::BRANCH_BACKING_METADATA) as usize
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let borrower = Arc::new(());
        let key = input.expected.metadata_sha256.clone();
        entries.insert(
            key.clone(),
            Arc::new(Entry {
                ownership: Arc::new(Ownership {
                    intent: input.intent.take().unwrap(),
                    creation,
                    jobs: input.jobs.clone(),
                }),
                expected: input.expected.clone(),
                borrower: Mutex::new(Arc::downgrade(&borrower)),
                work: Mutex::new(Work {
                    prepared: input.prepared.take(),
                    collected: None,
                    phase: Phase::Prepared,
                    worker: Weak::new(),
                    snapshot: None,
                    boot: None,
                }),
            }),
        );
        Ok(RetainedBranchPreparation {
            registry: Arc::downgrade(self),
            key,
            borrower,
        })
    }
}
impl Drop for Registry {
    fn drop(&mut self) {
        // Only an explicitly acknowledged backing-release receipt permits this
        // charge to reach zero. Owner loss never proves disposal. Keep history
        // during the owner's lifetime; normally drop only already released ones.
        for (_, child) in
            std::mem::take(self.completed.get_mut().unwrap_or_else(|e| e.into_inner()))
        {
            if child._backing.material_bytes() != 0 {
                child.jobs.quarantine();
                std::mem::forget(child);
            }
        }
        for (_, child) in std::mem::take(self.disposed.get_mut().unwrap_or_else(|e| e.into_inner()))
        {
            if child.backing.material_bytes() != 0 {
                child.jobs.quarantine();
                std::mem::forget(child);
            }
        }
        for (_, child) in std::mem::take(
            self.partial_disposed
                .get_mut()
                .unwrap_or_else(|e| e.into_inner()),
        ) {
            if child.backing.material_bytes() != 0 {
                child.jobs.quarantine();
                std::mem::forget(child);
            }
        }
        let entries = self.entries.get_mut().unwrap_or_else(|p| p.into_inner());
        for (_, entry) in std::mem::take(entries) {
            let retained = entry.work.try_lock().map_or(true, |work| {
                work.phase != Phase::Prepared
                    || work
                        .prepared
                        .as_ref()
                        .is_none_or(|p| p.verify_unentered_branch().is_err())
            });
            if retained {
                // No original SDK owner, source/child gate or allowance may be
                // released while entered work lacks publication/retirement.
                entry.ownership.jobs.quarantine();
                std::mem::forget(entry);
            }
        }
    }
}
impl RetainedBranchPreparation {
    fn completed(&self, engine: &Engine) -> Result<Option<crate::BranchCompletion>> {
        let registry = self
            .registry
            .upgrade()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !Arc::ptr_eq(&registry, &engine.branch_retention)
            || !Arc::ptr_eq(&registry.domain, &engine.domain)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        registry.domain.verify()?;
        let completed = registry
            .completed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let Some(child) = completed.get(&self.key) else {
            return Ok(None);
        };
        if !child
            .borrower
            .upgrade()
            .is_some_and(|owner| Arc::ptr_eq(&owner, &self.borrower))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(Some(child.result.clone()))
    }
    fn entry(&self, engine: &Engine) -> Result<Arc<Entry>> {
        let registry = self
            .registry
            .upgrade()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !Arc::ptr_eq(&registry, &engine.branch_retention)
            || !Arc::ptr_eq(&registry.domain, &engine.domain)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        registry.domain.verify()?;
        let entry = registry
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .get(&self.key)
            .cloned()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !entry
            .borrower
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .upgrade()
            .is_some_and(|borrower| Arc::ptr_eq(&borrower, &self.borrower))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(entry)
    }
    /// In-memory original-job state only, never child absence or ready evidence.
    pub fn state(&self, engine: &Engine) -> Result<BranchPreparationState> {
        if let Some(completed) = self.completed(engine)? {
            return Ok(if completed.held {
                BranchPreparationState::Held
            } else {
                BranchPreparationState::Ready
            });
        }
        let entry = self.entry(engine)?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work
            .boot
            .as_ref()
            .is_some_and(|boot| boot.collection_started())
        {
            return Ok(BranchPreparationState::Unresolved);
        }
        Ok(match work.phase {
            Phase::Prepared => BranchPreparationState::Prepared,
            Phase::Verified => BranchPreparationState::Collected,
            Phase::Published => BranchPreparationState::MaterialPublished,
            Phase::DisposalEntered => BranchPreparationState::Disposing,
            Phase::Disposed => BranchPreparationState::Disposed,
            Phase::BootEntered if work.worker.upgrade().is_some() => {
                BranchPreparationState::Booting
            }
            Phase::BootEntered => BranchPreparationState::Unresolved,
            Phase::Booted => BranchPreparationState::Booted,
            Phase::IdentityEntered if work.worker.upgrade().is_some() => {
                BranchPreparationState::Initializing
            }
            Phase::IdentityEntered => BranchPreparationState::Unresolved,
            Phase::IdentityReady => BranchPreparationState::IdentityReady,
            Phase::ReleaseEntered if work.worker.upgrade().is_some() => {
                BranchPreparationState::Releasing
            }
            Phase::ReleaseEntered => BranchPreparationState::Unresolved,
            Phase::Released => BranchPreparationState::Released,
            Phase::Entered if work.worker.upgrade().is_some() => BranchPreparationState::Preparing,
            Phase::Entered => BranchPreparationState::Unresolved,
        })
    }
    /// Explicitly retire only unchanged unentered input with positive original
    /// source authority. Failure preserves the registered owner and admission.
    pub fn abort(self, engine: &Engine, budget: &ReadBudget) -> Result<InitialBranchRetirement> {
        let entry = self.entry(engine)?;
        let registry = self
            .registry
            .upgrade()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        registry.retire_entry(engine, &entry, budget)
    }
    /// Enter the clean SDK held-fork preparation exactly once. Successful
    /// collection verifies Created no-PID child material but grants no child ownership,
    /// boot, release or public ready result. Retention remains charged afterwards.
    /// The bridge must retain the public child-plus-extra reservation separately;
    /// native preparation backing admission does not replace store capacity.
    pub fn prepare_fork(&self, engine: &Engine) -> Result<()> {
        let entry = self.entry(engine)?;
        let intent = &entry.ownership.intent;
        let budget = &intent.guard.budget;
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.phase != Phase::Prepared {
            return Err(Error::before(ErrorCode::State));
        }
        intent.recheck(engine)?;
        engine.binding().validate()?;
        let supervisor = engine
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let prepared = work
            .prepared
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?;
        prepared.verify_unentered_branch()?;
        let crate::transfer_worker::Kind::BranchPrepare { metadata, expected } =
            &prepared.request.kind
        else {
            return Err(Error::before(ErrorCode::Validation));
        };
        if *expected != entry.expected {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let selected: crate::branch_worker::Metadata =
            metadata.read(prepared.request.owner, crate::branch_worker::METADATA_BYTES)?;
        let stage = crate::export_source::Root::open(&selected.grant.directory)?;
        let info = stage
            .descriptor()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if (info.dev(), info.ino()) != (selected.grant.device, selected.grant.inode) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        stage.verify()?;
        drop(stage);
        let before = engine
            .observation_record(&intent.intent.source.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        intent.intent.verify_record(&before)?;
        budget.check()?;
        // Retention and the conservative in-memory entered state precede even
        // the journal write: an fsync error cannot release original authority.
        work.phase = Phase::Entered;
        let journal = crate::material::MaterialJournal::at(&selected.source_directory);
        journal
            .enter_branch_preparation(&selected.grant, &entry.expected, &before)
            .map_err(|e| Error::uncertain(e.code))?;
        let prepared = work
            .prepared
            .take()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        let worker = Arc::new(());
        work.worker = Arc::downgrade(&worker);
        drop(work);
        let result = supervisor
            .run(
                prepared,
                Box::new((entry.ownership.clone(), worker)),
                budget.deadline,
                &budget.cancel,
            )
            .map_err(|e| Error::uncertain(e.code))?;
        let RunResult::Collected(mut collected) = result else {
            return Err(Error::uncertain(ErrorCode::Native));
        };
        let verified = verify_collected(
            &mut collected,
            &selected,
            &entry.expected,
            &before,
            budget,
        )
        .and_then(|snapshot| {
            engine.verify_database_identity()?;
            if engine.observation_epoch().as_deref() != Some(intent.intent.epoch.as_str()) {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            if !engine
                .branch_source_authority(
                    &intent.intent.source,
                    intent.intent.source_pid,
                    &snapshot.source,
                    &snapshot.child,
                    budget,
                )?
                .running()
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            intent.guard.source_root.verify()?;
            journal.authorize_branch_preparation(&selected.grant, &entry.expected, &before)?;
            budget.check()?;
            Ok(snapshot)
        });
        let mut work = entry
            .work
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        // Collection alone never permits spool removal or allowance release.
        work.collected = Some(collected);
        work.worker = Weak::new();
        match verified {
            Ok(snapshot) => {
                work.snapshot = Some(snapshot);
                work.phase = Phase::Verified;
                Ok(())
            }
            Err(error) => Err(Error::uncertain(error.code)),
        }
    }
    /// Publish independent child material and the permitted source transition.
    /// Both original gates and backing remain retained; this is not child boot,
    /// readiness, release or permission to retire its source dependency.
    pub fn publish_material(&self, engine: &Engine) -> Result<crate::BranchPublication> {
        let entry = self.entry(engine)?;
        self.publish_material_with_budget(engine, &entry.ownership.intent.guard.budget)
    }
    pub(super) fn publish_material_with_budget(
        &self,
        engine: &Engine,
        budget: &ReadBudget,
    ) -> Result<crate::BranchPublication> {
        self.publish_material_checked(
            engine,
            budget,
            || engine.binding().validate(),
            |intent, source, child, budget| {
                engine.branch_source_authority(
                    &intent.source,
                    intent.source_pid,
                    source,
                    child,
                    budget,
                )
            },
        )
    }
    fn publish_material_checked(
        &self,
        engine: &Engine,
        budget: &ReadBudget,
        binding: impl Fn() -> Result<()>,
        source_authority: impl Fn(
            &InitialBranchJournal,
            &smolvm::config::VmRecord,
            &smolvm::config::VmRecord,
            &ReadBudget,
        ) -> Result<crate::capture_resolution::SourceAuthority>,
    ) -> Result<crate::BranchPublication> {
        let entry = self.entry(engine)?;
        let original = &entry.ownership.intent;
        let intent = &original.intent;
        let journal = crate::material::MaterialJournal::at(original.guard.source_root.path());
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if !matches!(work.phase, Phase::Verified | Phase::Published) {
            return Err(Error::before(ErrorCode::State));
        }
        (|| {
            engine.verify_database_identity()?;
            original.guard.source_root.verify()?;
            require_marker(engine, &intent.source)?;
            // A synchronized result may outlive acknowledgement and its original
            // deadline. Exact lookup never changes SDK rows, labels or journal head.
            if let Some(completed) = journal.completed_branch_publication(
                &intent.source,
                &intent.child.operation_id,
                &intent.request_sha256,
            )? {
                engine.promote_branch_handle(&completed.previous, &completed.receipt)?;
                work.phase = Phase::Published;
                return Ok(completed);
            }
            if work.phase != Phase::Verified {
                return Err(Error::before(ErrorCode::State));
            }
            binding()?;
            budget.check()?;
            if engine.observation_epoch().as_deref() != Some(intent.epoch.as_str()) {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let snapshot = work
                .snapshot
                .as_ref()
                .ok_or(Error::before(ErrorCode::State))?;
            snapshot._snapshot.verify()?;
            snapshot._child.verify()?;
            let generation = snapshot
                .child
                .fork_generation
                .as_deref()
                .ok_or(Error::before(ErrorCode::Ownership))?;
            let (publication, owned) = crate::BranchPublication::issue(
                intent,
                &snapshot.before,
                &snapshot.source,
                &snapshot.child,
                generation,
            )?;
            let collected = work
                .collected
                .as_ref()
                .ok_or(Error::before(ErrorCode::State))?;
            let crate::transfer_worker::Kind::BranchPrepare { metadata, .. } =
                &collected.prepared.request.kind
            else {
                return Err(Error::before(ErrorCode::State));
            };
            let selected: crate::branch_worker::Metadata = metadata.read(
                collected.prepared.request.owner,
                crate::branch_worker::METADATA_BYTES,
            )?;
            crate::branch_worker::verify_request(
                &selected,
                &collected.prepared.request,
                &entry.expected,
            )?;
            let pending = journal.pending_branch_publication(&selected.grant, &entry.expected)?;
            if pending
                .as_ref()
                .is_some_and(|previous| previous != &publication)
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let source = engine
                .observation_record(&intent.source.name, budget)?
                .ok_or(Error::before(ErrorCode::Ownership))?;
            let child = engine
                .observation_record(&intent.child.name, budget)?
                .ok_or(Error::before(ErrorCode::Ownership))?;
            engine.branch_child_unstarted(&intent.child.name)?;
            if !publication.receipt.matches(&source)?
                || source.pid.zip(source.pid_start_time) != Some(intent.source_pid)
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let raw_hash = crate::material::hash(&snapshot.child)?;
            let owned_hash = crate::material::hash(&owned)?;
            let current_hash = crate::material::hash(&child)?;
            if current_hash != raw_hash && (pending.is_none() || current_hash != owned_hash) {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if pending.is_none() {
                for name in ["smolbox.incarnation", "smolbox.material-v2.json"] {
                    match std::fs::symlink_metadata(snapshot._child.path().join(name)) {
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                        _ => return Err(Error::before(ErrorCode::Ownership)),
                    }
                }
            }
            let authority = source_authority(intent, &source, &child, budget)?;
            if !authority.running() {
                return Err(Error::before(ErrorCode::Ownership));
            }
            budget.check()?;
            journal.begin_branch_publication(
                &selected.grant,
                &entry.expected,
                &publication,
                &snapshot.before,
                &snapshot.source,
                &snapshot.child,
            )?;
            // Only the exact protected publication can continue this private row
            // transition. Never recover ownership from a label or current row.
            if current_hash == raw_hash {
                let mut replaced = false;
                engine
                    .db
                    .update_vm(&intent.child.name, |record| {
                        if crate::material::hash(record).ok().as_ref() == Some(&raw_hash) {
                            *record = owned.clone();
                            replaced = true;
                        }
                    })
                    .map_err(|_| Error::uncertain(ErrorCode::Database))?;
                if !replaced {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
            }
            budget.check().map_err(|e| Error::uncertain(e.code))?;
            snapshot
                ._child
                .verify()
                .map_err(|e| Error::uncertain(e.code))?;
            let child = engine
                .observation_record(&intent.child.name, budget)?
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            if crate::material::hash(&child)? != owned_hash {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            journal.authorize_branch_publication(&selected.grant, &entry.expected, &publication)?;
            crate::machine::publish_branch_marker(publication.child(), snapshot._child.path())?;
            crate::material::MaterialJournal::at(snapshot._child.path())
                .initialize_branch_child(&publication, &child)?;
            snapshot
                ._child
                .verify()
                .map_err(|e| Error::uncertain(e.code))?;
            snapshot
                ._snapshot
                .verify()
                .map_err(|e| Error::uncertain(e.code))?;
            let source = engine
                .observation_record(&intent.source.name, budget)?
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            let authority = source_authority(intent, &source, &child, budget)?;
            budget.check().map_err(|e| Error::uncertain(e.code))?;
            original
                .guard
                .source_root
                .verify()
                .map_err(|e| Error::uncertain(e.code))?;
            let completed = journal.complete_branch_publication(
                &selected.grant,
                &entry.expected,
                &publication,
                (&source, &child),
                snapshot._child.path(),
                &authority,
            )?;
            engine
                .promote_branch_handle(&completed.previous, &completed.receipt)
                .map_err(|e| Error::uncertain(e.code))?;
            work.phase = Phase::Published;
            Ok(completed)
        })()
        .map_err(|error| Error::uncertain(error.code))
    }
}

fn verify_collected(
    collected: &mut Collected,
    metadata: &crate::branch_worker::Metadata,
    expected: &crate::branch_worker::Expected,
    before: &smolvm::config::VmRecord,
    budget: &ReadBudget,
) -> Result<VerifiedSnapshot> {
    budget.check()?;
    let crate::transfer_worker::Kind::BranchPrepare {
        metadata: blob,
        expected: selected,
    } = &collected.prepared.request.kind
    else {
        return Err(Error::uncertain(ErrorCode::Ownership));
    };
    if selected != expected {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    let received: crate::branch_worker::Metadata = blob.read(
        collected.prepared.request.owner,
        crate::branch_worker::METADATA_BYTES,
    )?;
    crate::branch_worker::verify_request(&received, &collected.prepared.request, expected)?;
    crate::branch_worker::verify_request(metadata, &collected.prepared.request, expected)?;
    let proof = collected
        .branch_prepared
        .as_ref()
        .filter(|proof| proof.matches(expected))
        .ok_or(Error::uncertain(ErrorCode::Native))?;
    if !collected.outcome.success() || !collected.outcome.native_acknowledged {
        return Err(Error::uncertain(ErrorCode::Native));
    }
    let output = read_output(
        &mut collected.prepared.spool,
        proof,
        expected,
        metadata.grant.owner,
        budget,
    )?;
    crate::sdk_compat::validate_database(
        &metadata.database,
        (metadata.database_device, metadata.database_inode),
    )?;
    crate::sdk_compat::observe_records(
        &metadata.database,
        (metadata.database_device, metadata.database_inode),
        budget,
    )?;
    let read = |name: &str| {
        crate::sdk_compat::observe_record(
            &metadata.database,
            (metadata.database_device, metadata.database_inode),
            name,
            budget,
        )?
        .ok_or(Error::uncertain(ErrorCode::Ownership))
    };
    let source = read(&metadata.grant.intent.source.name)?;
    let child = read(&metadata.grant.intent.child.name)?;
    if crate::identity::material_hash(&source)? != output.source_material_sha256
        || crate::identity::material_hash(&child)? != output.child_material_sha256
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    crate::branch_worker::verify_sdk_result(
        &metadata.grant.intent,
        before,
        &source,
        &smolvm::agent::fork::PreparedFork {
            snapshot_dir: output.snapshot.clone(),
            clone_record: child.clone(),
            port_remaps: vec![],
            source_continues: output.source_continues,
        },
    )?;
    let snapshot = crate::export_source::Root::open(&output.snapshot)?;
    let info = snapshot
        .descriptor()
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    if (info.dev(), info.ino()) != (output.snapshot_device, output.snapshot_inode) {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    let child_root = crate::export_source::Root::open(&smolvm::agent::vm_data_dir(
        &metadata.grant.intent.child.name,
    ))?;
    budget.check()?;
    Ok(VerifiedSnapshot {
        before: before.clone(),
        source,
        child,
        _snapshot: snapshot,
        _child: child_root,
    })
}
fn read_output(
    spool: &mut crate::transfer_supervisor::Spool,
    proof: &crate::branch_worker::Proof,
    expected: &crate::branch_worker::Expected,
    owner: crate::OwnerIdentity,
    budget: &ReadBudget,
) -> Result<crate::branch_worker::Output> {
    budget.check()?;
    if !proof.matches(expected) {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    spool.verify()?;
    let info = spool
        .file
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let version = crate::checkpoint_materialize::FileVersion::of(&info);
    if info.len() != proof.bytes
        || info.nlink() != 1
        || info.uid() != owner.uid
        || info.mode() & 0o777 != 0o600
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    spool
        .file
        .seek(SeekFrom::Start(0))
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let mut bytes = Vec::new();
    std::io::Read::by_ref(&mut spool.file)
        .take(crate::branch_worker::OUTPUT_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let output: crate::branch_worker::Output =
        serde_json::from_slice(&bytes).map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
    if bytes.len() as u64 != proof.bytes
        || output.schema != 1
        || !output.source_continues
        || crate::material::hash(&output)? != proof.sha256
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    spool.verify()?;
    if crate::checkpoint_materialize::FileVersion::of(
        &spool
            .file
            .metadata()
            .map_err(|_| Error::uncertain(ErrorCode::Io))?,
    ) != version
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    budget.check()?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    #[test]
    fn ordinary_non_branch_deletion_selection_ignores_busy_branch_completion_registry() {
        let temp = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(temp.path());
        let child = crate::machine::tests::install_record(&engine);
        let _busy = engine.branch_retention.completed.lock().unwrap();
        let budget = ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap();
        assert!(!engine
            .retained_released_deletion_head(&child, &budget)
            .unwrap());
        // Ordinary missing-row selection also avoids unrelated branch state;
        // the caller still performs its own receipt-bound presence checks.
        engine.db.remove_vm(&child.name).unwrap();
        assert!(!engine
            .retained_released_deletion_head(&child, &budget)
            .unwrap());
    }

    use super::*;
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;
    #[test]
    fn prepared_input_cannot_handoff_a_manager_or_free_source_child_gates() {
        let (_temp, engine, metadata, retained) = fixture();
        let counts = engine.jobs.counts();
        let source = engine
            .db
            .get_vm(&metadata.grant.intent.source.name)
            .unwrap()
            .unwrap();
        assert_eq!(
            retained.finish_child(&engine).unwrap_err().dispatch,
            crate::Dispatch::NotDispatched
        );
        assert_eq!(engine.jobs.counts(), counts);
        assert!(engine.owned_managers.lock().unwrap().is_empty());
        assert!(engine
            .observation_gate(&source.name)
            .unwrap()
            .try_lock()
            .is_err());
        assert!(engine
            .observation_gate(&metadata.grant.intent.child.name)
            .unwrap()
            .try_lock()
            .is_err());
        assert_eq!(
            crate::material::hash(&engine.db.get_vm(&source.name).unwrap().unwrap()).unwrap(),
            crate::material::hash(&source).unwrap()
        );
    }

    // Pure private-DB ownership model. These synthetic SDK PID fields are never
    // enrolled into a runtime, and insert_with_creation_checked cannot dispatch an SDK call.
    fn fixture() -> (
        tempfile::TempDir,
        Engine,
        crate::branch_worker::Metadata,
        RetainedBranchPreparation,
    ) {
        fixture_bound(false)
    }
    pub(super) fn fixture_bound(
        bound: bool,
    ) -> (
        tempfile::TempDir,
        Engine,
        crate::branch_worker::Metadata,
        RetainedBranchPreparation,
    ) {
        fixture_bound_with_budget(
            bound,
            ReadBudget::for_checkpoint_work(
                Duration::from_secs(60),
                crate::Cancellation::default(),
            )
            .unwrap(),
        )
    }
    pub(super) fn fixture_bound_with_budget(
        bound: bool,
        budget: ReadBudget,
    ) -> (
        tempfile::TempDir,
        Engine,
        crate::branch_worker::Metadata,
        RetainedBranchPreparation,
    ) {
        let (temp, metadata, expected) = crate::branch_worker::tests::fixture();
        let root = temp.path().canonicalize().unwrap();
        let engine = crate::machine::tests::test_engine(&root);
        let intent = metadata.grant.intent.clone();
        let record = engine.db.get_vm(&intent.source.name).unwrap().unwrap();
        crate::material::MaterialJournal::at(&metadata.source_directory)
            .prepare_initial_branch(&intent, &record)
            .unwrap();
        let executable = root.join("never-executed");
        std::fs::write(&executable, b"inert model executable").unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o500)).unwrap();
        let identity = crate::Executable {
            path: executable,
            sha256: hex::encode(sha2::Sha256::digest(b"inert model executable")),
        };
        let host = crate::HostContext::capture(
            engine.binding().clone(),
            "b".repeat(32),
            "c".repeat(64),
            crate::ExecutableLocator {
                boot: identity.clone(),
                file_worker: identity,
                library_directory: root,
            },
        )
        .unwrap();
        let supervisor =
            crate::transfer_supervisor::TransferSupervisor::new(&host, engine.jobs.clone())
                .unwrap();
        let (bytes, _) = metadata.encode().unwrap();
        let prepared = supervisor
            .prepare_branch_owned(&metadata.grant.directory, &bytes, expected.clone())
            .unwrap();
        let source_gate = engine.gate(&intent.source.name).unwrap();
        let child_gate = engine.gate(&intent.child.name).unwrap();
        let gates = crate::gate::lock_pair(
            (&intent.source.name, &source_gate),
            (&intent.child.name, &child_gate),
        )
        .unwrap();
        let mut job = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        job.promote_branch_preparation().unwrap();
        job.promote_branch_backing(intent.plan.preparation_disk_bytes().unwrap())
            .unwrap();
        let guard = PreparedInitialBranch {
            source: intent.source.clone(),
            intent: intent.child.clone(),
            approval: intent.approval.clone(),
            plan: intent.plan.clone(),
            request_sha256: intent.request_sha256.clone(),
            source_root: crate::export_source::Root::open(&metadata.source_directory).unwrap(),
            source_pid: intent.source_pid,
            epoch: intent.epoch.clone(),
            budget,
            _gates: gates,
            _job: job,
            domain: engine.domain.clone(),
            _runtime: engine.runtime.clone(),
        };
        let mut input = PreparedBranchWorker {
            prepared: Some(prepared),
            intent: Some(PreparedBranchIntent { guard, intent }),
            expected,
            jobs: engine.jobs.clone(),
        };
        let creation = bound.then(|| {
            let intent = &metadata.grant.intent;
            BranchCreateRequest {
                source: intent.source.clone(),
                child: intent.child.clone(),
                approval: intent.approval.clone(),
                initial_release: if intent.child.hold {
                    None
                } else {
                    Some(crate::BranchReleaseRequest {
                        operation_id: "original-activation".into(),
                        request_sha256: "a".repeat(64),
                    })
                },
            }
        });
        let token = engine
            .branch_retention
            .insert_with_creation_checked(&mut input, creation)
            .unwrap();
        assert!(input.intent.is_none() && input.prepared.is_none());
        (temp, engine, metadata, token)
    }
    use sha2::Digest;

    #[test]
    fn original_runtime_gates_and_admission_outlive_caller_and_engine_values() {
        let (temp, engine, metadata, token) = fixture();
        let source_gate = engine
            .observation_gate(&metadata.grant.intent.source.name)
            .unwrap();
        let child_gate = engine
            .observation_gate(&metadata.grant.intent.child.name)
            .unwrap();
        let before = engine.jobs.counts();
        assert_eq!(
            token.state(&engine).unwrap(),
            BranchPreparationState::Prepared
        );
        let entry = token.entry(&engine).unwrap();
        let ownership = entry.ownership.clone();
        let runtime = Arc::downgrade(&engine.runtime);
        let jobs = engine.jobs.clone();
        let binding = engine.binding().clone();
        let directory = engine.domain.directory.clone();
        let paths = {
            let work = entry.work.lock().unwrap();
            let prepared = work.prepared.as_ref().unwrap();
            (
                prepared.spool.path.clone(),
                match &prepared.request.kind {
                    crate::transfer_worker::Kind::BranchPrepare { metadata, .. } => {
                        metadata.path.clone()
                    }
                    _ => unreachable!(),
                },
            )
        };
        drop(entry);
        drop(token);
        assert_eq!(jobs.counts(), before);
        assert!(source_gate.try_lock().is_err() && child_gate.try_lock().is_err());
        let controls = [
            jobs.acquire(crate::jobs::Demand::volume_observation())
                .unwrap(),
            jobs.acquire(crate::jobs::Demand::volume_observation())
                .unwrap(),
        ];
        assert!(jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .is_err());
        drop(controls);
        drop(engine); // Unentered input may retire normally; original job stays in ownership.
        assert!(!paths.0.exists() && !paths.1.exists());
        assert!(runtime.upgrade().is_some());
        assert_eq!(jobs.counts(), before);
        assert!(
            crate::domain::DomainGuard::acquire_at(&binding, directory.clone(), false).is_err()
        );
        drop(ownership);
        assert!(runtime.upgrade().is_none());
        assert_eq!(jobs.counts(), crate::jobs::Counts::default());
        drop((
            source_gate.try_lock().unwrap(),
            child_gate.try_lock().unwrap(),
        ));
        drop(crate::domain::DomainGuard::acquire_at(&binding, directory, false).unwrap());
        drop(temp);
    }

    #[test]
    fn crossed_owner_missing_live_enrollment_and_active_borrower_cannot_dispatch_or_retire() {
        let (_temp, engine, metadata, token) = fixture();
        let journal = metadata.source_directory.join("smolbox.material-v2.json");
        let before = std::fs::read(&journal).unwrap();
        let admitted = engine.jobs.counts();
        let other = tempfile::tempdir().unwrap();
        let other = crate::machine::tests::test_engine(other.path());
        assert_eq!(token.state(&other).unwrap_err().code, ErrorCode::Ownership);
        assert!(token.prepare_fork(&engine).is_err()); // No live SDK handle or epoch exists.
        let intent = &metadata.grant.intent;
        let budget =
            ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap();
        let checked = crate::branch::prepared_retirement::tests::request(intent);
        assert_eq!(
            engine
                .retire_prepared_branch_checked(&checked, &budget)
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        assert_eq!(engine.jobs.counts(), admitted);
        assert_eq!(std::fs::read(&journal).unwrap(), before);
        assert_eq!(
            engine
                .retire_prepared_initial_branch(
                    &intent.source,
                    &intent.child.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(token);
        assert!(engine
            .retire_prepared_initial_branch(
                &intent.source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget
            )
            .is_err());
        assert_eq!(std::fs::read(journal).unwrap(), before);
        assert_eq!(engine.jobs.counts(), admitted);
    }

    #[test]
    fn recorded_prepared_retirement_releases_original_lease_after_lost_ack_without_rechecking_inventory(
    ) {
        let (_temp, engine, metadata, token) = fixture();
        let intent = &metadata.grant.intent;
        let journal = crate::material::MaterialJournal::at(&metadata.source_directory);
        let record = engine.db.get_vm(&intent.source.name).unwrap().unwrap();
        // Pure prior-authority model: no real PID, runtime enrollment, child or
        // SDK call is created. The production result lookup must consume the
        // protected completed proof, not derive authority from this inventory.
        let authority = crate::capture_resolution::SourceAuthority::verify(
            &record,
            intent.source_pid,
            crate::capture_resolution::SourceFacts {
                owner: Some(true),
                runtime_pid: Some(intent.source_pid.0),
                original_alive: true,
                observed_birth: Some(intent.source_pid.1),
                excluded: false,
            },
        )
        .unwrap();
        let proof = journal
            .retire_initial_branch(intent, &record, &authority)
            .unwrap();
        let file = metadata.source_directory.join("smolbox.material-v2.json");
        let bytes = std::fs::read(&file).unwrap();
        let admitted = engine.jobs.counts();
        let budget =
            ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap();
        assert!(
            engine
                .inspect_initial_branch_retirement(
                    &intent.source,
                    &intent.child.operation_id,
                    &intent.request_sha256,
                    &budget
                )
                .unwrap()
                .as_ref()
                == Some(&proof)
        );
        assert_eq!(
            engine
                .retire_prepared_initial_branch(
                    &intent.source,
                    &intent.child.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        assert_eq!(engine.jobs.counts(), admitted);
        drop(token);
        let returned = engine
            .retire_prepared_initial_branch(
                &intent.source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget,
            )
            .unwrap();
        assert!(returned == proof);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.branch_retention.entries.lock().unwrap().is_empty());
        assert!(engine
            .observation_gate(&intent.source.name)
            .unwrap()
            .try_lock()
            .is_ok());
        assert!(engine
            .observation_gate(&intent.child.name)
            .unwrap()
            .try_lock()
            .is_ok());
        assert!(
            engine
                .retire_prepared_initial_branch(
                    &intent.source,
                    &intent.child.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap()
                == proof
        );
        assert_eq!(std::fs::read(file).unwrap(), bytes);
    }

    #[test]
    fn entered_marker_survives_reopen_and_collection_never_becomes_prepared_abort_or_replay() {
        let (_temp, engine, metadata, token) = fixture();
        let entry = token.entry(&engine).unwrap();
        let source = &metadata.grant.intent.source;
        let record = engine.db.get_vm(&source.name).unwrap().unwrap();
        let journal = crate::material::MaterialJournal::at(&metadata.source_directory);
        entry.work.lock().unwrap().phase = Phase::Entered;
        journal
            .enter_branch_preparation(&metadata.grant, &entry.expected, &record)
            .unwrap();
        let reopened = crate::material::MaterialJournal::at(&metadata.source_directory);
        reopened
            .authorize_branch_preparation(&metadata.grant, &entry.expected, &record)
            .unwrap();
        let bytes =
            std::fs::read(metadata.source_directory.join("smolbox.material-v2.json")).unwrap();
        let admitted = engine.jobs.counts();
        assert!(journal
            .enter_branch_preparation(&metadata.grant, &entry.expected, &record)
            .is_err());
        assert_eq!(
            token.state(&engine).unwrap(),
            BranchPreparationState::Unresolved
        );
        let worker = Arc::new(());
        entry.work.lock().unwrap().worker = Arc::downgrade(&worker);
        assert_eq!(
            token.state(&engine).unwrap(),
            BranchPreparationState::Preparing
        );
        drop(worker); // Deterministic collection model; no OS process is created.
        assert_eq!(
            token.state(&engine).unwrap(),
            BranchPreparationState::Unresolved
        );
        assert_eq!(
            token.prepare_fork(&engine).unwrap_err().code,
            ErrorCode::State
        );
        let budget =
            ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap();
        assert_eq!(
            token.abort(&engine, &budget).unwrap_err().code,
            ErrorCode::State
        );
        assert_eq!(
            engine
                .retire_prepared_initial_branch(
                    source,
                    &metadata.grant.intent.child.operation_id,
                    &metadata.grant.intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        assert_eq!(engine.jobs.counts(), admitted);
        assert_eq!(
            std::fs::read(metadata.source_directory.join("smolbox.material-v2.json")).unwrap(),
            bytes
        );
        assert!(engine
            .observation_gate(&source.name)
            .unwrap()
            .try_lock()
            .is_err());
        // Private value-model teardown only: the test never entered the SDK,
        // captured a source or created a child/backing file. Product APIs have
        // no operation that clears this entered registry/journal state.
        engine.branch_retention.entries.lock().unwrap().clear();
        drop(entry);
    }

    #[test]
    fn bounded_parent_output_reader_rehashes_original_inode_and_rejects_crossed_or_changed_proof() {
        let (_temp, engine, metadata, token) = fixture();
        let entry = token.entry(&engine).unwrap();
        let mut work = entry.work.lock().unwrap();
        let prepared = work.prepared.as_mut().unwrap();
        let output = crate::branch_worker::Output {
            schema: 1,
            snapshot: "/inert/source/s/aabbccdd".into(),
            snapshot_device: 1,
            snapshot_inode: 2,
            source_material_sha256: "a".repeat(64),
            child_material_sha256: "b".repeat(64),
            source_continues: true,
        };
        let bytes = serde_json::to_vec(&output).unwrap();
        let proof = crate::branch_worker::Proof {
            expected: entry.expected.clone(),
            bytes: bytes.len() as u64,
            sha256: crate::material::hash(&output).unwrap(),
        };
        prepared.spool.file.write_all(&bytes).unwrap();
        let budget =
            ReadBudget::new(Duration::from_secs(30), crate::Cancellation::default()).unwrap();
        let read = read_output(
            &mut prepared.spool,
            &proof,
            &entry.expected,
            metadata.grant.owner,
            &budget,
        )
        .unwrap();
        assert_eq!(read.child_material_sha256, output.child_material_sha256);
        let mut changed = proof.clone();
        changed.expected.operation_id = "other".into();
        assert!(read_output(
            &mut prepared.spool,
            &changed,
            &entry.expected,
            metadata.grant.owner,
            &budget
        )
        .is_err());
        changed = proof.clone();
        changed.sha256 = "f".repeat(64);
        assert!(read_output(
            &mut prepared.spool,
            &changed,
            &entry.expected,
            metadata.grant.owner,
            &budget
        )
        .is_err());
        changed = proof.clone();
        changed.bytes = crate::branch_worker::OUTPUT_BYTES + 1;
        assert!(read_output(
            &mut prepared.spool,
            &changed,
            &entry.expected,
            metadata.grant.owner,
            &budget
        )
        .is_err());
        let path = prepared.spool.path.clone();
        let saved = path.with_extension("original");
        std::fs::rename(&path, &saved).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        assert!(read_output(
            &mut prepared.spool,
            &proof,
            &entry.expected,
            metadata.grant.owner,
            &budget
        )
        .is_err());
        std::fs::remove_file(&path).unwrap();
        std::fs::rename(saved, path).unwrap();
        let cancelled =
            ReadBudget::new(Duration::from_secs(1), crate::Cancellation::default()).unwrap();
        cancelled.cancel.cancel();
        assert!(read_output(
            &mut prepared.spool,
            &proof,
            &entry.expected,
            metadata.grant.owner,
            &cancelled
        )
        .is_err());
        // Restore the original empty, unentered spool for normal private teardown.
        prepared.spool.file.set_len(0).unwrap();
        drop(work);
    }
}
