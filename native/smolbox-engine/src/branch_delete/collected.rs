//! Same-owner released children whose original manager was normally retired.
//! Retained completion and positive epoch collection are still required; SDK
//! inventory and a stopped row alone grant no original deletion authority.
use super::*;

impl Engine {
    pub(crate) fn retained_released_deletion_head(
        &self,
        child: &CreationReceipt,
        budget: &ReadBudget,
    ) -> Result<bool> {
        budget.check()?;
        self.domain.verify()?;
        let marked = self
            .observation_record(&child.name, budget)?
            .is_some_and(|row| {
                row.labels
                    .contains_key(crate::branch_material::PARENT_LABEL)
            });
        let journal = Journal::new(self.domain.clone(), child)?;
        let recorded = match std::fs::symlink_metadata(&journal.path) {
            Ok(_) => true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(_) => return Err(Error::before(ErrorCode::Io)),
        };
        // Inventory is only a filter, never authority. Fresh non-branch deletion
        // must not contend with an unrelated branch completion registry.
        if !marked && !recorded {
            return Ok(false);
        }
        let Some(context) = self.branch_retention.completed_context(child)? else {
            return Ok(false);
        };
        let original = self.retained_branch_context(child)?;
        if !Arc::ptr_eq(&context, &original) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        {
            let retained = context
                .deletion
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if let Some(retained) = retained.as_ref() {
                // A completed deletion may have removed the lifecycle directory.
                return Ok(retained.intent.receipt() == child);
            }
        }
        match self.require_no_active_branch_handles(child) {
            Ok(()) => {}
            // Existing stopped lifecycle behavior remains available for current
            // handles. It cannot borrow retired-original collection authority.
            Err(error) if error.code == ErrorCode::Ownership => return Ok(false),
            Err(error) => return Err(error),
        }
        match released_head(
            &context.plan,
            &context.enrollment,
            &context.identity_sha256,
            child,
            budget,
        ) {
            // Without a retained deletion intent, missing material grants no
            // original authority. The ordinary receipt-bound path still checks
            // its existing stopped/missing semantics.
            Err(error) if error.code == ErrorCode::NotFound => Ok(false),
            result => result,
        }
    }
    pub(super) fn branch_deletion_owner(
        &self,
        child: &CreationReceipt,
        context: &Arc<Context>,
        held: bool,
    ) -> Result<bool> {
        match self.original_branch_manager(child, context) {
            Ok(()) => return Ok(true),
            Err(error) if error.code == ErrorCode::Ownership && !held => {}
            Err(error) => return Err(error),
        }
        self.require_no_active_branch_handles(child)?;
        let manager = context
            .manager
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if manager.child_pid().is_some() || context._runtime.pid(&child.name).is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(false)
    }
}
fn released_head(
    plan: &crate::branch_boot::Plan,
    enrollment: &crate::epoch::BootEnrollment,
    identity_sha256: &str,
    child: &CreationReceipt,
    budget: &ReadBudget,
) -> Result<bool> {
    budget.check()?;
    let (head, held, _) = crate::branch_boot::Lifecycle::at(&plan.child.path).finish_record(
        plan,
        enrollment,
        identity_sha256,
    )?;
    budget.check()?;
    Ok(!held && &head == child)
}
pub(super) fn collected_before(
    intent: &Intent,
    before: &smolvm::config::VmRecord,
    authority: ResolutionAuthority<'_>,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check()?;
    intent.validate()?;
    if intent.release.is_none()
        || before.state != smolvm::config::RecordState::Stopped
        || before.pid.is_some()
        || before.pid_start_time.is_some()
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let collection = authority
        .epoch
        .collect_enrolled(&intent.receipt().name, authority.enrollment)?;
    // This verifies the original protected root, exact release/current head and
    // canonical stopped row without manufacturing a new boot enrollment.
    stopped_record(intent, before, &collection, budget)?;
    Ok(())
}
#[cfg(test)]
mod tests;
