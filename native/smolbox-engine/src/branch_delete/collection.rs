//! Explicit original-child collection after the original deletion worker returns.
//! Its independent acknowledgement grants neither SDK deletion nor capacity release.
use super::*;

const LEDGER_BYTES: u64 = 16 * 1024;
const REQUEST_BYTES: usize = 132 * 1024;
const PROOF_BYTES: usize = 4096;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchDeletionCollectionRequest {
    pub completion: crate::BranchCompletion,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release: Option<crate::BranchReleaseTransition>,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub quiesced: bool,
}
impl std::fmt::Debug for BranchDeletionCollectionRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchDeletionCollectionRequest")
            .finish_non_exhaustive()
    }
}
impl BranchDeletionCollectionRequest {
    pub fn validate(&self) -> Result<()> {
        self.completion.validate()?;
        match &self.release {
            None if self.completion.held && self.child == self.completion.child => (),
            Some(release) => {
                release.validate()?;
                if release.previous != *self.completion.publication.child()
                    || release.change.binding != self.completion.publication.change.child_origin
                    || release.change.identity_sha256 != self.completion.identity_sha256
                    || (!self.completion.held && self.completion.release.as_ref() != Some(release))
                    || self.child != release.receipt
                    || self.operation_id == release.change.request.operation_id
                {
                    return Err(Error::before(ErrorCode::Validation));
                }
            }
            _ => return Err(Error::before(ErrorCode::Validation)),
        }
        if !self.quiesced
            || !crate::domain::valid_id(&self.operation_id)
            || self.operation_id
                == self
                    .completion
                    .publication
                    .change
                    .child_origin
                    .intent
                    .child
                    .operation_id
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || self.request_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    /// Stable request digest; the digest field itself is excluded.
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-original-child-delete-collection-request-v1",
            &self.completion,
            &self.release,
            &self.child,
            &self.operation_id,
            self.quiesced,
        ))
    }
    fn matches_intent(&self, intent: &Intent) -> Result<()> {
        self.validate()?;
        intent.validate()?;
        if self.child != *intent.receipt()
            || self.release != intent.release
            || self.completion.publication != intent.plan.publication
            || self.completion.identity_sha256 != intent.identity_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub fn matches(&self, proof: &BranchDeletionCollection) -> Result<()> {
        self.validate()?;
        proof.validate()?;
        if proof.grant()? != Grant::new(self, &proof.deletion_sha256)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

/// Historical original-child collection only. It gives no readiness, stopped-row,
/// SDK deletion, namespace absence, dependency or backing-retirement authority.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchDeletionCollection {
    pub schema: u8,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub completion_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_sha256: Option<String>,
    pub deletion_sha256: String,
    pub collection_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for BranchDeletionCollection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchDeletionCollection")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl BranchDeletionCollection {
    fn grant(&self) -> Result<Grant> {
        let grant = Grant {
            child: self.child.clone(),
            operation_id: self.operation_id.clone(),
            request_sha256: self.request_sha256.clone(),
            completion_sha256: self.completion_sha256.clone(),
            release_sha256: self.release_sha256.clone(),
            deletion_sha256: self.deletion_sha256.clone(),
        };
        grant.validate()?;
        Ok(grant)
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-original-child-delete-collection-proof-v1",
            self.schema,
            self.grant()?,
            &self.collection_sha256,
        ))
    }
    pub fn validate(&self) -> Result<()> {
        if self.schema != 1
            || !crate::domain::valid_hex(&self.collection_sha256, 64)
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
    fn issue(
        grant: &Grant,
        intent: &Intent,
        collected: &crate::epoch::BootCollection,
    ) -> Result<Self> {
        intent.collected(collected)?;
        if grant.child != *intent.receipt()
            || grant.deletion_sha256 != crate::material::hash(intent)?
            || grant.release_sha256
                != intent
                    .release
                    .as_ref()
                    .map(crate::material::hash)
                    .transpose()?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut proof = Self {
            schema: 1,
            child: grant.child.clone(),
            operation_id: grant.operation_id.clone(),
            request_sha256: grant.request_sha256.clone(),
            completion_sha256: grant.completion_sha256.clone(),
            release_sha256: grant.release_sha256.clone(),
            deletion_sha256: grant.deletion_sha256.clone(),
            collection_sha256: crate::material::hash(&(
                "smolbox-original-child-delete-collected-actor-v1",
                collected.intent(),
                collected.child(),
            ))?,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        proof.validate()?;
        Ok(proof)
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Grant {
    child: CreationReceipt,
    operation_id: String,
    request_sha256: String,
    completion_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    release_sha256: Option<String>,
    deletion_sha256: String,
}
impl Grant {
    fn new(request: &BranchDeletionCollectionRequest, deletion_sha256: &str) -> Result<Self> {
        let grant = Self {
            child: request.child.clone(),
            operation_id: request.operation_id.clone(),
            request_sha256: request.request_sha256.clone(),
            completion_sha256: crate::material::hash(&request.completion)?,
            release_sha256: request
                .release
                .as_ref()
                .map(crate::material::hash)
                .transpose()?,
            deletion_sha256: deletion_sha256.into(),
        };
        grant.validate()?;
        Ok(grant)
    }
    fn validate(&self) -> Result<()> {
        let material = self
            .child
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        material.validate()?;
        if material.revision != u32::from(self.release_sha256.is_some())
            || !crate::domain::valid_id(&self.child.target_id)
            || !crate::domain::valid_id(&self.child.name)
            || !crate::domain::valid_hex(&self.child.domain_generation, 32)
            || !crate::domain::valid_hex(&self.child.owner_token, 64)
            || !crate::domain::valid_hex(&self.child.incarnation, 32)
            || !crate::domain::valid_hex(&self.child.material_sha256, 64)
            || !crate::domain::valid_id(&self.operation_id)
            || [
                &self.request_sha256,
                &self.completion_sha256,
                &self.deletion_sha256,
            ]
            .iter()
            .any(|value| !crate::domain::valid_hex(value, 64))
            || self
                .release_sha256
                .as_ref()
                .is_some_and(|value| !crate::domain::valid_hex(value, 64))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CollectionRecord {
    schema: u8,
    grant: Grant,
    proof: Option<BranchDeletionCollection>,
}
impl ProtectedRecord for CollectionRecord {
    const MAX_RECORD_BYTES: u64 = LEDGER_BYTES;
    fn validate_for(&self, journal: &Journal, bytes: u64) -> Result<()> {
        self.grant.validate()?;
        if self.schema != 1
            || bytes > LEDGER_BYTES
            || collection_journal(journal.domain.clone(), &self.grant.child)?.path != journal.path
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(proof) = &self.proof {
            proof.validate()?;
            if proof.grant()? != self.grant {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
}
fn collection_journal(
    domain: Arc<crate::domain::DomainGuard>,
    child: &CreationReceipt,
) -> Result<Journal> {
    let mut journal = Journal::new(domain, child)?;
    journal.path.set_extension("collection.json");
    Ok(journal)
}
pub(super) struct RetainedCollection {
    grant: Grant,
    // Once published, a missing ledger is an ownership failure, never new entry.
    published: bool,
}
impl Retained {
    fn prepare_collection(
        &mut self,
        main: &Journal,
        request: &BranchDeletionCollectionRequest,
        active: &Arc<()>,
        budget: &ReadBudget,
    ) -> Result<Option<BranchDeletionCollection>> {
        self.check_returned(&request.child)?;
        request.matches_intent(&self.intent)?;
        budget.check()?;
        let grant = Grant::new(request, &crate::material::hash(&self.intent)?)?;
        if self
            .collection
            .as_ref()
            .is_some_and(|prior| prior.grant != grant)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let ledger = collection_journal(main.domain.clone(), &request.child)?;
        let prior = match std::fs::symlink_metadata(&ledger.path) {
            Ok(_) => {
                // A durable record alone cannot enroll this control after replacement.
                if self.collection.is_none() {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let (record, version) = ledger.read_record::<CollectionRecord>()?;
                if record.grant != grant {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                ledger.sync_record::<CollectionRecord>(&version, budget)?;
                self.collection.as_mut().unwrap().published = true;
                if let Some(proof) = record.proof {
                    // Historical acknowledgement precedes current namespace traversal.
                    request.matches(&proof)?;
                    return Ok(Some(proof));
                }
                Some(record)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if self
                    .collection
                    .as_ref()
                    .is_some_and(|prior| prior.published)
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                None
            }
            Err(_) => return Err(Error::before(ErrorCode::Ownership)),
        };
        let (record, _) = main.read()?;
        if record.intent != self.intent
            || !matches!(record.phase, Phase::Collecting | Phase::Collected)
            || self.completion.is_some()
            || self.continuation.is_some()
            || self.cleanup.is_some()
            || self
                .leases
                .as_ref()
                .is_none_or(|leases| leases.source.is_none())
        {
            return Err(Error::before(ErrorCode::State));
        }
        // Freeze request and worker before publishing authority or entering SDK stop.
        if self.collection.is_none() {
            self.collection = Some(RetainedCollection {
                grant: grant.clone(),
                published: false,
            });
        }
        self.worker = Arc::downgrade(active);
        if prior.is_none() {
            budget.check()?;
            ledger
                .write_record(
                    &CollectionRecord {
                        schema: 1,
                        grant,
                        proof: None,
                    },
                    None,
                )
                .map_err(|e| Error::uncertain(e.code))?;
            self.collection.as_mut().unwrap().published = true;
        }
        let (_, version) = ledger.read_record::<CollectionRecord>()?;
        ledger.sync_record::<CollectionRecord>(&version, budget)?;
        Ok(None)
    }
    fn finish_collection(
        &mut self,
        main: &Journal,
        collected: &crate::epoch::BootCollection,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionCollection> {
        budget.check()?;
        let (main_record, _) = main.read()?;
        if main_record.intent != self.intent
            || !matches!(main_record.phase, Phase::Collecting | Phase::Collected)
        {
            return Err(Error::before(ErrorCode::State));
        }
        let retained = self
            .collection
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?;
        if !retained.published {
            return Err(Error::before(ErrorCode::State));
        }
        let ledger = collection_journal(main.domain.clone(), self.intent.receipt())?;
        let (mut record, version) = ledger.read_record::<CollectionRecord>()?;
        if record.grant != retained.grant {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let proof = BranchDeletionCollection::issue(&record.grant, &self.intent, collected)?;
        if let Some(prior) = &record.proof {
            if prior != &proof {
                return Err(Error::before(ErrorCode::Ownership));
            }
        } else {
            budget.check()?;
            record.proof = Some(proof.clone());
            ledger
                .write_record(&record, Some(version))
                .map_err(|e| Error::uncertain(e.code))?;
        }
        let (_, version) = ledger.read_record::<CollectionRecord>()?;
        ledger.sync_record::<CollectionRecord>(&version, budget)?;
        Ok(proof)
    }
}

impl Engine {
    /// Explicitly collect only the retained original child of a returned deletion.
    /// The caller must fence durable/controller work. Final deletion still needs
    /// its separate continuation; an entered final SDK deletion is never replayed.
    pub fn collect_branch_deletion_checked(
        &self,
        request: &BranchDeletionCollectionRequest,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionCollection> {
        request.validate()?;
        budget.check()?;
        if budget
            .deadline
            .saturating_duration_since(std::time::Instant::now())
            > std::time::Duration::from_secs(30)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        request.child.validate(self.binding())?;
        let control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self
            .branch_retention
            .completed_context_exact(&request.completion)?;
        if !Arc::ptr_eq(&context, &self.retained_branch_context(&request.child)?) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.domain.verify()?;
        let epoch = self.collection_epoch()?.clone();
        let journal = Journal::new(self.domain.clone(), &request.child)?;
        let active = Arc::new(());
        let mut retained = context
            .deletion
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let state = retained.as_mut().ok_or(Error::before(ErrorCode::State))?;
        if state.intent.plan != context.plan
            || state.intent.boot != *context.enrollment.intent()
            || state.intent.child != context.enrollment.child()
            || state.intent.identity_sha256 != context.identity_sha256
            || !epoch.bound_to(self.binding())
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(proof) = state.prepare_collection(&journal, request, &active, budget)? {
            budget.check()?;
            return Ok(proof);
        }
        self.binding().validate()?;
        self.verify_database_identity()?;
        drop(retained);
        let application = Collection {
            context,
            epoch,
            journal,
            database: self.binding().database.clone(),
            identity: self.database_identity,
            budget: budget.clone(),
            _control: control,
        };
        let proof = crate::oci_start::observe_owned(
            self.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _active = active;
                application.run()
            },
        )
        .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        request
            .matches(&proof)
            .map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
}
struct Collection {
    context: Arc<Context>,
    epoch: crate::epoch::ActorEpoch,
    journal: Journal,
    database: std::path::PathBuf,
    identity: (u64, u64),
    budget: ReadBudget,
    _control: crate::jobs::JobLease,
}
impl Collection {
    fn run(self) -> Result<BranchDeletionCollection> {
        let mut retained = self
            .context
            .deletion
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        let state = retained
            .as_mut()
            .ok_or(Error::uncertain(ErrorCode::State))?;
        self.budget.check()?;
        let (record, _) = self.journal.read()?;
        if record.intent != state.intent
            || !matches!(record.phase, Phase::Collecting | Phase::Collected)
            || state
                .leases
                .as_ref()
                .is_none_or(|leases| leases.source.is_none())
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        continuation::manager_is_original(&self.context)?;
        let collection_state = state
            .collection
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?;
        let ledger = collection_journal(self.journal.domain.clone(), state.intent.receipt())?;
        let (entered, version) = ledger.read_record::<CollectionRecord>()?;
        if !collection_state.published
            || entered.grant != collection_state.grant
            || entered.proof.is_some()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        ledger.sync_record::<CollectionRecord>(&version, &self.budget)?;
        let collection = match self
            .epoch
            .collect_enrolled(&state.intent.receipt().name, &self.context.enrollment)
        {
            Ok(proof) => {
                // Positive historical collection can be acknowledged without opening
                // a removed/recreated child namespace or issuing another SDK stop.
                self.context
                    .manager
                    .try_lock()
                    .map_err(|_| Error::before(ErrorCode::Conflict))?
                    .mark_stopped();
                proof
            }
            Err(error) if error.code == ErrorCode::Conflict => {
                self.context.plan.verify()?;
                let (head, held, release) =
                    crate::branch_boot::Lifecycle::at(&self.context.plan.child.path)
                        .finish_record(
                            &self.context.plan,
                            &self.context.enrollment,
                            &self.context.identity_sha256,
                        )?;
                if head != *state.intent.receipt()
                    || held != state.intent.release.is_none()
                    || release != state.intent.release
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                release_ready(&self.context, release.as_ref())?;
                let before = crate::sdk_compat::observe_record(
                    &self.database,
                    self.identity,
                    &head.name,
                    &self.budget,
                )?
                .ok_or(Error::before(ErrorCode::Ownership))?;
                verify_original_record(&state.intent, &before, &self.budget)?;
                self.context.collect_original(&self.epoch, &self.budget)?
            }
            Err(error) => return Err(error),
        };
        state.finish_collection(&self.journal, &collection, &self.budget)
    }
}

#[cfg(test)]
mod tests;
