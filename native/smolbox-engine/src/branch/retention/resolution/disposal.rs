//! Explicit disposal of an original published child that never entered boot.
//! A synchronized entered grant precedes SDK deletion. A failed/lost result can
//! only be observed, never replayed. Snapshot/backing and original gates stay
//! retained until the separate exact-proof terminal-job handoff.
use super::*;
use crate::branch_boot::Directory;
use serde::{Deserialize, Serialize};
mod archive;
mod candidate;
pub use candidate::UnbootedBranchDisposalCandidate;
mod ledger;
#[cfg(test)]
pub(super) mod tests;
pub(in crate::branch::retention) use archive::DisposedChild;
use ledger::{Intent, Ledger, Record, Stage};

const PROOF_BYTES: usize = 32 * 1024;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchDisposalRequest {
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for UnbootedBranchDisposalRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnbootedBranchDisposalRequest")
            .finish_non_exhaustive()
    }
}
impl UnbootedBranchDisposalRequest {
    pub fn digest(&self, creation: &BranchCreateRequest) -> Result<String> {
        crate::material::hash(&(
            "smolbox-unbooted-branch-disposal-request-v1",
            creation,
            &self.operation_id,
            self.quiesced,
        ))
    }
    fn validate(&self, creation: &BranchCreateRequest) -> Result<()> {
        validate_creation(creation)?;
        if !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id == creation.child.operation_id
            || creation
                .initial_release
                .as_ref()
                .is_some_and(|release| release.operation_id == self.operation_id)
            || self.request_sha256 != self.digest(creation)?
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UnbootedBranchDisposalCompletion {
    Deleted,
    ResolvedAbsent,
}
/// Historical acknowledgement that this original child was disposed before
/// boot. It preserves source publication and does not attest current source
/// liveness, snapshot removal, backing release, or any guest/boot completion.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchDisposal {
    pub schema: u8,
    pub completion: UnbootedBranchDisposalCompletion,
    pub creation: BranchCreateRequest,
    pub request: UnbootedBranchDisposalRequest,
    pub publication: crate::BranchPublication,
    pub disposal_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for UnbootedBranchDisposal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnbootedBranchDisposal")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl UnbootedBranchDisposal {
    pub fn validate(&self) -> Result<()> {
        self.request.validate(&self.creation)?;
        self.publication.validate()?;
        self.publication
            .change
            .child_origin
            .intent
            .matches_creation(&self.creation)?;
        if self.schema != 1
            || !crate::domain::valid_hex(&self.disposal_sha256, 64)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PROOF_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-unbooted-branch-disposal-proof-v1",
            self.schema,
            self.completion,
            &self.creation,
            &self.request,
            &self.publication,
            &self.disposal_sha256,
        ))
    }
    fn issue(intent: &Intent, completion: UnbootedBranchDisposalCompletion) -> Result<Self> {
        let mut proof = Self {
            schema: 1,
            completion,
            creation: intent.creation.clone(),
            request: intent.request.clone(),
            publication: intent.publication.clone(),
            disposal_sha256: crate::material::hash(intent)?,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        proof.validate()?;
        Ok(proof)
    }
}
impl RetainedBranchResolution {
    /// Delete only the original fully published, never-booted child. A failed
    /// entry/result cannot be retried; use resolve_unbooted_disposal to observe
    /// its exact entered grant. No stop, boot, release or source/snapshot cleanup.
    pub fn dispose_unbooted_child(
        &self,
        engine: &Engine,
        request: &UnbootedBranchDisposalRequest,
    ) -> Result<UnbootedBranchDisposal> {
        self.verify_epoch(engine)?;
        self.dispose_checked(
            engine,
            request,
            false,
            |publication, source, after| {
                live_source(engine, publication, source, &self.budget, after)
            },
            |name| {
                if smolvm::agent::vm_data_dir(name) != engine.vm_directory(name) {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                engine
                    .runtime
                    .delete_machine(name)
                    .map_err(|_| Error::uncertain(ErrorCode::Native))
            },
        )
    }
    /// Observe only the exact entered disposal. Child row/reservation/directory
    /// absence and the unchanged source are required. Never calls SDK deletion.
    pub fn resolve_unbooted_disposal(
        &self,
        engine: &Engine,
        request: &UnbootedBranchDisposalRequest,
    ) -> Result<UnbootedBranchDisposal> {
        self.verify_epoch(engine)?;
        self.dispose_checked(
            engine,
            request,
            true,
            |publication, source, after| {
                live_source(engine, publication, source, &self.budget, after)
            },
            |_| Err(Error::before(ErrorCode::State)),
        )
    }
    fn dispose_checked(
        &self,
        engine: &Engine,
        request: &UnbootedBranchDisposalRequest,
        observe_only: bool,
        source_authority: impl Fn(
            &crate::BranchPublication,
            &smolvm::config::VmRecord,
            bool,
        ) -> Result<()>,
        delete: impl FnOnce(&str) -> Result<()>,
    ) -> Result<UnbootedBranchDisposal> {
        validate_budget(&self.budget)?;
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        request.validate(&self.creation)?;
        let entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
        engine.verify_database_identity()?;
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.boot.is_some()
            || work.worker.upgrade().is_some()
            || !matches!(
                work.phase,
                Phase::Published | Phase::DisposalEntered | Phase::Disposed
            )
        {
            return Err(Error::before(ErrorCode::State));
        }
        let snapshot = work
            .snapshot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let publication =
            crate::material::MaterialJournal::at(entry.ownership.intent.guard.source_root.path())
                .completed_branch_publication(
                    &self.creation.source,
                    &self.creation.child.operation_id,
                    &entry.ownership.intent.intent.request_sha256,
                )?
                .ok_or(Error::before(ErrorCode::Ownership))?;
        let intent = intent(&entry, snapshot, &publication, request)?;
        let ledger = Ledger::new(engine.domain.clone(), &self.creation)?;
        let saved = ledger.read()?;
        if let Some((saved, version)) = &saved {
            if saved.intent != intent {
                return Err(Error::before(ErrorCode::Conflict));
            }
            if let Some(proof) = &saved.proof {
                ledger
                    .synchronize(version)
                    .map_err(|e| Error::uncertain(e.code))?;
                let proof = proof.clone();
                work.phase = Phase::Disposed;
                self.budget.check().map_err(|e| Error::uncertain(e.code))?;
                return Ok(proof);
            }
        }
        if observe_only {
            let (saved, version) = saved.ok_or(Error::before(ErrorCode::State))?;
            if saved.stage != Stage::Entered || work.phase != Phase::DisposalEntered {
                return Err(Error::before(ErrorCode::State));
            }
            self.absence(engine, &entry, &intent, snapshot, &source_authority)
                .map_err(|e| Error::uncertain(e.code))?;
            let proof = UnbootedBranchDisposal::issue(
                &intent,
                UnbootedBranchDisposalCompletion::ResolvedAbsent,
            )
            .map_err(|e| Error::uncertain(e.code))?;
            ledger
                .write(
                    &Record {
                        schema: 1,
                        intent,
                        stage: Stage::ResolvedAbsent,
                        proof: Some(proof.clone()),
                    },
                    Some(version),
                )
                .map_err(|e| Error::uncertain(e.code))?;
            work.phase = Phase::Disposed;
            self.budget.check().map_err(|e| Error::uncertain(e.code))?;
            return Ok(proof);
        }
        if saved.is_some() || work.phase != Phase::Published {
            return Err(Error::uncertain(ErrorCode::State));
        }
        self.ready(
            engine,
            &entry,
            &intent.publication,
            snapshot,
            &source_authority,
        )?;
        work.phase = Phase::DisposalEntered;
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
        let entered = ledger
            .read()
            .map_err(|e| Error::uncertain(e.code))?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if entered.0.intent != intent || entered.0.stage != Stage::Entered {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        delete(&intent.creation.child.name).map_err(|e| Error::uncertain(e.code))?;
        let snapshot = work
            .snapshot
            .as_ref()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        self.absence(engine, &entry, &intent, snapshot, &source_authority)
            .map_err(|e| Error::uncertain(e.code))?;
        let proof =
            UnbootedBranchDisposal::issue(&intent, UnbootedBranchDisposalCompletion::Deleted)
                .map_err(|e| Error::uncertain(e.code))?;
        ledger
            .write(
                &Record {
                    schema: 1,
                    intent,
                    stage: Stage::Deleted,
                    proof: Some(proof.clone()),
                },
                Some(entered.1),
            )
            .map_err(|e| Error::uncertain(e.code))?;
        work.phase = Phase::Disposed;
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
    fn ready(
        &self,
        engine: &Engine,
        entry: &Entry,
        publication: &crate::BranchPublication,
        snapshot: &VerifiedSnapshot,
        authority: &impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
    ) -> Result<()> {
        self.budget.check()?;
        snapshot._child.verify()?;
        snapshot._snapshot.verify()?;
        let name = &self.creation.child.name;
        engine.branch_child_unstarted(name)?;
        let record = engine
            .observation_record(name, &self.budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if record.state != smolvm::config::RecordState::Created
            || record.pid.is_some()
            || record.pid_start_time.is_some()
            || !record.forkpoint_held
            || !record.fork_env.is_empty()
            || !publication.child().matches(&record)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        crate::machine::verify_branch_marker(publication.child(), snapshot._child.path())?;
        let child_journal = crate::material::MaterialJournal::at(snapshot._child.path());
        child_journal.verify(publication.child())?;
        child_journal.verify_branch_child(publication.child(), &record)?;
        crate::branch_boot::Lifecycle::at(snapshot._child.path())
            .unentered(publication, &snapshot._child)?;
        crate::sdk_compat::branch_deletion_cache(snapshot._child.path())?;
        if !crate::sdk_compat::source_dependents(
            &engine.binding().database,
            engine.database_identity,
            name,
            &self.budget,
        )?
        .is_empty()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let source = source_record(engine, entry, publication, &self.budget)?;
        authority(publication, &source, false)?;
        self.budget.check()
    }
    fn absence(
        &self,
        engine: &Engine,
        entry: &Entry,
        intent: &Intent,
        snapshot: &VerifiedSnapshot,
        authority: &impl Fn(&crate::BranchPublication, &smolvm::config::VmRecord, bool) -> Result<()>,
    ) -> Result<()> {
        self.budget.check()?;
        snapshot._snapshot.verify()?;
        engine.branch_child_unstarted(&intent.creation.child.name)?;
        if !crate::sdk_compat::observe_absence_budget(
            &engine.binding().database,
            engine.database_identity,
            &intent.creation.child.name,
            &self.budget,
            || {
                Ok(
                    matches!(std::fs::symlink_metadata(&intent.child.path), Err(e) if e.kind() == std::io::ErrorKind::NotFound),
                )
            },
        )? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let source = source_record(engine, entry, &intent.publication, &self.budget)?;
        authority(&intent.publication, &source, true)?;
        self.budget.check()
    }
}
pub(super) fn source_record(
    engine: &Engine,
    entry: &Entry,
    publication: &crate::BranchPublication,
    budget: &ReadBudget,
) -> Result<smolvm::config::VmRecord> {
    engine.verify_database_identity()?;
    entry.ownership.intent.guard.source_root.verify()?;
    engine.domain.verify()?;
    require_marker(engine, &entry.ownership.intent.intent.source)?;
    let source = engine
        .observation_record(&publication.receipt.name, budget)?
        .ok_or(Error::before(ErrorCode::Ownership))?;
    if !publication.receipt.matches(&source)? {
        return Err(Error::before(ErrorCode::Ownership));
    }
    crate::material::MaterialJournal::at(entry.ownership.intent.guard.source_root.path())
        .verify(&publication.receipt)?;
    Ok(source)
}
pub(super) fn live_source(
    engine: &Engine,
    publication: &crate::BranchPublication,
    source: &smolvm::config::VmRecord,
    budget: &ReadBudget,
    after: bool,
) -> Result<()> {
    let authority = engine.branch_admission_source_authority(
        &publication.receipt,
        publication.change.child_origin.intent.source_pid,
        source,
        None,
        budget,
    )?;
    if !authority.running() {
        return Err(Error::before(ErrorCode::Ownership));
    }
    if !after
        && !crate::sdk_compat::source_dependents(
            &engine.binding().database,
            engine.database_identity,
            &publication.receipt.name,
            budget,
        )?
        .contains(&publication.child().name)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
fn intent(
    entry: &Entry,
    snapshot: &VerifiedSnapshot,
    publication: &crate::BranchPublication,
    request: &UnbootedBranchDisposalRequest,
) -> Result<Intent> {
    let creation = entry
        .ownership
        .creation
        .clone()
        .ok_or(Error::before(ErrorCode::Ownership))?;
    publication
        .change
        .child_origin
        .intent
        .matches_creation(&creation)?;
    if publication.change.child_origin.raw_child_sha256
        != crate::identity::material_hash(&snapshot.child)?
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    // The original open child descriptor remains the identity even after unlink.
    let info = snapshot
        ._child
        .descriptor()
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    Ok(Intent {
        creation,
        request: request.clone(),
        publication: publication.clone(),
        metadata_sha256: entry.expected.metadata_sha256.clone(),
        source: Directory::capture(&entry.ownership.intent.guard.source_root)?,
        child: Directory {
            path: snapshot._child.path().into(),
            device: info.dev(),
            inode: info.ino(),
        },
        snapshot: Directory::capture(&snapshot._snapshot)?,
    })
}
