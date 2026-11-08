//! SDK materialization into request-private storage. Never reserves a machine.
use crate::checkpoint::Budgeted;
use crate::transfer_worker::{Blob, Request};
use crate::{
    ApprovedCheckpoint, ApprovedCheckpointArtifact, Error, ErrorCode, ReadBudget, Resources, Result,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolvm_pack::format::{CheckpointLayout, PackManifest};
use std::collections::BTreeMap;
use std::fs::Metadata as FsMetadata;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub(crate) const METADATA_BYTES: u64 = 16 * 1024 * 1024;
pub(crate) const MATERIAL_BYTES: u64 = 2 * 1024 * 1024 * 1024 * 1024;
pub(crate) const THREADS: &str = "4";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Expected {
    pub metadata_sha256: String,
    pub source_sha256: String,
}
impl Expected {
    pub(crate) fn validate(&self) -> Result<()> {
        if !crate::domain::valid_hex(&self.metadata_sha256, 64)
            || !crate::domain::valid_hex(&self.source_sha256, 64)
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
    pub device: u64,
    pub inode: u64,
    pub logical_bytes: u64,
    pub files: u32,
    pub material_sha256: String,
}
impl Proof {
    pub(crate) fn matches(&self, expected: &Expected) -> bool {
        &self.expected == expected
            && self.logical_bytes > 0
            && self.logical_bytes <= MATERIAL_BYTES
            && (1..=256).contains(&self.files)
            && crate::domain::valid_hex(&self.material_sha256, 64)
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct FileVersion {
    device: u64,
    inode: u64,
    bytes: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
impl FileVersion {
    pub(crate) fn of(metadata: &FsMetadata) -> Self {
        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            bytes: metadata.len(),
            mode: metadata.mode(),
            uid: metadata.uid(),
            gid: metadata.gid(),
            mtime: metadata.mtime(),
            mtime_ns: metadata.mtime_nsec(),
            ctime: metadata.ctime(),
            ctime_ns: metadata.ctime_nsec(),
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
    cpus: u8,
    memory_mib: u32,
    storage_gib: u64,
    overlay_gib: u64,
}
impl Profile {
    fn resources(&self) -> Resources {
        Resources {
            cpus: self.cpus,
            memory_mib: self.memory_mib,
            storage_gib: self.storage_gib,
            overlay_gib: self.overlay_gib,
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Metadata {
    schema: u8,
    root: PathBuf,
    root_device: u64,
    root_inode: u64,
    source_sha256: String,
    source_bytes: u64,
    sdk_version: String,
    host_platform: String,
    guest_platform: String,
    profile: Profile,
    manifest: PackManifest,
    versions: BTreeMap<PathBuf, FileVersion>,
    deadline_ns: u64,
}
impl Metadata {
    pub(crate) fn new(
        root: &Path,
        root_metadata: &FsMetadata,
        approval: &ApprovedCheckpoint,
        manifest: &PackManifest,
        versions: &BTreeMap<PathBuf, FsMetadata>,
        deadline: std::time::Instant,
    ) -> Result<(Self, Expected)> {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() || remaining > Duration::from_secs(86_400) {
            return Err(Error::before(ErrorCode::State));
        }
        let deadline_ns = crate::buffered::monotonic_ns()?
            .checked_add(remaining.as_nanos() as u64)
            .ok_or(Error::before(ErrorCode::Validation))?;
        let resources = approval.resources;
        let metadata = Self {
            schema: 1,
            root: root.into(),
            root_device: root_metadata.dev(),
            root_inode: root_metadata.ino(),
            source_sha256: approval.artifact.sha256.clone(),
            source_bytes: approval.artifact.max_bytes,
            sdk_version: approval.sdk_version.clone(),
            host_platform: approval.host_platform.clone(),
            guest_platform: approval.artifact.guest_platform.clone(),
            profile: Profile {
                cpus: resources.cpus,
                memory_mib: resources.memory_mib,
                storage_gib: resources.storage_gib,
                overlay_gib: resources.overlay_gib,
            },
            manifest: manifest.clone(),
            versions: versions
                .iter()
                .map(|(path, metadata)| (path.clone(), FileVersion::of(metadata)))
                .collect(),
            deadline_ns,
        };
        let bytes = metadata.encode()?;
        let expected = Expected {
            metadata_sha256: hex::encode(Sha256::digest(bytes)),
            source_sha256: approval.artifact.sha256.clone(),
        };
        Ok((metadata, expected))
    }
    pub(crate) fn encode(&self) -> Result<Vec<u8>> {
        let bytes = serde_json::to_vec(self).map_err(|_| Error::before(ErrorCode::Validation))?;
        if bytes.is_empty() || bytes.len() as u64 > METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(bytes)
    }
    fn approval(&self) -> ApprovedCheckpoint {
        ApprovedCheckpoint {
            artifact: ApprovedCheckpointArtifact {
                path: self.root.join("input.smolcheckpoint"),
                sha256: self.source_sha256.clone(),
                max_bytes: self.source_bytes,
                guest_platform: self.guest_platform.clone(),
            },
            sdk_version: self.sdk_version.clone(),
            host_platform: self.host_platform.clone(),
            resources: self.profile.resources(),
        }
    }
    fn verify(&self, budget: &ReadBudget, uid: u32) -> Result<()> {
        budget.check()?;
        if self.schema != 1 || self.versions.len() > crate::checkpoint::HISTORY_ENTRIES + 258 {
            return Err(Error::before(ErrorCode::Validation));
        }
        crate::host::private_directory(&self.root)?;
        let root = std::fs::symlink_metadata(&self.root)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if root.uid() != uid || (root.dev(), root.ino()) != (self.root_device, self.root_inode) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.approval().validate_compatibility(&self.manifest)?;
        for (path, version) in &self.versions {
            budget.check()?;
            if !path.starts_with(&self.root)
                || path
                    .components()
                    .any(|part| matches!(part, std::path::Component::ParentDir))
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let file = crate::artifact::open_regular(path)?;
            let metadata = file
                .metadata()
                .map_err(|_| Error::before(ErrorCode::Ownership))?;
            if metadata.uid() != uid
                || metadata.mode() & 0o777 != 0o400
                || FileVersion::of(&metadata) != *version
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        if !self
            .versions
            .contains_key(&self.root.join("input.smolcheckpoint"))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

pub(crate) fn run(request: &Request, blob: &Blob, expected: &Expected) -> Result<Proof> {
    expected.validate()?;
    let metadata: Metadata = blob.read(request.owner, METADATA_BYTES)?;
    if hex::encode(Sha256::digest(metadata.encode()?)) != expected.metadata_sha256
        || metadata.source_sha256 != expected.source_sha256
        || request.staging.parent() != Some(metadata.root.as_path())
        || request.socket.parent() != Some(metadata.root.as_path())
        || std::env::var("SMOLVM_CHECKPOINT_THREADS").as_deref() != Ok(THREADS)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let remaining = metadata
        .deadline_ns
        .saturating_sub(crate::buffered::monotonic_ns()?);
    let budget = ReadBudget::for_checkpoint_work(
        Duration::from_nanos(remaining),
        crate::Cancellation::default(),
    )?;
    metadata.verify(&budget, request.owner.uid)?;
    let root = metadata.root.join("materialized");
    match std::fs::symlink_metadata(&root) {
        Ok(_) => return Err(Error::before(ErrorCode::Conflict)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(Error::before(ErrorCode::Io)),
    }
    let input = metadata.root.join("input.smolcheckpoint");
    let manifest =
        if metadata.manifest.checkpoint.as_ref().unwrap().payload == CheckpointLayout::Chunked {
            smolvm::checkpoint_store::materialize(&metadata.root.join("history"), &root)
                .map_err(|_| Error::before(ErrorCode::Native))?
        } else {
            let mut file = crate::artifact::open_regular(&input)?;
            let footer = smolvm_pack::packer::read_footer_from_file(&mut file)
                .map_err(|_| Error::before(ErrorCode::Validation))?;
            smolvm_pack::extract::extract_checkpoint_sidecar(&input, &root, &footer, &[], &[])
                .map_err(|_| Error::before(ErrorCode::Native))?;
            metadata.manifest.clone()
        };
    budget.check()?;
    metadata.verify(&budget, request.owner.uid)?;
    // SDK unpack applies archive parent-directory modes, including 0755. Only
    // this fresh output beneath the still-private source root may be tightened.
    let directory = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&root)
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    let identity = directory
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !identity.is_dir() || identity.uid() != request.owner.uid {
        return Err(Error::before(ErrorCode::Ownership));
    }
    directory
        .set_permissions(std::fs::Permissions::from_mode(0o700))
        .and_then(|()| directory.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let named =
        std::fs::symlink_metadata(&root).map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !named.is_dir() || (named.dev(), named.ino()) != (identity.dev(), identity.ino()) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut normalized = metadata.manifest.clone();
    if normalized.checkpoint.as_ref().unwrap().payload == CheckpointLayout::Chunked {
        let header = normalized.checkpoint.as_mut().unwrap();
        header.payload = CheckpointLayout::Assets;
        header.version = smolvm::portable_checkpoint::FORMAT_VERSION;
        header.history.clear();
    }
    if manifest
        .to_json()
        .map_err(|_| Error::before(ErrorCode::Validation))?
        != normalized
            .to_json()
            .map_err(|_| Error::before(ErrorCode::Validation))?
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    material_proof(
        &root,
        &manifest,
        metadata.profile.resources(),
        expected.clone(),
        &budget,
    )
}

pub(crate) fn material_bytes(manifest: &PackManifest, resources: Resources) -> Result<u64> {
    let mut head = manifest.clone();
    if let Some(checkpoint) = head.checkpoint.as_mut() {
        checkpoint.payload = CheckpointLayout::Assets;
        checkpoint.version = smolvm::portable_checkpoint::FORMAT_VERSION;
        checkpoint.history.clear();
    }
    let files = crate::archive::checkpoint_expected_files(&head, resources)?;
    let total = files.values().try_fold(0u64, |sum, (size, _)| {
        sum.checked_add(*size)
            .ok_or(Error::before(ErrorCode::Validation))
    })?;
    if total == 0 || total > MATERIAL_BYTES {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(total)
}

pub(crate) fn material_proof(
    root: &Path,
    manifest: &PackManifest,
    resources: Resources,
    expected: Expected,
    budget: &ReadBudget,
) -> Result<Proof> {
    budget.check()?;
    crate::host::private_directory(root)?;
    let files = crate::archive::checkpoint_expected_files(manifest, resources)?;
    let mut identities = BTreeMap::new();
    let mut total = 0u64;
    for (path, (size, digest)) in &files {
        budget.check()?;
        let mut file = crate::artifact::open_regular(&root.join(path))?;
        let before = file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if before.len() != *size
            || before.uid() != unsafe { libc::geteuid() }
            || before.mode() & 0o022 != 0
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(digest) = digest {
            let actual = crate::artifact::copy_hash(
                &mut Budgeted {
                    input: &mut file,
                    budget,
                },
                &mut std::io::sink(),
                *size,
            )?;
            if actual != *digest {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        crate::checkpoint::verify_input(&file, &root.join(path), &before)?;
        identities.insert(path, FileVersion::of(&before));
        total = total
            .checked_add(*size)
            .ok_or(Error::before(ErrorCode::Validation))?;
    }
    if total == 0 || total > MATERIAL_BYTES {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    let mut walked = Vec::from([root.to_path_buf()]);
    let mut seen = 0usize;
    while let Some(directory) = walked.pop() {
        budget.check()?;
        for entry in
            std::fs::read_dir(&directory).map_err(|_| Error::before(ErrorCode::Ownership))?
        {
            budget.check()?;
            seen += 1;
            if seen > 1024 {
                return Err(Error::before(ErrorCode::Validation));
            }
            let entry = entry.map_err(|_| Error::before(ErrorCode::Ownership))?;
            let metadata = std::fs::symlink_metadata(entry.path())
                .map_err(|_| Error::before(ErrorCode::Ownership))?;
            if metadata.is_dir() {
                walked.push(entry.path());
            } else if !metadata.is_file()
                || !files.contains_key(
                    entry
                        .path()
                        .strip_prefix(root)
                        .map_err(|_| Error::before(ErrorCode::Ownership))?
                        .to_str()
                        .ok_or(Error::before(ErrorCode::Ownership))?,
                )
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
    }
    let root_metadata =
        std::fs::symlink_metadata(root).map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !root_metadata.is_dir() {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(Proof {
        expected,
        device: root_metadata.dev(),
        inode: root_metadata.ino(),
        logical_bytes: total,
        files: files.len() as u32,
        material_sha256: hex::encode(Sha256::digest(
            serde_json::to_vec(&identities).map_err(|_| Error::before(ErrorCode::Validation))?,
        )),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    #[ignore = "requires an explicitly supplied ordinary SDK checkpoint fixture"]
    fn materialize_operator_checkpoint_fixture_without_native_state() {
        let input = PathBuf::from(
            std::env::var_os("SMOLBOX_CHECKPOINT_FIXTURE").expect("explicit checkpoint fixture"),
        );
        let expected =
            std::env::var("SMOLBOX_CHECKPOINT_FIXTURE_SHA256").expect("explicit checkpoint digest");
        assert_eq!(
            hex::encode(Sha256::digest(std::fs::read(&input).unwrap())),
            expected
        );
        let manifest = smolvm_pack::packer::read_manifest_from_sidecar(&input).unwrap();
        let header = manifest.checkpoint.as_ref().unwrap();
        let resources = Resources {
            cpus: header.cpus,
            memory_mib: header.memory_mib,
            storage_gib: header.storage_gib.unwrap(),
            overlay_gib: header.overlay_gib.unwrap(),
        };
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary
            .path()
            .canonicalize()
            .unwrap()
            .join("materialized");
        let footer =
            smolvm_pack::packer::read_footer_from_file(&mut std::fs::File::open(&input).unwrap())
                .unwrap();
        smolvm_pack::extract::extract_checkpoint_sidecar(&input, &root, &footer, &[], &[])
            .expect("SDK request-private extraction");
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        eprintln!("SDK request-private extraction passed");
        for (path, (size, _)) in
            crate::archive::checkpoint_expected_files(&manifest, resources).unwrap()
        {
            let metadata = std::fs::symlink_metadata(root.join(&path)).unwrap();
            if metadata.len() != size
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.mode() & 0o022 != 0
                || metadata.nlink() != 1
            {
                eprintln!(
                    "material mismatch {path}: size={} expected={size} mode={:o} uid={} links={}",
                    metadata.len(),
                    metadata.mode(),
                    metadata.uid(),
                    metadata.nlink()
                );
            }
        }
        let budget = ReadBudget::for_checkpoint_work(
            Duration::from_secs(120),
            crate::Cancellation::default(),
        )
        .unwrap();
        material_proof(
            &root,
            &manifest,
            resources,
            Expected {
                metadata_sha256: "a".repeat(64),
                source_sha256: expected,
            },
            &budget,
        )
        .expect("complete material proof");
        eprintln!("complete material proof passed; native state unopened");
    }

    #[test]
    fn material_evidence_binds_exact_files_versions_digests_and_rejects_extra_or_redirected_data() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let (approval, manifest, files) = crate::checkpoint::tests::payload_fixture();
        for (path, bytes) in files {
            let path = root.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, bytes).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let budget = ReadBudget::for_checkpoint_work(
            Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        let expected = Expected {
            metadata_sha256: "a".repeat(64),
            source_sha256: "b".repeat(64),
        };
        let proof = material_proof(
            &root,
            &manifest,
            approval.resources,
            expected.clone(),
            &budget,
        )
        .unwrap();
        assert!(proof.matches(&expected));
        assert_eq!(proof.files, 6);
        assert_eq!(
            proof.logical_bytes,
            material_bytes(&manifest, approval.resources).unwrap()
        );
        assert_eq!(
            proof,
            material_proof(
                &root,
                &manifest,
                approval.resources,
                expected.clone(),
                &budget
            )
            .unwrap()
        );
        std::fs::write(root.join("extra"), b"unlisted").unwrap();
        assert!(material_proof(
            &root,
            &manifest,
            approval.resources,
            expected.clone(),
            &budget
        )
        .is_err());
        std::fs::remove_file(root.join("extra")).unwrap();
        let state = root.join("checkpoint/checkpoint.bin");
        std::fs::write(&state, b"other").unwrap();
        assert!(material_proof(
            &root,
            &manifest,
            approval.resources,
            expected.clone(),
            &budget
        )
        .is_err());
        std::fs::remove_file(&state).unwrap();
        std::os::unix::fs::symlink(root.join("checkpoint/memory.bin"), &state).unwrap();
        assert!(material_proof(&root, &manifest, approval.resources, expected, &budget).is_err());
    }
}
