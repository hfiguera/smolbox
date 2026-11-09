//! Opt-in sequential engine API cancellation after a completed SDK boot call.
//! No fault injection, hidden launch pause, process loss or SDK source changes.
use super::*;

impl Session {
    pub(super) fn exercise_partial_cancellation(
        &mut self,
        settings: &Settings,
    ) -> ProofResult<Value> {
        self.prepare_source(settings)?;
        let request = BranchCreateRequest {
            source: self.receipt(0)?.clone(),
            child: BranchChildIntent {
                operation_id: format!("branch-{}", support::random(12)?),
                name: format!("sb-partial-{}", support::random(8)?),
                owner_token: support::random(32)?,
                incarnation: support::random(16)?,
                idle: true,
                hold: true,
            },
            approval: settings.branch_approval.clone(),
            initial_release: None,
        };
        self.stage("child-1-request", &request)?;
        self.members[1].creation = Some(request.clone());
        self.members[1].enter(&[State::Missing])?;
        let cancellation = Cancellation::new();
        let original_budget =
            ReadBudget::for_checkpoint_work(Duration::from_secs(120), cancellation.clone())?;
        let retained = self
            .engine
            .prepare_initial_branch(
                &request.source,
                &request.child,
                &request.approval,
                &original_budget,
            )?
            .persist_intent(&self.engine)?
            .prepare_sdk_worker(&self.engine)?
            .retain_creation(&self.engine, &request)?;
        retained.prepare_fork(&self.engine)?;
        let boot = retained.boot_child(&self.engine)?;
        // This is a returned public engine API boundary, not an observation of
        // a hidden process phase. The original manager and enrollment remain held.
        cancellation.cancel();
        self.stage("child-1-boot-returned", &boot)?;
        let rejected = retained.initialize_child(&self.engine);
        let cancelled_before_entry = matches!(rejected, Err(error)
            if error.code == smolbox_engine::ErrorCode::State
                && error.dispatch == Dispatch::NotDispatched);
        if !cancellation.is_cancelled()
            || Instant::now() >= original_budget.deadline()
            || !cancelled_before_entry
            || self
                .engine
                .inspect_branch_completion(&request, &budget()?)?
                .is_some()
        {
            return Err("cancelled original boot must not initialize or grant completion".into());
        }
        drop(retained);
        self.stage(
            "child-1-explicit-cancellation",
            &json!({
                "original_boot_api_returned": true,
                "original_token_cancelled": true,
                "initialization_rejected": true,
                "completed_branch_absent": true,
                "process_loss_or_boot_pause_injected": false,
            }),
        )?;

        // Reuse original-context typed controls; each new action is entered once.
        // An uncertain return stops the witness and retains its existing owner.
        for action in [
            "publish-collected-first",
            "collect-partial-first",
            "dispose-partial-first",
        ] {
            self.recover(recovery::parse(action).ok_or("missing ordinary typed control")?)?;
        }
        self.absence(1)?;
        self.check_data(0, "source-disksource-memory", true)?;
        self.delete(0)?;
        self.release_backing(1)?;
        Ok(json!({
            "status": "passed",
            "scope": "ordinary-shared-engine-partial-cancellation-linux-local-bare",
            "package_manifest_sha256": settings.manifest_sha256,
            "sdk_revision": smolbox_engine::SMOLVM_REVISION,
            "witness_executable_sha256": self.driver_sha256,
            "original_boot_api_returned": true,
            "explicit_operation_cancellation": true,
            "partial_collection_disposal_absence_and_backing": true,
            "source_disk_and_memory_preserved_before_owned_cleanup": true,
            "durable_dependency_retirement_qualified": false,
            "port_branch_routing_qualified": false,
            "public_consumer_qualified": false,
            "public_native_branch_admission_enabled": false,
            "crash_validation_performed": false,
            "distribution_approved": false,
        }))
    }
}
