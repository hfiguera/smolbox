//! Disposal selects only a head already authorized by the frozen lifecycle.
use super::*;
use crate::{PartialBranchCollection, PartialBranchCollectionRequest};
impl Lifecycle {
    pub(crate) fn partial_disposal_release(
        &self,
        plan: &Plan,
        request: &PartialBranchCollectionRequest,
        proof: &PartialBranchCollection,
        enrollment: &crate::epoch::BootEnrollment,
        row: &smolvm::config::VmRecord,
    ) -> Result<Option<crate::BranchReleaseTransition>> {
        if self.partial_collection(plan, request, enrollment)?.as_ref() != Some(proof) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let (journal, _) = self.read()?;
        if journal.plan != *plan || !collection::phase_matches(&journal.phase, enrollment) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        plan.publication.change.child_origin.verify_record(row)?;
        // A held row may be the before-state of an entered release. A cleared
        // flag alone cannot invent a released material head or readiness.
        if row.forkpoint_held
            && !matches!(journal.phase, Phase::Released { .. })
            && plan.publication.child().matches(row)?
        {
            return Ok(None);
        }
        match journal.phase {
            Phase::Releasing { intent } | Phase::Released { intent }
                if intent.matches(enrollment) && !row.forkpoint_held =>
            {
                intent.transition.verify_record(row)?;
                Ok(Some(intent.transition))
            }
            _ => Err(Error::before(ErrorCode::Ownership)),
        }
    }
}
