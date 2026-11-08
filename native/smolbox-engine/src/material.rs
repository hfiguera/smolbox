//! Owned evidence for authorized material changes. Inventory cannot create a
//! journal or supply its original receipt. Every SDK mutation remains in Engine.
use crate::domain::{valid_hex, valid_id};
use crate::host::unredirected;
use crate::identity::{material_hash, material_value};
use crate::{CreationReceipt, Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolvm::config::VmRecord;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const FILE_NAME: &str = "smolbox.material-v2.json";
const MAX_BYTES: u64 = 2 * 1024 * 1024;
const MAX_HISTORY: usize = 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MaterialProof {
    pub schema: u8,
    pub revision: u32,
    pub record_sha256: String,
    pub chain_sha256: String,
    pub operation_id: Option<String>,
    pub request_sha256: Option<String>,
}

impl std::fmt::Debug for MaterialProof {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MaterialProof")
            .field("schema", &self.schema)
            .field("revision", &self.revision)
            .finish_non_exhaustive()
    }
}

impl MaterialProof {
    pub fn validate(&self) -> Result<()> {
        let root = self.revision == 0;
        if self.schema != 2
            || self.revision as usize > MAX_HISTORY
            || !valid_hex(&self.record_sha256, 64)
            || !valid_hex(&self.chain_sha256, 64)
            || (root && (self.operation_id.is_some() || self.request_sha256.is_some()))
            || (!root
                && (!self.operation_id.as_deref().is_some_and(valid_id)
                    || !self
                        .request_sha256
                        .as_deref()
                        .is_some_and(|s| valid_hex(s, 64))))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrowDisks {
    pub storage_gib: Option<u64>,
    pub overlay_gib: Option<u64>,
}

impl GrowDisks {
    pub(crate) fn targets(&self, record: &VmRecord) -> Result<(u64, u64)> {
        let storage = record
            .storage_gb
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let overlay = record
            .overlay_gb
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let next_storage = self.storage_gib.unwrap_or(storage);
        let next_overlay = self.overlay_gib.unwrap_or(overlay);
        if self.storage_gib.is_none() && self.overlay_gib.is_none()
            || !(1..=64).contains(&next_storage)
            || !(1..=64).contains(&next_overlay)
            || next_storage < storage
            || next_overlay < overlay
            || (next_storage == storage && next_overlay == overlay)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok((next_storage, next_overlay))
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrowthChange {
    pub operation_id: String,
    pub request: GrowDisks,
    pub previous: MaterialProof,
    pub immutable_sha256: String,
    pub previous_storage_gib: u64,
    pub previous_overlay_gib: u64,
    pub storage_gib: u64,
    pub overlay_gib: u64,
}
impl std::fmt::Debug for GrowthChange {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GrowthChange")
            .field("storage_gib", &self.storage_gib)
            .field("overlay_gib", &self.overlay_gib)
            .finish_non_exhaustive()
    }
}

/// Correlated completed growth evidence; hashes bind semantic history, not a
/// signature or authority obtained from current inventory.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrowthTransition {
    pub schema: u8,
    pub previous: CreationReceipt,
    pub receipt: CreationReceipt,
    pub change: GrowthChange,
}
impl std::fmt::Debug for GrowthTransition {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GrowthTransition")
            .field("schema", &self.schema)
            .field(
                "revision",
                &self.receipt.material.as_ref().map(|proof| proof.revision),
            )
            .finish_non_exhaustive()
    }
}
impl GrowthTransition {
    pub fn validate(&self) -> Result<()> {
        let previous = self
            .previous
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let proof = self
            .receipt
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        proof.validate()?;
        let mut origin = self.previous.clone();
        origin.material = None;
        check_origin(&origin, &self.receipt)?;
        if self.schema != 1
            || !valid_id(&origin.target_id)
            || !valid_hex(&origin.domain_generation, 32)
            || !valid_id(&origin.name)
            || !valid_hex(&origin.owner_token, 64)
            || !valid_hex(&origin.incarnation, 32)
            || !valid_hex(&origin.material_sha256, 64)
            || !valid_change(&self.change)
            || *previous != self.change.previous
            || (previous.revision == 0 && *previous != root_proof(&origin)?)
            || *proof != next_proof(&self.change, proof.record_sha256.clone())?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Completed {
    change: GrowthChange,
    proof: MaterialProof,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    qualified_geometry_sha256: Option<String>,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Stage {
    Prepared,
    Entered,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Pending {
    change: GrowthChange,
    stage: Stage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    geometry: Option<crate::growth::Metadata>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    schema: u8,
    origin: CreationReceipt,
    head: MaterialProof,
    history: Vec<Completed>,
    pending: Option<Pending>,
}

pub(crate) struct MaterialJournal {
    directory: PathBuf,
}

pub(crate) struct Permit {
    change: GrowthChange,
    geometry: Option<crate::growth::Metadata>,
}

impl MaterialJournal {
    pub(crate) fn at(directory: &Path) -> Self {
        Self {
            directory: directory.to_path_buf(),
        }
    }

    /// Called only after Engine's successful fresh create and original marker.
    /// There is deliberately no promote-existing-receipt entry point.
    pub(crate) fn initialize(&self, origin: &CreationReceipt) -> Result<CreationReceipt> {
        if origin.material.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let head = root_proof(origin)?;
        let journal = Journal {
            schema: 2,
            origin: origin.clone(),
            head: head.clone(),
            history: Vec::new(),
            pending: None,
        };
        self.write(&journal, None)?;
        Ok(with_proof(origin, head))
    }

    pub(crate) fn verify(&self, receipt: &CreationReceipt) -> Result<()> {
        match &receipt.material {
            Some(proof) => {
                let (journal, _) = self.load()?;
                check_origin(&journal.origin, receipt)?;
                if journal.head != *proof {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                if journal.pending.is_some() {
                    return Err(Error::before(ErrorCode::State));
                }
                Ok(())
            }
            None => match std::fs::symlink_metadata(self.directory.join(FILE_NAME)) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                _ => Err(Error::before(ErrorCode::Ownership)),
            },
        }
    }

    #[cfg(test)]
    pub(crate) fn prepare(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: GrowDisks,
        record: &VmRecord,
    ) -> Result<Permit> {
        self.prepare_inner(receipt, operation_id, request, record, None)
    }

    pub(crate) fn prepare_geometry(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: GrowDisks,
        record: &VmRecord,
        geometry: &crate::growth::Metadata,
    ) -> Result<Permit> {
        self.prepare_inner(
            receipt,
            operation_id,
            request,
            record,
            Some(geometry.clone()),
        )
    }

    fn prepare_inner(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: GrowDisks,
        record: &VmRecord,
        geometry: Option<crate::growth::Metadata>,
    ) -> Result<Permit> {
        self.verify(receipt)?;
        let (mut journal, inode) = self.load()?;
        if !valid_id(operation_id)
            || journal.history.len() >= MAX_HISTORY
            || journal
                .history
                .iter()
                .any(|entry| entry.change.operation_id == operation_id)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if material_hash(record)? != journal.head.record_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let (storage_gib, overlay_gib) = request.targets(record)?;
        let change = GrowthChange {
            operation_id: operation_id.to_owned(),
            request,
            previous: journal.head.clone(),
            immutable_sha256: immutable_hash(record)?,
            previous_storage_gib: record
                .storage_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            previous_overlay_gib: record
                .overlay_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            storage_gib,
            overlay_gib,
        };
        if geometry
            .as_ref()
            .is_some_and(|value| !value.bound(&change) || value.directory() != self.directory)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        journal.pending = Some(Pending {
            change: change.clone(),
            stage: Stage::Prepared,
            geometry: geometry.clone(),
        });
        self.write(&journal, Some(inode))?;
        Ok(Permit { change, geometry })
    }

    /// Persist SDK-entry intent before mutation, not after an SDK result.
    pub(crate) fn enter(&self, permit: &Permit) -> Result<()> {
        let (mut journal, inode) = self.load()?;
        let pending = journal
            .pending
            .as_mut()
            .ok_or(Error::before(ErrorCode::State))?;
        if pending.change != permit.change
            || pending.geometry != permit.geometry
            || !matches!(pending.stage, Stage::Prepared)
        {
            return Err(Error::before(ErrorCode::State));
        }
        pending.stage = Stage::Entered;
        self.write(&journal, Some(inode))
    }

    /// A correlated SDK success plus checked postcondition is required. This
    /// never completes an entered mutation merely by reading current inventory.
    pub(crate) fn complete(
        &self,
        receipt: &CreationReceipt,
        permit: &Permit,
        record: &VmRecord,
    ) -> Result<CreationReceipt> {
        self.complete_inner(receipt, permit, record, false)
    }

    /// Record explicit quiesced qualification separately from SDK completion.
    /// Engine has verified the saved geometry; the original SDK outcome stays
    /// unknown and the public store must still use its resolved disposition.
    pub(crate) fn complete_repaired(
        &self,
        receipt: &CreationReceipt,
        permit: &Permit,
        record: &VmRecord,
    ) -> Result<CreationReceipt> {
        self.complete_inner(receipt, permit, record, true)
    }

    fn complete_inner(
        &self,
        receipt: &CreationReceipt,
        permit: &Permit,
        record: &VmRecord,
        qualified: bool,
    ) -> Result<CreationReceipt> {
        let (mut journal, inode) = self.load().map_err(after_entry)?;
        check_origin(&journal.origin, receipt).map_err(after_entry)?;
        let pending = journal
            .pending
            .as_ref()
            .ok_or(Error::uncertain(ErrorCode::State))?;
        let change = &permit.change;
        if pending.change != *change
            || pending.geometry != permit.geometry
            || !matches!(pending.stage, Stage::Entered)
            || journal.head != change.previous
            || immutable_hash(record).map_err(after_entry)? != change.immutable_sha256
            || record.storage_gb != Some(change.storage_gib)
            || record.overlay_gb != Some(change.overlay_gib)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let proof = next_proof(change, material_hash(record).map_err(after_entry)?)?;
        let qualified_geometry_sha256 = if qualified {
            let geometry = permit
                .geometry
                .as_ref()
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            let bytes = serde_json::to_vec(&("smolbox-growth-qualification-v1", geometry))
                .map_err(|_| Error::uncertain(ErrorCode::Native))?;
            Some(hex::encode(Sha256::digest(bytes)))
        } else {
            None
        };
        journal.history.push(Completed {
            change: change.clone(),
            proof: proof.clone(),
            qualified_geometry_sha256,
        });
        journal.head = proof.clone();
        journal.pending = None;
        self.write(&journal, Some(inode)).map_err(after_entry)?;
        Ok(with_proof(&journal.origin, proof))
    }

    /// Read recorded success after a lost reply; never dispatch or infer success
    /// for pending work. The original prior proof and request must still match.
    pub(crate) fn completed(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: GrowDisks,
    ) -> Result<Option<CreationReceipt>> {
        let (journal, _) = self.load()?;
        check_origin(&journal.origin, receipt)?;
        let entry = journal
            .history
            .iter()
            .find(|entry| entry.change.operation_id == operation_id);
        match entry {
            Some(entry)
                if entry.change.request == request
                    && receipt.material.as_ref() == Some(&entry.change.previous) =>
            {
                Ok(Some(with_proof(&journal.origin, entry.proof.clone())))
            }
            Some(_) => Err(Error::before(ErrorCode::Conflict)),
            None => Ok(None),
        }
    }

    pub(crate) fn completed_transition(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: GrowDisks,
    ) -> Result<Option<GrowthTransition>> {
        let (journal, _) = self.load()?;
        check_origin(&journal.origin, receipt)?;
        let Some(entry) = journal
            .history
            .iter()
            .find(|entry| entry.change.operation_id == operation_id)
        else {
            return Ok(None);
        };
        if entry.change.request != request
            || receipt.material.as_ref() != Some(&entry.change.previous)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let transition = GrowthTransition {
            schema: 1,
            previous: receipt.clone(),
            receipt: with_proof(&journal.origin, entry.proof.clone()),
            change: entry.change.clone(),
        };
        transition.validate()?;
        Ok(Some(transition))
    }

    pub(crate) fn recovery_permit(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: GrowDisks,
    ) -> Result<Permit> {
        let (journal, _) = self.load()?;
        check_origin(&journal.origin, receipt)?;
        let pending = journal.pending.ok_or(Error::before(ErrorCode::State))?;
        if !matches!(pending.stage, Stage::Entered)
            || pending.change.operation_id != operation_id
            || pending.change.request != request
            || receipt.material.as_ref() != Some(&pending.change.previous)
            || journal.head != pending.change.previous
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let geometry = pending
            .geometry
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        if !geometry.bound(&pending.change) || geometry.directory() != self.directory {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(Permit {
            change: pending.change,
            geometry: Some(geometry),
        })
    }

    pub(crate) fn verify_recovery(
        &self,
        permit: &Permit,
        record: &VmRecord,
        budget: &crate::ReadBudget,
    ) -> Result<(
        crate::disk_geometry::DiskGeometry,
        crate::disk_geometry::DiskGeometry,
    )> {
        let change = &permit.change;
        if immutable_hash(record)? != change.immutable_sha256
            || record.storage_gb != Some(change.storage_gib)
            || record.overlay_gb != Some(change.overlay_gib)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        permit
            .geometry
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?
            .verify_repaired(change, budget)
    }

    pub(crate) fn previous_sizes(permit: &Permit) -> (u64, u64) {
        (
            permit.change.previous_storage_gib,
            permit.change.previous_overlay_gib,
        )
    }

    fn load(&self) -> Result<(Journal, (u64, u64))> {
        let directory = self.directory_identity()?;
        let path = self.directory.join(FILE_NAME);
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let metadata = file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if !metadata.is_file()
            || metadata.mode() & 0o777 != 0o600
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.len() > MAX_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut bytes = Vec::new();
        Read::by_ref(&mut file)
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > MAX_BYTES
            || self.directory_identity()? != directory
            || inode_at(&path)? != (metadata.dev(), metadata.ino())
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let journal: Journal =
            serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
        validate_journal(&journal)?;
        Ok((journal, (metadata.dev(), metadata.ino())))
    }

    fn write(&self, journal: &Journal, expected: Option<(u64, u64)>) -> Result<()> {
        validate_journal(journal)?;
        let directory = self.directory_identity()?;
        let path = self.directory.join(FILE_NAME);
        let bytes = serde_json::to_vec(journal).map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::before(ErrorCode::State));
        }
        let mut staging = tempfile::NamedTempFile::new_in(&self.directory)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        staging
            .write_all(&bytes)
            .and_then(|()| staging.as_file().sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if self.directory_identity()? != directory {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(inode) = expected {
            if inode_at(&path)? != inode {
                return Err(Error::before(ErrorCode::Ownership));
            }
            staging
                .persist(&path)
                .map_err(|_| Error::before(ErrorCode::Io))?;
        } else {
            staging
                .persist_noclobber(&path)
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
        }
        File::open(&self.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))
    }

    fn directory_identity(&self) -> Result<(u64, u64)> {
        unredirected(&self.directory)?;
        let metadata = std::fs::symlink_metadata(&self.directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o022 != 0
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok((metadata.dev(), metadata.ino()))
    }
}

fn inode_at(path: &Path) -> Result<(u64, u64)> {
    let metadata =
        std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o600
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok((metadata.dev(), metadata.ino()))
}

fn with_proof(origin: &CreationReceipt, proof: MaterialProof) -> CreationReceipt {
    let mut receipt = origin.clone();
    receipt.material = Some(proof);
    receipt
}

fn check_origin(origin: &CreationReceipt, receipt: &CreationReceipt) -> Result<()> {
    let mut supplied = receipt.clone();
    supplied.material = None;
    if *origin != supplied {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

fn root_proof(origin: &CreationReceipt) -> Result<MaterialProof> {
    Ok(MaterialProof {
        schema: 2,
        revision: 0,
        record_sha256: origin.material_sha256.clone(),
        chain_sha256: hash(&("smolbox-material-origin-v2", origin))?,
        operation_id: None,
        request_sha256: None,
    })
}

fn next_proof(change: &GrowthChange, record_sha256: String) -> Result<MaterialProof> {
    let request_sha256 = hash(&change.request)?;
    let revision = change.previous.revision + 1;
    Ok(MaterialProof {
        schema: 2,
        revision,
        chain_sha256: hash(&("smolbox-material-transition-v2", change, &record_sha256))?,
        record_sha256,
        operation_id: Some(change.operation_id.clone()),
        request_sha256: Some(request_sha256),
    })
}

fn immutable_hash(record: &VmRecord) -> Result<String> {
    let mut value = material_value(record)?;
    let fields = value
        .as_object_mut()
        .ok_or(Error::before(ErrorCode::Ownership))?;
    fields.remove("storage_gb");
    fields.remove("overlay_gb");
    hash(&value)
}

fn hash(value: &impl Serialize) -> Result<String> {
    let bytes = serde_json::to_vec(value).map_err(|_| Error::before(ErrorCode::Io))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

fn validate_journal(journal: &Journal) -> Result<()> {
    if journal.schema != 2
        || journal.origin.material.is_some()
        || journal.history.len() > MAX_HISTORY
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut previous = root_proof(&journal.origin)?;
    previous.validate()?;
    let mut ids = std::collections::BTreeSet::new();
    let mut immutable = None;
    for entry in &journal.history {
        if !valid_change(&entry.change)
            || entry.change.previous != previous
            || !ids.insert(&entry.change.operation_id)
            || immutable.is_some_and(|hash| hash != &entry.change.immutable_sha256)
            || entry.proof != next_proof(&entry.change, entry.proof.record_sha256.clone())?
            || entry
                .qualified_geometry_sha256
                .as_ref()
                .is_some_and(|value| !valid_hex(value, 64))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        entry.proof.validate()?;
        immutable = Some(&entry.change.immutable_sha256);
        previous = entry.proof.clone();
    }
    if journal.head != previous
        || journal.pending.as_ref().is_some_and(|pending| {
            !valid_change(&pending.change)
                || pending.change.previous != previous
                || ids.contains(&pending.change.operation_id)
                || immutable.is_some_and(|hash| hash != &pending.change.immutable_sha256)
                || pending
                    .geometry
                    .as_ref()
                    .is_some_and(|value| !value.bound(&pending.change))
        })
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

fn valid_change(change: &GrowthChange) -> bool {
    valid_id(&change.operation_id)
        && valid_hex(&change.immutable_sha256, 64)
        && (1..=64).contains(&change.storage_gib)
        && (1..=64).contains(&change.overlay_gib)
        && change.previous.validate().is_ok()
        && (1..=64).contains(&change.previous_storage_gib)
        && (1..=64).contains(&change.previous_overlay_gib)
        && change.storage_gib >= change.previous_storage_gib
        && change.overlay_gib >= change.previous_overlay_gib
        && (change.storage_gib > change.previous_storage_gib
            || change.overlay_gib > change.previous_overlay_gib)
        && change
            .request
            .storage_gib
            .unwrap_or(change.previous_storage_gib)
            == change.storage_gib
        && change
            .request
            .overlay_gib
            .unwrap_or(change.previous_overlay_gib)
            == change.overlay_gib
}

fn after_entry(error: Error) -> Error {
    Error::uncertain(error.code)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn transitions() -> Vec<GrowthTransition> {
        serde_json::from_slice(include_bytes!(
            "../../smolbox-protocol/fixtures/growth-transitions-v1.json"
        ))
        .unwrap()
    }

    #[test]
    fn cross_language_transition_fixture_binds_exact_request_previous_proof_and_chain() {
        let transitions = transitions();
        for transition in &transitions {
            transition.validate().unwrap();
        }
        assert_eq!(transitions[0].receipt, transitions[1].previous);
        let original = &transitions[0];
        let debug = format!("{original:?} {:?}", original.change);
        for private in [
            &original.previous.owner_token,
            &original.change.operation_id,
            &original.receipt.material.as_ref().unwrap().chain_sha256,
        ] {
            assert!(!debug.contains(private));
        }
        let mut changed = original.clone();
        changed.change.request.overlay_gib = Some(1); // null and explicit unchanged target are distinct requests.
        assert!(changed.validate().is_err());
        changed = original.clone();
        changed.change.operation_id = "foreign".into();
        assert!(changed.validate().is_err());
        changed = original.clone();
        changed.previous.material.as_mut().unwrap().chain_sha256 = "9".repeat(64);
        changed.change.previous = changed.previous.material.clone().unwrap();
        assert!(changed.validate().is_err());
        changed = original.clone();
        changed.receipt.incarnation = "9".repeat(32);
        assert!(changed.validate().is_err());
        changed = original.clone();
        changed.receipt.material.as_mut().unwrap().record_sha256 = "8".repeat(64);
        assert!(changed.validate().is_err());
        changed = original.clone();
        changed.change.previous_storage_gib = 3;
        assert!(changed.validate().is_err());
        changed = original.clone();
        changed.receipt.material.as_mut().unwrap().revision = 1025;
        assert!(changed.validate().is_err());
        let mut wire = serde_json::to_value(original).unwrap();
        wire["change"]["unknown"] = serde_json::json!(true);
        assert!(serde_json::from_value::<GrowthTransition>(wire).is_err());
    }

    #[test]
    fn completed_transition_is_correlated_journal_evidence_not_pending_inventory_or_replay() {
        let (_directory, journal, receipt, mut record) = fixture();
        let request = grow();
        let permit = journal.prepare(&receipt, "grow", request, &record).unwrap();
        journal.enter(&permit).unwrap();
        assert!(journal
            .completed_transition(&receipt, "grow", request)
            .unwrap()
            .is_none());
        record.storage_gb = Some(2); // deterministic SDK-result boundary model.
        let updated = journal.complete(&receipt, &permit, &record).unwrap();
        let transition = journal
            .completed_transition(&receipt, "grow", request)
            .unwrap()
            .unwrap();
        transition.validate().unwrap();
        assert_eq!(transition.previous, receipt);
        assert_eq!(transition.receipt, updated);
        assert!(journal
            .completed_transition(&updated, "grow", request)
            .is_err());
        assert!(journal
            .completed_transition(
                &receipt,
                "grow",
                GrowDisks {
                    storage_gib: Some(3),
                    overlay_gib: None
                }
            )
            .is_err());
        assert!(journal
            .completed_transition(&receipt, "foreign", request)
            .unwrap()
            .is_none());
        assert!(journal
            .prepare(
                &updated,
                "grow",
                GrowDisks {
                    storage_gib: Some(3),
                    overlay_gib: None
                },
                &record
            )
            .is_err());
    }

    #[test]
    fn individually_valid_growth_links_cannot_change_the_history_immutable_configuration() {
        let (_directory, journal, receipt, mut record) = fixture();
        let permit = journal.prepare(&receipt, "first", grow(), &record).unwrap();
        journal.enter(&permit).unwrap();
        record.storage_gb = Some(2);
        let updated = journal.complete(&receipt, &permit, &record).unwrap();
        let request = GrowDisks {
            storage_gib: Some(3),
            overlay_gib: None,
        };
        let permit = journal
            .prepare(&updated, "second", request, &record)
            .unwrap();
        journal.enter(&permit).unwrap();
        record.storage_gb = Some(3);
        journal.complete(&updated, &permit, &record).unwrap();
        let (mut history, _) = journal.load().unwrap();
        let last = history.history.last_mut().unwrap();
        last.change.immutable_sha256 = "9".repeat(64);
        last.proof = next_proof(&last.change, last.proof.record_sha256.clone()).unwrap();
        history.head = last.proof.clone();
        assert!(valid_change(&last.change));
        assert!(last.proof.validate().is_ok());
        assert!(validate_journal(&history).is_err());
    }
    use std::os::unix::fs::PermissionsExt;

    fn fixture() -> (
        tempfile::TempDir,
        MaterialJournal,
        CreationReceipt,
        VmRecord,
    ) {
        let directory = tempfile::tempdir().unwrap();
        let journal = MaterialJournal::at(&directory.path().canonicalize().unwrap());
        let mut record = VmRecord::new("owned".into(), 1, 512, Vec::new(), Vec::new(), false);
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record.labels.insert("smolbox.owner".into(), "b".repeat(64));
        let origin = CreationReceipt {
            target_id: "local".into(),
            domain_generation: "a".repeat(32),
            name: record.name.clone(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: material_hash(&record).unwrap(),
            material: None,
        };
        let receipt = journal.initialize(&origin).unwrap();
        (directory, journal, receipt, record)
    }

    fn grow() -> GrowDisks {
        GrowDisks {
            storage_gib: Some(2),
            overlay_gib: None,
        }
    }

    #[test]
    fn fresh_origin_is_private_immutable_and_cannot_be_reinitialized_or_downgraded() {
        let (_directory, journal, receipt, record) = fixture();
        journal.verify(&receipt).unwrap();
        assert!(receipt.matches(&record).unwrap());
        let proof = receipt.material.as_ref().unwrap();
        assert_eq!(proof.revision, 0);
        assert_eq!(proof.record_sha256, receipt.material_sha256);
        assert_eq!(
            std::fs::metadata(journal.directory.join(FILE_NAME))
                .unwrap()
                .mode()
                & 0o777,
            0o600
        );
        let original = std::fs::read(journal.directory.join(FILE_NAME)).unwrap();
        let mut stripped = receipt.clone();
        stripped.material = None;
        assert_eq!(
            journal.verify(&stripped).err().unwrap().code,
            ErrorCode::Ownership
        );
        assert_eq!(
            journal.initialize(&stripped).err().unwrap().code,
            ErrorCode::Conflict
        );
        assert_eq!(
            std::fs::read(journal.directory.join(FILE_NAME)).unwrap(),
            original
        );
        assert_eq!(
            journal.initialize(&receipt).err().unwrap().code,
            ErrorCode::Ownership
        );
    }

    #[test]
    fn legacy_pending_geometry_is_absent_and_cannot_be_qualified_from_inventory() {
        let (_directory, journal, receipt, record) = fixture();
        let permit = journal
            .prepare(&receipt, "legacy", grow(), &record)
            .unwrap();
        journal.enter(&permit).unwrap();
        let bytes = std::fs::read(journal.directory.join(FILE_NAME)).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert!(value["pending"].get("geometry").is_none());
        assert_eq!(
            journal
                .recovery_permit(&receipt, "legacy", grow())
                .err()
                .unwrap()
                .code,
            ErrorCode::Unsupported
        );
        assert_eq!(
            std::fs::read(journal.directory.join(FILE_NAME)).unwrap(),
            bytes
        );
        let (loaded, _) = journal.load().unwrap();
        assert_eq!(serde_json::to_vec(&loaded).unwrap(), bytes);
    }

    #[test]
    fn correlated_growth_preserves_creation_authority_and_retires_the_old_material_proof() {
        let (_directory, journal, receipt, mut record) = fixture();
        let permit = journal
            .prepare(&receipt, "grow-1", grow(), &record)
            .unwrap();
        journal.enter(&permit).unwrap();
        record.storage_gb = Some(2);
        let advanced = journal.complete(&receipt, &permit, &record).unwrap();
        assert_eq!(advanced.material_sha256, receipt.material_sha256);
        assert_eq!(advanced.owner_token, receipt.owner_token);
        assert_eq!(advanced.incarnation, receipt.incarnation);
        assert_eq!(advanced.material.as_ref().unwrap().revision, 1);
        journal.verify(&advanced).unwrap();
        assert!(advanced.matches(&record).unwrap());
        assert!(!receipt.matches(&record).unwrap());
        assert_eq!(
            journal.verify(&receipt).err().unwrap().code,
            ErrorCode::Ownership
        );
        assert_eq!(
            journal
                .prepare(&advanced, "grow-1", grow(), &record)
                .err()
                .unwrap()
                .code,
            ErrorCode::Conflict
        );
    }

    #[test]
    fn pending_work_blocks_mutation_and_never_supplies_success_or_replay_authority() {
        let (_directory, journal, receipt, mut record) = fixture();
        let permit = journal
            .prepare(&receipt, "grow-1", grow(), &record)
            .unwrap();
        assert_eq!(
            journal.verify(&receipt).err().unwrap().code,
            ErrorCode::State
        );
        assert!(journal
            .completed(&receipt, "grow-1", grow())
            .unwrap()
            .is_none());
        assert_eq!(
            journal
                .prepare(&receipt, "grow-1", grow(), &record)
                .err()
                .unwrap()
                .code,
            ErrorCode::State
        );
        record.storage_gb = Some(2);
        let error = journal.complete(&receipt, &permit, &record).err().unwrap();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        journal.enter(&permit).unwrap();
        assert_eq!(journal.enter(&permit).err().unwrap().code, ErrorCode::State);
        assert!(journal
            .completed(&receipt, "grow-1", grow())
            .unwrap()
            .is_none());
    }

    #[test]
    fn recorded_result_can_be_read_after_lost_acknowledgment_without_sdk_entry() {
        let (_directory, journal, receipt, mut record) = fixture();
        let permit = journal
            .prepare(&receipt, "grow-1", grow(), &record)
            .unwrap();
        journal.enter(&permit).unwrap();
        record.storage_gb = Some(2);
        let expected = journal.complete(&receipt, &permit, &record).unwrap();
        let reader = MaterialJournal::at(&journal.directory);
        assert_eq!(
            reader.completed(&receipt, "grow-1", grow()).unwrap(),
            Some(expected)
        );
        assert!(reader
            .completed(&receipt, "unrecorded", grow())
            .unwrap()
            .is_none());
        let changed = GrowDisks {
            storage_gib: Some(3),
            overlay_gib: None,
        };
        assert_eq!(
            reader
                .completed(&receipt, "grow-1", changed)
                .err()
                .unwrap()
                .code,
            ErrorCode::Conflict
        );
    }

    #[test]
    fn different_owner_incarnation_domain_or_creation_hash_cannot_rebind_a_journal() {
        let (_directory, journal, receipt, record) = fixture();
        for changed in [
            CreationReceipt {
                owner_token: "d".repeat(64),
                ..receipt.clone()
            },
            CreationReceipt {
                incarnation: "e".repeat(32),
                ..receipt.clone()
            },
            CreationReceipt {
                domain_generation: "f".repeat(32),
                ..receipt.clone()
            },
            CreationReceipt {
                target_id: "other".into(),
                ..receipt.clone()
            },
            CreationReceipt {
                material_sha256: "0".repeat(64),
                ..receipt.clone()
            },
        ] {
            assert_eq!(
                journal.verify(&changed).err().unwrap().code,
                ErrorCode::Ownership
            );
            assert_eq!(
                journal
                    .prepare(&changed, "grow-1", grow(), &record)
                    .err()
                    .unwrap()
                    .code,
                ErrorCode::Ownership
            );
        }
    }

    #[test]
    fn growth_never_authorizes_simultaneous_unrelated_record_changes() {
        for kind in ["cpu", "network", "image", "owner", "workload"] {
            let (_directory, journal, receipt, mut record) = fixture();
            let permit = journal
                .prepare(&receipt, "grow-1", grow(), &record)
                .unwrap();
            journal.enter(&permit).unwrap();
            record.storage_gb = Some(2);
            match kind {
                "cpu" => record.cpus = 2,
                "network" => record.network = true,
                "image" => record.image = Some("different-image".into()),
                "owner" => {
                    record.labels.insert("smolbox.owner".into(), "d".repeat(64));
                }
                "workload" => record.cmd = vec!["unexpected".into()],
                _ => unreachable!(),
            }
            assert_eq!(
                journal
                    .complete(&receipt, &permit, &record)
                    .err()
                    .unwrap()
                    .code,
                ErrorCode::Ownership
            );
            assert!(journal
                .completed(&receipt, "grow-1", grow())
                .unwrap()
                .is_none());
        }
    }

    #[test]
    fn short_or_partial_geometry_stays_entered_and_unavailable() {
        let (_directory, journal, receipt, record) = fixture();
        let permit = journal
            .prepare(&receipt, "grow-1", grow(), &record)
            .unwrap();
        journal.enter(&permit).unwrap();
        assert_eq!(
            journal
                .complete(&receipt, &permit, &record)
                .err()
                .unwrap()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(
            journal.verify(&receipt).err().unwrap().code,
            ErrorCode::State
        );
        assert!(journal
            .completed(&receipt, "grow-1", grow())
            .unwrap()
            .is_none());
    }

    #[test]
    fn shrink_noop_empty_and_out_of_range_requests_fail_before_journal_mutation() {
        let (_directory, journal, receipt, mut record) = fixture();
        let original = std::fs::read(journal.directory.join(FILE_NAME)).unwrap();
        for request in [
            GrowDisks {
                storage_gib: None,
                overlay_gib: None,
            },
            GrowDisks {
                storage_gib: Some(1),
                overlay_gib: None,
            },
            GrowDisks {
                storage_gib: Some(0),
                overlay_gib: Some(2),
            },
            GrowDisks {
                storage_gib: Some(65),
                overlay_gib: None,
            },
        ] {
            assert_eq!(
                journal
                    .prepare(&receipt, "invalid", request, &record)
                    .err()
                    .unwrap()
                    .code,
                ErrorCode::Validation
            );
            assert_eq!(
                std::fs::read(journal.directory.join(FILE_NAME)).unwrap(),
                original
            );
        }
        record.storage_gb = Some(2);
        assert!(GrowDisks {
            storage_gib: Some(1),
            overlay_gib: Some(2)
        }
        .targets(&record)
        .is_err());
    }

    #[test]
    fn unknown_journal_fields_corruption_changed_bytes_and_readable_modes_fail_closed() {
        for kind in ["corrupt", "unknown", "changed", "mode"] {
            let (_directory, journal, receipt, _record) = fixture();
            let path = journal.directory.join(FILE_NAME);
            if kind == "corrupt" {
                std::fs::write(&path, b"{").unwrap();
            } else if kind == "mode" {
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
            } else {
                let mut value: serde_json::Value =
                    serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
                if kind == "unknown" {
                    value["foreign"] = serde_json::json!(true);
                } else {
                    value["head"]["record_sha256"] = serde_json::json!("0".repeat(64));
                }
                std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            }
            assert_eq!(
                journal.verify(&receipt).err().unwrap().code,
                ErrorCode::Ownership
            );
        }
    }

    #[test]
    fn redirected_journal_and_parent_do_not_follow_or_remove_foreign_files() {
        let (_directory, journal, receipt, _record) = fixture();
        let outside = tempfile::tempdir().unwrap();
        let sentinel = outside.path().join("sentinel");
        std::fs::write(&sentinel, b"unrelated").unwrap();
        let path = journal.directory.join(FILE_NAME);
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&sentinel, &path).unwrap();
        assert_eq!(
            journal.verify(&receipt).err().unwrap().code,
            ErrorCode::Ownership
        );
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"unrelated");
        let redirect = outside.path().join("redirect");
        std::os::unix::fs::symlink(&journal.directory, &redirect).unwrap();
        assert!(MaterialJournal::at(&redirect).verify(&receipt).is_err());
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"unrelated");
    }

    #[test]
    fn modeled_runtime_pid_state_and_init_changes_do_not_change_material_authority() {
        let (_directory, journal, receipt, mut record) = fixture();
        record.state = smolvm::config::RecordState::Running;
        record.pid = Some(12345);
        record.pid_start_time = Some(12);
        record.init_completed = true;
        journal.verify(&receipt).unwrap();
        assert!(receipt.matches(&record).unwrap());
    }

    #[test]
    fn proof_debug_never_exposes_tokens_hashes_operation_ids_or_requests() {
        let (_directory, journal, receipt, mut record) = fixture();
        let permit = journal
            .prepare(&receipt, "private-operation", grow(), &record)
            .unwrap();
        journal.enter(&permit).unwrap();
        record.storage_gb = Some(2);
        let advanced = journal.complete(&receipt, &permit, &record).unwrap();
        let proof = advanced.material.as_ref().unwrap();
        let debug = format!("{proof:?} {advanced:?}");
        for secret in [
            &receipt.owner_token,
            &proof.record_sha256,
            &proof.chain_sha256,
        ] {
            assert!(!debug.contains(secret));
        }
        assert!(!debug.contains("private-operation"));
    }
}
