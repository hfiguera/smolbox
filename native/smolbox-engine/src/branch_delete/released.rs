//! Exact original release qualification for ordinary collected-child deletion.
//! Legacy held-only resolution/continuation/cleanup never borrow this authority.
use super::*;
mod cleanup;
pub use cleanup::ReleasedBranchDeletionCleanupRequest;
mod continuation;
pub use continuation::{
    ReleasedBranchDeletionContinuation, ReleasedBranchDeletionContinuationRequest,
};
mod recovery;
pub use recovery::{
    ReleasedBranchDeletionRequest, ReleasedBranchDeletionResolution,
    RELEASED_BRANCH_DELETION_PROOF_BYTES, RELEASED_BRANCH_DELETION_REQUEST_BYTES,
};
pub(crate) fn release_ready(
    context: &Context,
    release: Option<&crate::BranchReleaseTransition>,
) -> Result<()> {
    let state = context
        .release
        .try_lock()
        .map_err(|_| Error::before(ErrorCode::Conflict))?;
    match (state.as_ref(), release) {
        (None, None) => Ok(()),
        (None, Some(release))
            if !context
                .plan
                .publication
                .change
                .child_origin
                .intent
                .child
                .hold =>
        {
            release.validate()
        }
        (Some(original), Some(release)) => original.deletion_ready(release),
        _ => Err(Error::before(ErrorCode::Ownership)),
    }
}
#[cfg(test)]
pub(super) mod tests;
