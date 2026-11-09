//! Branch admission, protected intent and original-owner SDK preparation.
//! Preparation does not publish source material, own a child or boot its VMM.
use crate::{CreationReceipt, Engine, Error, ErrorCode, ReadBudget, Resources, Result};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

mod creation;
pub(crate) mod prepared_retirement;
pub use prepared_retirement::{
    PreparedBranchRetirement, PreparedBranchRetirementRequest, PREPARED_BRANCH_RETIREMENT_BYTES,
};
pub(crate) mod retention;
pub use creation::BranchCreateRequest;
pub use retention::{
    BranchBackingRelease, BranchBootIdentity, BranchGuestIdentity, BranchPreparationState,
    RetainedBranchPreparation, RetainedBranchResolution, UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate, UnbootedBranchDisposalCompletion,
    UnbootedBranchDisposalRequest,
};

const POLICY_LIMIT: u64 = 1_048_576;
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchResources {
    pub slots: u64,
    pub cpus: u64,
    pub memory_mb: u64,
    pub disk_gb: u64,
}
impl BranchResources {
    fn validate(&self) -> Result<()> {
        if [self.slots, self.cpus, self.memory_mb, self.disk_gb]
            .iter()
            .any(|n| !(1..=POLICY_LIMIT).contains(n))
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    fn add(self, extra: Self) -> Result<Self> {
        let add = |a: u64, b: u64| a.checked_add(b).ok_or(Error::before(ErrorCode::Admission));
        Ok(Self {
            slots: add(self.slots, extra.slots)?,
            cpus: add(self.cpus, extra.cpus)?,
            memory_mb: add(self.memory_mb, extra.memory_mb)?,
            disk_gb: add(self.disk_gb, extra.disk_gb)?,
        })
    }
}
/// Exact operator policy plus the owning profile's separate host overhead.
/// A bridge must select this from its approved catalog, never from inventory.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchApproval {
    pub id: String,
    pub host_overhead_mb: u64,
    pub resources: BranchResources,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchResourcePlan {
    pub ordinary_child: BranchResources,
    pub total_additional: BranchResources,
    pub minimum_extra_memory_mb: u64,
    pub minimum_extra_disk_gb: u64,
}
impl BranchResourcePlan {
    /// Finite native preparation backing, within the separately approved public
    /// child-plus-extra reservation. This is admission, never a host disk quota.
    pub(crate) fn preparation_disk_bytes(&self) -> Result<u64> {
        self.ordinary_child
            .disk_gb
            .checked_add(self.minimum_extra_disk_gb)
            .and_then(|gib| gib.checked_mul(1 << 30))
            .ok_or(Error::before(ErrorCode::Admission))
    }
}
impl BranchApproval {
    fn validate(&self) -> Result<()> {
        if !crate::domain::valid_id(&self.id) || !(128..=16_384).contains(&self.host_overhead_mb) {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.resources.validate()
    }
    pub fn plan(&self, source: Resources) -> Result<BranchResourcePlan> {
        self.validate()?;
        source.validate()?;
        let disks = source
            .storage_gib
            .checked_add(source.overlay_gib)
            .ok_or(Error::before(ErrorCode::Admission))?;
        let memory = u64::from(source.memory_mib)
            .checked_add(self.host_overhead_mb)
            .ok_or(Error::before(ErrorCode::Admission))?;
        let minimum_disk = disks
            .checked_mul(2)
            .and_then(|n| n.checked_add(u64::from(source.memory_mib).div_ceil(1024)))
            .ok_or(Error::before(ErrorCode::Admission))?;
        if self.resources.memory_mb < memory || self.resources.disk_gb < minimum_disk {
            return Err(Error::before(ErrorCode::Admission));
        }
        let ordinary_child = BranchResources {
            slots: 1,
            cpus: u64::from(source.cpus),
            memory_mb: memory,
            disk_gb: disks,
        };
        Ok(BranchResourcePlan {
            total_additional: ordinary_child.add(self.resources)?,
            ordinary_child,
            minimum_extra_memory_mb: memory,
            minimum_extra_disk_gb: minimum_disk,
        })
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchChildIntent {
    pub operation_id: String,
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub idle: bool,
    pub hold: bool,
}
impl BranchChildIntent {
    fn validate(&self, source: &CreationReceipt) -> Result<()> {
        if !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_id(&self.name)
            || self.name == source.name
            || !crate::domain::valid_hex(&self.owner_token, 64)
            || !crate::domain::valid_hex(&self.incarnation, 32)
            || self.incarnation == source.incarnation
            || !self.idle
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        smolvm::data::validate_vm_name(&self.name, "branch child")
            .map_err(|_| Error::before(ErrorCode::Validation))
    }
}
/// Retains initial source/child exclusion and bounded admission metadata. This
/// cannot dispatch a fork or establish a persistent child/backing dependency.
pub struct PreparedInitialBranch {
    source: CreationReceipt,
    intent: BranchChildIntent,
    approval: BranchApproval,
    plan: BranchResourcePlan,
    request_sha256: String,
    source_root: crate::export_source::Root,
    source_pid: (i32, u64),
    epoch: String,
    budget: ReadBudget,
    _gates: [crate::gate::MachineLease; 2],
    _job: crate::jobs::JobLease,
    domain: Arc<crate::domain::DomainGuard>,
    // Retained workers must keep the actual SDK source handle alive as well as
    // its domain lock, even after the enclosing Engine value retires.
    _runtime: Arc<smolvm::embedded::EmbeddedRuntime>,
}
impl std::fmt::Debug for PreparedInitialBranch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedInitialBranch")
            .finish_non_exhaustive()
    }
}
impl PreparedInitialBranch {
    /// Persist the exact source/child declaration before any future fork path.
    /// This fences source mutation even if the caller drops its in-memory guard.
    /// No persistent capacity reservation, child ownership or SDK entry occurs.
    pub fn persist_intent(self, engine: &Engine) -> Result<PreparedBranchIntent> {
        self.recheck(engine)?;
        let intent = InitialBranchJournal {
            source: self.source.clone(),
            child: self.intent.clone(),
            approval: self.approval.clone(),
            plan: self.plan.clone(),
            request_sha256: self.request_sha256.clone(),
            source_pid: self.source_pid,
            epoch: self.epoch.clone(),
        };
        let journal = crate::material::MaterialJournal::at(&engine.vm_directory(&self.source.name));
        let record = engine
            .observation_record(&self.source.name, &self.budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        journal.prepare_initial_branch(&intent, &record)?;
        Ok(PreparedBranchIntent {
            guard: self,
            intent,
        })
    }
    pub fn resource_plan(&self) -> &BranchResourcePlan {
        &self.plan
    }
    pub fn request_sha256(&self) -> &str {
        &self.request_sha256
    }
    /// Recheck only this original owner, source and still-absent child. No
    /// inventory adoption, SDK reservation, filesystem creation or agent boot.
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        self.budget.check()?;
        verify_ram_mode()?;
        if !Arc::ptr_eq(&self.domain, &engine.domain)
            || !engine.available()
            || engine.observation_epoch().as_deref() != Some(self.epoch.as_str())
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.source_root.verify()?;
        let resources =
            source_resources(engine, &self.source, self.source_pid, &self.budget, None)?;
        if self.plan != self.approval.plan(resources)?
            || self.request_sha256
                != request_hash(
                    &self.source,
                    &self.intent,
                    &self.approval,
                    &self.plan,
                    self.source_pid,
                    &self.epoch,
                )?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        require_absent(engine, &self.intent.name, &self.budget)?;
        self.source_root.verify()?;
        self.budget.check()
    }
}

/// The original source/child gates, domain, job and protected prepared intent.
/// Dropping this handle does not erase the journal or authorize replay/cleanup.
pub struct PreparedBranchIntent {
    guard: PreparedInitialBranch,
    intent: InitialBranchJournal,
}
impl std::fmt::Debug for PreparedBranchIntent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedBranchIntent")
            .finish_non_exhaustive()
    }
}
impl PreparedBranchIntent {
    /// Build bounded worker IPC under the original admission. This does not
    /// write entered state or dispatch; retain this input before SDK entry.
    pub fn prepare_sdk_worker(mut self, engine: &Engine) -> Result<PreparedBranchWorker> {
        use std::os::unix::fs::MetadataExt;
        self.recheck(engine)?;
        engine.binding().validate()?;
        let supervisor = engine
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        self.guard._job.promote_branch_preparation()?;
        self.guard
            ._job
            .promote_branch_backing(self.guard.plan.preparation_disk_bytes()?)?;
        let directory = engine.domain.directory.join("transfers");
        crate::transfer_supervisor::prepare_directory(&directory)?;
        let stage =
            std::fs::symlink_metadata(&directory).map_err(|_| Error::before(ErrorCode::Io))?;
        let source = self
            .guard
            .source_root
            .descriptor()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let mut nonce = [0; 16];
        getrandom::fill(&mut nonce).map_err(|_| Error::before(ErrorCode::Native))?;
        // Sample the worker clock first so conversion never extends the
        // original absolute budget by time spent building the metadata.
        let now_ns = crate::buffered::monotonic_ns()?;
        let remaining = self
            .guard
            .budget
            .deadline
            .saturating_duration_since(std::time::Instant::now());
        self.guard.budget.check()?;
        let metadata = crate::branch_worker::Metadata {
            schema: 1,
            grant: crate::branch_worker::Grant {
                intent: self.intent.clone(),
                owner: supervisor.owner,
                worker_operation: hex::encode(nonce),
                directory: directory.clone(),
                device: stage.dev(),
                inode: stage.ino(),
            },
            database: engine.binding().database.clone(),
            database_device: engine.database_identity.0,
            database_inode: engine.database_identity.1,
            source_directory: engine.vm_directory(&self.guard.source.name),
            source_device: source.dev(),
            source_inode: source.ino(),
            deadline_ns: now_ns
                .checked_add(
                    u64::try_from(remaining.as_nanos())
                        .map_err(|_| Error::before(ErrorCode::Validation))?,
                )
                .ok_or(Error::before(ErrorCode::Validation))?,
        };
        let (bytes, expected) = metadata.encode()?;
        let prepared = supervisor.prepare_branch_owned(&directory, &bytes, expected.clone())?;
        self.guard.budget.check()?;
        Ok(PreparedBranchWorker {
            prepared: Some(prepared),
            intent: Some(self),
            expected,
            jobs: engine.jobs.clone(),
        })
    }
    pub fn resource_plan(&self) -> &BranchResourcePlan {
        &self.guard.plan
    }
    pub fn request_sha256(&self) -> &str {
        &self.guard.request_sha256
    }
    /// Check this original, still-unentered declaration only. No inventory row
    /// or serialized declaration can construct this retained owner authority.
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        verify_ram_mode()?;
        self.recheck_with_budget(engine, &self.guard.budget)
    }
    fn recheck_with_budget(&self, engine: &Engine, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        if !Arc::ptr_eq(&self.guard.domain, &engine.domain)
            || !engine.available()
            || engine.observation_epoch().as_deref() != Some(self.guard.epoch.as_str())
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.guard.source_root.verify()?;
        let resources = source_resources(
            engine,
            &self.guard.source,
            self.guard.source_pid,
            budget,
            Some(&self.intent),
        )?;
        if self.guard.plan != self.guard.approval.plan(resources)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        require_absent(engine, &self.guard.intent.name, budget)?;
        self.guard.source_root.verify()?;
        budget.check()
    }
    /// Explicit pre-SDK cancellation under the same owner/gates and unchanged
    /// source plus absent child. There is deliberately no entered-fork resolver.
    pub fn abort(self, engine: &Engine, budget: &ReadBudget) -> Result<InitialBranchRetirement> {
        self.retire_prepared(engine, budget)
    }
    fn retire_prepared(
        &self,
        engine: &Engine,
        budget: &ReadBudget,
    ) -> Result<InitialBranchRetirement> {
        // An explicit cleanup budget may outlive cancelled/expired admission;
        // it cannot authorize SDK entry or clear a changed/entered declaration.
        self.recheck_with_budget(engine, budget)?;
        let journal =
            crate::material::MaterialJournal::at(&engine.vm_directory(&self.guard.source.name));
        let record = engine
            .observation_record(&self.guard.source.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let authority = engine.branch_admission_source_authority(
            &self.guard.source,
            self.guard.source_pid,
            &record,
            Some(&self.intent.child.name),
            budget,
        )?;
        journal.retire_initial_branch(&self.intent, &record, &authority)
    }
}

