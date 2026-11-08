//! Explicit descriptor-relative cleanup of an originally owned child directory.
//! No SDK deletion retry, guest action, volume detach or backing retirement.
use super::*;
use std::os::fd::AsRawFd;

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Stage {
    Cleaning,
    Cleaned,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Cleanup {
    schema: u8,
    intent: Intent,
    continuation: Option<ContinuationRequest>,
    request: ContinuationRequest,
    parent: (u64, u64),
    stage: Stage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    resolution: Option<BranchDeletionResolution>,
}
fn ledger(main: &Journal) -> Journal {
    Journal {
        domain: main.domain.clone(),
        path: main.path.with_extension("residual.json"),
    }
}
impl ProtectedRecord for Cleanup {
    fn validate_for(&self, journal: &Journal, _: u64) -> Result<()> {
        self.intent.validate()?;
        self.request.validate()?;
        if let Some(request) = &self.continuation {
            request.validate()?;
        }
        let main = Journal::new(journal.domain.clone(), self.intent.receipt())?;
        if self.schema != 1
            || self.parent.0 == 0
            || self.parent.1 == 0
            || ledger(&main).path != journal.path
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match (self.stage, &self.resolution) {
            (Stage::Cleaning, None) => Ok(()),
            (Stage::Cleaned, Some(proof)) => {
                proof.validate()?;
                if proof.child != *self.intent.receipt()
                    || proof.deletion_sha256
                        != deletion_digest(&self.intent, self.continuation.as_ref())?
                    || !proof
                        .matches_request(&self.request.operation_id, &self.request.request_sha256)
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                Ok(())
            }
            _ => Err(Error::before(ErrorCode::Ownership)),
        }
    }
}
fn recorded(file: &Journal) -> Result<Option<(Cleanup, Version)>> {
    match std::fs::symlink_metadata(&file.path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(Error::before(ErrorCode::Ownership)),
        Ok(_) => file.read_record().map(Some),
    }
}
fn row_absent(
    intent: &Intent,
    authority: &ResolutionAuthority<'_>,
    budget: &ReadBudget,
) -> Result<()> {
    if !crate::sdk_compat::observe_absence_budget(
        authority.database,
        authority.identity,
        &intent.receipt().name,
        budget,
        || Ok(true),
    )? {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
fn identity(root: &crate::export_source::Root) -> Result<(u64, u64)> {
    root.verify()?;
    let info = root
        .descriptor()
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    Ok((info.dev(), info.ino()))
}
fn child_root(intent: &Intent) -> Result<crate::export_source::Root> {
    let root = crate::export_source::Root::open(&intent.plan.child.path)?;
    if identity(&root)? != (intent.plan.child.device, intent.plan.child.inode) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    crate::sdk_compat::branch_deletion_cache(&intent.plan.child.path)?;
    Ok(root)
}
fn absent_path(path: &std::path::Path) -> bool {
    matches!(std::fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound)
}
struct Removal<'a> {
    main: &'a Journal,
    file: Journal,
    authority: ResolutionAuthority<'a>,
    budget: &'a ReadBudget,
    max_entries: usize,
}
impl Removal<'_> {
    fn run(
        &self,
        state: &mut Retained,
        request: &ContinuationRequest,
    ) -> Result<BranchDeletionResolution> {
        self.budget.check()?;
        request.validate()?;
        let intent = state.intent.clone();
        let (main, _) = self.main.read()?;
        if main.intent != intent
            || main.continuation != state.continuation
            || state.cleanup.as_ref().is_some_and(|old| old != request)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let saved = recorded(&self.file)?;
        if let Some((saved, version)) = &saved {
            if saved.intent != intent
                || saved.continuation != main.continuation
                || saved.request != *request
            {
                return Err(Error::before(ErrorCode::Conflict));
            }
            if let Some(proof) = &main.resolution {
                if !proof.matches_request(&request.operation_id, &request.request_sha256) {
                    return Err(Error::before(ErrorCode::Conflict));
                }
                if saved
                    .resolution
                    .as_ref()
                    .is_some_and(|prior| prior != proof)
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let mut complete = saved.clone();
                complete.stage = Stage::Cleaned;
                complete.resolution = Some(proof.clone());
                if saved.stage != Stage::Cleaned {
                    self.budget.check()?;
                    self.file.write_record(&complete, Some(version.clone()))?;
                }
                state.cleanup = Some(request.clone());
                state.completion = Some(Completion::Resolved(Box::new(proof.clone())));
                return Ok(proof.clone());
            }
            if saved.stage == Stage::Cleaned {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        if !matches!(
            main.phase,
            Phase::Collecting | Phase::Collected | Phase::Finishing | Phase::Deleting
        ) || state.leases.is_none()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let collection = self
            .authority
            .epoch
            .collect_enrolled(&intent.receipt().name, self.authority.enrollment)?;
        intent.collected(&collection)?;
        let parent_path = intent
            .plan
            .child
            .path
            .parent()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let parent = crate::export_source::Root::open(parent_path)?;
        let leases = state.leases.as_mut().unwrap();
        if leases.source.is_none() {
            leases.source = Some(crate::sdk_compat::source_lease(
                parent_path,
                &intent.receipt().name,
            )?);
        }
        row_absent(&intent, &self.authority, self.budget)?;
        let (entry, version) = if let Some((entry, version)) = saved {
            if entry.parent != identity(&parent)? {
                return Err(Error::before(ErrorCode::Ownership));
            }
            (entry, version)
        } else {
            child_root(&intent)?; // Missing/replaced roots cannot create removal authority.
            let entry = Cleanup {
                schema: 1,
                intent: intent.clone(),
                continuation: main.continuation,
                request: request.clone(),
                parent: identity(&parent)?,
                stage: Stage::Cleaning,
                resolution: None,
            };
            state.cleanup = Some(request.clone());
            self.budget.check()?;
            self.file
                .write_record(&entry, None)
                .map_err(|e| Error::uncertain(e.code))?;
            let version = self.file.read_record::<Cleanup>()?.1;
            (entry, version)
        };
        state.cleanup = Some(request.clone());
        let result = (|| -> Result<BranchDeletionResolution> {
            if !absent_path(&intent.plan.child.path) {
                let root = child_root(&intent)?;
                crate::volumes::remove_owned_tree(
                    root.descriptor(),
                    self.budget,
                    self.max_entries,
                )?;
                root.descriptor()
                    .sync_all()
                    .map_err(|_| Error::before(ErrorCode::Io))?;
                root.verify()?;
                parent.verify()?;
                if identity(&child_root(&intent)?)? != identity(&root)? {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                row_absent(&intent, &self.authority, self.budget)?;
                let name =
                    std::ffi::CString::new(smolvm::agent::vm_dir_hash(&intent.receipt().name))
                        .map_err(|_| Error::before(ErrorCode::Ownership))?;
                self.budget.check()?;
                if unsafe {
                    libc::unlinkat(
                        parent.descriptor().as_raw_fd(),
                        name.as_ptr(),
                        libc::AT_REMOVEDIR,
                    )
                } != 0
                {
                    return Err(Error::before(ErrorCode::Io));
                }
            }
            parent
                .descriptor()
                .sync_all()
                .map_err(|_| Error::before(ErrorCode::Io))?;
            parent.verify()?;
            let collection = self
                .authority
                .epoch
                .collect_enrolled(&intent.receipt().name, self.authority.enrollment)?;
            let absent = absence(
                &intent,
                &collection,
                self.authority.database,
                self.authority.identity,
                self.budget,
            )?;
            let proof = self.main.resolve_absent(
                &intent,
                &request.operation_id,
                &request.request_sha256,
                &absent,
                self.budget,
            )?;
            let mut complete = entry;
            complete.stage = Stage::Cleaned;
            complete.resolution = Some(proof.clone());
            self.file.write_record(&complete, Some(version))?;
            state.completion = Some(Completion::Resolved(Box::new(proof.clone())));
            self.budget.check()?;
            Ok(proof)
        })();
        result.map_err(|e| Error::uncertain(e.code))
    }
}
impl Engine {
    /// Remove only an original collected child's residual directory after SDK
    /// row/reservation absence. Requires explicit fencing; never retries SDK work.
    pub fn cleanup_held_branch_deletion(
        &self,
        child: &CreationReceipt,
        operation_id: &str,
        request_sha256: &str,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionResolution> {
        let request = ContinuationRequest {
            operation_id: operation_id.into(),
            request_sha256: request_sha256.into(),
        };
        request.validate()?;
        if !quiesced {
            return Err(Error::before(ErrorCode::Validation));
        }
        budget.check()?;
        child.validate(self.binding())?;
        // Traversal retains the original 24-descriptor deletion-work lease.
        // Four extra control descriptors leave one four-descriptor observer.
        let control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self.retained_branch_context(child)?;
        let main = Journal::new(self.domain.clone(), child)?;
        let file = ledger(&main);
        let mut guard = context
            .deletion
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let state = guard.as_mut().ok_or(Error::before(ErrorCode::State))?;
        state.check_returned(child)?;
        if state.cleanup.as_ref().is_some_and(|old| old != &request) {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let saved = recorded(&file)?;
        let (primary, _) = main.read()?;
        let known = saved
            .as_ref()
            .is_some_and(|(record, _)| record.request == request && primary.resolution.is_some());
        let epoch = self.collection_epoch()?.clone();
        if !known {
            self.verify_database_identity()?;
            if state.intent.plan != context.plan
                || state.intent.boot != *context.enrollment.intent()
                || state.intent.child != context.enrollment.child()
                || state.intent.identity_sha256 != context.identity_sha256
                || !epoch.bound_to(self.binding())
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let proof = epoch.collect_enrolled(&child.name, &context.enrollment)?;
            state.intent.collected(&proof)?;
            continuation::manager_is_original(&context)?;
            context
                .manager
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?
                .mark_stopped();
        }
        let active = Arc::new(());
        state.worker = Arc::downgrade(&active);
        drop(guard);
        let retained = context.clone();
        let database = self.binding().database.clone();
        let identity = self.database_identity;
        let work_budget = budget.clone();
        let proof = crate::oci_start::observe_owned(
            self.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _active = active;
                let _control = control;
                let mut state = retained
                    .deletion
                    .lock()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                let state = state.as_mut().ok_or(Error::uncertain(ErrorCode::State))?;
                Removal {
                    main: &main,
                    file,
                    authority: ResolutionAuthority {
                        epoch: &epoch,
                        enrollment: &retained.enrollment,
                        database: &database,
                        identity,
                    },
                    budget: &work_budget,
                    max_entries: crate::VOLUME_DELETE_ENTRIES,
                }
                .run(state, &request)
            },
        )
        .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        let main = Journal::new(self.domain.clone(), child)?;
        if !self.known_branch_deletion(&context, &main, child)? {
            return Err(Error::uncertain(ErrorCode::State));
        }
        Ok(proof)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch_boot::tests::IdentityModel;
    use crate::branch_delete::tests::{authority, budget, fixture, retained};
    use std::os::unix::fs::PermissionsExt;

    fn request() -> ContinuationRequest {
        ContinuationRequest {
            operation_id: "cleanup-owned-child".into(),
            request_sha256: "d".repeat(64),
        }
    }
    fn entered(main: &Journal, model: &IdentityModel, intent: &Intent) {
        main.enter(intent).unwrap();
        let collected = model
            .actors
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        main.collected(intent, &collected).unwrap();
        main.advance(intent, Phase::Collected, Phase::Deleting)
            .unwrap();
    }
    fn removal<'a>(
        main: &'a Journal,
        model: &'a IdentityModel,
        budget: &'a ReadBudget,
        maximum: usize,
    ) -> Removal<'a> {
        Removal {
            main,
            file: ledger(main),
            authority: authority(model, &model.actors),
            budget,
            max_entries: maximum,
        }
    }
    #[test]
    fn cleanup_requires_fencing_and_original_context_without_creating_a_removal_intent() {
        let (model, _, intent, main) = fixture();
        let before = model.engine.jobs.counts();
        for (quiesced, id, hash) in [
            (false, "cleanup", "d".repeat(64)),
            (true, "../invalid", "d".repeat(64)),
            (true, "cleanup", "invalid".into()),
            (true, "cleanup", "d".repeat(64)),
        ] {
            let error = model
                .engine
                .cleanup_held_branch_deletion(intent.receipt(), id, &hash, quiesced, &budget())
                .unwrap_err();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(model.engine.jobs.counts(), before);
        }
        assert!(!ledger(&main).path.exists() && model.plan.child.path.exists());
    }
    #[test]
    fn row_or_reservation_presence_blocks_cleanup_before_any_unlink() {
        let (model, _, intent, main) = fixture();
        let mut state = retained(&model, &intent);
        entered(&main, &model, &intent);
        let work = budget();
        let remove = removal(&main, &model, &work, crate::VOLUME_DELETE_ENTRIES);
        assert!(remove.run(&mut state, &request()).is_err());
        assert!(!remove.file.path.exists());
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        let writer = rusqlite::Connection::open(&model.engine.binding().database).unwrap();
        writer
            .execute(
                "INSERT INTO vm_create_reservations VALUES (?1,'pending',-1,0)",
                [&intent.receipt().name],
            )
            .unwrap();
        assert!(remove.run(&mut state, &request()).is_err());
        assert!(!remove.file.path.exists());
        assert!(model
            .plan
            .child
            .path
            .join("smolbox.material-v2.json")
            .exists());
        assert!(state.leases.is_some() && state.cleanup.is_none());
    }
    #[test]
    fn residual_removal_preserves_sibling_links_backing_and_control_headroom() {
        let (model, _, intent, main) = fixture();
        let pool = &model.engine.jobs;
        let mut creation = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
        creation.promote_branch_preparation().unwrap();
        creation.promote_branch_backing(7 << 30).unwrap();
        let backing = creation.handoff_branch().unwrap();
        drop(creation);
        let mut state = retained(&model, &intent);
        entered(&main, &model, &intent);
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        // Private result model: SDK already removed some original marker files.
        std::fs::remove_file(model.plan.child.path.join("smolbox.material-v2.json")).unwrap();
        std::fs::remove_file(model.plan.child.path.join("smolbox.incarnation")).unwrap();
        let external = tempfile::tempdir().unwrap();
        let marker = external.path().join("source-cache");
        std::fs::write(&marker, b"retained").unwrap();
        std::os::unix::fs::symlink(external.path(), model.plan.child.path.join("pack")).unwrap();
        let nested = model.plan.child.path.join("runtime");
        std::fs::create_dir(&nested).unwrap();
        std::fs::write(nested.join("owned-log"), b"private runtime output").unwrap();
        pool.quarantine(); // Counter model only; no live persistence interruption.
        let control = pool
            .acquire(crate::jobs::Demand::material_resolution())
            .unwrap();
        let observer = pool
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        let work = budget();
        let remove = removal(&main, &model, &work, crate::VOLUME_DELETE_ENTRIES);
        let proof = remove.run(&mut state, &request()).unwrap();
        proof.validate().unwrap();
        assert!(!model.plan.child.path.exists());
        assert_eq!(std::fs::read(&marker).unwrap(), b"retained");
        assert!(model.plan.source.path.exists() && model.plan.snapshot.path.exists());
        let original_inode = state
            .leases
            .as_ref()
            .unwrap()
            ._root
            .descriptor()
            .metadata()
            .unwrap()
            .ino();
        assert_eq!(original_inode, intent.plan.child.inode); // Descriptor prevents inode reuse until acknowledgement.
        assert_eq!(pool.counts().work, 1);
        state.retire_transient().unwrap(); // Cache acknowledgement model; no actual manager is constructed.
        assert_eq!(pool.counts().work, 0);
        assert_eq!(pool.counts().checkpoint_material, 7 << 30);
        assert_eq!(
            pool.counts().branch_metadata,
            2 * crate::jobs::BRANCH_BACKING_METADATA
        );
        assert!(!pool.available());
        let bytes = std::fs::read(&remove.file.path).unwrap();
        assert_eq!(remove.run(&mut state, &request()).unwrap(), proof);
        assert_eq!(std::fs::read(&remove.file.path).unwrap(), bytes);
        drop((control, observer, backing)); // Pure bookkeeping teardown, no disposal claim.
    }
    #[test]
    fn partial_removal_keeps_its_frozen_request_and_resumes_only_forward() {
        let (model, _, intent, main) = fixture();
        let mut state = retained(&model, &intent);
        entered(&main, &model, &intent);
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        std::fs::write(model.plan.child.path.join("extra-one"), b"one").unwrap();
        std::fs::write(model.plan.child.path.join("extra-two"), b"two").unwrap();
        let work = budget();
        let remove = removal(&main, &model, &work, 1);
        assert_eq!(
            remove.run(&mut state, &request()).unwrap_err().dispatch,
            crate::Dispatch::MayHaveDispatched
        );
        assert!(remove.file.read_record::<Cleanup>().unwrap().0.stage == Stage::Cleaning);
        assert!(state.leases.is_some() && state.completion.is_none());
        let mut other = request();
        other.request_sha256 = "e".repeat(64);
        assert!(remove.run(&mut state, &other).is_err());
        assert!(state
            .resolve(
                &main,
                intent.receipt(),
                &other.operation_id,
                &other.request_sha256,
                authority(&model, &model.actors),
                &work
            )
            .is_err());
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(
            removal(&main, &model, &cancelled, crate::VOLUME_DELETE_ENTRIES)
                .run(&mut state, &request())
                .is_err()
        );
        let proof = removal(&main, &model, &budget(), crate::VOLUME_DELETE_ENTRIES)
            .run(&mut state, &request())
            .unwrap();
        assert!(proof.matches_request(&request().operation_id, &request().request_sha256));
        assert!(!model.plan.child.path.exists() && state.leases.is_some());
    }
    #[test]
    fn only_recorded_partial_cleanup_can_finish_an_already_removed_directory() {
        for recorded_cleanup in [false, true] {
            let (model, _, intent, main) = fixture();
            let mut state = retained(&model, &intent);
            entered(&main, &model, &intent);
            model.engine.db.remove_vm(&intent.receipt().name).unwrap();
            let work = budget();
            if recorded_cleanup {
                assert!(removal(&main, &model, &work, 1)
                    .run(&mut state, &request())
                    .is_err());
            }
            // Private completed-unlink result model, without owner interruption.
            std::fs::remove_dir_all(&model.plan.child.path).unwrap();
            let remove = removal(&main, &model, &work, crate::VOLUME_DELETE_ENTRIES);
            let result = remove.run(&mut state, &request());
            if recorded_cleanup {
                result.unwrap().validate().unwrap();
                assert!(remove.file.read_record::<Cleanup>().unwrap().0.stage == Stage::Cleaned);
                assert!(state.completion.is_some());
            } else {
                assert!(result.is_err());
                assert!(!remove.file.path.exists() && state.completion.is_none());
            }
            assert!(state.leases.is_some());
        }
    }
    #[test]
    fn foreign_collection_and_replaced_directory_never_authorize_cleanup() {
        let (model, _, intent, main) = fixture();
        let mut state = retained(&model, &intent);
        entered(&main, &model, &intent);
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        let foreign = crate::branch_boot::tests::identity_model(true);
        let work = budget();
        assert!(Removal {
            main: &main,
            file: ledger(&main),
            authority: authority(&model, &foreign.actors),
            budget: &work,
            max_entries: crate::VOLUME_DELETE_ENTRIES
        }
        .run(&mut state, &request())
        .is_err());
        let saved = model.plan.child.path.with_extension("original-child-model");
        std::fs::rename(&model.plan.child.path, &saved).unwrap();
        std::fs::create_dir(&model.plan.child.path).unwrap();
        std::fs::set_permissions(
            &model.plan.child.path,
            std::fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        let marker = model.plan.child.path.join("foreign-marker");
        std::fs::write(&marker, b"foreign").unwrap();
        let remove = removal(&main, &model, &work, crate::VOLUME_DELETE_ENTRIES);
        assert!(remove.run(&mut state, &request()).is_err());
        assert!(!remove.file.path.exists());
        assert_eq!(std::fs::read(marker).unwrap(), b"foreign");
        assert!(saved.join("smolbox.material-v2.json").exists());
    }
    #[test]
    fn primary_completion_can_recover_only_the_matching_cleanup_audit_without_touching_new_material(
    ) {
        let (model, _, intent, main) = fixture();
        let mut state = retained(&model, &intent);
        entered(&main, &model, &intent);
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        let work = budget();
        let remove = removal(&main, &model, &work, 1);
        assert!(remove.run(&mut state, &request()).is_err());
        std::fs::remove_dir_all(&model.plan.child.path).unwrap(); // Private completed-removal result model.
        let proof = state
            .resolve(
                &main,
                intent.receipt(),
                &request().operation_id,
                &request().request_sha256,
                authority(&model, &model.actors),
                &work,
            )
            .unwrap();
        state.retire_transient().unwrap(); // Original primary proof already confirms absence.
        std::fs::create_dir(&model.plan.child.path).unwrap();
        let marker = model.plan.child.path.join("new-incarnation-model");
        std::fs::write(&marker, b"new").unwrap();
        assert_eq!(remove.run(&mut state, &request()).unwrap(), proof);
        assert_eq!(std::fs::read(marker).unwrap(), b"new");
        assert!(remove.file.read_record::<Cleanup>().unwrap().0.stage == Stage::Cleaned);
        let mut other = request();
        other.operation_id = "another-cleanup".into();
        assert!(remove.run(&mut state, &other).is_err());
    }
    #[test]
    fn cleanup_record_cannot_cross_the_primary_namespace_or_forget_parent_identity() {
        let (model, _, intent, main) = fixture();
        let mut state = retained(&model, &intent);
        entered(&main, &model, &intent);
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        let work = budget();
        let remove = removal(&main, &model, &work, 1);
        assert!(remove.run(&mut state, &request()).is_err());
        let (entry, version) = remove.file.read_record::<Cleanup>().unwrap();
        assert!(main.write_record(&entry, None).is_err());
        assert!(remove
            .file
            .write_record(&main.read().unwrap().0, Some(version.clone()))
            .is_err());
        let mut wrong = entry.clone();
        wrong.parent.1 += 1;
        remove.file.write_record(&wrong, Some(version)).unwrap();
        let bytes = std::fs::read(&remove.file.path).unwrap();
        assert!(remove.run(&mut state, &request()).is_err());
        assert_eq!(std::fs::read(&remove.file.path).unwrap(), bytes);
        let mut wrong = entry;
        wrong.stage = Stage::Cleaned;
        assert!(wrong.validate_for(&remove.file, 1).is_err());
    }
}
