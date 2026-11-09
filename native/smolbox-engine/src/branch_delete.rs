//! Explicit deletion of a completed original held or released child. Collection
//! is distinct from deletion; neither retires backing/dependency reservations.
use crate::branch_owned::Context;
use crate::{
    CreationReceipt, Engine, Error, ErrorCode, Observation, ObservedState, ReadBudget, Result,
};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::sync::{Arc, Weak};
mod collected;
mod collection;
pub use collection::{BranchDeletionCollection, BranchDeletionCollectionRequest};
mod continuation;
mod released;
pub(crate) use released::release_ready;
pub use released::{
    ReleasedBranchDeletionCleanupRequest, ReleasedBranchDeletionContinuation,
    ReleasedBranchDeletionContinuationRequest, ReleasedBranchDeletionRequest,
    ReleasedBranchDeletionResolution, RELEASED_BRANCH_DELETION_PROOF_BYTES,
    RELEASED_BRANCH_DELETION_REQUEST_BYTES,
};
mod residual;

const LEGACY_BYTES: u64 = 64 * 1024;
// A schema-two result adds bounded request/proof metadata to an accepted legacy
// intent. Keep legacy records at their original limit, including on read.
const LEGACY_EXTENDED_BYTES: u64 = 80 * 1024;
const MAX_BYTES: u64 = 160 * 1024;
type Version = crate::checkpoint_materialize::FileVersion;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Intent {
    plan: crate::branch_boot::Plan,
    boot: crate::epoch::BootIntent,
    child: crate::OwnerIdentity,
    identity_sha256: String,
    nonce: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    release: Option<crate::BranchReleaseTransition>,
}
impl Intent {
    fn validate(&self) -> Result<()> {
        self.plan.validate()?;
        let binding = &self.plan.publication.change.child_origin;
        if !self
            .boot
            .matches(&binding.intent.child.name, &binding.intent.epoch)
            || self.child.pid <= 0
            || self.child.birth == 0
            || self.child.uid != unsafe { libc::geteuid() }
            || !crate::domain::valid_hex(&self.identity_sha256, 64)
            || !crate::domain::valid_hex(&self.nonce, 32)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match &self.release {
            None if binding.intent.child.hold => Ok(()),
            Some(release) => {
                release.validate()?;
                if release.previous != *self.plan.publication.child()
                    || release.change.binding != *binding
                    || release.change.identity_sha256 != self.identity_sha256
                    || release.change.boot_sha256 != crate::material::hash(&self.boot)?
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                Ok(())
            }
            None => Err(Error::before(ErrorCode::Ownership)),
        }
    }
    fn receipt(&self) -> &CreationReceipt {
        self.release
            .as_ref()
            .map_or_else(|| self.plan.publication.child(), |release| &release.receipt)
    }
    fn require_held(&self) -> Result<()> {
        if self.release.is_none() && self.plan.publication.change.child_origin.intent.child.hold {
            Ok(())
        } else {
            Err(Error::before(ErrorCode::Unsupported))
        }
    }
    fn collected(&self, proof: &crate::epoch::BootCollection) -> Result<()> {
        if proof.intent() != &self.boot || proof.child() != self.child {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Collecting,
    Collected,
    Deleting,
    Deleted,
    ResolvedAbsent,
    Finishing,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ContinuationRequest {
    operation_id: String,
    request_sha256: String,
}
impl ContinuationRequest {
    fn validate(&self) -> Result<()> {
        if !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
fn deletion_digest(intent: &Intent, continuation: Option<&ContinuationRequest>) -> Result<String> {
    match continuation {
        None => crate::material::hash(intent),
        Some(request) => {
            let domain = if intent.release.is_some() {
                "smolbox-released-delete-continuation-v1"
            } else {
                "smolbox-held-delete-continuation-v1"
            };
            crate::material::hash(&(domain, intent, request))
        }
    }
}
/// Explicit confirmed absence after an uncertain delete, not an SDK success.
/// The caller must retain this separately from backing/dependency retirement.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchDeletionResolution {
    pub schema: u8,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub deletion_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for BranchDeletionResolution {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchDeletionResolution")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl BranchDeletionResolution {
    pub fn validate(&self) -> Result<()> {
        let mut origin = self.child.clone();
        origin.material = None;
        if self.schema != 1
            || !crate::domain::valid_id(&self.child.target_id)
            || !crate::domain::valid_id(&self.child.name)
            || !crate::domain::valid_hex(&self.child.domain_generation, 32)
            || !crate::domain::valid_hex(&self.child.owner_token, 64)
            || !crate::domain::valid_hex(&self.child.incarnation, 32)
            || !crate::domain::valid_hex(&self.child.material_sha256, 64)
            || self.child.material.as_ref() != Some(&crate::material::root_proof(&origin)?)
            || !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || !crate::domain::valid_hex(&self.deletion_sha256, 64)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > crate::HELD_BRANCH_DELETION_PROOF_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-held-child-delete-resolution-v1",
            self.schema,
            &self.child,
            &self.operation_id,
            &self.request_sha256,
            &self.deletion_sha256,
        ))
    }
    fn issue(
        intent: &Intent,
        operation_id: &str,
        request_sha256: &str,
        continuation: Option<&ContinuationRequest>,
    ) -> Result<Self> {
        let mut proof = Self {
            schema: 1,
            child: intent.receipt().clone(),
            operation_id: operation_id.into(),
            request_sha256: request_sha256.into(),
            deletion_sha256: deletion_digest(intent, continuation)?,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        proof.validate()?;
        Ok(proof)
    }
    fn matches_request(&self, operation_id: &str, request_sha256: &str) -> bool {
        self.operation_id == operation_id && self.request_sha256 == request_sha256
    }
}
/// Acknowledgement of the original collected child's completed deletion continuation.
/// The caller must retain this separately from backing/dependency retirement.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchDeletionContinuation {
    pub schema: u8,
    pub child: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub deletion_sha256: String,
    pub proof_sha256: String,
}
impl std::fmt::Debug for BranchDeletionContinuation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchDeletionContinuation")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl BranchDeletionContinuation {
    pub fn validate(&self) -> Result<()> {
        let mut origin = self.child.clone();
        origin.material = None;
        if self.schema != 1
            || !crate::domain::valid_id(&self.child.target_id)
            || !crate::domain::valid_id(&self.child.name)
            || !crate::domain::valid_hex(&self.child.domain_generation, 32)
            || !crate::domain::valid_hex(&self.child.owner_token, 64)
            || !crate::domain::valid_hex(&self.child.incarnation, 32)
            || !crate::domain::valid_hex(&self.child.material_sha256, 64)
            || self.child.material.as_ref() != Some(&crate::material::root_proof(&origin)?)
            || !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
            || !crate::domain::valid_hex(&self.deletion_sha256, 64)
            || self.proof_sha256 != self.digest()?
            || serde_json::to_vec(self)
                .map_err(|_| Error::before(ErrorCode::Io))?
                .len()
                > crate::HELD_BRANCH_DELETION_PROOF_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-held-child-delete-continuation-proof-v1",
            self.schema,
            &self.child,
            &self.operation_id,
            &self.request_sha256,
            &self.deletion_sha256,
        ))
    }
    fn issue(
        intent: &Intent,
        operation_id: &str,
        request_sha256: &str,
        continuation: Option<&ContinuationRequest>,
    ) -> Result<Self> {
        let mut proof = Self {
            schema: 1,
            child: intent.receipt().clone(),
            operation_id: operation_id.into(),
            request_sha256: request_sha256.into(),
            deletion_sha256: deletion_digest(intent, continuation)?,
            proof_sha256: String::new(),
        };
        proof.proof_sha256 = proof.digest()?;
        proof.validate()?;
        Ok(proof)
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    schema: u8,
    intent: Intent,
    phase: Phase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    resolution: Option<BranchDeletionResolution>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    continuation: Option<ContinuationRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    released_resolution: Option<ReleasedBranchDeletionResolution>,
}
impl Record {
    fn validate(&self) -> Result<()> {
        self.intent.validate()?;
        if self.intent.release.is_some() {
            if self.schema == 6 {
                let request = self
                    .continuation
                    .as_ref()
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                request.validate()?;
                if self.resolution.is_some() {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                return match (&self.phase, &self.released_resolution) {
                    (Phase::Finishing | Phase::Deleting | Phase::Deleted, None) => Ok(()),
                    (Phase::ResolvedAbsent, Some(proof)) => {
                        proof.validate_for_intent(&self.intent, Some(request))
                    }
                    _ => Err(Error::before(ErrorCode::Ownership)),
                };
            }
            if self.schema == 5 && self.phase == Phase::ResolvedAbsent {
                let proof = self
                    .released_resolution
                    .as_ref()
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                proof.validate_for_intent(&self.intent, None)?;
                return if self.resolution.is_none() && self.continuation.is_none() {
                    Ok(())
                } else {
                    Err(Error::before(ErrorCode::Ownership))
                };
            }
            return if self.schema == 4
                && matches!(
                    self.phase,
                    Phase::Collecting | Phase::Collected | Phase::Deleting | Phase::Deleted
                )
                && self.resolution.is_none()
                && self.continuation.is_none()
                && self.released_resolution.is_none()
            {
                Ok(())
            } else {
                Err(Error::before(ErrorCode::Ownership))
            };
        }
        if self.released_resolution.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match (
            self.schema,
            self.phase,
            &self.resolution,
            &self.continuation,
        ) {
            (
                1,
                Phase::Collecting | Phase::Collected | Phase::Deleting | Phase::Deleted,
                None,
                None,
            ) => Ok(()),
            (3, Phase::Finishing | Phase::Deleting | Phase::Deleted, None, Some(request)) => {
                request.validate()
            }
            (2, Phase::ResolvedAbsent, Some(proof), None)
            | (3, Phase::ResolvedAbsent, Some(proof), Some(_)) => {
                if let Some(request) = &self.continuation {
                    request.validate()?;
                }
                proof.validate()?;
                if proof.child != *self.intent.receipt()
                    || proof.deletion_sha256
                        != deletion_digest(&self.intent, self.continuation.as_ref())?
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                Ok(())
            }
            _ => Err(Error::before(ErrorCode::Ownership)),
        }
    }
}
struct Journal {
    domain: Arc<crate::domain::DomainGuard>,
    path: std::path::PathBuf,
}
trait ProtectedRecord: Serialize + serde::de::DeserializeOwned {
    const MAX_RECORD_BYTES: u64 = MAX_BYTES;
    fn validate_for(&self, journal: &Journal, bytes: u64) -> Result<()>;
}
impl ProtectedRecord for Record {
    fn validate_for(&self, journal: &Journal, bytes: u64) -> Result<()> {
        self.validate()?;
        if (self.schema == 1 && bytes > LEGACY_BYTES)
            || (self.schema < 4 && bytes > LEGACY_EXTENDED_BYTES)
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        if Journal::new(journal.domain.clone(), self.intent.receipt())?.path != journal.path {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Journal {
    fn new(domain: Arc<crate::domain::DomainGuard>, receipt: &CreationReceipt) -> Result<Self> {
        let mut origin = receipt.clone();
        origin.material = None;
        let hash_domain =
            if receipt.material.as_ref() == Some(&crate::material::root_proof(&origin)?) {
                "smolbox-held-child-delete-v1"
            } else {
                "smolbox-released-child-delete-v1"
            };
        let key = crate::material::hash(&(hash_domain, receipt))?;
        let path = domain.directory.join(format!("branch-delete-{key}.json"));
        Ok(Self { domain, path })
    }
    fn read(&self) -> Result<(Record, Version)> {
        self.read_record()
    }
    fn read_record<T: ProtectedRecord>(&self) -> Result<(T, Version)> {
        self.domain.verify()?;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&self.path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let info = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if !info.is_file()
            || info.nlink() != 1
            || info.uid() != unsafe { libc::geteuid() }
            || info.mode() & 0o777 != 0o600
            || info.len() > T::MAX_RECORD_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let version = Version::of(&info);
        let mut bytes = Vec::new();
        std::io::Read::by_ref(&mut file)
            .take(T::MAX_RECORD_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > T::MAX_RECORD_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        let record: T =
            serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
        record.validate_for(self, bytes.len() as u64)?;
        if Version::of(&file.metadata().map_err(|_| Error::before(ErrorCode::Io))?) != version
            || Version::of(
                &std::fs::symlink_metadata(&self.path)
                    .map_err(|_| Error::before(ErrorCode::Ownership))?,
            ) != version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.domain.verify()?;
        Ok((record, version))
    }
    fn write(&self, record: &Record, previous: Option<Version>) -> Result<()> {
        self.write_record(record, previous)
    }
    fn write_record<T: ProtectedRecord>(
        &self,
        record: &T,
        previous: Option<Version>,
    ) -> Result<()> {
        self.domain.verify()?;
        let bytes = serde_json::to_vec(record).map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > T::MAX_RECORD_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        record.validate_for(self, bytes.len() as u64)?;
        let mut file = tempfile::NamedTempFile::new_in(&self.domain.directory)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        file.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))
            .and_then(|()| file.write_all(&bytes))
            .and_then(|()| file.as_file().sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        self.domain.verify()?;
        if let Some(previous) = previous {
            if self.read_record::<T>()?.1 != previous {
                return Err(Error::before(ErrorCode::Ownership));
            }
            file.persist(&self.path)
                .map_err(|_| Error::before(ErrorCode::Io))?;
        } else {
            file.persist_noclobber(&self.path)
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
        }
        File::open(&self.domain.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        self.domain.verify()
    }
    fn enter(&self, intent: &Intent) -> Result<()> {
        self.write(
            &Record {
                schema: if intent.release.is_some() { 4 } else { 1 },
                intent: intent.clone(),
                phase: Phase::Collecting,
                resolution: None,
                continuation: None,
                released_resolution: None,
            },
            None,
        )
    }
    fn advance(&self, intent: &Intent, before: Phase, after: Phase) -> Result<()> {
        if !matches!(
            (before, after),
            (Phase::Collecting, Phase::Collected)
                | (Phase::Collected | Phase::Finishing, Phase::Deleting)
                | (Phase::Deleting, Phase::Deleted)
        ) {
            return Err(Error::before(ErrorCode::State));
        }
        let (mut record, version) = self.read()?;
        if record.intent != *intent || record.phase != before {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        record.phase = after;
        self.write(&record, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
    fn collected(&self, intent: &Intent, proof: &crate::epoch::BootCollection) -> Result<()> {
        intent.collected(proof)?;
        self.advance(intent, Phase::Collecting, Phase::Collected)
    }
    fn deleted(&self, intent: &Intent, proof: &Absence) -> Result<()> {
        if proof.intent_sha256 != crate::material::hash(intent)? {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        self.advance(intent, Phase::Deleting, Phase::Deleted)
    }
    fn resolve_absent(
        &self,
        intent: &Intent,
        operation_id: &str,
        request_sha256: &str,
        absence: &Absence,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionResolution> {
        intent.require_held()?;
        let (mut record, version) = self.read()?;
        if record.intent != *intent
            || !matches!(
                record.phase,
                Phase::Collecting
                    | Phase::Collected
                    | Phase::Deleting
                    | Phase::Finishing
                    | Phase::Deleted
            )
            || absence.intent_sha256 != crate::material::hash(intent)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let proof = BranchDeletionResolution::issue(
            intent,
            operation_id,
            request_sha256,
            record.continuation.as_ref(),
        )?;
        record.schema = if record.continuation.is_some() { 3 } else { 2 };
        record.phase = Phase::ResolvedAbsent;
        record.resolution = Some(proof.clone());
        budget.check()?;
        self.write(&record, Some(version))
            .map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
}
struct Absence {
    intent_sha256: String,
}
fn absence(
    intent: &Intent,
    collection: &crate::epoch::BootCollection,
    database: &std::path::Path,
    identity: (u64, u64),
    budget: &ReadBudget,
) -> Result<Absence> {
    budget.check()?;
    intent.collected(collection)?;
    let parent = intent
        .plan
        .child
        .path
        .parent()
        .ok_or(Error::uncertain(ErrorCode::Ownership))?;
    crate::host::unredirected(parent)?;
    if !crate::sdk_compat::observe_absence_budget(
        database,
        identity,
        &intent.receipt().name,
        budget,
        || match std::fs::symlink_metadata(&intent.plan.child.path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
            Err(_) => Err(Error::uncertain(ErrorCode::Io)),
            Ok(_) => Ok(false),
        },
    )? {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    budget.check().map_err(|e| Error::uncertain(e.code))?;
    Ok(Absence {
        intent_sha256: crate::material::hash(intent)?,
    })
}
struct Leases {
    _gates: [crate::gate::MachineLease; 2],
    _root: crate::export_source::Root,
    source: Option<crate::sdk_compat::SourceLease>,
    _work: crate::jobs::JobLease,
}
pub(crate) struct Retained {
    intent: Intent,
    worker: Weak<()>,
    leases: Option<Leases>,
    completion: Option<Completion>,
    continuation: Option<ContinuationRequest>,
    cleanup: Option<ContinuationRequest>,
    collection: Option<collection::RetainedCollection>,
    _metadata: crate::jobs::BranchBackingLease,
    _release_metadata: Option<crate::jobs::BranchBackingLease>,
    _cleanup_metadata: Option<crate::jobs::BranchBackingLease>,
    _collection_metadata: crate::jobs::BranchBackingLease,
}
enum Completion {
    Deleted,
    Resolved(Box<BranchDeletionResolution>),
    ReleasedResolved(Box<ReleasedBranchDeletionResolution>),
}
impl Retained {
    fn import_completion(&mut self, record: Record) -> Result<bool> {
        if record.intent != self.intent {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let completion = match record.phase {
            Phase::Deleted => Some(Completion::Deleted),
            Phase::ResolvedAbsent => match record.released_resolution {
                Some(proof) => Some(Completion::ReleasedResolved(Box::new(proof))),
                None => record
                    .resolution
                    .map(|proof| Completion::Resolved(Box::new(proof))),
            },
            _ => None,
        };
        if completion.is_none() {
            return Ok(false);
        }
        if let Some(request) = &self.cleanup {
            if !matches!(&completion, Some(Completion::Resolved(proof))
                if proof.matches_request(&request.operation_id, &request.request_sha256))
                && !matches!(&completion, Some(Completion::ReleasedResolved(proof))
                    if proof.matches_request(&request.operation_id, &request.request_sha256))
            {
                return Err(Error::before(ErrorCode::Conflict));
            }
        }
        if self
            .continuation
            .as_ref()
            .is_some_and(|request| record.continuation.as_ref() != Some(request))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.continuation = record.continuation;
        self.completion = completion;
        Ok(true)
    }
    fn retire_transient(&mut self) -> Result<()> {
        self.check_returned(self.intent.receipt())?;
        if self.completion.is_none() {
            return Err(Error::uncertain(ErrorCode::State));
        }
        self.leases.take();
        Ok(())
    }
    fn check_returned(&self, receipt: &CreationReceipt) -> Result<()> {
        if self.intent.receipt() != receipt {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if self.worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        Ok(())
    }
    fn completed(&mut self, journal: &Journal, receipt: &CreationReceipt) -> Result<()> {
        self.check_returned(receipt)?;
        if self.completion.is_none() {
            let (record, _) = journal.read().map_err(|e| Error::uncertain(e.code))?;
            if !self
                .import_completion(record)
                .map_err(|e| Error::uncertain(e.code))?
            {
                return Err(Error::uncertain(ErrorCode::State));
            }
        }
        Ok(())
    }
    fn recorded_resolution(
        &mut self,
        journal: &Journal,
        child: &CreationReceipt,
        operation_id: &str,
        request_sha256: &str,
        budget: &ReadBudget,
    ) -> Result<Option<BranchDeletionResolution>> {
        if self.cleanup.as_ref().is_some_and(|request| {
            request.operation_id != operation_id || request.request_sha256 != request_sha256
        }) {
            return Err(Error::before(ErrorCode::Conflict));
        }
        self.check_returned(child)?;
        if self.completion.is_none() || matches!(self.completion, Some(Completion::Deleted)) {
            let (record, version) = journal.read()?;
            if let Some(proof) = &record.resolution {
                if !proof.matches_request(operation_id, request_sha256) {
                    return Err(Error::before(ErrorCode::Conflict));
                }
                journal.sync_record::<Record>(&version, budget)?;
            }
            if !self.import_completion(record)? {
                return Ok(None);
            }
        }
        match &self.completion {
            Some(Completion::Resolved(proof))
                if proof.matches_request(operation_id, request_sha256) =>
            {
                Ok(Some((**proof).clone()))
            }
            Some(Completion::Resolved(_)) => Err(Error::before(ErrorCode::Conflict)),
            Some(Completion::Deleted) => Ok(None),
            _ => Err(Error::before(ErrorCode::State)),
        }
    }
    fn resolve(
        &mut self,
        journal: &Journal,
        child: &CreationReceipt,
        operation_id: &str,
        request_sha256: &str,
        authority: ResolutionAuthority<'_>,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionResolution> {
        if let Some(proof) =
            self.recorded_resolution(journal, child, operation_id, request_sha256, budget)?
        {
            return Ok(proof);
        }
        if self.leases.is_none() && !matches!(self.completion, Some(Completion::Deleted)) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let collection = authority
            .epoch
            .collect_enrolled(&child.name, authority.enrollment)?;
        let absent = absence(
            &self.intent,
            &collection,
            authority.database,
            authority.identity,
            budget,
        )?;
        let proof =
            journal.resolve_absent(&self.intent, operation_id, request_sha256, &absent, budget)?;
        self.completion = Some(Completion::Resolved(Box::new(proof.clone())));
        // A late publication remains retained for exact recorded lookup.
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(proof)
    }
}
struct ResolutionAuthority<'a> {
    epoch: &'a crate::epoch::ActorEpoch,
    enrollment: &'a crate::epoch::BootEnrollment,
    database: &'a std::path::Path,
    identity: (u64, u64),
}
fn stopped_record(
    intent: &Intent,
    record: &smolvm::config::VmRecord,
    collection: &crate::epoch::BootCollection,
    budget: &ReadBudget,
) -> Result<smolvm::config::VmRecord> {
    budget.check()?;
    intent.collected(collection)?;
    verify_original_record(intent, record, budget)?;
    let mut stopped = record.clone();
    stopped.state = smolvm::config::RecordState::Stopped;
    stopped.pid = None;
    stopped.pid_start_time = None;
    budget.check()?;
    Ok(stopped)
}
fn verify_original_record(
    intent: &Intent,
    record: &smolvm::config::VmRecord,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check()?;
    intent.plan.verify()?;
    let allowed = match record.state {
        smolvm::config::RecordState::Running => {
            record.pid.zip(record.pid_start_time) == Some((intent.child.pid, intent.child.birth))
        }
        smolvm::config::RecordState::Stopped => {
            record.pid.is_none() && record.pid_start_time.is_none()
        }
        _ => false,
    };
    if !allowed
        || record.forkpoint_held != intent.release.is_none()
        || !intent.receipt().matches(record)?
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    crate::machine::verify_branch_marker(intent.receipt(), &intent.plan.child.path)?;
    let material = crate::material::MaterialJournal::at(&intent.plan.child.path);
    material.verify(intent.receipt())?;
    material.verify_branch_child(intent.receipt(), record)?;
    if let Some(release) = &intent.release {
        release.verify_record(record)?;
    }
    budget.check()
}
/// One final deletion step, shared by ordinary deletion and explicit continued
/// cleanup. Tests supply private row/file results; only the controller supplies SDK.
struct CollectedDeletion<'a> {
    journal: &'a Journal,
    authority: ResolutionAuthority<'a>,
    budget: &'a ReadBudget,
}
impl CollectedDeletion<'_> {
    fn finish(
        &self,
        state: &mut Retained,
        before: Phase,
        delete: impl FnOnce() -> Result<()>,
    ) -> Result<()> {
        if !matches!(before, Phase::Collected | Phase::Finishing) || state.leases.is_none() {
            return Err(Error::before(ErrorCode::State));
        }
        let intent = state.intent.clone();
        let name = &intent.receipt().name;
        let collection = self
            .authority
            .epoch
            .collect_enrolled(name, self.authority.enrollment)?;
        let row = crate::sdk_compat::observe_record(
            self.authority.database,
            self.authority.identity,
            name,
            self.budget,
        )?
        .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if row.state != smolvm::config::RecordState::Stopped
            || row.pid.is_some()
            || row.pid_start_time.is_some()
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        stopped_record(&intent, &row, &collection, self.budget)?;
        crate::sdk_compat::stopped_branch_deletion_cache(&intent.plan.child.path)?;
        // Runtime deletion reads SDK dependencies. Recheck bounded inventory
        // under this fresh cleanup budget before entering that convenience API.
        if !crate::sdk_compat::source_dependents(
            self.authority.database,
            self.authority.identity,
            name,
            self.budget,
        )?
        .is_empty()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let (record, _) = self.journal.read()?;
        if record.continuation != state.continuation {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        self.budget.check()?;
        self.journal.advance(&intent, before, Phase::Deleting)?;
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        // SDK Runtime deletion acquires its own source lock; keep original
        // SmolBox gates/work and close only the outer SDK lock before entry.
        state.leases.as_mut().unwrap().source.take();
        delete().map_err(|e| Error::uncertain(e.code))?;
        let collection = self
            .authority
            .epoch
            .collect_enrolled(name, self.authority.enrollment)?;
        let proof = absence(
            &intent,
            &collection,
            self.authority.database,
            self.authority.identity,
            self.budget,
        )?;
        self.journal.deleted(&intent, &proof)?;
        state.completion = Some(Completion::Deleted);
        Ok(())
    }
}
impl Engine {
    /// Resolve entered deletion by positively observing original-child collection
    /// and absence. No SDK shutdown/delete call, adoption or backing retirement.
    /// The bridge must fence its old durable/controller requests first.
    pub fn resolve_held_branch_deletion(
        &self,
        child: &CreationReceipt,
        operation_id: &str,
        request_sha256: &str,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionResolution> {
        self.resolve_held_branch_deletion_with_completion(
            child,
            (operation_id, request_sha256),
            quiesced,
            None,
            budget,
        )
    }
    pub(crate) fn resolve_held_branch_deletion_with_completion(
        &self,
        child: &CreationReceipt,
        request: (&str, &str),
        quiesced: bool,
        expected: Option<&crate::BranchCompletion>,
        budget: &ReadBudget,
    ) -> Result<BranchDeletionResolution> {
        let (operation_id, request_sha256) = request;
        if !quiesced
            || !crate::domain::valid_id(operation_id)
            || !crate::domain::valid_hex(request_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        budget.check()?;
        child.validate(self.binding())?;
        let _control = self
            .jobs
            .acquire(crate::jobs::Demand::material_resolution())?;
        let context = self.retained_branch_context(child)?;
        if let Some(expected) = expected {
            let original = self.branch_retention.completed_context_exact(expected)?;
            if !Arc::ptr_eq(&original, &context) {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        let journal = Journal::new(self.domain.clone(), child)?;
        let mut retained = context
            .deletion
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let state = retained.as_mut().ok_or(Error::before(ErrorCode::State))?;
        state.intent.require_held()?;
        let proof = match state.recorded_resolution(
            &journal,
            child,
            operation_id,
            request_sha256,
            budget,
        )? {
            Some(proof) => proof,
            None => {
                self.verify_database_identity()?;
                // Ordinary completion already retired its leases. Pin the
                // same pair again while proving current absence.
                let source_name = &context.plan.publication.previous.name;
                let _fresh_gates = if state.leases.is_none() {
                    let source_gate = self.observation_gate(source_name)?;
                    let child_gate = self.observation_gate(&child.name)?;
                    Some(
                        crate::gate::lock_pair(
                            (source_name, &source_gate),
                            (&child.name, &child_gate),
                        )
                        .map_err(|()| Error::before(ErrorCode::Conflict))?,
                    )
                } else {
                    None
                };
                let epoch = self.collection_epoch()?;
                if state.intent.plan != context.plan
                    || state.intent.boot != *context.enrollment.intent()
                    || state.intent.child != context.enrollment.child()
                    || state.intent.identity_sha256 != context.identity_sha256
                    || !epoch.bound_to(self.binding())
                    || !context
                        .enrollment
                        .intent()
                        .matches_epoch(&child.name, epoch)
                    || context._runtime.pid(&child.name).is_some()
                    || context
                        .manager
                        .try_lock()
                        .map_err(|_| Error::before(ErrorCode::Conflict))?
                        .child_pid()
                        .is_some()
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                state.resolve(
                    &journal,
                    child,
                    operation_id,
                    request_sha256,
                    ResolutionAuthority {
                        epoch,
                        enrollment: &context.enrollment,
                        database: &self.binding().database,
                        identity: self.database_identity,
                    },
                    budget,
                )?
            }
        };
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        drop(retained);
        // The retained original gates stay held until cache retirement succeeds.
        if !self.known_branch_deletion(&context, &journal, child)? {
            return Err(Error::uncertain(ErrorCode::State));
        }
        Ok(proof)
    }
    /// Explicit deletion only: ordinary held-child stop/start remain forbidden.
    /// The original child must have completed held initialization and handoff.
    pub fn delete_held_branch(
        &self,
        child: &CreationReceipt,
        budget: &ReadBudget,
    ) -> Result<Observation> {
        self.delete_original_branch(child, budget, true)
    }
    /// Delete a handed-off released child under retained original completion.
    /// A normally retired manager requires canonical stopped state and positive
    /// original epoch collection. Replacement helper owners stay separate.
    pub fn delete_released_branch(
        &self,
        child: &CreationReceipt,
        budget: &ReadBudget,
    ) -> Result<Observation> {
        self.delete_original_branch(child, budget, false)
    }
    fn delete_original_branch(
        &self,
        child: &CreationReceipt,
        budget: &ReadBudget,
        held: bool,
    ) -> Result<Observation> {
        let context = self.retained_branch_context(child)?;
        if (child == context.plan.publication.child()) != held {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let journal = Journal::new(self.domain.clone(), child)?;
        if self.known_branch_deletion(&context, &journal, child)? {
            return Ok(missing());
        }
        budget.check()?;
        self.binding().validate()?;
        self.verify_database_identity()?;
        self.branch_deletion_owner(child, &context, held)?;
        let work = self.jobs.acquire(crate::jobs::Demand::branch_delete())?;
        let metadata = self.jobs.branch_result_metadata()?;
        // Collection recovery must remain available under quarantine, without
        // asking the ordinary metadata pool for capacity after SDK entry.
        let collection_metadata = self.jobs.branch_result_metadata()?;
        let release_metadata = if held {
            None
        } else {
            Some(self.jobs.branch_result_metadata()?)
        };
        // Reserve the independent released cleanup ledger before uncertainty:
        // ordinary metadata admission is unavailable while quarantined.
        let cleanup_metadata = if held {
            None
        } else {
            Some(self.jobs.branch_result_metadata()?)
        };
        let source_name = &context.plan.publication.previous.name;
        let source_gate = self.gate(source_name)?;
        let child_gate = self.gate(&child.name)?;
        let gates = crate::gate::lock_pair((source_name, &source_gate), (&child.name, &child_gate))
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let original_manager = self.branch_deletion_owner(child, &context, held)?;
        let source = self.source_lease(child)?;
        let epoch = self.boot_epoch()?.clone();
        context.plan.verify()?;
        let (expected, actual_held, release) = crate::branch_boot::Lifecycle::at(
            &context.plan.child.path,
        )
        .finish_record(&context.plan, &context.enrollment, &context.identity_sha256)?;
        if actual_held != held || child != &expected {
            return Err(Error::before(ErrorCode::Ownership));
        }
        released::release_ready(&context, release.as_ref())?;
        let before = self
            .observation_record(&child.name, budget)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.verify_record(child, &before)?;
        if before.forkpoint_held != held
            || (original_manager
                && before.pid.zip(before.pid_start_time)
                    != Some((
                        context.enrollment.child().pid,
                        context.enrollment.child().birth,
                    )))
            || !epoch.bound_to(self.binding())
            || !context
                .enrollment
                .intent()
                .matches_epoch(&child.name, &epoch)
            || !crate::sdk_compat::source_dependents(
                &self.binding().database,
                self.database_identity,
                &child.name,
                budget,
            )?
            .is_empty()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut nonce = [0; 16];
        getrandom::fill(&mut nonce).map_err(|_| Error::before(ErrorCode::Native))?;
        let intent = Intent {
            plan: context.plan.clone(),
            boot: context.enrollment.intent().clone(),
            child: context.enrollment.child(),
            identity_sha256: context.identity_sha256.clone(),
            nonce: hex::encode(nonce),
            release,
        };
        intent.validate()?;
        if !original_manager {
            collected::collected_before(
                &intent,
                &before,
                ResolutionAuthority {
                    epoch: &epoch,
                    enrollment: &context.enrollment,
                    database: &self.binding().database,
                    identity: self.database_identity,
                },
                budget,
            )?;
        }
        let active = Arc::new(());
        let pinned_root = crate::export_source::Root::open(&context.plan.child.path)?;
        if crate::branch_boot::Directory::capture(&pinned_root)? != context.plan.child {
            return Err(Error::before(ErrorCode::Ownership));
        }
        {
            let mut retained = context
                .deletion
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if retained.is_some() {
                return Err(Error::before(ErrorCode::Conflict));
            }
            budget.check()?;
            *retained = Some(Box::new(Retained {
                intent: intent.clone(),
                worker: Arc::downgrade(&active),
                leases: Some(Leases {
                    _gates: gates,
                    _root: pinned_root,
                    source: Some(source),
                    _work: work,
                }),
                completion: None,
                continuation: None,
                cleanup: None,
                collection: None,
                _metadata: metadata,
                _release_metadata: release_metadata,
                _cleanup_metadata: cleanup_metadata,
                _collection_metadata: collection_metadata,
            }));
        }
        journal
            .enter(&intent)
            .map_err(|e| Error::uncertain(e.code))?;
        let application = Application {
            context: context.clone(),
            epoch,
            journal,
            before,
            database: self.binding().database.clone(),
            identity: self.database_identity,
            db: self.db.clone(),
            budget: budget.clone(),
        };
        crate::oci_start::observe_owned(
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
        let journal = Journal::new(self.domain.clone(), child)?;
        if !self.known_branch_deletion(&context, &journal, child)? {
            return Err(Error::uncertain(ErrorCode::State));
        }
        Ok(missing())
    }
    fn known_branch_deletion(
        &self,
        context: &Arc<Context>,
        journal: &Journal,
        child: &CreationReceipt,
    ) -> Result<bool> {
        let mut retained = context
            .deletion
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let Some(retained) = retained.as_mut() else {
            return Ok(false);
        };
        retained.completed(journal, child)?;
        self.retire_deleted_branch_handle(child, context)?;
        retained.retire_transient()?;
        Ok(true)
    }
}
struct Application {
    context: Arc<Context>,
    epoch: crate::epoch::ActorEpoch,
    journal: Journal,
    before: smolvm::config::VmRecord,
    database: std::path::PathBuf,
    identity: (u64, u64),
    db: smolvm::db::SmolvmDb,
    budget: ReadBudget,
}
impl Application {
    fn run(self) -> Result<()> {
        let mut retained = self
            .context
            .deletion
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        let state = retained
            .as_mut()
            .ok_or(Error::uncertain(ErrorCode::State))?;
        let intent = state.intent.clone();
        let name = &intent.receipt().name;
        let (entered, _) = self.journal.read()?;
        if entered.intent != intent || entered.phase != Phase::Collecting {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        self.context
            .require_no_runtime_boot()
            .map_err(|e| Error::uncertain(e.code))?;
        self.context.plan.verify()?;
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        let current =
            crate::sdk_compat::observe_record(&self.database, self.identity, name, &self.budget)?
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        let before_sha256 = crate::material::hash(&self.before)?;
        if crate::material::hash(&current)? != before_sha256 {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let collection = self
            .context
            .collect_original(&self.epoch, &self.budget)
            .map_err(|e| Error::uncertain(e.code))?;
        self.journal.collected(&intent, &collection)?;
        let mut changed = false;
        self.db
            .update_vm(name, |row| {
                if crate::material::hash(row).ok().as_ref() == Some(&before_sha256) {
                    row.state = smolvm::config::RecordState::Stopped;
                    row.pid = None;
                    row.pid_start_time = None;
                    changed = true;
                }
            })
            .map_err(|_| Error::uncertain(ErrorCode::Database))?;
        let stopped =
            crate::sdk_compat::observe_record(&self.database, self.identity, name, &self.budget)?
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if !changed
            || !intent.receipt().matches(&stopped)?
            || stopped.state != smolvm::config::RecordState::Stopped
            || stopped.pid.is_some()
            || stopped.pid_start_time.is_some()
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        CollectedDeletion {
            journal: &self.journal,
            authority: ResolutionAuthority {
                epoch: &self.epoch,
                enrollment: &self.context.enrollment,
                database: &self.database,
                identity: self.identity,
            },
            budget: &self.budget,
        }
        .finish(state, Phase::Collected, || {
            if smolvm::agent::vm_data_dir(name) != self.context.plan.child.path {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            self.context
                ._runtime
                .delete_machine(name)
                .map_err(|_| Error::uncertain(ErrorCode::Native))
        })?;
        Ok(())
    }
}
fn missing() -> Observation {
    Observation {
        state: ObservedState::Missing,
        resources: None,
        pid_identity: None,
        configuration: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch_boot::tests::{identity_model, IdentityModel};

    pub(super) fn budget() -> ReadBudget {
        ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap()
    }
    // Protected file/row/accounting models only. No manager, guest or SDK delete.
    pub(super) fn fixture() -> (IdentityModel, crate::epoch::ActorEpoch, Intent, Journal) {
        let model = identity_model(true);
        crate::branch_boot::Lifecycle::at(&model.plan.child.path)
            .finish_record(&model.plan, &model.enrollment, &model.identity_sha256)
            .unwrap();
        let epoch = model.actors.clone();
        let intent = Intent {
            plan: model.plan.clone(),
            boot: model.enrollment.intent().clone(),
            child: model.enrollment.child(),
            identity_sha256: model.identity_sha256.clone(),
            nonce: "a".repeat(32),
            release: None,
        };
        let journal = Journal::new(model.engine.domain.clone(), intent.receipt()).unwrap();
        (model, epoch, intent, journal)
    }
    pub(super) fn retained(model: &IdentityModel, intent: &Intent) -> Retained {
        let source = model
            .engine
            .observation_gate(&intent.plan.publication.previous.name)
            .unwrap();
        let child = model
            .engine
            .observation_gate(&intent.receipt().name)
            .unwrap();
        Retained {
            intent: intent.clone(),
            worker: Weak::new(),
            completion: None,
            continuation: None,
            cleanup: None,
            collection: None,
            leases: Some(Leases {
                _root: crate::export_source::Root::open(&intent.plan.child.path).unwrap(),
                _gates: crate::gate::lock_pair(
                    (&intent.plan.publication.previous.name, &source),
                    (&intent.receipt().name, &child),
                )
                .unwrap(),
                source: Some(
                    crate::sdk_compat::source_lease(
                        &model.engine.binding().vm_root,
                        &intent.receipt().name,
                    )
                    .unwrap(),
                ),
                _work: model
                    .engine
                    .jobs
                    .acquire(crate::jobs::Demand::branch_delete())
                    .unwrap(),
            }),
            _metadata: model.engine.jobs.branch_result_metadata().unwrap(),
            _collection_metadata: model.engine.jobs.branch_result_metadata().unwrap(),
            _release_metadata: if intent.release.is_some() {
                Some(model.engine.jobs.branch_result_metadata().unwrap())
            } else {
                None
            },
            _cleanup_metadata: if intent.release.is_some() {
                Some(model.engine.jobs.branch_result_metadata().unwrap())
            } else {
                None
            },
        }
    }
    pub(super) fn authority<'a>(
        model: &'a IdentityModel,
        epoch: &'a crate::epoch::ActorEpoch,
    ) -> ResolutionAuthority<'a> {
        ResolutionAuthority {
            epoch,
            enrollment: &model.enrollment,
            database: &model.engine.binding().database,
            identity: model.engine.database_identity,
        }
    }
    const RESOLVE_ID: &str = "resolve-owned-delete";
    fn request() -> String {
        "e".repeat(64)
    }
    #[test]
    fn resolution_requires_quiescence_valid_request_and_original_context_before_admission() {
        let (model, _, intent, journal) = fixture();
        let counts = model.engine.jobs.counts();
        let original = crate::material::hash(&model.record).unwrap();
        for (quiesced, id, hash) in [
            (false, RESOLVE_ID, request()),
            (true, "../invalid", request()),
            (true, RESOLVE_ID, "invalid".into()),
            (true, RESOLVE_ID, request()),
        ] {
            let error = model
                .engine
                .resolve_held_branch_deletion(intent.receipt(), id, &hash, quiesced, &budget())
                .unwrap_err();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(model.engine.jobs.counts(), counts);
        }
        assert!(!journal.path.exists());
        assert_eq!(
            crate::material::hash(&model.engine.record(intent.receipt()).unwrap()).unwrap(),
            original
        );
    }
    #[test]
    fn resolution_rejects_workers_foreign_collection_and_remaining_material_in_each_phase() {
        let (model, epoch, intent, journal) = fixture();
        let mut state = retained(&model, &intent);
        journal.enter(&intent).unwrap();
        let counts = model.engine.jobs.counts();
        let resolve = |state: &mut Retained| {
            state.resolve(
                &journal,
                intent.receipt(),
                RESOLVE_ID,
                &request(),
                authority(&model, &epoch),
                &budget(),
            )
        };
        assert!(resolve(&mut state).is_err());
        assert!(state.retire_transient().is_err());
        let collected = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        journal.collected(&intent, &collected).unwrap();
        assert!(resolve(&mut state).is_err());
        journal
            .advance(&intent, Phase::Collected, Phase::Deleting)
            .unwrap();
        let before = std::fs::read(&journal.path).unwrap();
        let active = Arc::new(());
        state.worker = Arc::downgrade(&active);
        assert_eq!(resolve(&mut state).unwrap_err().code, ErrorCode::Conflict);
        drop(active);
        assert!(resolve(&mut state).is_err()); // Both original row and directory remain.
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        assert!(resolve(&mut state).is_err()); // Directory alone still denies absence.
        std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
        let foreign = identity_model(true);
        assert!(state
            .resolve(
                &journal,
                intent.receipt(),
                RESOLVE_ID,
                &request(),
                ResolutionAuthority {
                    epoch: &foreign.actors,
                    enrollment: &foreign.enrollment,
                    database: &model.engine.binding().database,
                    identity: model.engine.database_identity,
                },
                &budget()
            )
            .is_err());
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(state
            .resolve(
                &journal,
                intent.receipt(),
                RESOLVE_ID,
                &request(),
                authority(&model, &epoch),
                &cancelled
            )
            .is_err());
        assert_eq!(std::fs::read(&journal.path).unwrap(), before);
        assert_eq!(model.engine.jobs.counts(), counts);
        assert!(state.leases.is_some() && state.completion.is_none());
    }
    #[test]
    fn explicit_absence_can_resolve_collection_uncertainty_without_claiming_sdk_deletion() {
        for collected_phase in [false, true] {
            let (model, epoch, intent, journal) = fixture();
            let mut state = retained(&model, &intent);
            journal.enter(&intent).unwrap();
            let collection = epoch
                .collect_enrolled(&intent.receipt().name, &model.enrollment)
                .unwrap();
            if collected_phase {
                journal.collected(&intent, &collection).unwrap();
            }
            // Explicitly disappeared child in a private row/file result model.
            // No shutdown, SDK deletion or live persistence fault is performed.
            model.engine.db.remove_vm(&intent.receipt().name).unwrap();
            std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
            let proof = state
                .resolve(
                    &journal,
                    intent.receipt(),
                    RESOLVE_ID,
                    &request(),
                    authority(&model, &epoch),
                    &budget(),
                )
                .unwrap();
            assert_eq!(journal.read().unwrap().0.resolution, Some(proof));
            assert!(matches!(state.completion, Some(Completion::Resolved(_))));
            assert!(state.leases.is_some() && model.plan.source.path.exists());
        }
    }
    #[test]
    fn resolved_absence_uses_control_while_quarantined_and_keeps_backing_and_exact_history() {
        let (model, epoch, intent, journal) = fixture();
        let pool = &model.engine.jobs;
        // Native admission model only; no real seven-GiB backing is created/disposed.
        let mut creation = pool.acquire(crate::jobs::Demand::branch_source()).unwrap();
        creation.promote_branch_preparation().unwrap();
        creation.promote_branch_backing(7 << 30).unwrap();
        let backing = creation.handoff_branch().unwrap();
        drop(creation);
        let mut state = retained(&model, &intent);
        journal.enter(&intent).unwrap();
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        journal.collected(&intent, &collection).unwrap();
        journal
            .advance(&intent, Phase::Collected, Phase::Deleting)
            .unwrap();
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
        pool.quarantine(); // Pure cancellation-admission model, no running SDK call.
        let control = pool
            .acquire(crate::jobs::Demand::material_resolution())
            .unwrap();
        let observer = pool
            .acquire(crate::jobs::Demand::volume_observation())
            .unwrap();
        let proof = state
            .resolve(
                &journal,
                intent.receipt(),
                RESOLVE_ID,
                &request(),
                authority(&model, &epoch),
                &budget(),
            )
            .unwrap();
        proof.validate().unwrap();
        assert_eq!(proof.child, *intent.receipt());
        assert_eq!(
            proof.deletion_sha256,
            crate::material::hash(&intent).unwrap()
        );
        let (record, _) = journal.read().unwrap();
        assert!(record.schema == 2 && record.phase == Phase::ResolvedAbsent);
        assert_eq!(record.resolution, Some(proof.clone()));
        assert_eq!(pool.counts().work, 1); // Completion alone does not retire retained gates.
        state.completed(&journal, intent.receipt()).unwrap();
        assert!(state.leases.is_some());
        state.retire_transient().unwrap(); // Model of caller acknowledgement after cache retirement.
        assert_eq!(pool.counts().work, 0);
        assert_eq!(pool.counts().checkpoint_material, 7 << 30);
        assert_eq!(
            pool.counts().branch_metadata,
            3 * crate::jobs::BRANCH_BACKING_METADATA
        );
        assert!(!pool.available()); // Resolving this child never unquarantines unrelated authority.
        let bytes = std::fs::read(&journal.path).unwrap();
        state.completion = None; // Exact journal recovery of a lost result, no SDK work.
        assert_eq!(
            state
                .recorded_resolution(
                    &journal,
                    intent.receipt(),
                    RESOLVE_ID,
                    &request(),
                    &budget()
                )
                .unwrap(),
            Some(proof.clone())
        );
        assert!(state
            .recorded_resolution(
                &journal,
                intent.receipt(),
                "another-resolution",
                &request(),
                &budget()
            )
            .is_err());
        assert!(state
            .recorded_resolution(
                &journal,
                intent.receipt(),
                RESOLVE_ID,
                &"f".repeat(64),
                &budget()
            )
            .is_err());
        assert_eq!(std::fs::read(&journal.path).unwrap(), bytes);
        std::fs::rename(
            &journal.path,
            journal.path.with_extension("saved-resolution-model"),
        )
        .unwrap();
        assert_eq!(
            state
                .recorded_resolution(
                    &journal,
                    intent.receipt(),
                    RESOLVE_ID,
                    &request(),
                    &budget()
                )
                .unwrap(),
            Some(proof)
        );
        assert!(model.plan.source.path.exists() && model.plan.snapshot.path.exists());
        drop((control, observer, backing)); // Accounting teardown only, no disposal claim.
    }
    #[test]
    fn resolution_proof_and_record_versions_reject_conversion_corruption_and_legacy_widening() {
        let (model, epoch, intent, journal) = fixture();
        journal.enter(&intent).unwrap();
        let legacy = std::fs::read(&journal.path).unwrap();
        assert!(!std::str::from_utf8(&legacy)
            .unwrap()
            .contains("\"resolution\""));
        let mut padded = legacy.clone();
        padded.resize(LEGACY_BYTES as usize + 1, b' ');
        std::fs::write(&journal.path, &padded).unwrap();
        assert!(journal.read().is_err());
        std::fs::write(&journal.path, &legacy).unwrap();
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        journal.collected(&intent, &collection).unwrap();
        journal
            .advance(&intent, Phase::Collected, Phase::Deleting)
            .unwrap();
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
        let absent = absence(
            &intent,
            &collection,
            &model.engine.binding().database,
            model.engine.database_identity,
            &budget(),
        )
        .unwrap();
        let proof = journal
            .resolve_absent(&intent, RESOLVE_ID, &request(), &absent, &budget())
            .unwrap();
        for case in 0..6 {
            let mut changed = proof.clone();
            match case {
                0 => changed.schema = 2,
                1 => changed.operation_id.clear(),
                2 => changed.request_sha256 = "bad".into(),
                3 => changed.deletion_sha256 = "f".repeat(64),
                4 => changed.child.owner_token = "f".repeat(64),
                _ => changed.proof_sha256 = "f".repeat(64),
            }
            assert!(changed.validate().is_err());
        }
        let (record, version) = journal.read().unwrap();
        let mut wrong = record.clone();
        wrong.schema = 1;
        assert!(wrong.validate().is_err());
        wrong = record.clone();
        wrong.phase = Phase::Deleted;
        assert!(wrong.validate().is_err());
        wrong = record.clone();
        wrong.resolution = None;
        assert!(wrong.validate().is_err());
        wrong = record.clone();
        let changed = wrong.resolution.as_mut().unwrap();
        changed.deletion_sha256 = "f".repeat(64);
        changed.proof_sha256 = changed.digest().unwrap();
        changed.validate().unwrap(); // Self-consistent proof still cannot cross the protected intent.
        assert!(wrong.validate().is_err());
        let mut padded = serde_json::to_vec(&record).unwrap();
        padded.resize(LEGACY_BYTES as usize + 1, b' ');
        std::fs::write(&journal.path, &padded).unwrap();
        journal.read().unwrap(); // Schema two funds its bounded extra result bytes.
        padded.resize(MAX_BYTES as usize + 1, b' ');
        std::fs::write(&journal.path, &padded).unwrap();
        assert!(journal.read().is_err());
        assert!(journal.write(&record, Some(version)).is_err());
    }
    #[test]
    fn held_deletion_cannot_reconstruct_an_original_manager_from_rows_or_receipts() {
        let (model, _, intent, _) = fixture();
        let before = crate::material::hash(&model.record).unwrap();
        let counts = model.engine.jobs.counts();
        assert_eq!(
            model
                .engine
                .delete_held_branch(intent.receipt(), &budget())
                .unwrap_err()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        assert!(model.engine.stop(intent.receipt()).is_err());
        assert!(model
            .engine
            .delete_with_budget(intent.receipt(), &budget())
            .is_err());
        assert_eq!(model.engine.jobs.counts(), counts);
        assert_eq!(
            crate::material::hash(&model.engine.record(intent.receipt()).unwrap()).unwrap(),
            before
        );
        assert!(model.plan.child.path.exists());
    }
    #[test]
    fn original_collection_then_exact_database_and_directory_absence_precede_delete_completion() {
        let (model, epoch, intent, journal) = fixture();
        journal.enter(&intent).unwrap();
        assert!(journal
            .advance(&intent, Phase::Collected, Phase::Deleting)
            .is_err());
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        let mut crossed = intent.clone();
        crossed.child.birth += 1;
        assert!(journal.collected(&crossed, &collection).is_err());
        journal.collected(&intent, &collection).unwrap();
        assert!(absence(
            &intent,
            &collection,
            &model.engine.binding().database,
            model.engine.database_identity,
            &budget()
        )
        .is_err());
        journal
            .advance(&intent, Phase::Collected, Phase::Deleting)
            .unwrap();
        // Deliberate private row/file result model, not an SDK cleanup witness.
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        assert!(absence(
            &intent,
            &collection,
            &model.engine.binding().database,
            model.engine.database_identity,
            &budget()
        )
        .is_err());
        std::fs::remove_dir_all(&model.plan.child.path).unwrap();
        let proof = absence(
            &intent,
            &collection,
            &model.engine.binding().database,
            model.engine.database_identity,
            &budget(),
        )
        .unwrap();
        journal.deleted(&intent, &proof).unwrap();
        let (record, _) = journal.read().unwrap();
        assert!(record.phase == Phase::Deleted && record.intent == intent);
        assert!(journal.path.exists()); // Result outlives the deleted SDK directory.
        assert!(model.plan.source.path.exists() && model.plan.snapshot.path.exists());
        let cancelled = budget();
        cancelled.cancel.cancel();
        assert!(absence(
            &intent,
            &collection,
            &model.engine.binding().database,
            model.engine.database_identity,
            &cancelled
        )
        .is_err());
    }
    #[test]
    fn unknown_delete_keeps_original_gates_work_and_metadata_without_replaying() {
        let (model, _, intent, journal) = fixture();
        let source_gate = model
            .engine
            .observation_gate(&intent.plan.publication.previous.name)
            .unwrap();
        let child_gate = model
            .engine
            .observation_gate(&intent.receipt().name)
            .unwrap();
        let gates = crate::gate::lock_pair(
            (&intent.plan.publication.previous.name, &source_gate),
            (&intent.receipt().name, &child_gate),
        )
        .unwrap();
        let mut state = Retained {
            intent: intent.clone(),
            worker: Weak::new(),
            leases: Some(Leases {
                _root: crate::export_source::Root::open(&intent.plan.child.path).unwrap(),
                _gates: gates,
                source: Some(
                    crate::sdk_compat::source_lease(
                        &model.engine.binding().vm_root,
                        &intent.receipt().name,
                    )
                    .unwrap(),
                ),
                _work: model
                    .engine
                    .jobs
                    .acquire(crate::jobs::Demand::branch_delete())
                    .unwrap(),
            }),
            completion: None,
            continuation: None,
            cleanup: None,
            collection: None,
            _metadata: model.engine.jobs.branch_result_metadata().unwrap(),
            _release_metadata: None,
            _cleanup_metadata: None,
            _collection_metadata: model.engine.jobs.branch_result_metadata().unwrap(),
        };
        journal.enter(&intent).unwrap();
        let counts = model.engine.jobs.counts();
        assert_eq!(counts.children, 0);
        assert_eq!(counts.work_descriptors, 24);
        assert_eq!(
            counts.checkpoint_metadata,
            crate::jobs::JOB_CHECKPOINT_METADATA_BYTES
        );
        let bytes = std::fs::read(&journal.path).unwrap();
        for _ in 0..2 {
            assert!(state.completed(&journal, intent.receipt()).is_err());
            assert_eq!(model.engine.jobs.counts(), counts);
            assert!(source_gate.try_lock().is_err() && child_gate.try_lock().is_err());
        }
        let observers = [
            model
                .engine
                .jobs
                .acquire(crate::jobs::Demand::volume_observation())
                .unwrap(),
            model
                .engine
                .jobs
                .acquire(crate::jobs::Demand::volume_observation())
                .unwrap(),
        ];
        drop(observers);
        assert_eq!(std::fs::read(&journal.path).unwrap(), bytes);
        assert!(state.leases.is_some());
        let mut foreign = intent.receipt().clone();
        foreign.incarnation = "f".repeat(32);
        assert!(state.completed(&journal, &foreign).is_err());
        let active = Arc::new(());
        state.worker = Arc::downgrade(&active);
        state.completion = Some(Completion::Deleted); // Even retained completion cannot bypass a live host worker.
        assert_eq!(
            state
                .completed(&journal, intent.receipt())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
    }
    #[test]
    fn successful_completion_retains_history_metadata_and_never_reenters_sdk_work() {
        let (model, epoch, intent, journal) = fixture();
        journal.enter(&intent).unwrap();
        let collection = epoch
            .collect_enrolled(&intent.receipt().name, &model.enrollment)
            .unwrap();
        journal.collected(&intent, &collection).unwrap();
        journal
            .advance(&intent, Phase::Collected, Phase::Deleting)
            .unwrap();
        model.engine.db.remove_vm(&intent.receipt().name).unwrap();
        std::fs::remove_dir_all(&intent.plan.child.path).unwrap();
        let proof = absence(
            &intent,
            &collection,
            &model.engine.binding().database,
            model.engine.database_identity,
            &budget(),
        )
        .unwrap();
        journal.deleted(&intent, &proof).unwrap();
        let mut state = Retained {
            intent: intent.clone(),
            worker: Weak::new(),
            leases: None,
            completion: None,
            continuation: None,
            cleanup: None,
            collection: None,
            _metadata: model.engine.jobs.branch_result_metadata().unwrap(),
            _release_metadata: None,
            _cleanup_metadata: None,
            _collection_metadata: model.engine.jobs.branch_result_metadata().unwrap(),
        };
        let before = std::fs::read(&journal.path).unwrap();
        for _ in 0..2 {
            state.completed(&journal, intent.receipt()).unwrap();
        }
        assert!(state
            .recorded_resolution(
                &journal,
                intent.receipt(),
                RESOLVE_ID,
                &request(),
                &budget()
            )
            .unwrap()
            .is_none());
        assert_eq!(std::fs::read(&journal.path).unwrap(), before);
        let resolve = |state: &mut Retained| {
            state.resolve(
                &journal,
                intent.receipt(),
                RESOLVE_ID,
                &request(),
                authority(&model, &epoch),
                &budget(),
            )
        };
        std::fs::create_dir(&intent.plan.child.path).unwrap();
        assert!(resolve(&mut state).is_err());
        assert_eq!(std::fs::read(&journal.path).unwrap(), before);
        std::fs::remove_dir(&intent.plan.child.path).unwrap();
        let proof = resolve(&mut state).unwrap();
        let resolved = std::fs::read(&journal.path).unwrap();
        assert_eq!(resolve(&mut state).unwrap(), proof);
        assert_eq!(std::fs::read(&journal.path).unwrap(), resolved);
        assert_eq!(
            model.engine.jobs.counts().branch_metadata,
            2 * crate::jobs::BRANCH_BACKING_METADATA
        );
        assert_eq!(model.engine.jobs.counts().work, 0);
        // Cached exact original result survives later ordinary file retirement.
        std::fs::rename(&journal.path, journal.path.with_extension("saved-model")).unwrap();
        state.completed(&journal, intent.receipt()).unwrap();
        assert!(model.plan.source.path.exists());
    }
    #[test]
    fn protected_delete_record_rejects_crossed_intents_links_modes_and_stale_replacement() {
        let (_model, _, intent, journal) = fixture();
        journal.enter(&intent).unwrap();
        let (record, version) = journal.read().unwrap();
        assert!(journal.enter(&intent).is_err());
        let mut crossed = intent.clone();
        crossed.nonce = "b".repeat(32);
        assert!(journal
            .advance(&crossed, Phase::Collecting, Phase::Collected)
            .is_err());
        journal
            .advance(&intent, Phase::Collecting, Phase::Collected)
            .unwrap();
        assert!(journal.write(&record, Some(version)).is_err());
        std::fs::set_permissions(&journal.path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(journal.read().is_err());
        std::fs::set_permissions(&journal.path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let link = journal.path.with_extension("linked-model");
        std::fs::hard_link(&journal.path, &link).unwrap();
        assert!(journal.read().is_err());
        std::fs::remove_file(&link).unwrap();
        let bytes = std::fs::read(&journal.path).unwrap();
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["unexpected"] = serde_json::json!(true);
        std::fs::write(&journal.path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(journal.read().is_err());
    }
}
