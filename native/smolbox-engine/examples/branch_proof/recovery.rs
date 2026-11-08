//! Explicit original-context controls for a failed ordinary witness. These use
//! the existing engine's opaque owners and typed proofs, never saved-file adoption.
use super::*;
use smolbox_engine::{
    BranchPreparationState, PartialBranchBackingReleaseRequest, PartialBranchChildAbsence,
    PartialBranchChildAbsenceRequest, PartialBranchCollection, PartialBranchCollectionRequest,
    PartialBranchDisposal, PartialBranchDisposalCleanup, PartialBranchDisposalCleanupRequest,
    PartialBranchDisposalCleanupUnneeded, PartialBranchDisposalRequest, PreparedBranchRetirement,
    PreparedBranchRetirementRequest, RetainedBranchResolution, UnbootedBranchBackingReleaseRequest,
    UnbootedBranchChildAbsence, UnbootedBranchChildAbsenceRequest, UnbootedBranchDisposal,
    UnbootedBranchDisposalRequest,
};

#[derive(Default)]
pub(super) struct Recovery {
    publication: Option<smolbox_engine::BranchPublication>,
    ready: Option<BranchCompletion>,
    prepared: Option<PreparedBranchRetirement>,
    prepared_request: Option<PreparedBranchRetirementRequest>,
    collection_request: Option<PartialBranchCollectionRequest>,
    collection: Option<PartialBranchCollection>,
    partial_request: Option<PartialBranchDisposalRequest>,
    unbooted_request: Option<UnbootedBranchDisposalRequest>,
    cleanup_request: Option<PartialBranchDisposalCleanupRequest>,
    cleanup_ack: Option<CleanupAck>,
    observed_phase: Option<String>,
    disposal: Option<Disposal>,
    archived: bool,
    absence_request: Option<AbsenceRequest>,
    absence: Option<Absence>,
    backing: Option<Backing>,
}
impl Recovery {
    pub(super) fn has_disposal(&self) -> bool {
        self.disposal.is_some()
    }
    pub(super) fn has_absence(&self) -> bool {
        self.archived && self.absence.is_some()
    }
    pub(super) fn cleanup_complete(&self) -> bool {
        self.cleanup_request.is_none() || self.cleanup_ack.is_some()
    }
    pub(super) fn last_observed_phase(&self) -> Option<&str> {
        self.observed_phase.as_deref()
    }
    pub(super) fn retired_unentered(&self) -> bool {
        self.prepared.is_some()
    }
    fn cleanup_started(&self) -> bool {
        self.collection_request.is_some()
            || self.unbooted_request.is_some()
            || self.disposal.is_some()
    }
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "snake_case")]
enum Disposal {
    Partial(Box<PartialBranchDisposal>),
    Unbooted(Box<UnbootedBranchDisposal>),
}
impl Disposal {
    fn creation(&self) -> &BranchCreateRequest {
        match self {
            Self::Partial(p) => &p.request.collection_request.creation,
            Self::Unbooted(p) => &p.creation,
        }
    }
    fn publication(&self) -> &smolbox_engine::BranchPublication {
        match self {
            Self::Partial(p) => &p.publication,
            Self::Unbooted(p) => &p.publication,
        }
    }
    fn child(&self) -> &CreationReceipt {
        match self {
            Self::Partial(p) => p
                .release
                .as_ref()
                .map_or(p.publication.child(), |r| &r.receipt),
            Self::Unbooted(p) => p.publication.child(),
        }
    }
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "snake_case")]
enum AbsenceRequest {
    Partial(Box<PartialBranchChildAbsenceRequest>),
    Unbooted(Box<UnbootedBranchChildAbsenceRequest>),
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum Absence {
    Partial(Box<PartialBranchChildAbsence>),
    Unbooted(Box<UnbootedBranchChildAbsence>),
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "snake_case")]
enum Backing {
    Partial(Box<PartialBranchBackingReleaseRequest>),
    Unbooted(Box<UnbootedBranchBackingReleaseRequest>),
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum CleanupAck {
    Removed(Box<PartialBranchDisposalCleanup>),
    Unneeded(Box<PartialBranchDisposalCleanupUnneeded>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    Publish,
    Ready,
    Phase,
    Prepared,
    Collect,
    Dispose,
    Resolve,
    Cleanup,
    QualifyCleanup,
    ResolveCleanup,
    Finish,
    Unbooted,
    ResolveUnbooted,
    Release,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Action {
    index: usize,
    step: Step,
}
pub(super) fn parse(action: &str) -> Option<Action> {
    if action == "qualify-held-release" {
        return Some(Action {
            index: 2,
            step: Step::Release,
        });
    }
    for (label, index) in [("first", 1), ("held", 2)] {
        for (verb, step) in [
            ("publish-collected", Step::Publish),
            ("qualify-ready", Step::Ready),
            ("inspect-retained", Step::Phase),
            ("retire-prepared", Step::Prepared),
            ("collect-partial", Step::Collect),
            ("dispose-partial", Step::Dispose),
            ("resolve-partial", Step::Resolve),
            ("cleanup-partial", Step::Cleanup),
            ("qualify-cleanup", Step::QualifyCleanup),
            ("resolve-cleanup", Step::ResolveCleanup),
            ("finish-disposal", Step::Finish),
            ("dispose-unbooted", Step::Unbooted),
            ("resolve-unbooted", Step::ResolveUnbooted),
        ] {
            if action == format!("{verb}-{label}") {
                return Some(Action { index, step });
            }
        }
    }
    None
}

impl Session {
    fn original_creation(&self, index: usize) -> ProofResult<BranchCreateRequest> {
        let member = &self.members[index];
        if member.completion.is_some() || member.state != State::Unknown {
            return Err("partial control requires this original incomplete creation".into());
        }
        member
            .creation
            .clone()
            .ok_or("missing original creation request; no adoption".into())
    }
    fn original_resolution(
        &self,
        index: usize,
        budget: &ReadBudget,
    ) -> ProofResult<RetainedBranchResolution> {
        let creation = self.original_creation(index)?;
        self.engine
            .retain_branch_resolution(&creation, true, budget)?
            .ok_or("missing original retained context; no absence or replay authority".into())
    }
    pub(super) fn recover(&mut self, action: Action) -> ProofResult<()> {
        let index = action.index;
        let b = budget()?;
        match action.step {
            Step::Publish => self.publish_collected(index, &b),
            Step::Ready => self.recover_ready(index, &b),
            Step::Release => self.recover_release(&b),
            Step::Prepared => self.retire_prepared(index, &b),
            Step::Phase => {
                let state = self.original_resolution(index, &b)?.state(&self.engine)?;
                self.members[index].recovery.observed_phase = Some(format!("{state:?}"));
                Ok(())
            }
            Step::Collect => self.collect_partial(index, &b),
            Step::Dispose | Step::Resolve => {
                self.dispose_partial(index, action.step == Step::Resolve, &b)
            }
            Step::Unbooted | Step::ResolveUnbooted => {
                self.dispose_unbooted(index, action.step == Step::ResolveUnbooted, &b)
            }
            Step::Cleanup => self.cleanup_partial(index, &b),
            Step::QualifyCleanup | Step::ResolveCleanup => {
                self.qualify_cleanup(index, action.step == Step::ResolveCleanup, &b)
            }
            Step::Finish => self.finish_disposal(index, &b),
        }
    }
    fn publish_collected(&mut self, index: usize, b: &ReadBudget) -> ProofResult<()> {
        let creation = self.original_creation(index)?;
        if self.members[index].recovery.cleanup_started()
            || self.members[index].recovery.ready.is_some()
            || self.members[0].state != State::Running
        {
            return Err("publication cannot cross cleanup, completion or a stopped source".into());
        }
        let previous = self.members[index].recovery.publication.clone();
        let current = self.receipt(0)?;
        if current != &creation.source && previous.as_ref().is_none_or(|p| &p.receipt != current) {
            return Err("local source head crossed the original publication".into());
        }
        let fresh = previous.is_none();
        let publication = if let Some(publication) = previous {
            publication
        } else {
            self.original_resolution(index, b)?
                .publish_collected_material(&self.engine)?
        };
        record_publication(&mut self.members[index], &creation, publication.clone())?;
        self.members[0].receipt = Some(publication.receipt.clone());
        if fresh {
            self.stage(
                &format!("child-{index}-collected-publication"),
                &publication,
            )?;
        }
        if Instant::now() >= b.deadline() {
            return Err("late publication acknowledgement; original facts remain retained".into());
        }
        Ok(())
    }
    fn recover_ready(&mut self, index: usize, b: &ReadBudget) -> ProofResult<()> {
        let creation = self.original_creation(index)?;
        if self.members[index].recovery.cleanup_started() || self.members[0].state != State::Running
        {
            return Err("ready lookup cannot cross cleanup entry or a stopped source".into());
        }
        let proof = self
            .engine
            .resolve_ready_branch_completion(&creation, true, b)?
            .ok_or("no positive original completion; no replay or adoption".to_string())?;
        self.members[index].recovery.ready = Some(proof.clone());
        // A historical result alone is not current liveness/readiness.
        self.engine
            .branch_preflight(&proof.publication.receipt, b)?;
        if self.engine.inspect(&proof.child)?.state != ObservedState::Running {
            return Err("original completed child is not currently running".into());
        }
        self.members[0].receipt = Some(proof.publication.receipt.clone());
        self.members[index].receipt = Some(proof.child.clone());
        self.members[index].state = if proof.held {
            State::Held
        } else {
            State::Running
        };
        self.members[index].completion = Some(proof.clone());
        self.stage(&format!("child-{index}-qualified-completion"), &proof)
    }
    fn recover_release(&mut self, b: &ReadBudget) -> ProofResult<()> {
        let member = &self.members[2];
        if member.state != State::Unknown {
            return Err("only uncertain original held release may qualify".into());
        }
        let original = member
            .completion
            .as_ref()
            .ok_or("missing original held completion")?;
        let request = member
            .release
            .as_ref()
            .ok_or("missing exact original release request")?;
        let result = self
            .engine
            .qualify_held_branch_release(original, self.receipt(0)?, request, b)?
            .ok_or("no positive original release result")?;
        self.engine.branch_preflight(self.receipt(0)?, b)?;
        if self.engine.inspect(&result.receipt)?.state != ObservedState::Running {
            return Err("qualified original release has no current running child".into());
        }
        self.members[2].receipt = Some(result.receipt.clone());
        self.members[2].state = State::Running;
        self.stage("held-release-qualified", &result)
    }
    fn retire_prepared(&mut self, index: usize, b: &ReadBudget) -> ProofResult<()> {
        if self.members[index].recovery.prepared.is_some() {
            return Ok(());
        }
        let creation = self.original_creation(index)?;
        if self.members[index].recovery.prepared_request.is_none() {
            let request = prepared_request(creation)?;
            self.stage(
                &format!("child-{index}-prepared-retirement-request"),
                &request,
            )?;
            self.members[index].recovery.prepared_request = Some(request);
        }
        let request = self.members[index]
            .recovery
            .prepared_request
            .as_ref()
            .ok_or("missing exact prepared retirement request")?;
        let proof = self.engine.retire_prepared_branch_checked(request, b)?;
        request.matches(&proof)?;
        self.members[index].recovery.prepared = Some(proof.clone());
        self.members[index].state = State::Deleted;
        self.stage(&format!("child-{index}-prepared-retirement-proof"), &proof)
    }
    fn collect_partial(&mut self, index: usize, b: &ReadBudget) -> ProofResult<()> {
        let creation = self.original_creation(index)?;
        if self.members[index].recovery.unbooted_request.is_some()
            || self.members[index].recovery.ready.is_some()
        {
            return Err(
                "collection cannot cross an unbooted disposal or completed candidate".into(),
            );
        }
        if self.members[index].recovery.collection.is_some() {
            return Ok(());
        }
        let owner = self.original_resolution(index, b)?;
        if self.members[index].recovery.collection_request.is_none()
            && !partial_phase(owner.state(&self.engine)?)
        {
            return Err(
                "original phase is not a pre-handoff boot; no collection request accepted".into(),
            );
        }
        if self.members[index].recovery.collection_request.is_none() {
            let request = collection_request(creation, format!("collect-{index}"))?;
            owner.inspect_partial_collection(&self.engine, &request)?;
            self.stage(&format!("child-{index}-collection-request"), &request)?;
            self.members[index].recovery.collection_request = Some(request);
        }
        let request = self.members[index]
            .recovery
            .collection_request
            .as_ref()
            .ok_or("missing original collection request")?;
        let proof = owner.collect_partial_child(&self.engine, request)?;
        self.members[index].recovery.collection = Some(proof.clone());
        self.stage(&format!("child-{index}-collection-proof"), &proof)
    }
    fn dispose_partial(&mut self, index: usize, observe: bool, b: &ReadBudget) -> ProofResult<()> {
        self.original_creation(index)?;
        if self.members[index].recovery.disposal.is_some() {
            return self.finish_disposal(index, b);
        }
        if !observe && self.members[index].recovery.partial_request.is_some() {
            return Err(
                "disposal entry already accepted; use resolve-partial, never SDK replay".into(),
            );
        }
        if self.members[index].recovery.partial_request.is_none() {
            if observe {
                return Err("missing exact original disposal request".into());
            }
            let r = &self.members[index].recovery;
            let request = partial_request(
                r.collection_request
                    .clone()
                    .ok_or("missing original collection request")?,
                r.collection
                    .clone()
                    .ok_or("positive original collection required")?,
                format!("dispose-{index}"),
            )?;
            self.stage(&format!("child-{index}-disposal-request"), &request)?;
            self.members[index].recovery.partial_request = Some(request);
        }
        let request = self.members[index]
            .recovery
            .partial_request
            .as_ref()
            .ok_or("missing original disposal")?;
        let owner = self.original_resolution(index, b)?;
        let proof = if observe {
            owner.resolve_partial_disposal(&self.engine, request)?
        } else {
            owner.dispose_partial_child(&self.engine, request)?
        };
        self.members[index].recovery.disposal = Some(Disposal::Partial(Box::new(proof.clone())));
        self.stage(&format!("child-{index}-disposal-proof"), &proof)?;
        drop(owner);
        self.finish_disposal(index, b)
    }
    fn dispose_unbooted(&mut self, index: usize, observe: bool, b: &ReadBudget) -> ProofResult<()> {
        let creation = self.original_creation(index)?;
        if self.members[index].recovery.disposal.is_some() {
            return self.finish_disposal(index, b);
        }
        if self.members[index].recovery.collection_request.is_some()
            || self.members[index].recovery.ready.is_some()
        {
            return Err(
                "unbooted disposal cannot borrow collection or completion authority".into(),
            );
        }
        if !observe && self.members[index].recovery.unbooted_request.is_some() {
            return Err("unbooted entry already accepted; use resolve-unbooted".into());
        }
        let owner = self.original_resolution(index, b)?;
        if self.members[index].recovery.unbooted_request.is_none() {
            if observe {
                return Err("missing original unbooted disposal request".into());
            }
            if owner.state(&self.engine)? != BranchPreparationState::MaterialPublished {
                return Err(
                    "original phase is not published/unbooted; no disposal request accepted".into(),
                );
            }
            let request = unbooted_request(&creation, format!("unbooted-{index}"))?;
            self.stage(&format!("child-{index}-unbooted-request"), &request)?;
            self.members[index].recovery.unbooted_request = Some(request);
        }
        let request = self.members[index]
            .recovery
            .unbooted_request
            .as_ref()
            .ok_or("missing unbooted request")?;
        let proof = if observe {
            owner.resolve_unbooted_disposal(&self.engine, request)?
        } else {
            owner.dispose_unbooted_child(&self.engine, request)?
        };
        self.members[index].recovery.disposal = Some(Disposal::Unbooted(Box::new(proof.clone())));
        self.stage(&format!("child-{index}-unbooted-proof"), &proof)?;
        drop(owner);
        self.finish_disposal(index, b)
    }
    fn cleanup_partial(&mut self, index: usize, b: &ReadBudget) -> ProofResult<()> {
        self.original_creation(index)?;
        if self.members[index].recovery.cleanup_request.is_some() {
            return Err(
                "cleanup already accepted; select qualify-cleanup or resolve-cleanup explicitly"
                    .into(),
            );
        } else {
            let disposal = self.members[index]
                .recovery
                .partial_request
                .clone()
                .ok_or("missing original disposal request")?;
            let request = cleanup_request(disposal, format!("cleanup-{index}"))?;
            self.stage(&format!("child-{index}-cleanup-request"), &request)?;
            self.members[index].recovery.cleanup_request = Some(request.clone());
            let owner = self.original_resolution(index, b)?;
            let proof = owner.cleanup_partial_disposal(&self.engine, &request)?;
            self.members[index].recovery.disposal =
                Some(Disposal::Partial(Box::new(proof.disposal.clone())));
            self.members[index].recovery.cleanup_ack =
                Some(CleanupAck::Removed(Box::new(proof.clone())));
            self.stage(&format!("child-{index}-cleanup-proof"), &proof)?;
        }
        self.finish_disposal(index, b)
    }
    fn qualify_cleanup(&mut self, index: usize, unneeded: bool, b: &ReadBudget) -> ProofResult<()> {
        let request = self.members[index]
            .recovery
            .cleanup_request
            .as_ref()
            .ok_or("missing exact accepted cleanup request")?;
        if self.members[index].recovery.cleanup_ack.is_some() {
            return self.finish_disposal(index, b);
        }
        // Distinct lookups have no fallback to each other or to mutation.
        let (disposal, ack) = if unneeded {
            let proof = self
                .engine
                .resolve_unneeded_partial_cleanup(request, b)?
                .ok_or("no positive original unused-cleanup acknowledgement")?;
            (
                proof.disposal.clone(),
                CleanupAck::Unneeded(Box::new(proof)),
            )
        } else {
            let proof = self
                .engine
                .inspect_partial_disposal_cleanup(request, b)?
                .ok_or("no positive original removal acknowledgement")?;
            (proof.disposal.clone(), CleanupAck::Removed(Box::new(proof)))
        };
        self.members[index].recovery.disposal = Some(Disposal::Partial(Box::new(disposal)));
        self.members[index].recovery.cleanup_ack = Some(ack);
        self.stage(
            &format!("child-{index}-qualified-cleanup"),
            &self.members[index].recovery.cleanup_ack,
        )?;
        self.finish_disposal(index, b)
    }
    fn finish_disposal(&mut self, index: usize, b: &ReadBudget) -> ProofResult<()> {
        if self.members[index].recovery.archived {
            return Ok(());
        }
        let proof = self.members[index]
            .recovery
            .disposal
            .clone()
            .ok_or("positive original disposal proof required")?;
        if self.members[index].creation.as_ref() != Some(proof.creation()) {
            return Err("disposal belongs to another original creation".into());
        }
        if self.receipt(0)? != &proof.creation().source
            && self.receipt(0)? != &proof.publication().receipt
        {
            return Err("original source head crossed another action".into());
        }
        // The archive is itself an original-engine acknowledgement, never a file
        // or inventory-derived completion. Selection/handoff controls are sequential.
        let archived = match &proof {
            Disposal::Partial(p) => {
                self.engine
                    .inspect_partial_branch_disposal(&p.request, b)?
                    .as_ref()
                    == Some(p.as_ref())
            }
            Disposal::Unbooted(p) => {
                self.engine
                    .inspect_unbooted_branch_disposal(&p.creation, &p.request, b)?
                    .as_ref()
                    == Some(p.as_ref())
            }
        };
        if !archived {
            let owner = self.original_resolution(index, b)?;
            match &proof {
                Disposal::Partial(p) => {
                    owner.finish_partial_branch_disposal(&self.engine, p)?;
                }
                Disposal::Unbooted(p) => {
                    owner.finish_unbooted_disposal(&self.engine, p)?;
                }
            }
        }
        self.members[index].recovery.archived = true;
        self.members[index].receipt = Some(proof.child().clone());
        self.members[index].state = State::Deleted;
        self.members[0].receipt = Some(proof.publication().receipt.clone());
        self.stage(&format!("child-{index}-disposal-handoff"), &proof)
    }
    pub(super) fn disposal_absence(&mut self, index: usize) -> ProofResult<()> {
        if self.members[index].recovery.has_absence() {
            return Ok(());
        }
        let r = &self.members[index].recovery;
        if !r.archived || self.members[index].state != State::Deleted {
            return Err("original disposal handoff required".into());
        }
        if r.absence_request.is_none() {
            let proof = r.disposal.as_ref().ok_or("missing disposal")?;
            let request = absence_request(proof, format!("absent-{index}"))?;
            self.stage(&format!("child-{index}-disposal-absence-request"), &request)?;
            self.members[index].recovery.absence_request = Some(request);
        }
        let request = self.members[index]
            .recovery
            .absence_request
            .as_ref()
            .ok_or("missing exact absence request")?;
        let proof = match request {
            AbsenceRequest::Partial(r) => Absence::Partial(Box::new(
                self.engine
                    .qualify_partial_branch_child_absence(r, &budget()?)?,
            )),
            AbsenceRequest::Unbooted(r) => Absence::Unbooted(Box::new(
                self.engine
                    .qualify_unbooted_branch_child_absence(r, &budget()?)?,
            )),
        };
        self.members[index].recovery.absence = Some(proof);
        self.stage(
            &format!("child-{index}-disposal-absence-proof"),
            &self.members[index].recovery.absence,
        )
    }
    pub(super) fn disposal_backing(&mut self, index: usize) -> ProofResult<()> {
        if self.members[index].backing_proof.is_some() {
            return Ok(());
        }
        if !self.members[index].recovery.has_absence()
            || !self.members[index].recovery.cleanup_complete()
            || self.members.iter().any(|m| !m.known_absent())
        {
            return Err("original disposal absence and all member deletions required".into());
        }
        for m in &self.members {
            if m.unentered() {
                continue;
            }
            if !matches!(std::fs::symlink_metadata(smolvm::agent::vm_data_dir(&m.receipt()?.name)), Err(e) if e.kind()==std::io::ErrorKind::NotFound)
            {
                return Err("original backing namespace remains".into());
            }
        }
        if self.members[index].recovery.backing.is_none() {
            let proof = self.members[index]
                .recovery
                .disposal
                .as_ref()
                .ok_or("missing original disposal")?;
            let request = disposal_backing_request(
                proof,
                self.receipt(0)?.clone(),
                format!("backing-{index}"),
            )?;
            self.stage(&format!("child-{index}-disposal-backing-request"), &request)?;
            self.members[index].recovery.backing = Some(request);
        }
        let request = self.members[index]
            .recovery
            .backing
            .as_ref()
            .ok_or("missing exact backing request")?;
        let proof = match request {
            Backing::Partial(r) => self
                .engine
                .release_partial_branch_backing_checked(r, &budget()?)?,
            Backing::Unbooted(r) => self
                .engine
                .release_unbooted_branch_backing_checked(r, &budget()?)?,
        };
        self.members[index].backing_proof = Some(proof.clone());
        self.stage(&format!("child-{index}-disposal-backing-proof"), &proof)
    }
}

fn partial_phase(state: BranchPreparationState) -> bool {
    matches!(
        state,
        BranchPreparationState::Booting
            | BranchPreparationState::Booted
            | BranchPreparationState::Initializing
            | BranchPreparationState::IdentityReady
            | BranchPreparationState::Releasing
            | BranchPreparationState::Released
    )
}
fn record_publication(
    member: &mut Member,
    creation: &BranchCreateRequest,
    publication: smolbox_engine::BranchPublication,
) -> ProofResult<()> {
    // Preserve returned original facts before any diagnostic IO or correlation
    // failure. A publication can never turn an incomplete creation into ready.
    member.recovery.publication = Some(publication.clone());
    if member.state != State::Unknown || member.creation.as_ref() != Some(creation) {
        return Err("missing original incomplete member".into());
    }
    creation.matches_publication(&publication)?;
    member.receipt = Some(publication.child().clone());
    Ok(())
}
fn prepared_request(creation: BranchCreateRequest) -> ProofResult<PreparedBranchRetirementRequest> {
    let request_sha256 = digest(&(
        "smolbox-prepared-branch-retirement-request-v1",
        &creation,
        true,
    ))?;
    Ok(PreparedBranchRetirementRequest {
        creation,
        request_sha256,
        quiesced: true,
    })
}
fn collection_request(
    creation: BranchCreateRequest,
    operation_id: String,
) -> ProofResult<PartialBranchCollectionRequest> {
    let mut r = PartialBranchCollectionRequest {
        creation,
        operation_id,
        request_sha256: String::new(),
        quiesced: true,
    };
    r.request_sha256 = r.digest()?;
    r.validate()?;
    Ok(r)
}
fn partial_request(
    collection_request: PartialBranchCollectionRequest,
    collection: PartialBranchCollection,
    operation_id: String,
) -> ProofResult<PartialBranchDisposalRequest> {
    let mut r = PartialBranchDisposalRequest {
        collection_request,
        collection,
        operation_id,
        request_sha256: String::new(),
        quiesced: true,
    };
    r.request_sha256 = r.digest()?;
    r.validate()?;
    Ok(r)
}
fn unbooted_request(
    creation: &BranchCreateRequest,
    operation_id: String,
) -> ProofResult<UnbootedBranchDisposalRequest> {
    let mut r = UnbootedBranchDisposalRequest {
        operation_id,
        request_sha256: String::new(),
        quiesced: true,
    };
    r.request_sha256 = r.digest(creation)?;
    Ok(r)
}
fn cleanup_request(
    disposal_request: PartialBranchDisposalRequest,
    operation_id: String,
) -> ProofResult<PartialBranchDisposalCleanupRequest> {
    let mut r = PartialBranchDisposalCleanupRequest {
        disposal_request,
        operation_id,
        request_sha256: String::new(),
        quiesced: true,
    };
    r.request_sha256 = r.digest()?;
    r.validate()?;
    Ok(r)
}
fn absence_request(proof: &Disposal, operation_id: String) -> ProofResult<AbsenceRequest> {
    Ok(match proof {
        Disposal::Partial(p) => {
            let mut r = PartialBranchChildAbsenceRequest {
                disposal: *p.clone(),
                operation_id,
                request_sha256: String::new(),
                quiesced: true,
            };
            r.request_sha256 = r.digest()?;
            r.validate()?;
            AbsenceRequest::Partial(Box::new(r))
        }
        Disposal::Unbooted(p) => {
            let mut r = UnbootedBranchChildAbsenceRequest {
                disposal: *p.clone(),
                operation_id,
                request_sha256: String::new(),
                quiesced: true,
            };
            r.request_sha256 = r.digest()?;
            r.validate()?;
            AbsenceRequest::Unbooted(Box::new(r))
        }
    })
}
fn disposal_backing_request(
    proof: &Disposal,
    source: CreationReceipt,
    operation_id: String,
) -> ProofResult<Backing> {
    Ok(match proof {
        Disposal::Partial(p) => {
            let mut r = PartialBranchBackingReleaseRequest {
                disposal: *p.clone(),
                source,
                child: proof.child().clone(),
                operation_id,
                request_sha256: String::new(),
                quiesced: true,
                backing_removed: true,
            };
            r.request_sha256 = r.digest()?;
            r.validate()?;
            Backing::Partial(Box::new(r))
        }
        Disposal::Unbooted(p) => {
            let mut r = UnbootedBranchBackingReleaseRequest {
                disposal: *p.clone(),
                source,
                child: proof.child().clone(),
                operation_id,
                request_sha256: String::new(),
                quiesced: true,
                backing_removed: true,
            };
            r.request_sha256 = r.digest()?;
            r.validate()?;
            Backing::Unbooted(Box::new(r))
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn controls_select_only_original_child_steps_and_never_accept_paths_or_programs() {
        for label in ["first", "held"] {
            for verb in [
                "publish-collected",
                "qualify-ready",
                "inspect-retained",
                "retire-prepared",
                "collect-partial",
                "dispose-partial",
                "resolve-partial",
                "cleanup-partial",
                "qualify-cleanup",
                "resolve-cleanup",
                "finish-disposal",
                "dispose-unbooted",
                "resolve-unbooted",
            ] {
                parse(&format!("{verb}-{label}")).unwrap();
            }
        }
        parse("qualify-held-release").unwrap();
        for s in [
            "dispose-partial-source",
            "collect-partial-3",
            "adopt-first",
            "replay-first",
            "kill-first",
            "exec-first sh",
            "resolve-partial-/tmp/path",
        ] {
            assert!(parse(s).is_none());
        }
    }
    #[test]
    fn collected_publication_preserves_original_facts_without_readiness_or_release() {
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/unbooted-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let proof: UnbootedBranchDisposal =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let mut member = Member::empty();
            member.creation = Some(proof.creation.clone());
            member.state = State::Unknown;
            record_publication(&mut member, &proof.creation, proof.publication.clone()).unwrap();
            assert_eq!(member.state, State::Unknown);
            assert!(member.completion.is_none() && member.release.is_none());
            assert!(member.receipt.as_ref() == Some(proof.publication.child()));
            assert!(!member.child_closed() && !member.unentered());
            let mut changed = proof.creation.clone();
            changed.child.owner_token = "f".repeat(64);
            let mut crossed = Member::empty();
            crossed.creation = Some(changed.clone());
            crossed.state = State::Unknown;
            assert!(record_publication(&mut crossed, &changed, proof.publication.clone()).is_err());
            assert!(crossed.recovery.publication.is_some());
            assert!(crossed.receipt.is_none() && crossed.state == State::Unknown);
        }
    }
    #[test]
    fn collection_and_disposal_builders_keep_frozen_cross_reader_bytes() {
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/partial-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let r: PartialBranchDisposalRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let c = collection_request(
                r.collection_request.creation.clone(),
                r.collection_request.operation_id.clone(),
            )
            .unwrap();
            assert_eq!(
                serde_json::to_value(c).unwrap(),
                serde_json::to_value(&r.collection_request).unwrap()
            );
            let built = partial_request(
                r.collection_request.clone(),
                r.collection.clone(),
                r.operation_id.clone(),
            )
            .unwrap();
            assert_eq!(serde_json::to_value(built).unwrap(), row["request"]);
        }
    }
    #[test]
    fn incomplete_or_crossed_original_collection_cannot_supply_disposal_authority() {
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/partial-branch-disposal-v1.json"
        ))
        .unwrap();
        let r: PartialBranchDisposalRequest =
            serde_json::from_value(rows[0]["request"].clone()).unwrap();
        let mut wrong = r.collection.clone();
        wrong.proof_sha256 = "0".repeat(64);
        assert!(
            partial_request(r.collection_request.clone(), wrong, r.operation_id.clone()).is_err()
        );
        let mut request = r.collection_request.clone();
        request.creation.child.owner_token = "f".repeat(64);
        assert!(partial_request(request, r.collection.clone(), r.operation_id).is_err());
        let state = Recovery::default();
        assert!(!state.has_disposal() && !state.has_absence() && !state.cleanup_started());
    }
    #[test]
    fn distinct_disposal_origins_keep_exact_absence_and_backing_requests() {
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/partial-branch-child-absence-v1.json"
        ))
        .unwrap();
        for row in rows {
            let r: PartialBranchChildAbsenceRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            match absence_request(&Disposal::Partial(Box::new(r.disposal)), r.operation_id).unwrap()
            {
                AbsenceRequest::Partial(b) => {
                    assert_eq!(serde_json::to_value(b).unwrap(), row["request"])
                }
                _ => panic!("crossed origin"),
            }
        }
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/partial-branch-backing-release-v1.json"
        ))
        .unwrap();
        for row in rows {
            let r: PartialBranchBackingReleaseRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            match disposal_backing_request(
                &Disposal::Partial(Box::new(r.disposal)),
                r.source,
                r.operation_id,
            )
            .unwrap()
            {
                Backing::Partial(b) => assert_eq!(serde_json::to_value(b).unwrap(), row["request"]),
                _ => panic!("crossed origin"),
            }
        }
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/unbooted-branch-disposal-v1.json"
        ))
        .unwrap();
        for row in rows {
            let p: UnbootedBranchDisposal = serde_json::from_value(row["proof"].clone()).unwrap();
            let built = unbooted_request(&p.creation, p.request.operation_id.clone()).unwrap();
            assert_eq!(
                serde_json::to_value(built).unwrap(),
                serde_json::to_value(&p.request).unwrap()
            );
            let r: UnbootedBranchBackingReleaseRequest =
                serde_json::from_value(row["backing_request"].clone()).unwrap();
            match disposal_backing_request(
                &Disposal::Unbooted(Box::new(p)),
                r.source,
                r.operation_id,
            )
            .unwrap()
            {
                Backing::Unbooted(b) => {
                    assert_eq!(serde_json::to_value(b).unwrap(), row["backing_request"])
                }
                _ => panic!("crossed origin"),
            }
        }
    }
    #[test]
    fn prepared_retirement_uses_the_exact_original_declaration_and_is_not_empty_namespace_authority(
    ) {
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/prepared-branch-retirement-v1.json"
        ))
        .unwrap();
        for row in rows {
            let original: PreparedBranchRetirementRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PreparedBranchRetirement =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let built = prepared_request(original.creation.clone()).unwrap();
            built.matches(&proof).unwrap();
            assert_eq!(serde_json::to_value(built).unwrap(), row["request"]);
            let mut member = Member::empty();
            member.creation = Some(original.creation);
            member.state = State::Unknown;
            assert!(!member.unentered() && !member.child_closed());
            member.recovery.prepared = Some(proof);
            assert!(!member.unentered());
            member.state = State::Deleted;
            assert!(member.unentered() && member.child_closed());
        }
    }
    #[test]
    fn phase_routing_does_not_enroll_wrong_kind_and_acceptance_alone_cannot_ack_cleanup() {
        for state in [
            BranchPreparationState::Prepared,
            BranchPreparationState::Preparing,
            BranchPreparationState::MaterialPublished,
            BranchPreparationState::Held,
            BranchPreparationState::Ready,
        ] {
            assert!(!partial_phase(state));
        }
        for state in [
            BranchPreparationState::Booting,
            BranchPreparationState::Booted,
            BranchPreparationState::Initializing,
            BranchPreparationState::IdentityReady,
            BranchPreparationState::Releasing,
            BranchPreparationState::Released,
        ] {
            assert!(partial_phase(state));
        }
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../../smolbox-protocol/fixtures/partial-branch-disposal-cleanup-v1.json"
        ))
        .unwrap();
        for row in rows {
            let request: PartialBranchDisposalCleanupRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let proof: PartialBranchDisposalCleanup =
                serde_json::from_value(row["proof"].clone()).unwrap();
            let built = cleanup_request(
                request.disposal_request.clone(),
                request.operation_id.clone(),
            )
            .unwrap();
            assert_eq!(serde_json::to_value(&built).unwrap(), row["request"]);
            let mut state = Recovery {
                cleanup_request: Some(built),
                ..Default::default()
            };
            assert!(!state.cleanup_complete());
            state.cleanup_ack = Some(CleanupAck::Removed(Box::new(proof)));
            assert!(state.cleanup_complete());
        }
    }
}
