//! Read-only original-context selection, never SDK entry or disposal authority.
use super::*;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnbootedBranchDisposalCandidate {
    pub schema: u8,
    pub creation: BranchCreateRequest,
    pub publication: crate::BranchPublication,
    pub preparation_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for UnbootedBranchDisposalCandidate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnbootedBranchDisposalCandidate")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl UnbootedBranchDisposalCandidate {
    pub fn matches(&self, creation: &BranchCreateRequest) -> Result<()> {
        validate_creation(creation)?;
        self.validate()?;
        if self.creation != *creation {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub fn validate(&self) -> Result<()> {
        validate_creation(&self.creation)?;
        self.publication.validate()?;
        self.publication
            .change
            .child_origin
            .intent
            .matches_creation(&self.creation)?;
        if self.schema != 1
            || !crate::domain::valid_hex(&self.preparation_sha256, 64)
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
            "smolbox-original-unbooted-disposal-candidate-v1",
            self.schema,
            &self.creation,
            &self.publication,
            &self.preparation_sha256,
        ))
    }
}
impl RetainedBranchResolution {
    /// Positively inspect only the original fully published, never-booted job.
    /// No SDK call, journal mutation, guest readiness, absence or capacity release.
    /// Actual disposal must independently recheck its accepted request/context.
    pub fn inspect_disposal_candidate(
        &self,
        engine: &Engine,
    ) -> Result<UnbootedBranchDisposalCandidate> {
        self.verify_epoch(engine)?;
        self.candidate_checked(engine, |publication, source, after| {
            live_source(engine, publication, source, &self.budget, after)
        })
    }
    pub(super) fn candidate_checked(
        &self,
        engine: &Engine,
        source_authority: impl Fn(
            &crate::BranchPublication,
            &smolvm::config::VmRecord,
            bool,
        ) -> Result<()>,
    ) -> Result<UnbootedBranchDisposalCandidate> {
        validate_budget(&self.budget)?;
        let _control = engine
            .jobs
            .acquire(crate::jobs::Demand::branch_retirement())?;
        let entry = self.original.entry(engine)?;
        verify_original(engine, &entry, &self.creation)?;
        engine.verify_database_identity()?;
        if Ledger::new(engine.domain.clone(), &self.creation)?
            .read()?
            .is_some()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.phase != Phase::Published || work.boot.is_some() || work.worker.upgrade().is_some()
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
        if publication.change.child_origin.raw_child_sha256
            != crate::identity::material_hash(&snapshot.child)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.ready(engine, &entry, &publication, snapshot, &source_authority)?;
        let mut result = UnbootedBranchDisposalCandidate {
            schema: 1,
            creation: self.creation.clone(),
            publication,
            preparation_sha256: entry.expected.metadata_sha256.clone(),
            proof_sha256: String::new(),
        };
        result.proof_sha256 = result.digest()?;
        result.validate()?;
        self.budget.check()?;
        Ok(result)
    }
}
