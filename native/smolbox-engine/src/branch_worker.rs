//! Private SDK fork preparation. Requires a separately protected entered grant;
//! preparing IPC alone cannot enter the SDK, publish a child or boot a VMM.
use crate::branch::InitialBranchJournal;
use crate::transfer_worker::{Blob, Request};
use crate::{Error, ErrorCode, OwnerIdentity, Result};
use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::PathBuf;

pub(crate) const METADATA_BYTES: u64 = 64 * 1024;
pub(crate) const OUTPUT_BYTES: u64 = 16 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Expected {
    pub metadata_sha256: String,
    pub operation_id: String,
    pub request_sha256: String,
}
impl Expected {
    pub(crate) fn validate(&self) -> Result<()> {
        if !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.metadata_sha256, 64)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Grant {
    pub intent: InitialBranchJournal,
    pub owner: OwnerIdentity,
    pub worker_operation: String,
    pub directory: PathBuf,
    pub device: u64,
    pub inode: u64,
}
impl Grant {
    pub(crate) fn validate(&self) -> Result<()> {
        self.intent.validate()?;
        if self.owner.pid <= 0
            || self.owner.birth == 0
            || !crate::domain::valid_hex(&self.worker_operation, 32)
            || !valid_path(&self.directory)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
/// Protected entry written only after retaining the original owner/admission.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Entry {
    pub grant: Grant,
    pub metadata_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub publication: Option<crate::BranchPublication>,
}
impl Entry {
    pub(crate) fn validate(&self) -> Result<()> {
        self.grant.validate()?;
        if !crate::domain::valid_hex(&self.metadata_sha256, 64) {
            return Err(Error::before(ErrorCode::Validation));
        }
        if let Some(publication) = &self.publication {
            publication.validate()?;
            if publication.previous != self.grant.intent.source
                || publication.change.child_origin.intent != self.grant.intent
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Metadata {
    pub schema: u8,
    pub grant: Grant,
    pub database: PathBuf,
    pub database_device: u64,
    pub database_inode: u64,
    pub source_directory: PathBuf,
    pub source_device: u64,
    pub source_inode: u64,
    pub deadline_ns: u64,
}
impl Metadata {
    pub(crate) fn encode(&self) -> Result<(Vec<u8>, Expected)> {
        self.validate()?;
        let bytes = serde_json::to_vec(self).map_err(|_| Error::before(ErrorCode::Validation))?;
        if bytes.len() as u64 > METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        let expected = Expected {
            metadata_sha256: crate::material::hash(self)?,
            operation_id: self.grant.intent.child.operation_id.clone(),
            request_sha256: self.grant.intent.request_sha256.clone(),
        };
        expected.validate()?;
        Ok((bytes, expected))
    }
    fn validate(&self) -> Result<()> {
        self.grant.validate()?;
        if self.schema != 1
            || self.deadline_ns == 0
            || !valid_path(&self.database)
            || !valid_path(&self.source_directory)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Proof {
    pub expected: Expected,
    pub bytes: u64,
    pub sha256: String,
}
impl Proof {
    pub(crate) fn matches(&self, expected: &Expected) -> bool {
        self.expected == *expected
            && expected.validate().is_ok()
            && (1..=OUTPUT_BYTES).contains(&self.bytes)
            && crate::domain::valid_hex(&self.sha256, 64)
    }
}
/// Only hashes and generation identity cross the worker boundary. The parent
/// must independently read/verify SDK rows, source transition and child material.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Output {
    pub schema: u8,
    pub snapshot: PathBuf,
    pub snapshot_device: u64,
    pub snapshot_inode: u64,
    pub source_material_sha256: String,
    pub child_material_sha256: String,
    pub source_continues: bool,
}
fn valid_path(path: &std::path::Path) -> bool {
    path.is_absolute()
        && path.as_os_str().len() <= 4096
        && !path.components().any(|c| {
            matches!(
                c,
                std::path::Component::ParentDir | std::path::Component::CurDir
            )
        })
}
fn budget(metadata: &Metadata) -> Result<crate::ReadBudget> {
    let remaining = metadata
        .deadline_ns
        .checked_sub(crate::buffered::monotonic_ns()?)
        .filter(|remaining| *remaining > 0)
        .ok_or(Error::before(ErrorCode::State))?;
    crate::ReadBudget::for_checkpoint_work(
        std::time::Duration::from_nanos(remaining),
        crate::Cancellation::new(),
    )
}
pub(crate) fn verify_request(
    metadata: &Metadata,
    request: &Request,
    expected: &Expected,
) -> Result<()> {
    metadata.validate()?;
    expected.validate()?;
    if metadata.grant.owner != request.owner
        || metadata.grant.worker_operation != request.operation
        || metadata.grant.directory.as_path()
            != request
                .staging
                .parent()
                .ok_or(Error::before(ErrorCode::Validation))?
        || metadata.source_directory.join("agent.sock") != request.socket
        || request.max_bytes != OUTPUT_BYTES
        || metadata.grant.intent.child.operation_id != expected.operation_id
        || metadata.grant.intent.request_sha256 != expected.request_sha256
        || crate::material::hash(metadata)? != expected.metadata_sha256
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

pub(crate) fn run(request: &Request, blob: &Blob, expected: &Expected) -> Result<Proof> {
    let metadata: Metadata = blob.read(request.owner, METADATA_BYTES)?;
    verify_request(&metadata, request, expected)?;
    let work = budget(&metadata)?;
    if std::env::var_os("SMOLVM_BRANCH_RAM_MODE").as_deref() != Some(std::ffi::OsStr::new("shared"))
        || !cfg!(any(target_os = "linux", target_os = "macos"))
        || smolvm::db::SmolvmDb::default_path()
            .map_err(|_| Error::before(ErrorCode::Unsupported))?
            != metadata.database
        || smolvm::agent::vm_data_dir(&metadata.grant.intent.source.name)
            != metadata.source_directory
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    let stage = crate::export_source::Root::open(&metadata.grant.directory)?;
    let source = crate::export_source::Root::open(&metadata.source_directory)?;
    for (root, expected_identity) in [
        (&stage, (metadata.grant.device, metadata.grant.inode)),
        (&source, (metadata.source_device, metadata.source_inode)),
    ] {
        let info = root
            .descriptor()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if (info.dev(), info.ino(), info.uid())
            != (expected_identity.0, expected_identity.1, request.owner.uid)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    crate::host::unredirected(&metadata.database)?;
    let database = crate::artifact::open_regular(&metadata.database)?;
    let info = database
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if (info.dev(), info.ino(), info.uid())
        != (
            metadata.database_device,
            metadata.database_inode,
            request.owner.uid,
        )
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    crate::sdk_compat::validate_database(&metadata.database, (info.dev(), info.ino()))?;
    // Bounded preflight precedes SDK list_vms; no independent CLI writers are
    // supported. Preparation is single-source/single-child, never a batch.
    let before = crate::sdk_compat::observe_record(
        &metadata.database,
        (info.dev(), info.ino()),
        &metadata.grant.intent.source.name,
        &work,
    )?
    .ok_or(Error::before(ErrorCode::Ownership))?;
    metadata.grant.intent.verify_record(&before)?;
    let journal = crate::material::MaterialJournal::at(&metadata.source_directory);
    journal.authorize_branch_preparation(&metadata.grant, expected, &before)?;
    if !crate::machine::marker_matches(&metadata.grant.intent.source, &metadata.source_directory)?
        || !smolvm::process::is_alive(metadata.grant.intent.source_pid.0)
        || smolvm::process::process_start_time(metadata.grant.intent.source_pid.0)
            != Some(metadata.grant.intent.source_pid.1)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    crate::sdk_compat::observe_records(&metadata.database, (info.dev(), info.ino()), &work)?;
    let db = smolvm::db::SmolvmDb::open_at(&metadata.database)
        .map_err(|_| Error::before(ErrorCode::Database))?;
    let _source_lock = smolvm::agent::fork::lock_fork_source(&before.name)
        .map_err(|_| Error::before(ErrorCode::Conflict))?;
    // An entered grant exempts only its new child. Existing leaves still need
    // protected current material before this SDK call and after collection.
    let dependents = crate::sdk_compat::source_dependents(
        &metadata.database,
        (info.dev(), info.ino()),
        &before.name,
        &work,
    )?;
    if dependents.contains(&metadata.grant.intent.child.name)
        || !journal.branch_dependencies(
            &metadata.grant.intent.source,
            Some(&metadata.grant.intent.child.name),
            &dependents,
            &metadata.database,
            (info.dev(), info.ino()),
            &work,
        )?
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    work.check()?;
    source.verify()?;
    stage.verify()?;
    let prepared = smolvm::agent::fork::prepare_held_fork(
        &db,
        &before.name,
        &metadata.grant.intent.child.name,
        &[],
        &[],
        &std::collections::BTreeMap::new(),
        smolvm::agent::fork::ForkSourcePolicy::PlatformDefault,
    )
    .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    work.check().map_err(|e| Error::uncertain(e.code))?;
    source.verify().map_err(|e| Error::uncertain(e.code))?;
    stage.verify().map_err(|e| Error::uncertain(e.code))?;
    let after = crate::sdk_compat::observe_record(
        &metadata.database,
        (info.dev(), info.ino()),
        &before.name,
        &work,
    )?
    .ok_or(Error::uncertain(ErrorCode::Ownership))?;
    verify_sdk_result(&metadata.grant.intent, &before, &after, &prepared)?;
    let registered = crate::sdk_compat::observe_record(
        &metadata.database,
        (info.dev(), info.ino()),
        &metadata.grant.intent.child.name,
        &work,
    )?
    .ok_or(Error::uncertain(ErrorCode::Ownership))?;
    if registered.state != smolvm::config::RecordState::Created
        || registered.pid.is_some()
        || registered.pid_start_time.is_some()
        || crate::identity::material_hash(&registered)?
            != crate::identity::material_hash(&prepared.clone_record)?
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    let snapshot = crate::export_source::Root::open(&prepared.snapshot_dir)?;
    let snapshot_info = snapshot
        .descriptor()
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
    let output = Output {
        schema: 1,
        snapshot: prepared.snapshot_dir,
        snapshot_device: snapshot_info.dev(),
        snapshot_inode: snapshot_info.ino(),
        source_material_sha256: crate::identity::material_hash(&after)?,
        child_material_sha256: crate::identity::material_hash(&prepared.clone_record)?,
        source_continues: true,
    };
    let bytes = serde_json::to_vec(&output).map_err(|_| Error::uncertain(ErrorCode::Native))?;
    if bytes.is_empty() || bytes.len() as u64 > OUTPUT_BYTES {
        return Err(Error::uncertain(ErrorCode::OutputLimit));
    }
    let mut file = OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(&request.staging)
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let info = file
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    if !info.is_file()
        || info.len() != 0
        || info.nlink() != 1
        || info.uid() != request.owner.uid
        || info.mode() & 0o777 != 0o600
        || (info.dev(), info.ino()) != (request.staging_device, request.staging_inode)
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    file.write_all(&bytes)
        .and_then(|()| file.sync_all())
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    snapshot.verify()?;
    source.verify()?;
    stage.verify()?;
    work.check()?;
    Ok(Proof {
        expected: expected.clone(),
        bytes: bytes.len() as u64,
        sha256: crate::material::hash(&output)?,
    })
}

pub(crate) fn verify_sdk_result(
    intent: &InitialBranchJournal,
    before: &smolvm::config::VmRecord,
    after: &smolvm::config::VmRecord,
    prepared: &smolvm::agent::fork::PreparedFork,
) -> Result<()> {
    intent.verify_record(before)?;
    let generation = prepared
        .snapshot_dir
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| crate::domain::valid_hex(s, 8))
        .ok_or(Error::uncertain(ErrorCode::Ownership))?;
    if prepared.snapshot_dir.parent()
        != Some(smolvm::agent::vm_data_dir(&before.name).join("s").as_path())
        || !prepared.source_continues
        || !prepared.port_remaps.is_empty()
        || after.state != smolvm::config::RecordState::Running
        || after.pid.zip(after.pid_start_time) != Some(intent.source_pid)
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    let mut expected_source = before.clone();
    if cfg!(target_os = "linux") {
        expected_source.fork_lineage_pid_start_time = Some(intent.source_pid.1);
    }
    if crate::identity::material_hash(after)? != crate::identity::material_hash(&expected_source)? {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    let child = &prepared.clone_record;
    let mut expected_child = after.clone();
    expected_child.name = intent.child.name.clone();
    expected_child.state = smolvm::config::RecordState::Created;
    expected_child.pid = None;
    expected_child.pid_start_time = None;
    expected_child.created_at = child.created_at;
    expected_child.fork_overlay_owner = before
        .fork_overlay_owner
        .clone()
        .or(before.golden.clone())
        .or(Some(before.name.clone()));
    expected_child.golden = Some(before.name.clone());
    expected_child.fork_generation = Some(generation.into());
    expected_child.fork_lineage_pid_start_time = None;
    expected_child.forkable = false;
    expected_child.forkpoint_held = true;
    expected_child.fork_env.clear();
    if child.state != smolvm::config::RecordState::Created
        || child.pid.is_some()
        || child.pid_start_time.is_some()
        || crate::identity::material_hash(child)?
            != crate::identity::material_hash(&expected_child)?
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn fixture() -> (tempfile::TempDir, Metadata, Expected) {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let (engine, receipt) =
            crate::export_source::tests::fixture_record(&root, false, |record| {
                record.entrypoint = vec!["/bin/true".into()];
                record.cmd.clear();
                record.env.clear();
                record.user = None;
                record.workdir = Some("/".into());
                record.forkable = true;
                record.state = smolvm::config::RecordState::Running;
                record.pid = Some(123);
                record.pid_start_time = Some(456);
            });
        let record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        let intent = crate::branch::tests::initial_journal(&receipt, &record);
        let directory = root.join("stage");
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let info = std::fs::metadata(&directory).unwrap();
        let source = engine.vm_directory(&receipt.name);
        let source_info = std::fs::metadata(&source).unwrap();
        let metadata = Metadata {
            schema: 1,
            grant: Grant {
                intent,
                owner: OwnerIdentity::capture().unwrap(),
                worker_operation: "a".repeat(32),
                directory,
                device: info.dev(),
                inode: info.ino(),
            },
            database: engine.binding().database.clone(),
            database_device: engine.database_identity.0,
            database_inode: engine.database_identity.1,
            source_directory: source,
            source_device: source_info.dev(),
            source_inode: source_info.ino(),
            deadline_ns: crate::buffered::monotonic_ns().unwrap() + 60_000_000_000,
        };
        let expected = metadata.encode().unwrap().1;
        (temp, metadata, expected)
    }
    use std::os::unix::fs::DirBuilderExt;

    #[test]
    fn metadata_and_expected_bind_owner_nonce_source_and_absolute_deadline() {
        let (_root, metadata, expected) = fixture();
        let (bytes, _) = metadata.encode().unwrap();
        assert!(bytes.len() as u64 <= METADATA_BYTES);
        let mut query = Request {
            schema: 1,
            operation: metadata.grant.worker_operation.clone(),
            owner: metadata.grant.owner,
            socket: metadata.source_directory.join("agent.sock"),
            staging: metadata.grant.directory.join("output"),
            staging_device: 1,
            staging_inode: 2,
            guest_path: "/workspace/.smolbox-branch-prepare".into(),
            max_bytes: OUTPUT_BYTES,
            kind: crate::transfer_worker::Kind::BranchPrepare {
                metadata: Blob {
                    path: metadata.grant.directory.join("input"),
                    device: 1,
                    inode: 3,
                    bytes: bytes.len() as u64,
                },
                expected: expected.clone(),
            },
        };
        query.validate().unwrap();
        verify_request(&metadata, &query, &expected).unwrap();
        query.owner.birth += 1;
        assert!(verify_request(&metadata, &query, &expected).is_err());
        query.owner = metadata.grant.owner;
        query.operation = "b".repeat(32);
        assert!(verify_request(&metadata, &query, &expected).is_err());
        query.operation = metadata.grant.worker_operation.clone();
        query.max_bytes += 1;
        assert!(query.validate().is_err());
        let mut value = serde_json::to_value(&metadata).unwrap();
        value["deadline_ns"] = 0.into();
        assert!(serde_json::from_value::<Metadata>(value)
            .unwrap()
            .encode()
            .is_err());
        let mut value = serde_json::to_value(&metadata).unwrap();
        value["ram_mode"] = "paged".into();
        assert!(serde_json::from_value::<Metadata>(value).is_err());
    }
    #[test]
    fn sdk_result_projection_keeps_shared_source_and_held_unowned_leaf_distinct() {
        let (_root, metadata, _) = fixture();
        let before = crate::sdk_compat::observe_record(
            &metadata.database,
            (metadata.database_device, metadata.database_inode),
            &metadata.grant.intent.source.name,
            &budget(&metadata).unwrap(),
        )
        .unwrap()
        .unwrap();
        let mut after = before.clone();
        if cfg!(target_os = "linux") {
            after.fork_lineage_pid_start_time = Some(456);
        }
        let mut child = after.clone();
        child.name = metadata.grant.intent.child.name.clone();
        child.state = smolvm::config::RecordState::Created;
        child.pid = None;
        child.pid_start_time = None;
        child.created_at += 1;
        child.golden = Some(before.name.clone());
        child.fork_overlay_owner = Some(before.name.clone());
        child.fork_generation = Some("aabbccdd".into());
        child.fork_lineage_pid_start_time = None;
        child.forkable = false;
        child.forkpoint_held = true;
        child.fork_env.clear();
        let mut prepared = smolvm::agent::fork::PreparedFork {
            snapshot_dir: smolvm::agent::vm_data_dir(&before.name).join("s/aabbccdd"),
            clone_record: child.clone(),
            port_remaps: vec![],
            source_continues: true,
        };
        verify_sdk_result(&metadata.grant.intent, &before, &after, &prepared).unwrap();
        assert_eq!(
            child.labels.get("smolbox.owner"),
            before.labels.get("smolbox.owner")
        );
        // Wall clocks may move; SDK-selected creation time is a dynamic field.
        prepared.clone_record.created_at = 0;
        verify_sdk_result(&metadata.grant.intent, &before, &after, &prepared).unwrap();
        for case in 0..12 {
            prepared.clone_record = child.clone();
            prepared.source_continues = true;
            prepared.port_remaps.clear();
            let mut source = after.clone();
            match case {
                0 => source.cpus = 2,
                1 => source.pid_start_time = Some(999),
                2 => source.checkpoint_head = Some("f".repeat(32)),
                3 => prepared.clone_record.name = "foreign".into(),
                4 => {
                    prepared
                        .clone_record
                        .labels
                        .insert("smolbox.owner".into(), "d".repeat(64));
                }
                5 => prepared.clone_record.forkpoint_held = false,
                6 => prepared.clone_record.fork_generation = Some("eeff0000".into()),
                7 => prepared.clone_record.state = smolvm::config::RecordState::Running,
                8 => prepared.clone_record.pid = Some(999),
                9 => prepared.clone_record.image = Some("foreign".into()),
                10 => prepared.source_continues = false,
                _ => prepared.port_remaps.push((1, 2, 3)),
            }
            assert!(
                verify_sdk_result(&metadata.grant.intent, &before, &source, &prepared).is_err(),
                "{case}"
            );
        }
    }
}
