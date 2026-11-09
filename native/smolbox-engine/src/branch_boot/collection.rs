//! A cleanup fence preserves the original lifecycle and blocks readiness/restart.
use super::*;
use crate::{PartialBranchCollection, PartialBranchCollectionRequest};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CollectionRecord {
    request: PartialBranchCollectionRequest,
    boot: crate::epoch::BootIntent,
    child: crate::OwnerIdentity,
    phase_sha256: String,
    proof: Option<PartialBranchCollection>,
}
pub(super) fn phase_matches(phase: &Phase, enrollment: &crate::epoch::BootEnrollment) -> bool {
    phase_matches_return(phase, enrollment.intent(), enrollment.child())
}
fn phase_matches_return(
    phase: &Phase,
    original: &crate::epoch::BootIntent,
    identity: crate::OwnerIdentity,
) -> bool {
    match phase {
        Phase::Entered { boot } => boot == original,
        Phase::Returned {
            boot,
            child: Some(child),
            ..
        }
        | Phase::Initialized { boot, child, .. } => boot == original && *child == identity,
        Phase::Initializing { intent }
        | Phase::IdentityReady { intent, .. }
        | Phase::HeldReady { intent, .. } => intent.boot == *original && intent.child == identity,
        Phase::Releasing { intent } | Phase::Released { intent } => {
            intent.boot == *original && intent.child == identity
        }
        _ => false,
    }
}
impl CollectionRecord {
    pub(super) fn validate(&self, plan: &Plan, phase: &Phase) -> Result<()> {
        self.request.validate()?;
        plan.publication
            .change
            .child_origin
            .intent
            .matches_creation(&self.request.creation)?;
        if !self.boot.matches(
            &plan.publication.child().name,
            &plan.publication.change.child_origin.intent.epoch,
        ) || self.child.pid <= 0
            || self.child.birth == 0
            || self.child.uid != unsafe { libc::geteuid() }
            || self.phase_sha256 != crate::material::hash(phase)?
            || !phase_matches_return(phase, &self.boot, self.child)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(proof) = &self.proof {
            self.request.matches(proof)?;
            if proof.publication_sha256 != crate::material::hash(&plan.publication)?
                || proof.boot_sha256 != crate::material::hash(&self.boot)?
                || proof.collection_sha256 != crate::material::hash(&(&self.boot, self.child))?
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
    fn matches(
        &self,
        request: &PartialBranchCollectionRequest,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<()> {
        if self.request != *request
            || self.boot != *enrollment.intent()
            || self.child != enrollment.child()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Lifecycle {
    /// Inspect the same original plan/enrollment/request without registering a
    /// cleanup fence, synchronizing a proof or changing lifecycle phase.
    pub(crate) fn inspect_partial_collection(
        &self,
        plan: &Plan,
        request: &PartialBranchCollectionRequest,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<bool> {
        request.validate()?;
        plan.verify()?;
        plan.publication
            .change
            .child_origin
            .intent
            .matches_creation(&request.creation)?;
        let (journal, _) = self.read()?;
        if journal.plan != *plan || !phase_matches(&journal.phase, enrollment) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(record) = &journal.collection {
            record.matches(request, enrollment)?;
        }
        Ok(journal.collection.is_some())
    }
    pub(crate) fn partial_collection_started(&self) -> Result<bool> {
        Ok(self.read()?.0.collection.is_some())
    }
    pub(crate) fn begin_partial_collection(
        &self,
        plan: &Plan,
        request: &PartialBranchCollectionRequest,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<()> {
        request.validate()?;
        plan.verify()?;
        let (mut journal, version) = self.read()?;
        if journal.plan != *plan || !phase_matches(&journal.phase, enrollment) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(record) = &journal.collection {
            record.matches(request, enrollment)?;
        } else {
            journal.collection = Some(CollectionRecord {
                request: request.clone(),
                boot: enrollment.intent().clone(),
                child: enrollment.child(),
                phase_sha256: crate::material::hash(&journal.phase)?,
                proof: None,
            });
            self.write(&journal, Some(version))
                .map_err(|e| Error::uncertain(e.code))?;
        }
        self.synchronize_collection(&self.read()?.1)
    }
    pub(crate) fn partial_collection(
        &self,
        plan: &Plan,
        request: &PartialBranchCollectionRequest,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<Option<PartialBranchCollection>> {
        request.validate()?;
        let (journal, version) = self.read()?;
        if journal.plan != *plan || !phase_matches(&journal.phase, enrollment) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let Some(record) = journal.collection else {
            return Ok(None);
        };
        record.matches(request, enrollment)?;
        self.synchronize_collection(&version)?;
        Ok(record.proof)
    }
    pub(crate) fn finish_partial_collection(
        &self,
        plan: &Plan,
        request: &PartialBranchCollectionRequest,
        collected: &crate::epoch::BootCollection,
    ) -> Result<PartialBranchCollection> {
        let (mut journal, version) = self.read()?;
        if journal.plan != *plan {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let record = journal
            .collection
            .as_mut()
            .ok_or(Error::before(ErrorCode::State))?;
        if record.request != *request
            || record.boot != *collected.intent()
            || record.child != collected.child()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let proof = PartialBranchCollection::issue(request, &plan.publication, collected)?;
        if let Some(previous) = &record.proof {
            if previous != &proof {
                return Err(Error::before(ErrorCode::Ownership));
            }
        } else {
            record.proof = Some(proof.clone());
            self.write(&journal, Some(version))
                .map_err(|e| Error::uncertain(e.code))?;
        }
        self.synchronize_collection(&self.read()?.1)
            .map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
    fn synchronize_collection(
        &self,
        version: &crate::checkpoint_materialize::FileVersion,
    ) -> Result<()> {
        if self.read()?.1 != *version {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(self.directory.join(FILE_NAME))
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if crate::checkpoint_materialize::FileVersion::of(
            &file.metadata().map_err(|_| Error::before(ErrorCode::Io))?,
        ) != *version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        file.sync_all().map_err(|_| Error::before(ErrorCode::Io))?;
        OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&self.directory)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if self.read()?.1 != *version {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(plan: &Plan) -> PartialBranchCollectionRequest {
        let intent = &plan.publication.change.child_origin.intent;
        let mut request = PartialBranchCollectionRequest {
            creation: crate::BranchCreateRequest {
                source: intent.source.clone(),
                child: intent.child.clone(),
                approval: intent.approval.clone(),
                initial_release: if intent.child.hold {
                    None
                } else {
                    Some(crate::BranchReleaseRequest {
                        operation_id: "initial-release-model".into(),
                        request_sha256: "d".repeat(64),
                    })
                },
            },
            operation_id: "collect-partial-model".into(),
            request_sha256: String::new(),
            quiesced: true,
        };
        request.request_sha256 = request.digest().unwrap();
        request
    }

    #[test]
    fn eligibility_inspection_never_registers_collection_or_changes_phase_rows_or_charges() {
        // Synthetic enrollment beyond the OS PID range; no SDK or VM operation.
        let model = crate::branch_boot::tests::identity_model(true);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        let request = request(&model.plan);
        let path = model.plan.child.path.join(FILE_NAME);
        let before = std::fs::read(&path).unwrap();
        let counts = model.engine.jobs.counts();
        let rows = || {
            serde_json::to_vec(&[
                model
                    .engine
                    .db
                    .get_vm(&request.creation.source.name)
                    .unwrap(),
                model
                    .engine
                    .db
                    .get_vm(&request.creation.child.name)
                    .unwrap(),
            ])
            .unwrap()
        };
        let original = rows();
        assert!(!lifecycle
            .inspect_partial_collection(&model.plan, &request, &model.enrollment)
            .unwrap());
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert_eq!(rows(), original);
        assert_eq!(model.engine.jobs.counts(), counts);
        assert!(!lifecycle.partial_collection_started().unwrap());
        assert!(model.engine.owned_managers.lock().unwrap().is_empty());

        lifecycle
            .begin_partial_collection(&model.plan, &request, &model.enrollment)
            .unwrap();
        let saved = std::fs::read(&path).unwrap();
        assert!(lifecycle
            .inspect_partial_collection(&model.plan, &request, &model.enrollment)
            .unwrap());
        let mut crossed = request.clone();
        crossed.operation_id = "another-collection".into();
        crossed.request_sha256 = crossed.digest().unwrap();
        assert!(lifecycle
            .inspect_partial_collection(&model.plan, &crossed, &model.enrollment)
            .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), saved);
        assert_eq!(rows(), original);
        assert_eq!(model.engine.jobs.counts(), counts);
    }

    #[test]
    fn eligibility_refuses_unentered_phase_without_saving_a_collection() {
        let model = crate::branch_boot::tests::identity_model(true);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        let request = request(&model.plan);
        let (_, version) = lifecycle.read().unwrap();
        lifecycle
            .write(
                &Journal {
                    plan: model.plan.clone(),
                    phase: Phase::Prepared,
                    collection: None,
                },
                Some(version),
            )
            .unwrap();
        let path = model.plan.child.path.join(FILE_NAME);
        let before = std::fs::read(&path).unwrap();
        assert!(lifecycle
            .inspect_partial_collection(&model.plan, &request, &model.enrollment)
            .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert!(!lifecycle.partial_collection_started().unwrap());
    }

    #[test]
    fn protected_collection_preserves_phase_source_rows_and_allowances_but_blocks_ready_and_restart(
    ) {
        // Inert actor/file model, with a synthetic PID beyond the OS PID range.
        // No SDK start/stop, owner loss or persistence interruption is performed.
        let model = crate::branch_boot::tests::identity_model(true);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        let request = request(&model.plan);
        let (before, _) = lifecycle.read().unwrap();
        let phase = crate::material::hash(&before.phase).unwrap();
        let rows = [
            model
                .engine
                .db
                .get_vm(&request.creation.source.name)
                .unwrap(),
            model
                .engine
                .db
                .get_vm(&request.creation.child.name)
                .unwrap(),
        ];
        let mut original = model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::branch_source())
            .unwrap();
        original.promote_branch_preparation().unwrap();
        original.promote_branch_backing(1024 * 1024 * 1024).unwrap();
        let charged = model.engine.jobs.counts();
        let control = model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())
            .unwrap();
        let observer = model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        let counts = model.engine.jobs.counts();
        assert_eq!(counts.descriptors, crate::jobs::JOB_DESCRIPTORS);
        assert_eq!(counts.work_metadata, crate::jobs::JOB_METADATA_BYTES);
        assert!(model
            .engine
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())
            .is_err());
        lifecycle
            .begin_partial_collection(&model.plan, &request, &model.enrollment)
            .unwrap();
        assert!(lifecycle.partial_collection_started().unwrap());
        assert!(lifecycle
            .partial_collection(&model.plan, &request, &model.enrollment)
            .unwrap()
            .is_none());
        assert_eq!(
            crate::material::hash(&lifecycle.read().unwrap().0.phase).unwrap(),
            phase
        );
        assert!(lifecycle
            .finish_record(&model.plan, &model.enrollment, &model.identity_sha256)
            .is_err());
        assert!(lifecycle
            .require_regular_restart(model.plan.publication.child())
            .is_err());
        assert!(lifecycle.uncertain(model.plan.publication.child()).unwrap());
        assert!(lifecycle.prepare(&model.plan).is_err());
        let collected = model
            .actors
            .collect_enrolled(&request.creation.child.name, &model.enrollment)
            .unwrap();
        let proof = lifecycle
            .finish_partial_collection(&model.plan, &request, &collected)
            .unwrap();
        request.matches(&proof).unwrap();
        assert_eq!(
            lifecycle
                .partial_collection(&model.plan, &request, &model.enrollment)
                .unwrap(),
            Some(proof.clone())
        );
        assert!(
            lifecycle
                .finish_partial_collection(&model.plan, &request, &collected)
                .unwrap()
                == proof
        );
        assert_eq!(model.engine.jobs.counts(), counts);
        let after = [
            model
                .engine
                .db
                .get_vm(&request.creation.source.name)
                .unwrap(),
            model
                .engine
                .db
                .get_vm(&request.creation.child.name)
                .unwrap(),
        ];
        assert_eq!(
            crate::material::hash(&rows).unwrap(),
            crate::material::hash(&after).unwrap()
        );
        assert!(
            model.plan.child.path.exists()
                && model.plan.source.path.exists()
                && model.plan.snapshot.path.exists()
        );
        assert!(model.engine.owned_managers.lock().unwrap().is_empty());
        drop((control, observer));
        assert_eq!(model.engine.jobs.counts(), charged);
        drop(original);
    }

    #[test]
    fn original_entered_and_failed_return_can_collect_without_inventing_initialized_identity() {
        let model = crate::branch_boot::tests::identity_model(true);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        let request = request(&model.plan);
        for phase in [
            Phase::Entered {
                boot: model.enrollment.intent().clone(),
            },
            Phase::Returned {
                boot: model.enrollment.intent().clone(),
                child: Some(model.enrollment.child()),
                sdk_succeeded: false,
            },
        ] {
            let (_, version) = lifecycle.read().unwrap();
            lifecycle
                .write(
                    &Journal {
                        plan: model.plan.clone(),
                        phase,
                        collection: None,
                    },
                    Some(version),
                )
                .unwrap();
            lifecycle
                .begin_partial_collection(&model.plan, &request, &model.enrollment)
                .unwrap();
            assert!(lifecycle
                .finish_record(&model.plan, &model.enrollment, &model.identity_sha256)
                .is_err());
        }
        let (_, version) = lifecycle.read().unwrap();
        lifecycle
            .write(
                &Journal {
                    plan: model.plan.clone(),
                    phase: Phase::Prepared,
                    collection: None,
                },
                Some(version),
            )
            .unwrap();
        assert!(lifecycle
            .begin_partial_collection(&model.plan, &request, &model.enrollment)
            .is_err());
        assert!(!lifecycle.partial_collection_started().unwrap());
    }

    #[test]
    fn crossed_enrollment_creation_request_and_proof_never_replace_original_collection() {
        let model = crate::branch_boot::tests::identity_model(true);
        let other = crate::branch_boot::tests::identity_model(true);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        let request = request(&model.plan);
        lifecycle
            .begin_partial_collection(&model.plan, &request, &model.enrollment)
            .unwrap();
        let path = model.plan.child.path.join(FILE_NAME);
        let bytes = std::fs::read(&path).unwrap();
        assert!(lifecycle
            .begin_partial_collection(&model.plan, &request, &other.enrollment)
            .is_err());
        let foreign = other
            .actors
            .collect_enrolled(&other.record.name, &other.enrollment)
            .unwrap();
        assert!(lifecycle
            .finish_partial_collection(&model.plan, &request, &foreign)
            .is_err());
        let mut changed = request.clone();
        changed.operation_id = "different-collection".into();
        changed.request_sha256 = changed.digest().unwrap();
        assert!(lifecycle
            .begin_partial_collection(&model.plan, &changed, &model.enrollment)
            .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        let own = model
            .actors
            .collect_enrolled(&model.record.name, &model.enrollment)
            .unwrap();
        let proof = lifecycle
            .finish_partial_collection(&model.plan, &request, &own)
            .unwrap();
        assert!(changed.matches(&proof).is_err());
        let encoded = serde_json::to_value(&proof).unwrap();
        for key in [
            "creation_sha256",
            "publication_sha256",
            "request_sha256",
            "boot_sha256",
            "collection_sha256",
        ] {
            let mut bad = encoded.clone();
            bad[key] = serde_json::Value::String("0".repeat(64));
            assert!(serde_json::from_value::<PartialBranchCollection>(bad)
                .unwrap()
                .validate()
                .is_err());
        }
    }

    #[test]
    fn old_lifecycle_bytes_roundtrip_without_new_defaults_and_cleanup_grants_are_strict() {
        let model = crate::branch_boot::tests::identity_model(true);
        let path = model.plan.child.path.join(FILE_NAME);
        let bytes = std::fs::read(&path).unwrap();
        let journal: Journal = serde_json::from_slice(&bytes).unwrap();
        assert!(journal.collection.is_none());
        assert_eq!(serde_json::to_vec(&journal).unwrap(), bytes);
        let request = request(&model.plan);
        for operation in [request.creation.child.operation_id.clone(), "".into()] {
            let mut bad = request.clone();
            bad.operation_id = operation;
            bad.request_sha256 = bad.digest().unwrap();
            assert!(bad.validate().is_err());
        }
        let mut bad = request.clone();
        bad.quiesced = false;
        bad.request_sha256 = bad.digest().unwrap();
        assert!(bad.validate().is_err());
        let mut encoded = serde_json::to_value(&request).unwrap();
        encoded["pid"] = 123.into();
        assert!(serde_json::from_value::<PartialBranchCollectionRequest>(encoded).is_err());
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        lifecycle
            .begin_partial_collection(&model.plan, &request, &model.enrollment)
            .unwrap();
        let mut record: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        record["collection"]["phase_sha256"] = "0".repeat(64).into();
        std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
        let corrupted = std::fs::read(&path).unwrap();
        assert!(lifecycle.partial_collection_started().is_err());
        assert!(lifecycle
            .begin_partial_collection(&model.plan, &request, &model.enrollment)
            .is_err());
        assert_eq!(std::fs::read(path).unwrap(), corrupted);
    }
}