/// Unentered, bounded worker input. No API on this value starts a worker or
/// authorizes SDK mutation. Source intent remains fenced when it is dropped.
pub struct PreparedBranchWorker {
    prepared: Option<crate::transfer_supervisor::Prepared>,
    intent: Option<PreparedBranchIntent>,
    expected: crate::branch_worker::Expected,
    jobs: crate::jobs::JobPool,
}
impl std::fmt::Debug for PreparedBranchWorker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedBranchWorker")
            .finish_non_exhaustive()
    }
}
impl PreparedBranchWorker {
    /// Retain the original source, gates, SDK runtime and admission in Engine.
    /// This publishes no entered state and never invokes the SDK.
    pub fn retain(self, engine: &Engine) -> Result<RetainedBranchPreparation> {
        engine.branch_retention.insert(self, engine, None)
    }
    /// Freeze the full host creation request, including an initial activation
    /// choice, before SDK entry. Later resolution can select only this original
    /// retained context; legacy unbound preparations cannot be adopted by request.
    pub fn retain_creation(
        self,
        engine: &Engine,
        request: &BranchCreateRequest,
    ) -> Result<RetainedBranchPreparation> {
        engine
            .branch_retention
            .insert(self, engine, Some(request.clone()))
    }
    pub fn metadata_sha256(&self) -> &str {
        &self.expected.metadata_sha256
    }
    pub fn request_sha256(&self) -> &str {
        &self.expected.request_sha256
    }
    pub fn resource_plan(&self) -> &BranchResourcePlan {
        self.intent.as_ref().unwrap().resource_plan()
    }
    pub fn abort(
        mut self,
        engine: &Engine,
        budget: &ReadBudget,
    ) -> Result<InitialBranchRetirement> {
        self.prepared
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?
            .verify_unentered_branch()?;
        self.prepared.take();
        self.intent
            .take()
            .ok_or(Error::before(ErrorCode::State))?
            .abort(engine, budget)
    }
}
impl Drop for PreparedBranchWorker {
    fn drop(&mut self) {
        if self
            .prepared
            .as_ref()
            .is_some_and(|prepared| prepared.verify_unentered_branch().is_err())
        {
            self.jobs.quarantine();
            // Keep the original domain, gates, spools and allowance when named
            // files changed; no substituted file becomes cleanup authority.
            if let Some(prepared) = self.prepared.take() {
                std::mem::forget(prepared);
            }
            if let Some(intent) = self.intent.take() {
                std::mem::forget(intent);
            }
        } else {
            self.prepared.take();
        }
    }
}

