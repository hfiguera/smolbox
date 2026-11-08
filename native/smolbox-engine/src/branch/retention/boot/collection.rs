//! Original pre-handoff manager only; protected cleanup fencing never creates a
//! completed branch or replays initialization/release.
use super::*;
use crate::{PartialBranchCollection, PartialBranchCollectionRequest};

pub(super) struct RetainedCollection {
    request: PartialBranchCollectionRequest,
    published: bool,
    disposal: Option<super::super::resolution::partial_disposal::PartialDisposalIntent>,
    disposal_published: bool,
    sdk_entry: Option<Arc<Mutex<super::super::resolution::partial_disposal::RetainedSdkEntry>>>,
    cleanup: Option<Arc<Mutex<super::super::resolution::partial_disposal::RetainedCleanup>>>,
}
impl RetainedCollection {
    fn prepare(
        slot: &mut Option<Self>,
        plan: &Plan,
        enrollment: &crate::epoch::BootEnrollment,
        request: &PartialBranchCollectionRequest,
    ) -> Result<()> {
        request.validate()?;
        plan.publication
            .change
            .child_origin
            .intent
            .matches_creation(&request.creation)?;
        if slot.as_ref().is_some_and(|prior| prior.request != *request) {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let lifecycle = Lifecycle::at(&plan.child.path);
        // A published cleanup fence cannot disappear and become fresh work.
        if slot.as_ref().is_some_and(|prior| prior.published) {
            lifecycle.partial_collection(plan, request, enrollment)?;
            if !lifecycle.partial_collection_started()? {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        if slot.is_none() {
            *slot = Some(RetainedCollection {
                request: request.clone(),
                published: false,
                disposal: None,
                disposal_published: false,
                sdk_entry: None,
                cleanup: None,
            });
        }
        lifecycle.begin_partial_collection(plan, request, enrollment)?;
        slot.as_mut().unwrap().published = true;
        Ok(())
    }
}
impl RetainedCollection {
    fn retain_disposal(
        &mut self,
        intent: super::super::resolution::partial_disposal::PartialDisposalIntent,
    ) -> Result<()> {
        if !self.published
            || self.request != intent.request.collection_request
            || self.disposal.as_ref().is_some_and(|saved| *saved != intent)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if self.disposal.is_none() {
            self.sdk_entry = Some(Arc::new(Mutex::new(
                super::super::resolution::partial_disposal::RetainedSdkEntry::new(&intent)?,
            )));
            self.disposal = Some(intent);
        }
        Ok(())
    }

    fn recover_disposal_publication(
        &mut self,
        domain: Arc<crate::domain::DomainGuard>,
        intent: &super::super::resolution::partial_disposal::PartialDisposalIntent,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        if !self.published
            || self.disposal_published
            || self.cleanup.is_some()
            || self.request != intent.request.collection_request
            || self.disposal.as_ref() != Some(intent)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let sdk = self
            .sdk_entry
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let sdk = sdk
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        sdk.unpublished_primary(domain, intent, budget)?;
        self.disposal_published = true;
        budget.check().map_err(|e| Error::uncertain(e.code))
    }
}
impl OwnedBoot {
    pub(in crate::branch::retention) fn collection_handle(&self) -> &CreationReceipt {
        self.plan.publication.child()
    }
    pub(in crate::branch::retention) fn inspect_partial_collection(
        &self,
        request: &PartialBranchCollectionRequest,
    ) -> Result<&str> {
        let enrollment = self
            .enrollment()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if self
            .collection
            .as_ref()
            .is_some_and(|prior| prior.request != *request)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let published = Lifecycle::at(&self.plan.child.path)
            .inspect_partial_collection(&self.plan, request, enrollment)?;
        if self
            .collection
            .as_ref()
            .is_some_and(|prior| prior.published)
            && !published
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(&self.plan.publication.change.platform)
    }
    pub(in crate::branch::retention) fn collection_started(&self) -> bool {
        self.collection.is_some()
    }
    pub(in crate::branch::retention) fn prepare_partial_collection(
        &mut self,
        request: &PartialBranchCollectionRequest,
    ) -> Result<()> {
        let enrollment = self
            .enrollment()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .clone();
        RetainedCollection::prepare(&mut self.collection, &self.plan, &enrollment, request)
    }
    pub(in crate::branch::retention) fn collect_partial_child(
        &self,
        epoch: &crate::epoch::ActorEpoch,
        budget: &ReadBudget,
    ) -> Result<PartialBranchCollection> {
        budget.check()?;
        let retained = self
            .collection
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?;
        if !retained.published {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let enrollment = self
            .enrollment()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let lifecycle = Lifecycle::at(&self.plan.child.path);
        // Revalidate and resynchronize the frozen grant before any SDK stop.
        lifecycle.begin_partial_collection(&self.plan, &retained.request, enrollment)?;
        let collection = crate::branch_owned::collect_manager(
            &self.plan,
            &self.manager,
            epoch,
            enrollment,
            budget,
        )?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        lifecycle
            .finish_partial_collection(&self.plan, &retained.request, &collection)
            .map_err(|e| Error::uncertain(e.code))
    }
}

impl OwnedBoot {
    pub(in crate::branch::retention) fn partial_disposal_intent(
        &self,
    ) -> Option<(
        &super::super::resolution::partial_disposal::PartialDisposalIntent,
        bool,
    )> {
        let state = self.collection.as_ref()?;
        Some((state.disposal.as_ref()?, state.disposal_published))
    }
    pub(in crate::branch::retention) fn retain_partial_disposal(
        &mut self,
        intent: super::super::resolution::partial_disposal::PartialDisposalIntent,
    ) -> Result<()> {
        let state = self
            .collection
            .as_mut()
            .ok_or(Error::before(ErrorCode::State))?;
        state.retain_disposal(intent)
    }

    pub(in crate::branch::retention) fn partial_disposal_published(&mut self) -> Result<()> {
        let state = self
            .collection
            .as_mut()
            .ok_or(Error::before(ErrorCode::State))?;
        if state.disposal.is_none() {
            return Err(Error::before(ErrorCode::State));
        }
        state.disposal_published = true;
        Ok(())
    }

    pub(in crate::branch::retention) fn recover_partial_disposal_publication(
        &mut self,
        domain: Arc<crate::domain::DomainGuard>,
        intent: &super::super::resolution::partial_disposal::PartialDisposalIntent,
        budget: &ReadBudget,
    ) -> Result<()> {
        self.collection
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .recover_disposal_publication(domain, intent, budget)
    }
    pub(in crate::branch::retention) fn partial_cleanup_started(&self) -> bool {
        self.collection
            .as_ref()
            .is_some_and(|state| state.cleanup.is_some())
    }
    pub(in crate::branch::retention) fn partial_cleanup_handoff(
        &self,
    ) -> Result<super::super::resolution::partial_disposal::archive::CleanupHandoff> {
        let state = self
            .collection
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        match state.cleanup.as_ref() {
            None => Ok(
                super::super::resolution::partial_disposal::archive::CleanupHandoff::NeverEnrolled,
            ),
            Some(cached) => {
                super::super::resolution::partial_disposal::RetainedCleanup::handoff(cached)
            }
        }
    }
    pub(in crate::branch::retention) fn partial_disposal_sdk_entry(
        &self,
    ) -> Option<Arc<Mutex<super::super::resolution::partial_disposal::RetainedSdkEntry>>> {
        self.collection.as_ref()?.sdk_entry.clone()
    }
    pub(in crate::branch::retention) fn retain_partial_cleanup(
        &mut self,
        request: &crate::PartialBranchDisposalCleanupRequest,
    ) -> Result<Arc<Mutex<super::super::resolution::partial_disposal::RetainedCleanup>>> {
        let state = self
            .collection
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !state.disposal_published
            || state
                .disposal
                .as_ref()
                .is_none_or(|intent| intent.request != request.disposal_request)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if state.cleanup.is_none() {
            state.cleanup = Some(Arc::new(Mutex::new(
                super::super::resolution::partial_disposal::RetainedCleanup::new(request)?,
            )));
        }
        let cached = state.cleanup.as_ref().unwrap();
        cached
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .matches(request)?;
        Ok(cached.clone())
    }
    pub(in crate::branch::retention) fn verify_partial_disposal_owner(
        &self,
        request: &crate::PartialBranchDisposalRequest,
        epoch: &crate::epoch::ActorEpoch,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        request.validate()?;
        let state = self
            .collection
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let enrollment = self
            .enrollment()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !state.published || state.request != request.collection_request {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let manager = self
            .manager
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.manager_paths.verify_collected(&self.plan, &manager)?;
        let collected = epoch.collect_enrolled(&self.plan.publication.child().name, enrollment)?;
        if PartialBranchCollection::issue(&state.request, &self.plan.publication, &collected)?
            != request.collection
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()
    }
    pub(in crate::branch::retention) fn qualify_partial_disposal(
        &self,
        request: &crate::PartialBranchDisposalRequest,
        epoch: &crate::epoch::ActorEpoch,
        budget: &ReadBudget,
        row: &smolvm::config::VmRecord,
    ) -> Result<Option<crate::BranchReleaseTransition>> {
        self.verify_partial_disposal_owner(request, epoch, budget)?;
        self.plan.verify()?;
        let enrollment = self
            .enrollment()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let pid = row.pid.zip(row.pid_start_time);
        if !matches!(
            row.state,
            smolvm::config::RecordState::Created
                | smolvm::config::RecordState::Running
                | smolvm::config::RecordState::Stopped
        ) || !(pid == Some((enrollment.child().pid, enrollment.child().birth))
            || (row.pid.is_none()
                && row.pid_start_time.is_none()
                && row.state != smolvm::config::RecordState::Running))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Lifecycle::at(&self.plan.child.path).partial_disposal_release(
            &self.plan,
            &request.collection_request,
            &request.collection,
            enrollment,
            row,
        )
    }
}

impl OwnedBoot {
    pub(in crate::branch::retention) fn partial_disposal_plan(&self) -> &Plan {
        &self.plan
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(plan: &Plan) -> PartialBranchCollectionRequest {
        let intent = &plan.publication.change.child_origin.intent;
        let mut request = PartialBranchCollectionRequest {
            creation: BranchCreateRequest {
                source: intent.source.clone(),
                child: intent.child.clone(),
                approval: intent.approval.clone(),
                initial_release: None,
            },
            operation_id: "collect-partial-model".into(),
            request_sha256: String::new(),
            quiesced: true,
        };
        request.request_sha256 = request.digest().unwrap();
        request
    }
    fn unpublished_disposal(
        model: &super::super::super::resolution::partial_disposal::tests::Model,
    ) -> RetainedCollection {
        let mut state = RetainedCollection {
            request: model.intent.request.collection_request.clone(),
            published: true,
            disposal: None,
            disposal_published: false,
            sdk_entry: None,
            cleanup: None,
        };
        state.retain_disposal(model.intent.clone()).unwrap();
        state
    }

    #[test]
    fn original_visible_primary_recovers_without_replacing_intent_cache_or_file() {
        for mode in 0..4 {
            let model = super::super::super::resolution::partial_disposal::tests::Model::new(mode);
            let mut retained = unpublished_disposal(&model);
            model.enter();
            let original = retained.sdk_entry.clone().unwrap();
            let path = model.publication_path();
            let bytes = std::fs::read(&path).unwrap();
            let budget = ReadBudget::new(
                std::time::Duration::from_secs(30),
                crate::Cancellation::default(),
            )
            .unwrap();
            retained
                .recover_disposal_publication(model.publication_domain(), &model.intent, &budget)
                .unwrap();
            assert!(retained.disposal_published);
            assert!(retained.disposal.as_ref() == Some(&model.intent));
            assert!(Arc::ptr_eq(&original, retained.sdk_entry.as_ref().unwrap()));
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            assert!(!path.with_extension("sdk-entry.json").exists());
            // A later ordinary retry selects published context; this helper
            // cannot reset or republish its already acknowledged cache.
            assert!(retained
                .recover_disposal_publication(model.publication_domain(), &model.intent, &budget)
                .is_err());
            assert!(retained.disposal_published);
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
    }

    #[test]
    fn missing_legacy_busy_or_used_sdk_grants_cannot_acknowledge_primary_publication() {
        for case in 0..5 {
            let model = super::super::super::resolution::partial_disposal::tests::Model::new(1);
            let mut retained = unpublished_disposal(&model);
            model.enter();
            let original = retained.sdk_entry.clone().unwrap();
            let budget = ReadBudget::new(
                std::time::Duration::from_secs(30),
                crate::Cancellation::default(),
            )
            .unwrap();
            match case {
                0 => retained.sdk_entry = None,
                1 => retained.published = false,
                2 => {
                    original
                        .lock()
                        .unwrap()
                        .prepare(model.publication_domain(), &model.intent, &budget)
                        .unwrap();
                }
                3 => {
                    let mut sdk = original.lock().unwrap();
                    sdk.prepare(model.publication_domain(), &model.intent, &budget)
                        .unwrap();
                    sdk.enter(model.publication_domain(), &model.intent, &budget)
                        .unwrap();
                }
                _ => std::fs::remove_file(model.publication_path()).unwrap(),
            }
            let bytes = std::fs::read(model.publication_path()).ok();
            assert!(retained
                .recover_disposal_publication(model.publication_domain(), &model.intent, &budget)
                .is_err());
            assert!(!retained.disposal_published);
            assert!(retained.disposal.as_ref() == Some(&model.intent));
            assert_eq!(std::fs::read(model.publication_path()).ok(), bytes);
            if case == 0 {
                assert!(retained.sdk_entry.is_none());
            } else {
                assert!(Arc::ptr_eq(&original, retained.sdk_entry.as_ref().unwrap()));
                let held = original.lock().unwrap();
                assert!(retained
                    .recover_disposal_publication(
                        model.publication_domain(),
                        &model.intent,
                        &budget
                    )
                    .is_err());
                assert!(!retained.disposal_published);
                drop(held);
            }
        }
    }

    #[test]
    fn otherwise_eligible_primary_recovery_is_nonblocking_and_cannot_outlive_its_budget() {
        for case in 0..3 {
            let model = super::super::super::resolution::partial_disposal::tests::Model::new(1);
            let mut retained = unpublished_disposal(&model);
            model.enter();
            let original = retained.sdk_entry.clone().unwrap();
            let mut budget = ReadBudget::new(
                std::time::Duration::from_secs(30),
                crate::Cancellation::default(),
            )
            .unwrap();
            if case == 1 {
                budget.deadline = std::time::Instant::now() - std::time::Duration::from_millis(1);
            }
            if case == 2 {
                budget.cancel.cancel();
            }
            let held = if case == 0 {
                Some(original.lock().unwrap())
            } else {
                None
            };
            let path = model.publication_path();
            let bytes = std::fs::read(&path).unwrap();
            let error = retained
                .recover_disposal_publication(model.publication_domain(), &model.intent, &budget)
                .unwrap_err();
            if case == 0 {
                assert_eq!(error.code, ErrorCode::Conflict);
            }
            assert!(!retained.disposal_published);
            assert!(Arc::ptr_eq(&original, retained.sdk_entry.as_ref().unwrap()));
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            assert!(!path.with_extension("sdk-entry.json").exists());
            drop(held);
        }
    }

    #[test]
    fn original_disposal_retention_creates_one_entry_cache_and_never_retrofits_legacy_intent() {
        let model = super::super::super::resolution::partial_disposal::tests::Model::new(1);
        let mut retained = RetainedCollection {
            request: model.intent.request.collection_request.clone(),
            published: true,
            disposal: None,
            disposal_published: false,
            sdk_entry: None,
            cleanup: None,
        };
        retained.retain_disposal(model.intent.clone()).unwrap();
        let original = retained.sdk_entry.clone().unwrap();
        retained.retain_disposal(model.intent.clone()).unwrap();
        assert!(Arc::ptr_eq(&original, retained.sdk_entry.as_ref().unwrap()));
        let mut crossed = model.intent.clone();
        crossed.request.operation_id = "crossed-disposal-model".into();
        crossed.request.request_sha256 = crossed.request.digest().unwrap();
        assert!(retained.retain_disposal(crossed).is_err());
        assert!(Arc::ptr_eq(&original, retained.sdk_entry.as_ref().unwrap()));
        // An older retained collection may have a primary intent but no new
        // SDK-entry cache. Re-offering that intent must not reconstruct one.
        retained.sdk_entry = None;
        retained.disposal_published = true;
        retained.retain_disposal(model.intent.clone()).unwrap();
        assert!(retained.sdk_entry.is_none());
        assert!(retained.disposal.as_ref() == Some(&model.intent));
    }

    #[test]
    fn original_collection_request_freezes_once_and_cannot_recreate_a_missing_published_fence() {
        let model = crate::branch_boot::tests::identity_model(true);
        let request = request(&model.plan);
        let path = model.plan.child.path.join("smolbox.branch-start-v1.json");
        let before = std::fs::read(&path).unwrap();
        let counts = model.engine.jobs.counts();
        let mut retained = None;
        RetainedCollection::prepare(&mut retained, &model.plan, &model.enrollment, &request)
            .unwrap();
        assert!(retained.as_ref().unwrap().published);
        let fenced = std::fs::read(&path).unwrap();
        RetainedCollection::prepare(&mut retained, &model.plan, &model.enrollment, &request)
            .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), fenced);
        let mut crossed = request.clone();
        crossed.operation_id = "other-collection".into();
        crossed.request_sha256 = crossed.digest().unwrap();
        assert!(RetainedCollection::prepare(
            &mut retained,
            &model.plan,
            &model.enrollment,
            &crossed
        )
        .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), fenced);
        // Deterministic private file substitution, never live persistence interruption.
        std::fs::write(&path, &before).unwrap();
        assert!(RetainedCollection::prepare(
            &mut retained,
            &model.plan,
            &model.enrollment,
            &request
        )
        .is_err());
        assert_eq!(std::fs::read(path).unwrap(), before);
        assert!(retained.as_ref().unwrap().request == request);
        assert_eq!(model.engine.jobs.counts(), counts);
    }

    #[test]
    fn crossed_original_creation_cannot_poison_an_unentered_collection_slot() {
        let model = crate::branch_boot::tests::identity_model(true);
        let mut request = request(&model.plan);
        request.creation.child.operation_id = "foreign-creation".into();
        request.request_sha256 = request.digest().unwrap();
        let mut retained = None;
        assert!(RetainedCollection::prepare(
            &mut retained,
            &model.plan,
            &model.enrollment,
            &request
        )
        .is_err());
        assert!(retained.is_none());
        assert!(!Lifecycle::at(&model.plan.child.path)
            .partial_collection_started()
            .unwrap());
    }
}
