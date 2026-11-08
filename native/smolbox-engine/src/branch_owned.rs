//! Original completed-child context. A receipt or SDK row cannot construct it.
use crate::{BranchPublication, CreationReceipt, Error, ErrorCode, Result};
use std::sync::{Arc, Mutex};
mod collection;
pub(crate) use collection::collect_manager;
mod paths;
pub(crate) use paths::ManagerPaths;

pub(crate) struct Context {
    // Drop the child's actual manager before its original source/runtime/domain.
    pub manager: Arc<Mutex<smolvm::agent::AgentManager>>,
    pub plan: crate::branch_boot::Plan,
    pub manager_paths: ManagerPaths,
    pub enrollment: Arc<crate::epoch::BootEnrollment>,
    pub identity_sha256: String,
    pub release: Mutex<Option<Box<crate::branch_held_release::Retained>>>,
    pub deletion: Mutex<Option<Box<crate::branch_delete::Retained>>>,
    pub runtime_boots: Arc<crate::runtime_boot::Registry>,
    pub _runtime: Arc<smolvm::embedded::EmbeddedRuntime>,
    pub _domain: Arc<crate::domain::DomainGuard>,
}
#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchCompletion {
    pub schema: u8,
    pub publication: BranchPublication,
    pub child: CreationReceipt,
    pub identity_sha256: String,
    pub held: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release: Option<crate::BranchReleaseTransition>,
}
impl std::fmt::Debug for BranchCompletion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchCompletion")
            .field("schema", &self.schema)
            .field("held", &self.held)
            .finish_non_exhaustive()
    }
}
impl BranchCompletion {
    pub fn validate(&self) -> Result<()> {
        self.publication.validate()?;
        if self.schema != 1 || !crate::domain::valid_hex(&self.identity_sha256, 64) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match &self.release {
            Some(release) => {
                release.validate()?;
                if self.held
                    || release.previous != *self.publication.child()
                    || release.receipt != self.child
                    || release.change.identity_sha256 != self.identity_sha256
                    || release.change.binding != self.publication.change.child_origin
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
            }
            None if self.held
                && self.publication.change.child_origin.intent.child.hold
                && self.child == *self.publication.child() => {}
            None => return Err(Error::before(ErrorCode::Ownership)),
        }
        if serde_json::to_vec(self)
            .map_err(|_| Error::before(ErrorCode::Io))?
            .len()
            > 64 * 1024
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        Ok(())
    }
}
impl crate::Engine {
    pub(crate) fn install_branch_manager(
        &self,
        completion: &BranchCompletion,
        context: Arc<Context>,
    ) -> Result<()> {
        completion.validate()?;
        if context.plan.publication != completion.publication
            || context.identity_sha256 != completion.identity_sha256
            || !Arc::ptr_eq(&context._domain, &self.domain)
            || !Arc::ptr_eq(&context._runtime, &self.runtime)
            || !Arc::ptr_eq(&context.runtime_boots, &self.runtime_boots)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        {
            let manager = context
                .manager
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            context.manager_paths.verify(&context.plan, &manager)?;
        }
        self.install_original_branch_manager(&completion.child, context)
    }
}
