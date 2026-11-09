//! Source-bound SDK capture in a collected native job worker. No VM boot,
//! source adoption, controller path selection or cache retention is allowed.
use crate::checkpoint_materialize::FileVersion;
use crate::transfer_worker::{Blob, Request};
use crate::{
    CaptureArtifact, CaptureRequest, CreationReceipt, Error, ErrorCode, ReadBudget, Result,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::PathBuf;
use std::time::Duration;

pub(crate) const METADATA_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Expected {
    pub metadata_sha256: String,
    pub operation_id: String,
}
impl Expected {
    pub(crate) fn validate(&self) -> Result<()> {
        if !crate::domain::valid_hex(&self.metadata_sha256, 64)
            || !crate::domain::valid_id(&self.operation_id)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Proof {
    pub expected: Expected,
    pub artifact: CaptureArtifact,
    pub device: u64,
    pub inode: u64,
    pub source_pid: (i32, u64),
    pub source_material_sha256: String,
}
impl Proof {
    pub(crate) fn matches(&self, expected: &Expected) -> bool {
        &self.expected == expected
            && crate::domain::valid_hex(&self.artifact.sha256, 64)
            && self.artifact.size_bytes > 0
            && self.artifact.size_bytes <= crate::CHECKPOINT_ARTIFACT_BYTES
            && crate::domain::valid_hex(&self.artifact.head, 32)
            && self.artifact.parent.as_ref().is_none_or(|parent| {
                crate::domain::valid_hex(parent, 32) && *parent != self.artifact.head
            })
            && self.source_pid.0 > 0
            && self.source_pid.1 > 0
            && crate::domain::valid_hex(&self.source_material_sha256, 64)
    }
}
impl std::fmt::Debug for Proof {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CaptureProof")
            .field("size_bytes", &self.artifact.size_bytes)
            .finish_non_exhaustive()
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Metadata {
    pub schema: u8,
    pub root: PathBuf,
    pub root_device: u64,
    pub root_inode: u64,
    pub database: PathBuf,
    pub database_device: u64,
    pub database_inode: u64,
    pub source_directory: PathBuf,
    pub receipt: CreationReceipt,
    pub request: CaptureRequest,
    pub operation_id: String,
    pub libraries: PathBuf,
    pub rootfs: PathBuf,
    pub deadline_ns: u64,
}

impl Metadata {
    pub(crate) fn encode(&self) -> Result<(Vec<u8>, Expected)> {
        let bytes = serde_json::to_vec(self).map_err(|_| Error::before(ErrorCode::Validation))?;
        if bytes.is_empty() || bytes.len() as u64 > METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        let expected = Expected {
            metadata_sha256: hex::encode(Sha256::digest(&bytes)),
            operation_id: self.operation_id.clone(),
        };
        expected.validate()?;
        Ok((bytes, expected))
    }
}

pub(crate) fn run(request: &Request, blob: &Blob, expected: &Expected) -> Result<Proof> {
    expected.validate()?;
    let metadata: Metadata = blob.read(request.owner, METADATA_BYTES)?;
    let encoded =
        serde_json::to_vec(&metadata).map_err(|_| Error::before(ErrorCode::Validation))?;
    if hex::encode(Sha256::digest(&encoded)) != expected.metadata_sha256
        || metadata.schema != 1
        || metadata.operation_id != expected.operation_id
        || request.staging.parent() != Some(metadata.root.as_path())
        || request.socket.parent() != Some(metadata.source_directory.as_path())
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let remaining = metadata
        .deadline_ns
        .checked_sub(crate::buffered::monotonic_ns()?)
        .ok_or(Error::before(ErrorCode::State))?;
    let budget = ReadBudget::for_checkpoint_work(
        Duration::from_nanos(remaining),
        crate::Cancellation::new(),
    )?;
    metadata.request.validate()?;
    crate::host::private_directory(&metadata.root)?;
    let root = std::fs::symlink_metadata(&metadata.root)
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if (root.dev(), root.ino(), root.uid())
        != (metadata.root_device, metadata.root_inode, request.owner.uid)
        || smolvm::db::SmolvmDb::default_path()
            .map_err(|_| Error::before(ErrorCode::Unsupported))?
            != metadata.database
        || smolvm::agent::vm_data_dir(&metadata.receipt.name) != metadata.source_directory
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    crate::host::unredirected(&metadata.database)?;
    crate::host::unredirected(&metadata.source_directory)?;
    let database = crate::artifact::open_regular(&metadata.database)?;
    let identity = database
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if (identity.dev(), identity.ino(), identity.uid())
        != (
            metadata.database_device,
            metadata.database_inode,
            request.owner.uid,
        )
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let db = smolvm::db::SmolvmDb::open_at(&metadata.database)
        .map_err(|_| Error::before(ErrorCode::Database))?;
    let before = db
        .get_vm(&metadata.receipt.name)
        .map_err(|_| Error::before(ErrorCode::Database))?
        .ok_or(Error::before(ErrorCode::NotFound))?;
    let journal = crate::material::MaterialJournal::at(&metadata.source_directory);
    let source_pid = journal.capture_dispatch(
        &metadata.receipt,
        &metadata.operation_id,
        &metadata.request,
        &before,
        crate::material::CaptureSourcePhase::BeforeCapture,
    )?;
    let resources = crate::checkpoint_capture::validate_portable_record(&before)?;
    if !smolvm::process::is_alive(source_pid.0)
        || smolvm::process::process_start_time(source_pid.0) != Some(source_pid.1)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let output = metadata.root.join("capture.smolcheckpoint");
    if std::fs::symlink_metadata(&output).is_ok() {
        return Err(Error::before(ErrorCode::Conflict));
    }
    let staging = metadata.root.join("sdk-staging");
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&staging)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    budget.check()?;
    let options = smolvm::portable_checkpoint::CaptureOptions {
        prepared_cache_budget_bytes: Some(0),
        host_mounts: false,
        store_dir: None,
        staging_dir: Some(staging),
        lib_dir: Some(metadata.libraries),
        rootfs_dir: Some(metadata.rootfs),
    };
    // The SDK takes its source flock; do not wrap it in another SDK source lock.
    let captured = smolvm::embedded::EmbeddedRuntime::with_db(db.clone())
        .checkpoint_machine(&metadata.receipt.name, &output, &options)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    budget
        .check()
        .map_err(|_| Error::uncertain(ErrorCode::State))?;
    let mut file = crate::artifact::open_regular(&output)?;
    let version = file
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    if version.len() == 0
        || version.len() > metadata.request.max_bytes
        || captured.size_bytes != version.len()
    {
        return Err(Error::uncertain(ErrorCode::OutputLimit));
    }
    let mut hash = Sha256::new();
    let mut bytes = 0u64;
    let mut buffer = [0; 65536];
    loop {
        budget.check()?;
        let count = file
            .read(&mut buffer)
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        if count == 0 {
            break;
        }
        bytes += count as u64;
        if bytes > metadata.request.max_bytes {
            return Err(Error::uncertain(ErrorCode::OutputLimit));
        }
        hash.update(&buffer[..count]);
    }
    if bytes != version.len()
        || FileVersion::of(
            &file
                .metadata()
                .map_err(|_| Error::uncertain(ErrorCode::Ownership))?,
        ) != FileVersion::of(&version)
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    file.sync_all()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let digest = hex::encode(hash.finalize());
    let approval = crate::ApprovedCheckpoint {
        artifact: crate::ApprovedCheckpointArtifact {
            path: output.clone(),
            sha256: digest.clone(),
            max_bytes: metadata.request.max_bytes,
            guest_platform: crate::oci::native_oci_platform().into(),
        },
        sdk_version: smolvm::VERSION.into(),
        host_platform: smolvm::platform::Platform::current()
            .host_oci_platform()
            .into(),
        resources,
    };
    let manifest = crate::checkpoint::inspect_artifact(&approval, &budget)?;
    let lineage = manifest
        .checkpoint
        .as_ref()
        .and_then(|value| value.lineage.as_ref())
        .ok_or(Error::uncertain(ErrorCode::Ownership))?;
    let artifact = CaptureArtifact {
        sha256: digest,
        size_bytes: version.len(),
        head: lineage.id.clone(),
        parent: lineage.parent.clone(),
    };
    let after = db
        .get_vm(&metadata.receipt.name)
        .map_err(|_| Error::uncertain(ErrorCode::Database))?
        .ok_or(Error::uncertain(ErrorCode::NotFound))?;
    journal
        .capture_dispatch(
            &metadata.receipt,
            &metadata.operation_id,
            &metadata.request,
            &after,
            crate::material::CaptureSourcePhase::AfterCapture,
        )
        .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
    if after.checkpoint_head.as_ref() != Some(&artifact.head)
        || artifact.parent != before.checkpoint_head
        || !smolvm::process::is_alive(source_pid.0)
        || smolvm::process::process_start_time(source_pid.0) != Some(source_pid.1)
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    crate::host::unredirected(&metadata.root)
        .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
    let final_root = std::fs::symlink_metadata(&metadata.root)
        .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
    let final_output =
        std::fs::symlink_metadata(&output).map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
    if (final_root.dev(), final_root.ino()) != (metadata.root_device, metadata.root_inode)
        || !final_root.is_dir()
        || final_root.uid() != request.owner.uid
        || final_root.mode() & 0o777 != 0o700
        || FileVersion::of(&final_output) != FileVersion::of(&version)
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    Ok(Proof {
        expected: expected.clone(),
        artifact,
        device: version.dev(),
        inode: version.ino(),
        source_pid,
        source_material_sha256: crate::identity::material_hash(&after)?,
    })
}
