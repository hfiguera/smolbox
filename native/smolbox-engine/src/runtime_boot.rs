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
    pub(crate) fn verify_before(
        &self,
        receipt: &CreationReceipt,
        row: &smolvm::config::VmRecord,
    ) -> Result<()> {
        self.matches(receipt)?;
        let child = self.enrolled()?.child();
        if !receipt.matches(row)?
            || row.forkpoint_held
            || !matches!(
                row.state,
                smolvm::config::RecordState::Running | smolvm::config::RecordState::Stopped
            )
            || !(row.pid.zip(row.pid_start_time) == Some((child.pid, child.birth))
                || (row.state == smolvm::config::RecordState::Stopped
                    && row.pid.is_none()
                    && row.pid_start_time.is_none()))
        {
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
        owned.call(
            receipt,
            self.collection_epoch()?,
            self.runtime.pid(&receipt.name),
            budget,
            || {
                self.runtime
                    .stop_machine(&receipt.name)
                    .map_err(|_| Error::uncertain(ErrorCode::Native))
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
        verify_stopped(receipt, &stopped, &after, self.runtime.pid(&receipt.name))?;
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
