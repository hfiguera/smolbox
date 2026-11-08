//! Original terminal disposal with positive unused-cleanup cache provenance.
//! A bounded acknowledgement closes an accepted action, never removes files.
use super::super::ledger::ProtectedRecord;
use super::*;
use crate::{PartialBranchDisposalCleanupRequest, PartialBranchDisposalCleanupUnneeded};
use serde::{Deserialize, Serialize};

pub(super) struct RetainedUnneeded {
    request_sha256: String,
    proof_sha256: String,
    attempted: bool,
    published: bool,
}
impl RetainedUnneeded {
    fn new(proof: &PartialBranchDisposalCleanupUnneeded) -> Result<Self> {
        proof.validate()?;
        Ok(Self {
            request_sha256: proof.request.request_sha256.clone(),
            proof_sha256: proof.proof_sha256.clone(),
            attempted: false,
            published: false,
        })
    }
    fn acknowledge(
        &mut self,
        ledger: &Ledger,
        proof: &PartialBranchDisposalCleanupUnneeded,
        budget: &ReadBudget,
    ) -> Result<()> {
        self.acknowledge_with(ledger, proof, budget, |ledger, record| {
            ledger.write_record(record, None)
        })
    }
    fn acknowledge_with(
        &mut self,
        ledger: &Ledger,
        proof: &PartialBranchDisposalCleanupUnneeded,
        budget: &ReadBudget,
        publish: impl FnOnce(&Ledger, &Receipt) -> Result<()>,
    ) -> Result<()> {
        proof.validate()?;
        budget.check()?;
        if self.request_sha256 != proof.request.request_sha256
            || self.proof_sha256 != proof.proof_sha256
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        match ledger.read_record::<Receipt>()? {
            Some((record, _)) if self.attempted && record.proof == *proof => {}
            Some(_) => return Err(Error::before(ErrorCode::Ownership)),
            None if self.published => return Err(Error::before(ErrorCode::Ownership)),
            None => {
                // Retain this original publication attempt before any fallible
                // private IO; a visible unsynchronized receipt can be recovered.
                self.attempted = true;
                publish(
                    ledger,
                    &Receipt {
                        schema: 1,
                        proof: proof.clone(),
                    },
                )
                .map_err(|e| Error::uncertain(e.code))?;
            }
        }
        let (record, version) = ledger
            .read_record::<Receipt>()?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if record.proof != *proof {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        ledger
            .synchronize_record::<Receipt>(&version)
            .map_err(|e| Error::uncertain(e.code))?;
        self.published = true;
        budget.check().map_err(|e| Error::uncertain(e.code))
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    schema: u8,
    proof: PartialBranchDisposalCleanupUnneeded,
}
impl ProtectedRecord for Receipt {
    const MAX_BYTES: u64 = crate::PARTIAL_BRANCH_UNNEEDED_CLEANUP_PROOF_BYTES as u64 + 256;
    fn validate_for(&self, ledger: &Ledger) -> Result<()> {
        self.proof.validate()?;
        if self.schema != 1 || file(ledger.domain.clone(), &self.proof.request)?.path != ledger.path
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
fn file(
    domain: Arc<crate::domain::DomainGuard>,
    request: &PartialBranchDisposalCleanupRequest,
) -> Result<Ledger> {
    let mut ledger = Ledger::new(
        domain,
        &request.disposal_request.collection_request.creation,
    )?;
    ledger.path = ledger.path.with_extension("cleanup-unneeded.json");
    Ok(ledger)
}

pub(in crate::branch::retention::resolution::partial_disposal) fn require_no_unneeded_file(
    domain: Arc<crate::domain::DomainGuard>,
    creation: &crate::BranchCreateRequest,
) -> Result<()> {
    let path = Ledger::new(domain, creation)?
        .path
        .with_extension("cleanup-unneeded.json");
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(Error::before(ErrorCode::Ownership)),
    }
}

pub(in crate::branch::retention::resolution::partial_disposal) fn require_no_unneeded_history(
    engine: &Engine,
    creation: &crate::BranchCreateRequest,
) -> Result<()> {
    require_no_unneeded_file(engine.domain.clone(), creation)?;
    let disposed = engine
        .branch_retention
        .partial_disposed
        .try_lock()
        .map_err(|_| Error::before(ErrorCode::Conflict))?;
    if disposed.values().any(|child| {
        child.proof.request.collection_request.creation == *creation && child.unneeded.is_some()
    }) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

impl Engine {
    /// Acknowledge unnecessary accepted cleanup after protected original
    /// terminal completion. An exact unattempted enrollment may first complete
    /// an existing disposal from fresh original-context positive absence. Never
    /// dispatches SDK lifecycle/removal or reconstructs ownership. Historical
    /// terminal acknowledgement reads leave current VM namespaces untouched.
    /// Callers still require fresh source observation and guarded public commit.
    pub fn resolve_unneeded_partial_cleanup(
        &self,
        request: &PartialBranchDisposalCleanupRequest,
        budget: &ReadBudget,
    ) -> Result<Option<PartialBranchDisposalCleanupUnneeded>> {
        validate_budget(budget)?;
        request.validate()?;
        let creation = &request.disposal_request.collection_request.creation;
        creation.validate(self)?;
        if self
            .inspect_partial_branch_disposal(&request.disposal_request, budget)?
            .is_none()
        {
            if let Some(original) = self.retain_branch_resolution(creation, true, budget)? {
                original.recover_unneeded_partial_handoff(self, request)?;
            }
        }
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        self.verify_database_identity()?;
        self.domain.verify()?;
        let mut disposed = self
            .branch_retention
            .partial_disposed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut selected = None;
        for (key, child) in disposed.iter() {
            budget.check()?;
            let original = &child.proof.request.collection_request.creation;
            if original.child.name != creation.child.name
                && !(original.source.name == creation.source.name
                    && original.child.operation_id == creation.child.operation_id)
            {
                continue;
            }
            if child.proof.request != request.disposal_request || selected.is_some() {
                return Err(Error::before(ErrorCode::Ownership));
            }
            selected = Some(key.clone());
        }
        let Some(key) = selected else {
            return Ok(None);
        };
        let child = disposed
            .get_mut(&key)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !child.cleanup.permits(request)? {
            // Unavailable is not cleanup eligibility or permission to replay SDK.
            return Ok(None);
        }
        let original = child.record(self)?;
        let cleanup = super::super::residual::file(self.domain.clone(), creation)?;
        match std::fs::symlink_metadata(&cleanup.path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            _ => return Err(Error::before(ErrorCode::Ownership)),
        }
        if original.proof.as_ref() != Some(&child.proof) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let proof = PartialBranchDisposalCleanupUnneeded::issue(request, child.proof.clone())?;
        budget.check()?;
        if child.unneeded.is_none() {
            child.unneeded = Some(RetainedUnneeded::new(&proof)?);
        }
        child
            .unneeded
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .acknowledge(&file(self.domain.clone(), request)?, &proof, budget)?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(Some(proof))
    }
}

#[cfg(test)]
#[path = "unneeded/tests.rs"]
mod tests;
