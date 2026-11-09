//! Same-engine ordinary SDK boot ownership. Persisted rows cannot reconstruct
//! the returned enrollment; metadata stays charged through uncertain collection.
use crate::epoch::{ActorEpoch, BootEnrollment};
use crate::{CreationReceipt, Engine, Error, ErrorCode, Observation, ReadBudget, Result};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Default)]
pub(crate) struct Registry(Mutex<BTreeMap<String, Arc<Owned>>>);
pub(crate) struct Owned {
    origin: CreationReceipt,
    enrollment: OnceLock<Arc<BootEnrollment>>,
    _metadata: crate::jobs::BranchBackingLease,
}
impl Registry {
    pub(crate) fn reserve(
        &self,
        receipt: &CreationReceipt,
        jobs: &crate::jobs::JobPool,
    ) -> Result<Arc<Owned>> {
        let mut entries = self
            .0
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if entries.contains_key(&receipt.name) {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let metadata = jobs.branch_result_metadata()?;
        let mut origin = receipt.clone();
        origin.material = None;
        let owned = Arc::new(Owned {
            origin,
            enrollment: OnceLock::new(),
            _metadata: metadata,
        });
        entries.insert(receipt.name.clone(), owned.clone());
        Ok(owned)
    }
    pub(crate) fn get(&self, receipt: &CreationReceipt) -> Result<Option<Arc<Owned>>> {
        let entry = self
            .0
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            .cloned();
        if let Some(entry) = &entry {
            entry.matches(receipt)?;
        }
        Ok(entry)
    }
    pub(crate) fn contains(&self, name: &str) -> Result<bool> {
        Ok(self
            .0
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .contains_key(name))
    }
    /// Bounded control observation must not wait behind another registry user.
    pub(crate) fn try_contains(&self, name: &str) -> Result<bool> {
        Ok(self
            .0
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .contains_key(name))
    }
    pub(crate) fn retire(&self, owned: &Arc<Owned>) -> Result<()> {
        let mut entries = self
            .0
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if !entries
            .get(&owned.origin.name)
            .is_some_and(|current| Arc::ptr_eq(current, owned))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        entries.remove(&owned.origin.name);
        Ok(())
    }
}
impl Owned {
    fn matches(&self, receipt: &CreationReceipt) -> Result<()> {
        crate::material::check_origin(&self.origin, receipt)
    }
    pub(crate) fn enroll(&self, enrollment: BootEnrollment, epoch: &ActorEpoch) -> Result<()> {
        if !enrollment.intent().matches_epoch(&self.origin.name, epoch) {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        self.enrollment
            .set(Arc::new(enrollment))
            .map_err(|_| Error::uncertain(ErrorCode::Conflict))
    }
    fn enrolled(&self) -> Result<&BootEnrollment> {
        self.enrollment
            .get()
            .map(Arc::as_ref)
            .ok_or(Error::before(ErrorCode::Ownership))
    }
    /// A database snapshot is only a candidate. The start-only readiness wait
    /// remains bound to this returned enrollment, never a discovered live PID.
    pub(crate) fn verify_running(
        &self,
        receipt: &CreationReceipt,
        observation: &Observation,
        runtime_pid: Option<i32>,
    ) -> Result<()> {
        self.matches(receipt)?;
        let child = self.enrolled()?.child();
        if observation.state != crate::ObservedState::Running
            || observation.pid_identity != Some((child.pid, child.birth))
            || runtime_pid != Some(child.pid)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn verify_before(
        &self,
        receipt: &CreationReceipt,
        row: &smolvm::config::VmRecord,
    ) -> Result<()> {
        self.matches(receipt)?;
        let child = self.enrolled()?.child();
        // SDK startup can return an error after an enrolled child exits while
        // leaving the original row Created. Permit its normal SDK cleanup only
        // with this original enrollment, no stored PID and positive absence or
        // read-only exit evidence for the originally enrolled child. Do not reap
        // its wait status before the normal SDK collection call.
        // A Created row, absent PID or missing enrollment alone grants nothing.
        let failed_created = row.state == smolvm::config::RecordState::Created
            && row.pid.is_none()
            && row.pid_start_time.is_none()
            && created_child_exited(child)?;
        let retained_state = matches!(
            row.state,
            smolvm::config::RecordState::Running | smolvm::config::RecordState::Stopped
        ) && (row.pid.zip(row.pid_start_time)
            == Some((child.pid, child.birth))
            || (row.state == smolvm::config::RecordState::Stopped
                && row.pid.is_none()
                && row.pid_start_time.is_none()));
        if !receipt.matches(row)? || row.forkpoint_held || !(failed_created || retained_state) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn call(
        &self,
        receipt: &CreationReceipt,
        epoch: &ActorEpoch,
        runtime_pid: Option<i32>,
        budget: &ReadBudget,
        call: impl FnOnce() -> Result<()>,
    ) -> Result<()> {
        budget.check()?;
        self.matches(receipt)?;
        let enrollment = self.enrolled()?;
        let child = enrollment.child();
        if runtime_pid.is_some_and(|pid| pid != child.pid)
            || (smolvm::process::is_alive(child.pid)
                && smolvm::process::process_start_time(child.pid) != Some(child.birth))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // Publish even for an exited child: SDK still owns its cached handle
        // until the explicit lifecycle call returns. Do not sweep it first.
        let dispatch = epoch.begin_collection(&receipt.name, enrollment)?;
        dispatch.run(budget, call)?;
        epoch
            .collect_enrolled(&receipt.name, enrollment)
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn collected(
        &self,
        receipt: &CreationReceipt,
        epoch: &ActorEpoch,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.matches(receipt)?;
        epoch.collect_enrolled(&receipt.name, self.enrolled()?)?;
        budget.check()
    }
}

/// Retry only read-only agent reachability after the SDK's single boot call.
/// The caller verifies original enrollment on every snapshot. Uncertain return
/// neither stops the child nor retires its authority/resources.
pub(crate) fn wait_until_ready(
    budget: &ReadBudget,
    mut observe_original: impl FnMut() -> Result<Observation>,
    mut probe: impl FnMut(&ReadBudget) -> Result<()>,
) -> Result<Observation> {
    let uncertain = |error: Error| Error::uncertain(error.code);
    loop {
        budget.check().map_err(uncertain)?;
        let before = observe_original().map_err(uncertain)?;
        let attempt = ReadBudget {
            deadline: budget
                .deadline
                .min(std::time::Instant::now() + std::time::Duration::from_millis(250)),
            cancel: budget.cancel.clone(),
        };
        match probe(&attempt) {
            Ok(()) => {
                budget.check().map_err(uncertain)?;
                let after = observe_original().map_err(uncertain)?;
                if before != after {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                budget.check().map_err(uncertain)?;
                return Ok(after);
            }
            // A per-attempt timeout is not the original operation's timeout.
            // Admission, identity, filesystem and protocol-limit failures stop.
            Err(error) if matches!(error.code, ErrorCode::Native | ErrorCode::State) => {}
            Err(error) => return Err(uncertain(error)),
        }
        budget.check().map_err(uncertain)?;
        std::thread::sleep(
            std::time::Duration::from_millis(25).min(
                budget
                    .deadline
                    .saturating_duration_since(std::time::Instant::now()),
            ),
        );
    }
}
fn created_child_exited(child: crate::OwnerIdentity) -> Result<bool> {
    match smolvm::process::process_start_time(child.pid) {
        Some(birth) => Ok(cfg!(target_os = "linux")
            && birth == child.birth
            && !smolvm::process::is_alive(child.pid)),
        None => crate::epoch::gone(child),
    }
}
impl Engine {
    pub(crate) fn stop_runtime_boot(
        &self,
        receipt: &CreationReceipt,
        expected: &Observation,
        owned: &Arc<Owned>,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.verify_lifecycle_preconditions(receipt, expected)?;
        let before = self
            .observation_record(&receipt.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_record(receipt, &before)?;
        owned.verify_before(receipt, &before)?;
        let _work = self.jobs.acquire(crate::jobs::Demand::branch_delete())?;
        let manager = self
            .owned_managers
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            .cloned();
        owned.call(
            receipt,
            self.collection_epoch()?,
            self.runtime_pid(&receipt.name),
            budget,
            || {
                if let Some(manager) = manager {
                    let _source = self.source_lease(receipt)?;
                    manager
                        .try_lock()
                        .map_err(|_| Error::before(ErrorCode::Conflict))?
                        .stop()
                        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                    self.db
                        .update_vm(&receipt.name, |row| {
                            row.state = smolvm::config::RecordState::Stopped;
                            row.pid = None;
                            row.pid_start_time = None;
                        })
                        .map_err(|_| Error::uncertain(ErrorCode::Database))?
                        .ok_or(Error::uncertain(ErrorCode::Ownership))?;
                    Ok(())
                } else {
                    self.runtime
                        .stop_machine(&receipt.name)
                        .map_err(|_| Error::uncertain(ErrorCode::Native))
                }
            },
        )?;
        let after = self
            .observation_record(&receipt.name, budget)
            .map_err(|e| Error::uncertain(e.code))?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        self.verify_record(receipt, &after)
            .map_err(|e| Error::uncertain(e.code))?;
        let mut stopped = before;
        stopped.state = smolvm::config::RecordState::Stopped;
        stopped.pid = None;
        stopped.pid_start_time = None;
        verify_stopped(receipt, &stopped, &after, self.runtime_pid(&receipt.name))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(())
    }
}
fn verify_stopped(
    receipt: &CreationReceipt,
    stopped: &smolvm::config::VmRecord,
    after: &smolvm::config::VmRecord,
    runtime_pid: Option<i32>,
) -> Result<()> {
    if runtime_pid.is_some()
        || !receipt.matches(after)?
        || after.state != smolvm::config::RecordState::Stopped
        || after.pid.is_some()
        || after.pid_start_time.is_some()
        || crate::material::hash(after)? != crate::material::hash(stopped)?
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    Ok(())
}
#[cfg(test)]
mod tests;