/// Positive retirement of one protected, unentered declaration. This is neither
/// a material transition nor evidence of a child's disposal or released backing.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InitialBranchRetirement {
    pub schema: u8,
    intent: InitialBranchJournal,
    pub proof_sha256: String,
}
impl std::fmt::Debug for InitialBranchRetirement {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InitialBranchRetirement")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl InitialBranchRetirement {
    pub fn source(&self) -> &CreationReceipt {
        &self.intent.source
    }
    pub fn child(&self) -> &BranchChildIntent {
        &self.intent.child
    }
    pub fn resource_plan(&self) -> &BranchResourcePlan {
        &self.intent.plan
    }
    pub(crate) fn matches_creation(&self, request: &BranchCreateRequest) -> Result<()> {
        self.validate()?;
        self.intent.matches_creation(request)
    }

    pub fn request_sha256(&self) -> &str {
        &self.intent.request_sha256
    }
    pub fn validate(&self) -> Result<()> {
        self.intent.validate()?;
        if self.schema != 1
            || self.proof_sha256
                != crate::material::hash(&("smolbox-initial-branch-retirement-v1", &self.intent))?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn issue(intent: InitialBranchJournal) -> Result<Self> {
        let result = Self {
            schema: 1,
            proof_sha256: crate::material::hash(&(
                "smolbox-initial-branch-retirement-v1",
                &intent,
            ))?,
            intent,
        };
        result.validate()?;
        Ok(result)
    }
}

/// Protected declaration, not a public receipt or proof of backing allocation.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct InitialBranchJournal {
    pub source: CreationReceipt,
    pub child: BranchChildIntent,
    pub approval: BranchApproval,
    pub plan: BranchResourcePlan,
    pub request_sha256: String,
    pub source_pid: (i32, u64),
    pub epoch: String,
}
impl InitialBranchJournal {
    pub(crate) fn validate(&self) -> Result<()> {
        self.child.validate(&self.source)?;
        self.approval.validate()?;
        let proof = self
            .source
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        proof.validate()?;
        if proof.revision >= 1024 {
            return Err(Error::before(ErrorCode::State));
        }
        let ordinary = self.plan.ordinary_child;
        let guest_memory = ordinary
            .memory_mb
            .checked_sub(self.approval.host_overhead_mb)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let minimum_disk = ordinary
            .disk_gb
            .checked_mul(2)
            .and_then(|disks| disks.checked_add(guest_memory.div_ceil(1024)))
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !crate::domain::valid_id(&self.source.target_id)
            || !crate::domain::valid_hex(&self.source.domain_generation, 32)
            || !crate::domain::valid_id(&self.source.name)
            || !crate::domain::valid_hex(&self.source.owner_token, 64)
            || !crate::domain::valid_hex(&self.source.incarnation, 32)
            || !crate::domain::valid_hex(&self.source.material_sha256, 64)
            || ordinary.slots != 1
            || !(1..=16).contains(&ordinary.cpus)
            || !(64..=65_536).contains(&guest_memory)
            || !(2..=2048).contains(&ordinary.disk_gb)
            || self.plan.minimum_extra_memory_mb != ordinary.memory_mb
            || self.plan.minimum_extra_disk_gb != minimum_disk
            || self.approval.resources.memory_mb < ordinary.memory_mb
            || self.approval.resources.disk_gb < minimum_disk
            || self.plan.total_additional != ordinary.add(self.approval.resources)?
            || self.request_sha256
                != request_hash(
                    &self.source,
                    &self.child,
                    &self.approval,
                    &self.plan,
                    self.source_pid,
                    &self.epoch,
                )?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn matches_creation(&self, request: &BranchCreateRequest) -> Result<()> {
        self.validate()?;
        if self.source != request.source
            || self.child != request.child
            || self.approval != request.approval
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn verify_record(&self, record: &smolvm::config::VmRecord) -> Result<()> {
        self.verify_material(record)?;
        if record.state != smolvm::config::RecordState::Running
            || record.pid.zip(record.pid_start_time) != Some(self.source_pid)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn verify_material(&self, record: &smolvm::config::VmRecord) -> Result<()> {
        self.validate()?;
        let resources = source_profile(record)?;
        if !self.source.matches(record)? || self.plan != self.approval.plan(resources)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
// The SDK's auto mode uses shared materialized RAM; paged mode can create
// an additional raw-forked guardian outside the ordinary boot enrollment path.
// Initial admission supports only the clean shared path. Read, never mutate,
// process environment; future SDK dispatch must freeze it in its owned worker.
fn shared_ram_mode(value: Option<&std::ffi::OsStr>) -> Result<()> {
    if matches!(
        value.and_then(std::ffi::OsStr::to_str),
        Some("auto" | "shared")
    ) || value.is_none()
    {
        Ok(())
    } else {
        Err(Error::before(ErrorCode::Unsupported))
    }
}
fn verify_ram_mode() -> Result<()> {
    shared_ram_mode(std::env::var_os("SMOLVM_BRANCH_RAM_MODE").as_deref())
}
fn request_hash(
    source: &CreationReceipt,
    child: &BranchChildIntent,
    approval: &BranchApproval,
    plan: &BranchResourcePlan,
    source_pid: (i32, u64),
    epoch: &str,
) -> Result<String> {
    if source_pid.0 <= 0 || source_pid.1 == 0 || !crate::domain::valid_hex(epoch, 32) {
        return Err(Error::before(ErrorCode::Validation));
    }
    crate::material::hash(&(
        "smolbox-initial-branch-admission-v1",
        crate::SMOLVM_REVISION,
        "shared-materialized-ram",
        source,
        child,
        approval,
        plan,
        source_pid,
        epoch,
    ))
}
fn eligible_record(record: &smolvm::config::VmRecord) -> Result<Resources> {
    let resources = source_profile(record)?;
    if record.state != smolvm::config::RecordState::Running {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(resources)
}
fn source_profile(record: &smolvm::config::VmRecord) -> Result<Resources> {
    let resources = crate::checkpoint_capture::validate_record(record)?;
    if !record.forkable
        || record.golden.is_some()
        || record.forkpoint_held
        || !record.fork_env.is_empty()
        || record.source_registry_ref.is_some()
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(resources)
}
fn source_resources(
    engine: &Engine,
    source: &CreationReceipt,
    pid: (i32, u64),
    budget: &ReadBudget,
    pending: Option<&InitialBranchJournal>,
) -> Result<Resources> {
    budget.check()?;
    let record = engine
        .observation_record(&source.name, budget)?
        .ok_or(Error::before(ErrorCode::Ownership))?;
    if let Some(pending) = pending {
        if !crate::machine::marker_matches(source, &engine.vm_directory(&source.name))? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        crate::material::MaterialJournal::at(&engine.vm_directory(&source.name))
            .verify_initial_branch(pending, &record)?;
    } else {
        engine.verify_record(source, &record)?;
    }
    let resources = eligible_record(&record)?;
    if record.pid.zip(record.pid_start_time) != Some(pid)
        || !engine
            .branch_admission_source_authority(
                source,
                pid,
                &record,
                pending.map(|intent| intent.child.name.as_str()),
                budget,
            )?
            .running()
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    engine.verify_templates()?;
    budget.check()?;
    Ok(resources)
}
fn require_absent(engine: &Engine, name: &str, budget: &ReadBudget) -> Result<()> {
    engine.verify_database_identity()?;
    if !crate::sdk_compat::observe_absence_budget(
        &engine.binding().database,
        engine.database_identity,
        name,
        budget,
        || engine.creation_material_absent(name),
    )? {
        return Err(Error::before(ErrorCode::Conflict));
    }
    engine.verify_database_identity()?;
    budget.check()
}
impl Engine {
    /// Read protected completed evidence without inspecting current source or
    /// child inventory. None grants no absence, replay or capacity authority.
    pub fn inspect_initial_branch_retirement(
        &self,
        source: &CreationReceipt,
        operation_id: &str,
        request_sha256: &str,
        budget: &ReadBudget,
    ) -> Result<Option<InitialBranchRetirement>> {
        validate_lookup(self, source, operation_id, request_sha256, budget)?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        let root = crate::export_source::Root::open(&self.vm_directory(&source.name))?;
        require_marker(self, source)?;
        let proof = crate::material::MaterialJournal::at(&self.vm_directory(&source.name))
            .retired_initial_branch(source, operation_id, request_sha256)?;
        root.verify()?;
        self.domain.verify()?;
        budget.check()?;
        Ok(proof)
    }
    /// Explicit caller-fenced cleanup of known prepared-only intent. Reopening
    /// never invokes this automatically. No SDK dispatch, adoption or VM stop.
    pub fn retire_prepared_initial_branch(
        &self,
        source: &CreationReceipt,
        operation_id: &str,
        request_sha256: &str,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<InitialBranchRetirement> {
        if !quiesced {
            return Err(Error::before(ErrorCode::Validation));
        }
        validate_lookup(self, source, operation_id, request_sha256, budget)?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        let root = crate::export_source::Root::open(&self.vm_directory(&source.name))?;
        require_marker(self, source)?;
        let journal = crate::material::MaterialJournal::at(&self.vm_directory(&source.name));
        // A recorded completion precedes current material/PID/gate checks;
        // acknowledgement retry returns that proof without another journal
        // write, and may explicitly release its original prepared-only leases.
        if let Some(proof) = journal.retired_initial_branch(source, operation_id, request_sha256)? {
            if let Some(retained) = self.branch_retention.retire_prepared(
                self,
                source,
                operation_id,
                request_sha256,
                budget,
            )? {
                if retained != proof {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
            }
            root.verify()?;
            self.domain.verify()?;
            budget.check()?;
            return Ok(proof);
        }
        if let Some(proof) = self.branch_retention.retire_prepared(
            self,
            source,
            operation_id,
            request_sha256,
            budget,
        )? {
            return Ok(proof);
        }
        let intent = journal.pending_initial_branch(source, operation_id, request_sha256)?;
        let source_gate = self.gate(&source.name)?;
        let child_gate = self.gate(&intent.child.name)?;
        let _gates = crate::gate::lock_pair(
            (&source.name, &source_gate),
            (&intent.child.name, &child_gate),
        )
        .map_err(|_| Error::before(ErrorCode::Conflict))?;
        root.verify()?;
        self.domain.verify()?;
        require_marker(self, source)?;
        let current = journal.pending_initial_branch(source, operation_id, request_sha256)?;
        if current != intent {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let record = self
            .observation_record(&source.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        intent.verify_material(&record)?;
        let authority = self.branch_admission_source_authority(
            source,
            intent.source_pid,
            &record,
            Some(&intent.child.name),
            budget,
        )?;
        require_absent(self, &intent.child.name, budget)?;
        root.verify()?;
        self.domain.verify()?;
        budget.check()?;
        let proof = journal.retire_initial_branch(&intent, &record, &authority)?;
        root.verify()
            .map_err(|error| Error::uncertain(error.code))?;
        self.domain
            .verify()
            .map_err(|error| Error::uncertain(error.code))?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(proof)
    }
    /// Bounded branch source qualification, including previously published leaves.
    /// This does not assert guest idleness, permit capture or adopt an SDK owner.
    pub fn branch_preflight(
        &self,
        source: &CreationReceipt,
        budget: &ReadBudget,
    ) -> Result<crate::Observation> {
        budget.check()?;
        source.validate(self.binding())?;
        let _job = self.jobs.acquire(crate::jobs::Demand::branch_probe())?;
        let gate = self.observation_gate(&source.name)?;
        let _gate = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let record = self
            .observation_record(&source.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_record(source, &record)?;
        eligible_record(&record)?;
        let pid = record
            .pid
            .zip(record.pid_start_time)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let resources = source_resources(self, source, pid, budget, None)?;
        let directory = self.vm_directory(&source.name);
        if crate::checkpoint_lifecycle::Lifecycle::at(&directory)
            .uncertain(source, &record, budget)?
        {
            return Err(Error::before(ErrorCode::State));
        }
        crate::branch_agent::exchange(
            &directory.join("agent.sock"),
            &self.transfer_directory()?,
            64 * 1024,
            budget,
            |agent, _| agent.ping().map_err(|_| Error::before(ErrorCode::State)),
        )?;
        source_resources(self, source, pid, budget, None)?;
        Ok(crate::Observation {
            state: crate::ObservedState::Running,
            resources: Some(resources),
            pid_identity: Some(pid),
            configuration: crate::MachineConfiguration::observe(&record),
        })
    }
    /// Source admission requires an enrolled parent and a fresh child.
    /// Persistent intent/resource reservation and
    /// source/child material transitions must precede any future SDK dispatch.
    pub fn prepare_initial_branch(
        &self,
        source: &CreationReceipt,
        child: &BranchChildIntent,
        approval: &BranchApproval,
        budget: &ReadBudget,
    ) -> Result<PreparedInitialBranch> {
        budget.check()?;
        verify_ram_mode()?;
        source.validate(self.binding())?;
        if source.material.is_none() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        child.validate(source)?;
        // Older prepared-only declarations can still be read and explicitly
        // retired. New dispatch requires a distinct child creation token.
        if child.owner_token == source.owner_token {
            return Err(Error::before(ErrorCode::Validation));
        }
        approval.validate()?;
        // Existing guarded preflight authenticates actual agent readiness and
        // original engine enrollment, without promoting inventory ownership.
        let observed = self.branch_preflight(source, budget)?;
        let pid = observed
            .pid_identity
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let epoch = self
            .observation_epoch()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let source_gate = self.gate(&source.name)?;
        let child_gate = self.gate(&child.name)?;
        let gates =
            crate::gate::lock_pair((&source.name, &source_gate), (&child.name, &child_gate))
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let job = self.jobs.acquire(crate::jobs::Demand::branch_source())?;
        let source_root = crate::export_source::Root::open(&self.vm_directory(&source.name))?;
        // Recheck after acquiring both gates; preflight's temporary guard is not
        // continuous exclusion and cannot authorize a changed source or child.
        let resources = source_resources(self, source, pid, budget, None)?;
        require_absent(self, &child.name, budget)?;
        let plan = approval.plan(resources)?;
        let prepared = PreparedInitialBranch {
            source: source.clone(),
            intent: child.clone(),
            approval: approval.clone(),
            request_sha256: request_hash(source, child, approval, &plan, pid, &epoch)?,
            plan,
            source_root,
            source_pid: pid,
            epoch,
            budget: budget.clone(),
            _gates: gates,
            _job: job,
            domain: self.domain.clone(),
            _runtime: self.runtime.clone(),
        };
        prepared.recheck(self)?;
        Ok(prepared)
    }
}

fn validate_lookup(
    engine: &Engine,
    source: &CreationReceipt,
    operation_id: &str,
    request_sha256: &str,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check()?;
    source.validate(engine.binding())?;
    if source.material.is_none() {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    if !crate::domain::valid_id(operation_id) || !crate::domain::valid_hex(request_sha256, 64) {
        return Err(Error::before(ErrorCode::Validation));
    }
    engine.domain.verify()
}
fn require_marker(engine: &Engine, source: &CreationReceipt) -> Result<()> {
    if !crate::machine::marker_matches(source, &engine.vm_directory(&source.name))? {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::Cancellation;
    use std::time::Duration;
    fn budget() -> ReadBudget {
        ReadBudget::for_checkpoint_work(Duration::from_secs(30), Cancellation::default()).unwrap()
    }
    fn approval() -> BranchApproval {
        BranchApproval {
            id: "branches".into(),
            host_overhead_mb: 256,
            resources: BranchResources {
                slots: 1,
                cpus: 1,
                memory_mb: 512,
                disk_gb: 5,
            },
        }
    }
    fn child() -> BranchChildIntent {
        BranchChildIntent {
            operation_id: "first-child".into(),
            name: "new-child".into(),
            owner_token: "c".repeat(64),
            incarnation: "d".repeat(32),
            idle: true,
            hold: false,
        }
    }
    pub(crate) fn initial_journal(
        source: &CreationReceipt,
        record: &smolvm::config::VmRecord,
    ) -> InitialBranchJournal {
        initial_journal_named(source, record, "first-child")
    }
    pub(crate) fn set_initial_hold(intent: &mut InitialBranchJournal, hold: bool) {
        intent.child.hold = hold;
        intent.request_sha256 = request_hash(
            &intent.source,
            &intent.child,
            &intent.approval,
            &intent.plan,
            intent.source_pid,
            &intent.epoch,
        )
        .unwrap();
        intent.validate().unwrap();
    }
    pub(crate) fn initial_journal_named(
        source: &CreationReceipt,
        record: &smolvm::config::VmRecord,
        operation_id: &str,
    ) -> InitialBranchJournal {
        let resources = eligible_record(record).unwrap();
        let mut approval = approval();
        approval.resources.memory_mb = u64::from(resources.memory_mib) + approval.host_overhead_mb;
        approval.resources.disk_gb = 2 * (resources.storage_gib + resources.overlay_gib)
            + u64::from(resources.memory_mib).div_ceil(1024);
        let mut child = child();
        child.operation_id = operation_id.into();
        let plan = approval.plan(resources).unwrap();
        let source_pid = record.pid.zip(record.pid_start_time).unwrap();
        let epoch = "1".repeat(32);
        InitialBranchJournal {
            source: source.clone(),
            request_sha256: request_hash(source, &child, &approval, &plan, source_pid, &epoch)
                .unwrap(),
            child,
            approval,
            plan,
            source_pid,
            epoch,
        }
    }
    pub(super) fn prepared_stopped_model(
        root: &std::path::Path,
        live_original: bool,
    ) -> (Engine, CreationReceipt, InitialBranchJournal) {
        let (engine, receipt) =
            crate::export_source::tests::fixture_record(root, false, |record| {
                record.entrypoint = vec!["/bin/true".into()];
                record.cmd.clear();
                record.env.clear();
                record.user = None;
                record.workdir = Some("/".into());
                record.forkable = true;
                record.state = smolvm::config::RecordState::Running;
                let pid = if live_original {
                    std::process::id() as i32
                } else {
                    i32::MAX
                };
                record.pid = Some(pid);
                record.pid_start_time = Some(if live_original {
                    smolvm::process::process_start_time(pid).unwrap()
                } else {
                    1
                });
            });
        let record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        let intent = initial_journal(&receipt, &record);
        crate::material::MaterialJournal::at(&engine.vm_directory(&receipt.name))
            .prepare_initial_branch(&intent, &record)
            .unwrap();
        // A deterministic SDK shutdown-result model only. No VMM exists and no
        // process is stopped, signalled, paused or adopted by this fixture.
        engine
            .db
            .update_vm(&receipt.name, |record| {
                record.state = smolvm::config::RecordState::Stopped;
                record.pid = None;
                record.pid_start_time = None;
            })
            .unwrap();
        (engine, receipt, intent)
    }

    #[test]
    fn older_prepared_same_owner_intent_can_retire_but_fresh_admission_requires_distinct_owner() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, source, mut intent) = prepared_stopped_model(temp.path(), false);
        intent.child.owner_token = source.owner_token.clone();
        intent.request_sha256 = request_hash(
            &intent.source,
            &intent.child,
            &intent.approval,
            &intent.plan,
            intent.source_pid,
            &intent.epoch,
        )
        .unwrap();
        intent.validate().unwrap();
        let path = engine
            .vm_directory(&source.name)
            .join("smolbox.material-v2.json");
        let mut value: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        // Deterministic legacy private-journal value, never a live VM boundary.
        value["initial_branch"] = serde_json::to_value(&intent).unwrap();
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert_eq!(
            engine
                .prepare_initial_branch(&source, &intent.child, &intent.approval, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Validation
        );
        let retired = engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget(),
            )
            .unwrap();
        retired.validate().unwrap();
        assert_eq!(retired.child().owner_token, source.owner_token);
    }

    #[test]
    fn initial_branch_retirement_survives_normal_reopen_and_lost_ack_without_sdk_replay() {
        let root = tempfile::tempdir().unwrap();
        let (engine, source, intent) = prepared_stopped_model(root.path(), false);
        drop(engine);
        let engine = crate::machine::tests::test_engine(root.path());
        let file = engine
            .vm_directory(&source.name)
            .join("smolbox.material-v2.json");
        let before = std::fs::read(&file).unwrap();
        assert!(engine
            .inspect_initial_branch_retirement(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                &budget()
            )
            .unwrap()
            .is_none());
        assert_eq!(std::fs::read(&file).unwrap(), before);
        assert!(engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                false,
                &budget()
            )
            .is_err());
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &cancelled
            )
            .is_err());
        let work = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        let observer = engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        let second = engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        assert!(engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget()
            )
            .is_err());
        assert_eq!(std::fs::read(&file).unwrap(), before);
        drop(second);
        let held = engine.jobs.counts();
        let proof = engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget(),
            )
            .unwrap();
        proof.validate().unwrap();
        assert_eq!(proof.source(), &source);
        assert!(engine.inspect(&source).unwrap().state == crate::ObservedState::Stopped);
        assert_eq!(engine.jobs.counts(), held);
        drop((observer, work));
        let retired_bytes = std::fs::read(&file).unwrap();
        drop(engine);
        let engine = crate::machine::tests::test_engine(root.path());
        let child_gate = engine.gate(&intent.child.name).unwrap();
        let _busy = child_gate.try_lock().unwrap();
        // Completion lookup precedes gates, source state and child inspection.
        assert_eq!(
            engine
                .retire_prepared_initial_branch(
                    &source,
                    &intent.child.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget()
                )
                .unwrap(),
            proof
        );
        assert_eq!(
            engine
                .inspect_initial_branch_retirement(
                    &source,
                    &intent.child.operation_id,
                    &intent.request_sha256,
                    &budget()
                )
                .unwrap(),
            Some(proof)
        );
        assert_eq!(std::fs::read(&file).unwrap(), retired_bytes);
        assert!(engine.db.get_vm(&intent.child.name).unwrap().is_none());
        assert!(!engine.vm_directory(&intent.child.name).exists());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn initial_branch_retirement_requires_original_absence_unchanged_source_and_child_exclusion() {
        let root = tempfile::tempdir().unwrap();
        let (engine, source, intent) = prepared_stopped_model(root.path(), false);
        let file = engine
            .vm_directory(&source.name)
            .join("smolbox.material-v2.json");
        let before = std::fs::read(&file).unwrap();
        let child_gate = engine.gate(&intent.child.name).unwrap();
        let busy = child_gate.try_lock().unwrap();
        assert!(engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget()
            )
            .is_err());
        assert!(engine.gate(&source.name).unwrap().try_lock().is_ok());
        drop(busy);
        let child_path = engine.vm_directory(&intent.child.name);
        std::fs::create_dir_all(&child_path).unwrap();
        assert!(engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget()
            )
            .is_err());
        std::fs::remove_dir(&child_path).unwrap();
        engine
            .db
            .update_vm(&source.name, |record| record.cpus = 2)
            .unwrap();
        assert!(engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget()
            )
            .is_err());
        assert_eq!(std::fs::read(&file).unwrap(), before);
        assert!(engine
            .inspect_initial_branch_retirement(
                &source,
                &intent.child.operation_id,
                &"0".repeat(64),
                &budget()
            )
            .unwrap()
            .is_none());
        assert!(engine
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &"0".repeat(64),
                true,
                &budget()
            )
            .is_err());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());

        let other_root = tempfile::tempdir().unwrap();
        let (other, source, intent) = prepared_stopped_model(other_root.path(), true);
        // A stopped row does not prove that its original recorded PID died.
        assert!(other
            .retire_prepared_initial_branch(
                &source,
                &intent.child.operation_id,
                &intent.request_sha256,
                true,
                &budget()
            )
            .is_err());
        assert_eq!(other.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn persisted_initial_branch_fences_engine_lifecycle_commands_and_observation_without_sdk_entry()
    {
        let root = tempfile::tempdir().unwrap();
        // Synthetic journal/result fixture only: these process fields never
        // establish engine enrollment or become a positive branch admission.
        let (engine, receipt) =
            crate::export_source::tests::fixture_record(root.path(), false, |record| {
                record.entrypoint = vec!["/bin/true".into()];
                record.cmd.clear();
                record.env.clear();
                record.user = None;
                record.workdir = Some("/".into());
                record.forkable = true;
                record.state = smolvm::config::RecordState::Running;
                record.pid = Some(123);
                record.pid_start_time = Some(456);
            });
        let record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        let before = serde_json::to_vec(&record).unwrap();
        let intent = initial_journal(&receipt, &record);
        let journal = crate::material::MaterialJournal::at(&engine.vm_directory(&receipt.name));
        journal.prepare_initial_branch(&intent, &record).unwrap();
        let work = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        let first_control = engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        let second_control = engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        assert!(engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .is_err());
        assert_eq!(engine.observation_records(&budget()).unwrap().len(), 1);
        for result in [
            engine.inspect(&receipt),
            engine.start(&receipt),
            engine.stop(&receipt),
            engine.delete(&receipt),
        ] {
            assert_eq!(
                result.err().unwrap().dispatch,
                crate::Dispatch::NotDispatched
            );
        }
        let result = engine.exec(
            &receipt,
            crate::Command {
                argv: vec!["/bin/true".into()],
                env: vec![],
                workdir: None,
                user: None,
                timeout: Duration::from_secs(1),
                max_output_bytes: 1024,
            },
            Cancellation::default(),
            |_| panic!("no SDK command output"),
        );
        assert_eq!(
            result.err().unwrap().dispatch,
            crate::Dispatch::NotDispatched
        );
        assert!(engine
            .prepare_initial_branch(&receipt, &intent.child, &intent.approval, &budget())
            .is_err());
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap().unwrap()).unwrap(),
            before
        );
        assert!(engine.db.get_vm(&intent.child.name).unwrap().is_none());
        assert!(!engine.vm_directory(&intent.child.name).exists());
        drop((first_control, second_control, work));
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn shared_sdk_ram_strategy_is_pure_and_excludes_unenrolled_paged_guardians() {
        use std::ffi::OsStr;
        assert!(shared_ram_mode(None).is_ok());
        for mode in ["auto", "shared"] {
            assert!(shared_ram_mode(Some(OsStr::new(mode))).is_ok());
        }
        for mode in ["paged", "", "SHARED", "shared ", "foreign"] {
            assert_eq!(
                shared_ram_mode(Some(OsStr::new(mode))).unwrap_err().code,
                ErrorCode::Unsupported
            );
        }
        use std::os::unix::ffi::OsStrExt;
        assert!(shared_ram_mode(Some(OsStr::from_bytes(&[0xff]))).is_err());
    }
    #[test]
    fn shared_branch_resource_cases_preserve_public_child_plus_extra_accounting() {
        #[derive(Deserialize)]
        struct Case {
            cpus: u8,
            memory_mb: u32,
            storage_gb: u64,
            overlay_gb: u64,
            host_overhead_mb: u64,
            extra: BranchResources,
            expected: Option<BranchResourcePlan>,
        }
        let cases: Vec<Case> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-admission-v1.json"
        ))
        .unwrap();
        assert_eq!(cases.len(), 6);
        for case in cases {
            let grant = BranchApproval {
                id: "shared".into(),
                host_overhead_mb: case.host_overhead_mb,
                resources: case.extra,
            };
            let result = grant.plan(Resources {
                cpus: case.cpus,
                memory_mib: case.memory_mb,
                storage_gib: case.storage_gb,
                overlay_gib: case.overlay_gb,
            });
            match case.expected {
                Some(expected) => assert_eq!(result.unwrap(), expected),
                None => assert!(result.is_err()),
            }
        }
    }
    #[test]
    fn initial_source_profile_rejects_nested_held_remote_networked_and_injected_state() {
        let mut record = smolvm::embedded::MachineSpec {
            name: "branch-source".into(),
            persistent: true,
            resources: smolvm::agent::VmResources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: Some(1),
                overlay_gib: Some(1),
                network: false,
                ..Default::default()
            },
            ..Default::default()
        }
        .to_record();
        record.state = smolvm::config::RecordState::Running;
        record.forkable = true;
        record.entrypoint = vec!["/bin/true".into()];
        record.cmd.clear();
        record.env.clear();
        record.user = None;
        record.workdir = Some("/".into());
        assert!(eligible_record(&record).is_ok());
        let before = crate::identity::material_hash(&record).unwrap();
        for case in 0..10 {
            let mut changed = record.clone();
            match case {
                0 => changed.golden = Some("parent".into()),
                1 => changed.forkpoint_held = true,
                2 => changed.fork_env = vec![("TOKEN".into(), "private".into())],
                3 => changed.source_registry_ref = Some("remote".into()),
                4 => changed.forkable = false,
                5 => changed.network = true,
                6 => changed.image = Some("container".into()),
                7 => changed.ports = vec![(80, 80)],
                8 => changed.env = vec![("TOKEN".into(), "private".into())],
                _ => changed.state = smolvm::config::RecordState::Stopped,
            }
            assert!(eligible_record(&changed).is_err(), "{case}");
        }
        assert_eq!(before, crate::identity::material_hash(&record).unwrap());
    }
    #[test]
    fn initial_child_intent_and_hash_bind_both_identities_hold_and_the_exact_policy() {
        let temp = tempfile::tempdir().unwrap();
        let (_engine, source) = crate::export_source::tests::fixture(temp.path(), false);
        let child = child();
        child.validate(&source).unwrap();
        let grant = approval();
        let plan = grant
            .plan(Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 1,
                overlay_gib: 1,
            })
            .unwrap();
        let pid = (11, 22);
        let epoch = "1".repeat(32);
        let original = request_hash(&source, &child, &grant, &plan, pid, &epoch).unwrap();
        assert_ne!(
            original,
            request_hash(&source, &child, &grant, &plan, (11, 23), &epoch).unwrap()
        );
        assert_ne!(
            original,
            request_hash(&source, &child, &grant, &plan, pid, &"2".repeat(32)).unwrap()
        );
        for case in 0..5 {
            let mut changed = child.clone();
            match case {
                0 => changed.name = source.name.clone(),
                1 => changed.incarnation = source.incarnation.clone(),
                2 => changed.idle = false,
                3 => changed.owner_token = "x".into(),
                _ => changed.operation_id = "../invalid".into(),
            }
            assert!(changed.validate(&source).is_err());
        }
        for case in 0..4 {
            let mut changed = child.clone();
            let mut grant = grant.clone();
            let mut source = source.clone();
            match case {
                0 => changed.hold = true,
                1 => changed.incarnation = "e".repeat(32),
                2 => grant.resources.disk_gb += 1,
                _ => source.incarnation = "f".repeat(32),
            }
            assert_ne!(
                original,
                request_hash(&source, &changed, &grant, &plan, pid, &epoch).unwrap()
            );
        }
        let mut unknown = serde_json::to_value(&child).unwrap();
        unknown["env"] = serde_json::json!({"TOKEN":"private"});
        assert!(serde_json::from_value::<BranchChildIntent>(unknown).is_err());
    }
    #[test]
    fn stopped_cancelled_legacy_or_foreign_sources_never_reserve_a_child_or_mutate_sdk_state() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, source) = crate::export_source::tests::fixture(temp.path(), false);
        let child = child();
        let grant = approval();
        let original =
            serde_json::to_value(engine.observation_records(&budget()).unwrap()).unwrap();
        for case in 0..5 {
            let work = budget();
            let mut supplied = source.clone();
            let mut intent = child.clone();
            let mut grant = grant.clone();
            match case {
                0 => work.cancel.cancel(),
                1 => {
                    supplied.domain_generation = if source.domain_generation == "a".repeat(32) {
                        "b".repeat(32)
                    } else {
                        "a".repeat(32)
                    };
                }
                2 => supplied.material = None,
                3 => intent.name = source.name.clone(),
                _ => grant.host_overhead_mb = 0,
            }
            let error = engine
                .prepare_initial_branch(&supplied, &intent, &grant, &work)
                .err()
                .unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
        assert!(engine
            .prepare_initial_branch(&source, &child, &grant, &budget())
            .is_err());
        assert_eq!(
            serde_json::to_value(engine.observation_records(&budget()).unwrap()).unwrap(),
            original
        );
        assert!(!engine.vm_directory(&child.name).exists());
        assert!(engine.db.get_vm(&child.name).unwrap().is_none());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn branch_preflight_work_memory_keeps_both_control_observers_available_under_quarantine() {
        let temp = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(temp.path());
        let permit = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        assert_eq!(
            engine.jobs.counts().work_metadata,
            crate::JOB_METADATA_BYTES
        );
        assert!(engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .is_err());
        engine.jobs.quarantine();
        let a = engine
            .jobs
            .acquire(crate::jobs::Demand::export_observation())
            .unwrap();
        let b = engine
            .jobs
            .acquire(crate::jobs::Demand::export_observation())
            .unwrap();
        assert!(engine
            .jobs
            .acquire(crate::jobs::Demand::export_observation())
            .is_err());
        assert_eq!(engine.jobs.counts().work, 1);
        drop((a, b, permit));
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(!engine.available());
    }
}
