//! Explicit retirement of a protected unentered branch declaration. Request
//! correlation is separate from native admission/PID/epoch evidence. No entered
//! fork disposal, SDK action, source material transition or backing release.
use super::*;

pub const PREPARED_BRANCH_RETIREMENT_BYTES: usize = 16 * 1024;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedBranchRetirementRequest {
    pub creation: BranchCreateRequest,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for PreparedBranchRetirementRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedBranchRetirementRequest")
            .finish_non_exhaustive()
    }
}
impl PreparedBranchRetirementRequest {
    fn validate(&self, engine: &Engine) -> Result<()> {
        self.creation.validate(engine)?;
        self.validate_envelope()
    }
    fn validate_envelope(&self) -> Result<()> {
        self.creation.validate_declaration()?;
        if !self.quiesced
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PREPARED_BRANCH_RETIREMENT_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-prepared-branch-retirement-request-v1",
            &self.creation,
            self.quiesced,
        ))
    }
    pub fn matches(&self, proof: &PreparedBranchRetirement) -> Result<()> {
        self.validate_envelope()?;
        proof.validate()?;
        if proof.request_sha256 != self.request_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        proof.retirement.matches_creation(&self.creation)
    }
}
/// Positive prepared-only result, never an entered-child absence acknowledgement.
/// The outer hash correlates host intent (including an unused initial-release
/// choice); the protected inner proof attests only its native declaration.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedBranchRetirement {
    pub schema: u8,
    pub request_sha256: String,
    pub retirement: InitialBranchRetirement,
    pub proof_sha256: String,
}
impl std::fmt::Debug for PreparedBranchRetirement {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedBranchRetirement")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl PreparedBranchRetirement {
    pub fn validate(&self) -> Result<()> {
        self.retirement.validate()?;
        if self.schema != 1
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > PREPARED_BRANCH_RETIREMENT_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-prepared-branch-retirement-proof-v1",
            self.schema,
            &self.request_sha256,
            &self.retirement,
        ))
    }
    fn issue(
        request: &PreparedBranchRetirementRequest,
        retirement: InitialBranchRetirement,
    ) -> Result<Self> {
        retirement.matches_creation(&request.creation)?;
        let mut proof = Self {
            schema: 1,
            request_sha256: request.request_sha256.clone(),
            retirement,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        request.matches(&proof)?;
        Ok(proof)
    }
}
impl Engine {
    /// Explicitly retire only known prepared state with the original native
    /// admission digest selected from protected history. None/entered state
    /// cannot become absence, even when mutable SDK inventory is empty.
    pub fn retire_prepared_branch_checked(
        &self,
        request: &PreparedBranchRetirementRequest,
        budget: &ReadBudget,
    ) -> Result<PreparedBranchRetirement> {
        budget.check()?;
        request.validate(self)?;
        let native_request = {
            let _control = self
                .jobs
                .acquire(crate::jobs::Demand::branch_retirement())?;
            let source = &request.creation.source;
            let root = crate::export_source::Root::open(&self.vm_directory(&source.name))?;
            require_marker(self, source)?;
            let selected = crate::material::MaterialJournal::at(&self.vm_directory(&source.name))
                .prepared_branch_request(&request.creation)?
                .ok_or(Error::before(ErrorCode::State))?;
            root.verify()?;
            self.domain.verify()?;
            budget.check()?;
            selected
        }; // Never nest the finite control allowance with the retirement job.
        let retired = self.retire_prepared_initial_branch(
            &request.creation.source,
            &request.creation.child.operation_id,
            &native_request,
            request.quiesced,
            budget,
        )?;
        let proof = PreparedBranchRetirement::issue(request, retired)
            .map_err(|error| Error::uncertain(error.code))?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(proof)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::time::Duration;
    fn budget() -> ReadBudget {
        ReadBudget::new(Duration::from_secs(5), crate::Cancellation::default()).unwrap()
    }
    pub(crate) fn request(intent: &InitialBranchJournal) -> PreparedBranchRetirementRequest {
        let creation = BranchCreateRequest {
            source: intent.source.clone(),
            child: intent.child.clone(),
            approval: intent.approval.clone(),
            initial_release: (!intent.child.hold).then_some(crate::BranchReleaseRequest {
                operation_id: "initial-activation".into(),
                request_sha256: "d".repeat(64),
            }),
        };
        let mut request = PreparedBranchRetirementRequest {
            creation,
            request_sha256: String::new(),
            quiesced: true,
        };
        request.request_sha256 = request.digest().unwrap();
        request
    }
    #[test]
    fn synthetic_readers_bind_native_declaration_and_distinct_host_correlation_without_child_authority(
    ) {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/prepared-branch-retirement-v1.json"
        ))
        .unwrap();
        for row in rows {
            let request: PreparedBranchRetirementRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PreparedBranchRetirement =
                serde_json::from_value(row["proof"].clone()).unwrap();
            request.matches(&proof).unwrap();
            assert!(!format!("{request:?} {proof:?}").contains(&request.creation.child.owner_token));
            for mode in 0..5 {
                let mut changed = request.clone();
                match mode {
                    0 => changed.quiesced = false,
                    1 => changed.creation.child.owner_token = "f".repeat(64),
                    2 => changed.creation.approval.resources.disk_gb += 1,
                    3 => changed.creation.source.domain_generation = "f".repeat(32),
                    _ => {
                        changed.creation.initial_release = if changed.creation.child.hold {
                            Some(crate::BranchReleaseRequest {
                                operation_id: "unused".into(),
                                request_sha256: "e".repeat(64),
                            })
                        } else {
                            None
                        }
                    }
                }
                changed.request_sha256 = changed.digest().unwrap();
                assert!(changed.matches(&proof).is_err());
            }
            let mut changed = proof.clone();
            changed.retirement.proof_sha256 = "0".repeat(64);
            changed.proof_sha256 = changed.digest().unwrap();
            assert!(changed.validate().is_err());
            let mut changed = proof;
            changed.request_sha256 = "0".repeat(64);
            changed.proof_sha256 = changed.digest().unwrap();
            changed.validate().unwrap();
            assert!(request.matches(&changed).is_err());
        }
    }
    #[test]
    fn checked_prepared_retirement_preserves_material_and_history_after_normal_reopen_without_sdk()
    {
        // Private stopped-row model only: no source/child process or SDK entry.
        let temp = tempfile::tempdir().unwrap();
        let (engine, source, intent) =
            crate::branch::tests::prepared_stopped_model(temp.path(), false);
        let request = request(&intent);
        request.validate(&engine).unwrap();
        let before = engine.jobs.counts();
        let proof = engine
            .retire_prepared_branch_checked(&request, &budget())
            .unwrap();
        request.matches(&proof).unwrap();
        assert_eq!(engine.jobs.counts(), before);
        assert_eq!(
            engine.inspect(&source).unwrap().state,
            crate::ObservedState::Stopped
        );
        assert!(engine
            .db
            .get_vm(&request.creation.child.name)
            .unwrap()
            .is_none());
        assert!(!engine.vm_directory(&request.creation.child.name).exists());
        let path = engine
            .vm_directory(&source.name)
            .join("smolbox.material-v2.json");
        let bytes = std::fs::read(&path).unwrap();
        drop(engine);
        let engine = crate::machine::tests::test_engine(temp.path());
        let gate = engine.gate(&request.creation.child.name).unwrap();
        let _busy = gate.try_lock().unwrap();
        assert!(
            engine
                .retire_prepared_branch_checked(&request, &budget())
                .unwrap()
                == proof
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        assert!(engine
            .prepare_initial_branch(
                &source,
                &request.creation.child,
                &request.creation.approval,
                &budget()
            )
            .is_err());
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
    #[test]
    fn cancellation_crossed_declaration_and_missing_prepared_evidence_never_assert_absence_or_release_work(
    ) {
        let temp = tempfile::tempdir().unwrap();
        let (engine, source, intent) =
            crate::branch::tests::prepared_stopped_model(temp.path(), false);
        let valid = request(&intent);
        let path = engine
            .vm_directory(&source.name)
            .join("smolbox.material-v2.json");
        let original = std::fs::read(&path).unwrap();
        let before = engine.jobs.counts();
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(engine
            .retire_prepared_branch_checked(&valid, &cancelled)
            .is_err());
        for mode in 0..3 {
            let mut crossed = valid.clone();
            match mode {
                0 => crossed.quiesced = false,
                1 => crossed.creation.child.name = "foreign-child".into(),
                _ => crossed.creation.approval.resources.disk_gb += 1,
            }
            crossed.request_sha256 = crossed.digest().unwrap();
            assert_eq!(
                engine
                    .retire_prepared_branch_checked(&crossed, &budget())
                    .unwrap_err()
                    .dispatch,
                crate::Dispatch::NotDispatched
            );
            assert_eq!(std::fs::read(&path).unwrap(), original);
            assert_eq!(engine.jobs.counts(), before);
        }
        engine
            .retire_prepared_branch_checked(&valid, &budget())
            .unwrap();
        let completed = std::fs::read(&path).unwrap();
        let mut missing = valid;
        missing.creation.child.operation_id = "never-admitted".into();
        missing.creation.child.name = "absent-without-declaration".into();
        missing.request_sha256 = missing.digest().unwrap();
        assert!(engine
            .db
            .get_vm(&missing.creation.child.name)
            .unwrap()
            .is_none());
        assert!(!engine.vm_directory(&missing.creation.child.name).exists());
        assert!(engine
            .retire_prepared_branch_checked(&missing, &budget())
            .is_err());
        assert_eq!(std::fs::read(path).unwrap(), completed);
        assert_eq!(engine.jobs.counts(), before);
    }
}
