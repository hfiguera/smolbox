//! Qualification of a pre-entry-aborted source is not material change or capture.
use crate::{CaptureStagingCleanupReceipt, CreationReceipt, Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureAbortSourceState {
    Running,
    Stopped,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureAbortSourceQualification {
    pub schema: u8,
    pub cleanup: CaptureStagingCleanupReceipt,
    pub(crate) intent: crate::capture_material::Intent,
    pub state: CaptureAbortSourceState,
    pub record_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for CaptureAbortSourceQualification {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CaptureAbortSourceQualification")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl CaptureAbortSourceQualification {
    pub fn validate(&self) -> Result<()> {
        self.cleanup.validate()?;
        let mut origin = self.cleanup.previous.clone();
        origin.material = None;
        if self.schema != 1
            || !self.intent.valid()
            || self.intent.operation_id != self.cleanup.operation_id
            || self.intent.request != self.cleanup.request
            || self.cleanup.previous.material.as_ref() != Some(&self.intent.previous)
            || (self.intent.previous.revision == 0
                && self.intent.previous != crate::material::root_proof(&origin)?)
            || self.record_sha256 != self.intent.previous.record_sha256
            || !crate::domain::valid_hex(&self.proof_sha256, 64)
            || self.proof_sha256 != self.digest()?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-preentry-aborted-source-v1",
            &self.cleanup,
            &self.intent,
            self.state,
            &self.record_sha256,
        ))
    }
    pub(crate) fn issue(
        cleanup: CaptureStagingCleanupReceipt,
        intent: crate::capture_material::Intent,
        record: &smolvm::config::VmRecord,
        authority: &crate::capture_resolution::SourceAuthority,
    ) -> Result<Self> {
        if !authority.matches(record, intent.source_pid)
            || crate::material::capture_immutable_hash(record)? != intent.immutable_sha256
            || crate::material::immutable_hash(record)? != intent.growth_immutable_sha256
            || record.checkpoint_head != intent.previous_head
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut proof = Self {
            schema: 1,
            cleanup,
            intent,
            state: if authority.running() {
                CaptureAbortSourceState::Running
            } else {
                CaptureAbortSourceState::Stopped
            },
            record_sha256: crate::identity::material_hash(record)?,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        proof.validate()?;
        Ok(proof)
    }
}

impl crate::Engine {
    /// Source qualification requires the recorded original process, actual
    /// engine/cache ownership or verified original-process absence. No SDK call
    /// reconnects, stops, starts or changes material.
    pub fn qualify_aborted_capture_source(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: &crate::CaptureRequest,
        quiesced: bool,
        budget: &crate::ReadBudget,
    ) -> Result<CaptureAbortSourceQualification> {
        if !quiesced || !crate::domain::valid_id(operation_id) {
            return Err(Error::before(ErrorCode::Validation));
        }
        budget.check()?;
        receipt.validate(self.binding())?;
        request.validate()?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let (cleanup, intent) =
            self.capture_staging
                .aborted_source(receipt, operation_id, request)?;
        let before = self.record(receipt)?;
        let authority = self.capture_source_authority(receipt, intent.source_pid, &before)?;
        let proof =
            CaptureAbortSourceQualification::issue(cleanup, intent.clone(), &before, &authority)?;
        budget.check()?;
        self.verify_database_identity()?;
        let after = self.record(receipt)?;
        if serde_json::to_vec(&before).ok() != serde_json::to_vec(&after).ok() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let current = self.capture_source_authority(receipt, intent.source_pid, &after)?;
        if !current.matches(&after, intent.source_pid) || current.running() != authority.running() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        proof.validate()?;
        Ok(proof)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture_resolution::{SourceAuthority, SourceFacts};

    fn fixture() -> (
        CaptureStagingCleanupReceipt,
        crate::capture_material::Intent,
        smolvm::config::VmRecord,
    ) {
        let mut record =
            smolvm::config::VmRecord::new("source".into(), 1, 512, vec![], vec![], false);
        record.forkable = true;
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record.entrypoint = vec!["/bin/true".into()];
        record.cmd.clear();
        record.env.clear();
        record.workdir = Some("/".into());
        record.user = None;
        record.state = smolvm::config::RecordState::Running;
        record.pid = Some(123);
        record.pid_start_time = Some(456);
        record.labels.insert("smolbox.owner".into(), "b".repeat(64));
        record
            .labels
            .insert("smolbox.incarnation".into(), "c".repeat(32));
        let mut previous = CreationReceipt {
            target_id: "local".into(),
            domain_generation: "a".repeat(32),
            name: record.name.clone(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: crate::identity::material_hash(&record).unwrap(),
            material: None,
        };
        previous.material = Some(crate::material::root_proof(&previous).unwrap());
        let request = crate::CaptureRequest {
            max_bytes: 1024,
            idle: true,
        };
        let intent =
            crate::material::capture_source_intent(&previous, "capture", request.clone(), &record)
                .unwrap();
        (
            CaptureStagingCleanupReceipt {
                schema: 1,
                previous,
                operation_id: "capture".into(),
                request,
                stage_sha256: "e".repeat(64),
            },
            intent,
            record,
        )
    }
    fn running_facts() -> SourceFacts {
        SourceFacts {
            owner: Some(true),
            runtime_pid: Some(123),
            original_alive: true,
            observed_birth: Some(456),
            excluded: false,
        }
    }

    #[test]
    fn running_qualification_requires_opaque_owned_process_authority_and_unchanged_material() {
        let (cleanup, intent, record) = fixture();
        let authority =
            SourceAuthority::verify(&record, intent.source_pid, running_facts()).unwrap();
        let proof = CaptureAbortSourceQualification::issue(
            cleanup.clone(),
            intent.clone(),
            &record,
            &authority,
        )
        .unwrap();
        proof.validate().unwrap();
        assert!(proof.state == CaptureAbortSourceState::Running);
        for case in 0..4 {
            let mut changed = record.clone();
            match case {
                0 => changed.pid_start_time = Some(457),
                1 => changed.checkpoint_head = Some("d".repeat(32)),
                2 => changed.mem += 1,
                _ => changed.forkable = false,
            }
            assert!(CaptureAbortSourceQualification::issue(
                cleanup.clone(),
                intent.clone(),
                &changed,
                &authority
            )
            .is_err());
        }
        let mut inventory = running_facts();
        inventory.owner = None;
        assert!(SourceAuthority::verify(&record, intent.source_pid, inventory).is_err());
    }

    #[test]
    fn qualification_is_a_distinct_proof_domain_without_artifact_or_material_success() {
        let (cleanup, intent, record) = fixture();
        let authority =
            SourceAuthority::verify(&record, intent.source_pid, running_facts()).unwrap();
        let proof =
            CaptureAbortSourceQualification::issue(cleanup, intent, &record, &authority).unwrap();
        let value = serde_json::to_value(&proof).unwrap();
        assert!(serde_json::from_value::<crate::CaptureTransition>(value.clone()).is_err());
        assert!(
            serde_json::from_value::<crate::CaptureResolutionTransition>(value.clone()).is_err()
        );
        let mut changed = proof.clone();
        changed.intent.source_pid.1 += 1;
        assert!(changed.validate().is_err());
        let mut changed = proof.clone();
        changed.state = CaptureAbortSourceState::Stopped;
        assert!(changed.validate().is_err());
        let mut changed = proof;
        changed.record_sha256 = "f".repeat(64);
        changed.proof_sha256 = changed.digest().unwrap();
        assert!(changed.validate().is_err());
        let mut changed = value;
        changed["artifact"] = serde_json::json!({});
        assert!(serde_json::from_value::<CaptureAbortSourceQualification>(changed).is_err());
    }
    #[test]
    fn shared_wire_fixtures_validate_with_actual_engine_proof_domain() {
        let proofs: Vec<CaptureAbortSourceQualification> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/capture-abort-sources-v1.json"
        ))
        .unwrap();
        for proof in proofs {
            proof.validate().unwrap();
        }
    }
}
