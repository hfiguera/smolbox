//! Original-manager collection shared by normal stop and explicit deletion.
//! An inventory row or PID cannot construct the retained enrollment authority.
use super::Context;
use crate::epoch::{ActorEpoch, BootCollection, BootEnrollment};
use crate::{CreationReceipt, Engine, Error, ErrorCode, Observation, ReadBudget, Result};

impl Context {
    pub(crate) fn require_no_runtime_boot(&self) -> Result<()> {
        require_no_runtime_boot(&self.runtime_boots, &self.plan.publication.child().name)
    }
    pub(crate) fn collect_original(
        &self,
        epoch: &ActorEpoch,
        budget: &ReadBudget,
    ) -> Result<BootCollection> {
        budget.check()?;
        self.plan.verify()?;
        self.require_no_runtime_boot()?;
        {
            let manager = self
                .manager
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            self.manager_paths.verify(&self.plan, &manager)?;
        }
        collect_manager(&self.plan, &self.manager, epoch, &self.enrollment, budget)
    }
}
fn require_no_runtime_boot(registry: &crate::runtime_boot::Registry, name: &str) -> Result<()> {
    // EmbeddedRuntime::pid also reads persisted rows. A running original
    // manager necessarily has such a PID; it does not imply a cached runtime
    // owner. Every ordinary runtime start reserves this shared registry before
    // SDK entry, and the caller retains the child gate through collection.
    if registry.try_contains(name)? {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
// Both completed and pre-handoff jobs retain the original manager/enrollment.
// This helper constructs neither from an SDK row or caller-supplied PID.
pub(crate) fn collect_manager(
    plan: &crate::branch_boot::Plan,
    manager: &std::sync::Mutex<smolvm::agent::AgentManager>,
    epoch: &ActorEpoch,
    enrollment: &BootEnrollment,
    budget: &ReadBudget,
) -> Result<BootCollection> {
    budget.check()?;
    let name = &plan.publication.child().name;
    let manager = manager
        .try_lock()
        .map_err(|_| Error::before(ErrorCode::Conflict))?;
    verify_manager_disks(
        plan,
        manager.name(),
        manager.storage_path(),
        manager.overlay_path(),
    )?;
    let proof = collect_with(budget, epoch, enrollment, name, manager.child_pid(), || {
        manager
            .stop()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        if manager.child_pid().is_some() {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    })?;
    // Only positive collection permits dropping the manager's launch flock.
    manager.mark_stopped();
    budget.check().map_err(|e| Error::uncertain(e.code))?;
    Ok(proof)
}
// Fork children use QCOW overlays even when the original source used raw
// disks. Bind collection to the original manager's exact resolved paths,
// rather than requiring raw filenames that the boot path never selected.
pub(super) fn verify_manager_disks(
    plan: &crate::branch_boot::Plan,
    name: Option<&str>,
    storage: &std::path::Path,
    overlay: &std::path::Path,
) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    plan.verify()?;
    if name != Some(plan.publication.child().name.as_str()) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    for (raw, actual) in [
        (smolvm::storage::STORAGE_DISK_FILENAME, storage),
        (smolvm::storage::OVERLAY_DISK_FILENAME, overlay),
    ] {
        let (resolved, _) = smolvm::agent::resolve_disk_image(&plan.child.path, raw);
        if actual != resolved {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let file = crate::artifact::open_regular(actual)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let held = file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let path =
            std::fs::symlink_metadata(actual).map_err(|_| Error::before(ErrorCode::Ownership))?;
        if !path.is_file()
            || (held.dev(), held.ino()) != (path.dev(), path.ino())
            || held.uid() != unsafe { libc::geteuid() }
            || held.mode() & 0o022 != 0
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    plan.verify()
}
fn collect_with(
    budget: &ReadBudget,
    epoch: &ActorEpoch,
    enrollment: &BootEnrollment,
    name: &str,
    manager_pid: Option<i32>,
    stop: impl FnOnce() -> Result<()>,
) -> Result<BootCollection> {
    if manager_pid.is_some_and(|pid| pid != enrollment.child().pid) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    match epoch.collect_enrolled(name, enrollment) {
        Ok(proof) => Ok(proof),
        Err(error) if error.code == ErrorCode::Conflict => {
            let child = enrollment.child();
            if manager_pid != Some(child.pid)
                || smolvm::process::process_start_time(child.pid) != Some(child.birth)
                || !smolvm::process::is_alive(child.pid)
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let dispatch = epoch.begin_collection(name, enrollment)?;
            dispatch.run(budget, stop)?;
            epoch
                .collect_enrolled(name, enrollment)
                .map_err(|e| Error::uncertain(e.code))
        }
        Err(error) => Err(error),
    }
}
impl Engine {
    /// Caller holds the child gate. Keep the original enrollment/manager until
    /// actual collection and exact stopped-row acknowledgement permit handoff to
    /// regular restart. Source dependencies and persistent backing do not retire.
    pub(crate) fn stop_original_branch(
        &self,
        receipt: &CreationReceipt,
        expected: &Observation,
        context: &std::sync::Arc<Context>,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        let original = self.retained_branch_context(receipt)?;
        if !std::sync::Arc::ptr_eq(&original, context) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.original_branch_manager(receipt, context)?;
        let _work = self.jobs.acquire(crate::jobs::Demand::branch_delete())?;
        // Direct manager stop acquires no source flock itself.
        let _source = self.source_lease(receipt)?;
        context.plan.verify()?;
        let (head, held, release) = crate::branch_boot::Lifecycle::at(&context.plan.child.path)
            .finish_record(&context.plan, &context.enrollment, &context.identity_sha256)?;
        if held {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // A later authorized material head retains this original process.
        // verify_record below requires the exact current protected head.
        let mut origin = head;
        origin.material = None;
        crate::material::check_origin(&origin, receipt)?;
        crate::branch_delete::release_ready(context, release.as_ref())?;
        self.verify_lifecycle_preconditions(receipt, expected)?;
        let before = self
            .observation_record(&receipt.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_record(receipt, &before)?;
        verify_row(&before, receipt, &context.enrollment)?;
        let epoch = self.collection_epoch()?;
        let proof = context.collect_original(epoch, budget)?;
        acknowledge_stopped(self, receipt, &context.enrollment, &before, &proof, budget)
    }
}
fn acknowledge_stopped(
    engine: &Engine,
    receipt: &CreationReceipt,
    enrollment: &BootEnrollment,
    before: &smolvm::config::VmRecord,
    proof: &BootCollection,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check().map_err(|e| Error::uncertain(e.code))?;
    if proof.intent() != enrollment.intent() || proof.child() != enrollment.child() {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    verify_row(before, receipt, enrollment).map_err(|e| Error::uncertain(e.code))?;
    let hash = crate::material::hash(before)?;
    let mut changed = false;
    engine
        .db
        .update_vm(&receipt.name, |row| {
            if crate::material::hash(row).ok().as_ref() == Some(&hash) {
                row.state = smolvm::config::RecordState::Stopped;
                row.pid = None;
                row.pid_start_time = None;
                changed = true;
            }
        })
        .map_err(|_| Error::uncertain(ErrorCode::Database))?;
    let after = engine
        .observation_record(&receipt.name, budget)
        .map_err(|e| Error::uncertain(e.code))?
        .ok_or(Error::uncertain(ErrorCode::Ownership))?;
    engine
        .verify_record(receipt, &after)
        .map_err(|e| Error::uncertain(e.code))?;
    let mut stopped = before.clone();
    stopped.state = smolvm::config::RecordState::Stopped;
    stopped.pid = None;
    stopped.pid_start_time = None;
    if !changed || crate::material::hash(&after)? != crate::material::hash(&stopped)? {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    budget.check().map_err(|e| Error::uncertain(e.code))
}

fn verify_row(
    row: &smolvm::config::VmRecord,
    receipt: &CreationReceipt,
    enrollment: &BootEnrollment,
) -> Result<()> {
    let pid = row.pid.zip(row.pid_start_time);
    let child = enrollment.child();
    if !receipt.matches(row)?
        || row.forkpoint_held
        || !matches!(
            row.state,
            smolvm::config::RecordState::Running | smolvm::config::RecordState::Stopped
        )
        || !((pid == Some((child.pid, child.birth)))
            || (row.state == smolvm::config::RecordState::Stopped
                && row.pid.is_none()
                && row.pid_start_time.is_none()))
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
#[cfg(test)]
mod tests;
