//! Pinned registry sidecar manifest verification, without fetching or cache
//! mutation. Descriptor evidence grants neither source approval nor pack authority.
use crate::{Error, ErrorCode, ImagePullRequest, Result, OCI_METADATA_BYTES};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::Instant;

/// Host cache bounds are separate from machine disk reservations and temporary
/// command output. Cache publication does not evict live machine dependencies.
pub const REGISTRY_CACHE_BYTES: u64 = 64 * 1024 * 1024 * 1024;
pub const REGISTRY_CACHE_FILES: usize = 1024;

/// Explicit host cache allowance, independent of machine disk reservations.
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistryCachePolicy {
    pub max_bytes: u64,
    pub max_files: usize,
}
impl RegistryCachePolicy {
    pub fn validate(&self) -> Result<()> {
        if self.max_bytes == 0
            || self.max_bytes > REGISTRY_CACHE_BYTES
            || self.max_files == 0
            || self.max_files > REGISTRY_CACHE_FILES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}

/// Transport-independent identity. Credentials are supplied separately per job.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistryArtifactSource {
    pub reference: String,
    pub platform: String,
    pub content_sha256: String,
}
impl RegistryArtifactSource {
    pub fn validate(&self) -> Result<()> {
        ImagePullRequest {
            reference: self.reference.clone(),
            platform: self.platform.clone(),
        }
        .validate()?;
        if !crate::domain::valid_hex(&self.content_sha256, 64) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }

    /// Verify the exact platform manifest before selecting a download. The
    /// bounded pack reader must separately verify architecture and file bytes.
    pub fn verify_manifest(&self, bytes: &[u8], max_bytes: u64) -> Result<RegistryBlobDescriptor> {
        self.validate()?;
        if max_bytes == 0 || max_bytes > 32 * 1024 * 1024 * 1024 {
            return Err(Error::before(ErrorCode::Validation));
        }
        if bytes.is_empty() || bytes.len() > OCI_METADATA_BYTES {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        let expected = self
            .reference
            .rsplit_once("@sha256:")
            .ok_or(Error::before(ErrorCode::Validation))?
            .1;
        if hex::encode(Sha256::digest(bytes)) != expected {
            return Err(Error::before(ErrorCode::Validation));
        }
        let manifest: Manifest =
            serde_json::from_slice(bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
        if manifest.schema_version != 2
            || manifest.media_type != "application/vnd.oci.image.manifest.v1+json"
            || manifest
                .artifact_type
                .as_deref()
                .is_some_and(|kind| kind != "application/vnd.smolmachines.smolmachine.v1")
            || manifest.config.media_type != "application/vnd.smolmachines.machine.config.v1+json"
            || !valid_digest(&manifest.config.digest)
            || manifest.config.size == 0
            || manifest.config.size > OCI_METADATA_BYTES as u64
            || manifest.layer.media_type != "application/vnd.smolmachines.smolmachine.v1"
            || manifest.layer.digest != format!("sha256:{}", self.content_sha256)
            || manifest.layer.size == 0
            || manifest.layer.size > max_bytes
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(RegistryBlobDescriptor {
            digest: manifest.layer.digest,
            size: manifest.layer.size,
        })
    }
}

/// Exact layer identity/size from a verified manifest; not downloaded content.
#[derive(Clone, PartialEq, Eq)]
pub struct RegistryBlobDescriptor {
    digest: String,
    size: u64,
}
impl RegistryBlobDescriptor {
    pub fn digest(&self) -> &str {
        &self.digest
    }
    pub fn size(&self) -> u64 {
        self.size
    }
}

/// Verified cached content, not a machine/pack qualification. The engine owns
/// the path; request callers cannot substitute one. Pack parsing is separate.
pub struct RegistryCachedBlob {
    path: PathBuf,
    source: RegistryArtifactSource,
    size: u64,
    cached: bool,
}
impl RegistryCachedBlob {
    /// Engine-selected content path. Revalidate it before subsequent use;
    /// cached bytes alone do not constitute an approved prepared pack.
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn source(&self) -> &RegistryArtifactSource {
        &self.source
    }
    pub fn size(&self) -> u64 {
        self.size
    }
    pub fn already_cached(&self) -> bool {
        self.cached
    }
    pub(crate) fn new(
        path: PathBuf,
        source: RegistryArtifactSource,
        size: u64,
        cached: bool,
    ) -> Self {
        Self {
            path,
            source,
            size,
            cached,
        }
    }
}

/// Pinned, validated sidecar plus exact registry origin. Only the engine can
/// construct it; it is not a receipt or approval for an existing machine.
pub struct QualifiedRegistryArtifact {
    pub(crate) source: RegistryArtifactSource,
    pub(crate) prepared: crate::artifact::PreparedArtifact,
    pub(crate) resources: crate::Resources,
}
impl QualifiedRegistryArtifact {
    pub fn source(&self) -> &RegistryArtifactSource {
        &self.source
    }
    pub fn resources(&self) -> crate::Resources {
        self.resources
    }
    pub fn platform(&self) -> &str {
        &self.prepared.manifest.platform
    }
}

fn qualify_blob(
    blob: RegistryCachedBlob,
    domain: &Path,
    resources: crate::Resources,
    deadline: Instant,
    cancel: &crate::Cancellation,
) -> Result<QualifiedRegistryArtifact> {
    resources.validate()?;
    blob.source.validate()?;
    let cache = RegistryCache::existing(domain)?;
    if cache.path(&blob.source) != blob.path
        || !cache.lookup(&blob.source, blob.size, deadline, cancel)?
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(&blob.path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let footer = smolvm_pack::packer::read_footer_from_file(&mut file)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    let manifest = crate::artifact::read_manifest(&mut file, &footer)?;
    let approved = crate::ApprovedArtifact {
        path: blob.path.clone(),
        sha256: blob.source.content_sha256.clone(),
        max_bytes: blob.size,
        guest_platform: blob.source.platform.clone(),
    };
    crate::artifact::validate_manifest(&manifest, &approved, resources)?;
    if cancel.is_cancelled() || Instant::now() >= deadline {
        return Err(Error::uncertain(ErrorCode::State));
    }
    let verified = smolvm::portable_checkpoint::verify_sidecar_pinned(&blob.path)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    if verified.footer().to_bytes() != footer.to_bytes() || !verified.covers(&blob.path) {
        return Err(Error::before(ErrorCode::Validation));
    }
    file.seek(SeekFrom::Start(footer.assets_offset))
        .map_err(|_| Error::before(ErrorCode::Io))?;
    crate::archive::validate_assets(
        BudgetReader {
            file: file.take(footer.assets_size),
            deadline,
            cancel,
        },
        &manifest,
        resources,
    )?;
    if cancel.is_cancelled() || Instant::now() >= deadline {
        return Err(Error::uncertain(ErrorCode::State));
    }
    cache.verify()?;
    if !verified.covers(&blob.path) {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(QualifiedRegistryArtifact {
        source: blob.source,
        resources,
        prepared: crate::artifact::PreparedArtifact {
            path: blob.path,
            manifest,
            verified,
        },
    })
}
struct BudgetReader<'a> {
    file: std::io::Take<File>,
    deadline: Instant,
    cancel: &'a crate::Cancellation,
}
impl Read for BudgetReader<'_> {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        if self.cancel.is_cancelled() || Instant::now() >= self.deadline {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "artifact budget expired",
            ));
        }
        self.file.read(bytes)
    }
}
impl crate::Engine {
    /// Requalify an exact previously prepared blob without registry traffic.
    /// Prepared size is observation, never authority: cache bytes/pack are rechecked.
    pub fn qualify_registry_cached(
        &self,
        source: RegistryArtifactSource,
        size: u64,
        policy: RegistryCachePolicy,
        resources: crate::Resources,
        deadline: Instant,
        cancel: crate::Cancellation,
    ) -> Result<QualifiedRegistryArtifact> {
        if cancel.is_cancelled() || Instant::now() >= deadline || !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
        source.validate()?;
        policy.validate()?;
        resources.validate()?;
        if size == 0
            || size > crate::JOB_REGISTRY_STAGING_BYTES
            || deadline.saturating_duration_since(Instant::now())
                > std::time::Duration::from_secs(86400)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.domain.verify()?;
        let permit = self.jobs.acquire(crate::jobs::Demand::oci_metadata())?;
        let domain = self.domain.clone();
        crate::oci_start::observe_owned(self.jobs.clone(), deadline, cancel.clone(), move || {
            let _lease = permit;
            domain.verify()?;
            let cache = RegistryCache::existing(&domain.directory)?;
            cache.admit(0, policy, deadline, &cancel)?;
            let blob = RegistryCachedBlob::new(cache.path(&source), source, size, true);
            let qualified = qualify_blob(blob, &domain.directory, resources, deadline, &cancel)?;
            domain.verify().map_err(|e| Error::uncertain(e.code))?;
            if cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(Error::uncertain(ErrorCode::State));
            }
            Ok(qualified)
        })
    }

    /// Qualify cached registry content without copying it into another cache or
    /// dispatching SDK creation. No template/guest startup is performed.
    pub fn qualify_registry_blob(
        &self,
        blob: RegistryCachedBlob,
        resources: crate::Resources,
        deadline: Instant,
        cancel: crate::Cancellation,
    ) -> Result<QualifiedRegistryArtifact> {
        if cancel.is_cancelled() || Instant::now() >= deadline || !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
        resources.validate()?;
        if deadline.saturating_duration_since(Instant::now())
            > std::time::Duration::from_secs(86400)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.domain.verify()?;
        let permit = self.jobs.acquire(crate::jobs::Demand::oci_metadata())?;
        let domain = self.domain.clone();
        crate::oci_start::observe_owned(self.jobs.clone(), deadline, cancel.clone(), move || {
            let _lease = permit;
            domain.verify()?;
            let qualified = qualify_blob(blob, &domain.directory, resources, deadline, &cancel)?;
            domain.verify().map_err(|e| Error::uncertain(e.code))?;
            if cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(Error::uncertain(ErrorCode::State));
            }
            Ok(qualified)
        })
    }
}

pub(crate) struct RegistryCache {
    directory: PathBuf,
    handle: File,
}
impl RegistryCache {
    pub(crate) fn open(domain: &Path) -> Result<Self> {
        let directory = domain.join("registry-blobs");
        match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => return Err(Error::before(ErrorCode::Io)),
        }
        Self::existing(domain)
    }
    pub(crate) fn existing(domain: &Path) -> Result<Self> {
        let directory = domain.join("registry-blobs");
        let handle = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let cache = Self { directory, handle };
        cache.verify()?;
        Ok(cache)
    }
    pub(crate) fn directory(&self) -> &Path {
        &self.directory
    }
    pub(crate) fn sync(&self) -> Result<()> {
        self.verify()?;
        self.handle
            .sync_all()
            .map_err(|_| Error::uncertain(ErrorCode::Io))
    }
    pub(crate) fn verify(&self) -> Result<()> {
        let actual = std::fs::symlink_metadata(&self.directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let opened = self
            .handle
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if !actual.is_dir()
            || actual.file_type().is_symlink()
            || actual.uid() != unsafe { libc::geteuid() }
            || actual.mode() & 0o777 != 0o700
            || (actual.dev(), actual.ino()) != (opened.dev(), opened.ino())
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn path(&self, source: &RegistryArtifactSource) -> PathBuf {
        self.directory
            .join(format!("{}.smolmachine", source.content_sha256))
    }
    pub(crate) fn admit(
        &self,
        additional: u64,
        policy: RegistryCachePolicy,
        deadline: Instant,
        cancel: &crate::Cancellation,
    ) -> Result<()> {
        policy.validate()?;
        self.admit_with_limits(
            additional,
            policy.max_bytes,
            policy.max_files,
            deadline,
            cancel,
        )
    }
    fn admit_with_limits(
        &self,
        additional: u64,
        byte_limit: u64,
        file_limit: usize,
        deadline: Instant,
        cancel: &crate::Cancellation,
    ) -> Result<()> {
        if cancel.is_cancelled() || Instant::now() >= deadline {
            return Err(Error::uncertain(ErrorCode::State));
        }
        self.verify()?;
        let mut bytes = 0u64;
        let mut count = 0usize;
        let entries =
            std::fs::read_dir(&self.directory).map_err(|_| Error::before(ErrorCode::Io))?;
        for entry in entries {
            if cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(Error::uncertain(ErrorCode::State));
            }
            count += 1;
            if count > file_limit || (additional > 0 && count == file_limit) {
                return Err(Error::before(ErrorCode::Admission));
            }
            let entry = entry.map_err(|_| Error::before(ErrorCode::Io))?;
            let name = entry.file_name();
            let valid = name
                .to_str()
                .and_then(|name| name.strip_suffix(".smolmachine"))
                .is_some_and(|hash| crate::domain::valid_hex(hash, 64));
            let metadata = std::fs::symlink_metadata(entry.path())
                .map_err(|_| Error::before(ErrorCode::Io))?;
            if !valid
                || !metadata.is_file()
                || metadata.file_type().is_symlink()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.mode() & 0o777 != 0o400
                || metadata.nlink() != 1
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            bytes = bytes
                .checked_add(metadata.len())
                .ok_or(Error::before(ErrorCode::Admission))?;
            if bytes > byte_limit {
                return Err(Error::before(ErrorCode::Admission));
            }
        }
        if additional > byte_limit.saturating_sub(bytes) {
            return Err(Error::before(ErrorCode::Admission));
        }
        self.verify()?;
        if cancel.is_cancelled() || Instant::now() >= deadline {
            return Err(Error::uncertain(ErrorCode::State));
        }
        Ok(())
    }
    pub(crate) fn lookup(
        &self,
        source: &RegistryArtifactSource,
        size: u64,
        deadline: Instant,
        cancel: &crate::Cancellation,
    ) -> Result<bool> {
        self.verify()?;
        let path = self.path(source);
        let mut file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&path)
        {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(_) => return Err(Error::before(ErrorCode::Ownership)),
        };
        let before = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if !before.is_file()
            || before.uid() != unsafe { libc::geteuid() }
            || before.mode() & 0o777 != 0o400
            || before.len() != size
            || before.nlink() != 1
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut hash = Sha256::new();
        let mut count = 0u64;
        let mut buffer = [0; 65536];
        loop {
            if cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(Error::uncertain(ErrorCode::State));
            }
            let read = file
                .read(&mut buffer)
                .map_err(|_| Error::before(ErrorCode::Io))?;
            if read == 0 {
                break;
            }
            count += read as u64;
            if count > size {
                return Err(Error::before(ErrorCode::Validation));
            }
            hash.update(&buffer[..read]);
        }
        let after = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        let named =
            std::fs::symlink_metadata(&path).map_err(|_| Error::before(ErrorCode::Ownership))?;
        if count != size
            || hex::encode(hash.finalize()) != source.content_sha256
            || (
                before.dev(),
                before.ino(),
                before.len(),
                before.mtime(),
                before.mtime_nsec(),
                before.ctime(),
                before.ctime_nsec(),
            ) != (
                after.dev(),
                after.ino(),
                after.len(),
                after.mtime(),
                after.mtime_nsec(),
                after.ctime(),
                after.ctime_nsec(),
            )
            || (named.dev(), named.ino()) != (after.dev(), after.ino())
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.verify()?;
        Ok(true)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    schema_version: u32,
    media_type: String,
    artifact_type: Option<String>,
    config: Descriptor,
    #[serde(rename = "layers", deserialize_with = "single_layer")]
    layer: Descriptor,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Descriptor {
    media_type: String,
    digest: String,
    size: u64,
}
fn valid_digest(value: &str) -> bool {
    value
        .strip_prefix("sha256:")
        .is_some_and(|hash| crate::domain::valid_hex(hash, 64))
}
fn single_layer<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<Descriptor, D::Error> {
    struct Visitor;
    impl<'de> serde::de::Visitor<'de> for Visitor {
        type Value = Descriptor;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("one sidecar layer")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> std::result::Result<Descriptor, A::Error> {
            let layer = seq
                .next_element()?
                .ok_or_else(|| serde::de::Error::custom("missing layer"))?;
            if seq.next_element::<serde::de::IgnoredAny>()?.is_some() {
                return Err(serde::de::Error::custom("extra layer"));
            }
            Ok(layer)
        }
    }
    decoder.deserialize_seq(Visitor)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    pub(crate) fn sidecar_fixture(domain: &Path, platform: &str) -> RegistryCachedBlob {
        sidecar_fixture_mode(domain, platform, smolvm_pack::format::PackMode::Container)
    }

    pub(crate) fn sidecar_fixture_mode(
        domain: &Path,
        platform: &str,
        mode: smolvm_pack::format::PackMode,
    ) -> RegistryCachedBlob {
        fn tar(files: &[(&str, &[u8])]) -> Vec<u8> {
            let mut builder = tar::Builder::new(Vec::new());
            for (path, bytes) in files {
                let mut header = tar::Header::new_gnu();
                header.set_size(bytes.len() as u64);
                header.set_mode(0o644);
                header.set_cksum();
                builder.append_data(&mut header, path, *bytes).unwrap();
            }
            builder.into_inner().unwrap()
        }
        let guest = tar(&[("usr/bin/witness", b"payload")]);
        let digest = "a".repeat(64);
        let layer = format!("layers/{digest}.tar");
        let mut manifest = smolvm_pack::format::PackManifest::new(
            "proof".into(),
            format!("sha256:{digest}"),
            platform.into(),
            "proof".into(),
        );
        manifest.mode = mode.clone();
        manifest.assets.agent_rootfs = smolvm_pack::format::AssetEntry {
            path: "agent-rootfs.tar".into(),
            size: guest.len() as u64,
        };
        let disk = crate::archive::tests::superblock((1 << 30) / 4096);
        let mut files = vec![("agent-rootfs.tar", guest.as_slice())];
        if mode == smolvm_pack::format::PackMode::Container {
            manifest.assets.layers = vec![smolvm_pack::format::LayerEntry {
                digest: format!("sha256:{digest}"),
                path: layer.clone(),
                size: guest.len() as u64,
            }];
            files.push((&layer, guest.as_slice()));
        } else {
            manifest.assets.storage_template = Some(smolvm_pack::format::AssetEntry {
                path: "storage.ext4".into(),
                size: disk.len() as u64,
            });
            manifest.assets.overlay_template = Some(smolvm_pack::format::AssetEntry {
                path: "overlay.ext4".into(),
                size: disk.len() as u64,
            });
            manifest.assets.storage_logical_size = Some(1 << 30);
            manifest.assets.overlay_logical_size = Some(1 << 30);
            files.extend([
                ("storage.ext4", disk.as_slice()),
                ("overlay.ext4", disk.as_slice()),
            ]);
        }
        let assets = zstd::stream::encode_all(tar(&files).as_slice(), 1).unwrap();
        let mut bytes = assets.clone();
        let json = manifest.to_json().unwrap();
        bytes.extend_from_slice(&json);
        let checksum = smolvm_pack::assets::crc32_reader_range(
            &mut std::io::Cursor::new(&bytes),
            0,
            bytes.len() as u64,
        )
        .unwrap();
        let footer = smolvm_pack::format::PackFooter {
            stub_size: 0,
            assets_offset: 0,
            assets_size: assets.len() as u64,
            manifest_offset: assets.len() as u64,
            manifest_size: json.len() as u64,
            checksum,
        };
        bytes.extend_from_slice(&footer.to_bytes());
        let source = RegistryArtifactSource {
            reference: format!("registry.example/team/app@sha256:{}", "b".repeat(64)),
            platform: platform.into(),
            content_sha256: hex::encode(Sha256::digest(&bytes)),
        };
        let cache = RegistryCache::open(domain).unwrap();
        let path = cache.path(&source);
        std::fs::write(&path, &bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        RegistryCachedBlob::new(path, source, bytes.len() as u64, true)
    }

    #[test]
    fn registry_pack_qualification_checks_real_sidecar_assets_and_platform_without_copying() {
        let temp = tempfile::tempdir().unwrap();
        let platform = crate::oci::native_oci_platform();
        let blob = sidecar_fixture(temp.path(), platform);
        let path = blob.path.clone();
        let resources = crate::Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let deadline = Instant::now() + std::time::Duration::from_secs(3);
        let qualified = qualify_blob(
            blob,
            temp.path(),
            resources,
            deadline,
            &crate::Cancellation::new(),
        )
        .unwrap();
        assert_eq!(qualified.platform(), platform);
        assert_eq!(qualified.resources(), resources);
        assert!(qualified.prepared.verified.covers(&path));
        assert_eq!(
            std::fs::read_dir(temp.path().join("registry-blobs"))
                .unwrap()
                .count(),
            1
        );
        let other = if platform == "linux/arm64" {
            "linux/amd64"
        } else {
            "linux/arm64"
        };
        let mut wrong = sidecar_fixture(temp.path(), other);
        wrong.source.platform = platform.into();
        assert!(qualify_blob(
            wrong,
            temp.path(),
            resources,
            deadline,
            &crate::Cancellation::new()
        )
        .is_err());
        let blob = sidecar_fixture(temp.path(), platform);
        let cancel = crate::Cancellation::new();
        cancel.cancel();
        assert!(qualify_blob(blob, temp.path(), resources, deadline, &cancel).is_err());
    }

    #[test]
    fn registry_pack_qualification_rejects_checksum_layout_and_asset_corruption() {
        let platform = crate::oci::native_oci_platform();
        let resources = crate::Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        for fault in ["checksum", "layout", "assets"] {
            let temp = tempfile::tempdir().unwrap();
            let blob = sidecar_fixture(temp.path(), platform);
            let mut bytes = std::fs::read(&blob.path).unwrap();
            let footer_offset = bytes.len() - smolvm_pack::format::FOOTER_SIZE;
            let mut footer = smolvm_pack::format::PackFooter::from_bytes(
                bytes[footer_offset..].try_into().unwrap(),
            )
            .unwrap();
            match fault {
                "checksum" => footer.checksum ^= 1,
                "layout" => footer.stub_size = 1,
                "assets" => {
                    bytes[0] ^= 1;
                    footer.checksum = smolvm_pack::assets::crc32(&bytes[..footer_offset]);
                }
                _ => unreachable!(),
            }
            bytes[footer_offset..].copy_from_slice(&footer.to_bytes());
            let cache = RegistryCache::open(temp.path()).unwrap();
            let mut source = blob.source.clone();
            source.content_sha256 = hex::encode(Sha256::digest(&bytes));
            let path = cache.path(&source);
            std::fs::write(&path, &bytes).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
            let changed = RegistryCachedBlob::new(path, source, bytes.len() as u64, true);
            assert!(
                qualify_blob(
                    changed,
                    temp.path(),
                    resources,
                    Instant::now() + std::time::Duration::from_secs(3),
                    &crate::Cancellation::new()
                )
                .is_err(),
                "{fault}"
            );
        }
    }

    #[test]
    fn registry_pack_reader_honors_budget_and_cached_blob_cannot_cross_domains() {
        let temp = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let blob = sidecar_fixture(temp.path(), crate::oci::native_oci_platform());
        let resources = crate::Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        assert!(qualify_blob(
            blob,
            other.path(),
            resources,
            Instant::now() + std::time::Duration::from_secs(2),
            &crate::Cancellation::new()
        )
        .is_err());
        let blob = sidecar_fixture(temp.path(), crate::oci::native_oci_platform());
        let file = File::open(blob.path()).unwrap();
        let cancel = crate::Cancellation::new();
        let mut reader = BudgetReader {
            file: file.take(blob.size),
            deadline: Instant::now(),
            cancel: &cancel,
        };
        assert_eq!(
            reader.read(&mut [0; 16]).unwrap_err().kind(),
            std::io::ErrorKind::TimedOut
        );
        let file = File::open(blob.path()).unwrap();
        cancel.cancel();
        let mut reader = BudgetReader {
            file: file.take(blob.size),
            deadline: Instant::now() + std::time::Duration::from_secs(2),
            cancel: &cancel,
        };
        assert!(reader.read(&mut [0; 16]).is_err());
    }

    #[test]
    fn retained_cache_capacity_counts_bytes_and_entries_without_eviction() {
        let temp = tempfile::tempdir().unwrap();
        let cache = RegistryCache::open(temp.path()).unwrap();
        let cancel = crate::Cancellation::new();
        let deadline = Instant::now() + std::time::Duration::from_secs(2);
        assert!(cache.admit_with_limits(6, 6, 2, deadline, &cancel).is_ok());
        let path = cache
            .directory()
            .join(format!("{}.smolmachine", "a".repeat(64)));
        std::fs::write(&path, b"1234").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert!(cache.admit_with_limits(2, 6, 2, deadline, &cancel).is_ok());
        assert!(cache.admit_with_limits(0, 4, 1, deadline, &cancel).is_ok());
        assert!(cache.admit_with_limits(0, 3, 1, deadline, &cancel).is_err());
        assert_eq!(
            cache
                .admit_with_limits(3, 6, 2, deadline, &cancel)
                .err()
                .unwrap()
                .code,
            ErrorCode::Admission
        );
        assert_eq!(
            cache
                .admit_with_limits(1, 6, 1, deadline, &cancel)
                .err()
                .unwrap()
                .code,
            ErrorCode::Admission
        );
        assert_eq!(std::fs::read(&path).unwrap(), b"1234");
        let unknown = cache.directory().join("unknown.partial");
        std::fs::write(&unknown, b"x").unwrap();
        assert_eq!(
            cache
                .admit_with_limits(1, 6, 4, deadline, &cancel)
                .err()
                .unwrap()
                .code,
            ErrorCode::Ownership
        );
        std::fs::remove_file(&unknown).unwrap();
        cancel.cancel();
        assert!(cache.admit_with_limits(1, 6, 2, deadline, &cancel).is_err());
    }

    #[test]
    fn cache_policy_is_explicit_bounded_and_strict() {
        for policy in [
            RegistryCachePolicy {
                max_bytes: 0,
                max_files: 1,
            },
            RegistryCachePolicy {
                max_bytes: REGISTRY_CACHE_BYTES + 1,
                max_files: 1,
            },
            RegistryCachePolicy {
                max_bytes: 1,
                max_files: 0,
            },
            RegistryCachePolicy {
                max_bytes: 1,
                max_files: REGISTRY_CACHE_FILES + 1,
            },
        ] {
            assert!(policy.validate().is_err());
        }
        let policy = RegistryCachePolicy {
            max_bytes: REGISTRY_CACHE_BYTES,
            max_files: REGISTRY_CACHE_FILES,
        };
        assert!(policy.validate().is_ok());
        let mut value = serde_json::to_value(policy).unwrap();
        value["evict"] = serde_json::json!(true);
        assert!(serde_json::from_value::<RegistryCachePolicy>(value).is_err());
    }

    #[test]
    fn protected_cache_rejects_links_wrong_modes_and_cancellation() {
        let temp = tempfile::tempdir().unwrap();
        let cache = RegistryCache::open(temp.path()).unwrap();
        let blob = b"cache";
        let source = RegistryArtifactSource {
            reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
            platform: "linux/arm64".into(),
            content_sha256: hex::encode(Sha256::digest(blob)),
        };
        let path = cache.path(&source);
        let deadline = Instant::now() + std::time::Duration::from_secs(2);
        assert!(!cache
            .lookup(&source, 5, deadline, &crate::Cancellation::new())
            .unwrap());
        std::fs::write(&path, blob).unwrap();
        assert!(cache
            .lookup(&source, 5, deadline, &crate::Cancellation::new())
            .is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert!(cache
            .lookup(&source, 5, deadline, &crate::Cancellation::new())
            .unwrap());
        let cancel = crate::Cancellation::new();
        cancel.cancel();
        assert!(cache.lookup(&source, 5, deadline, &cancel).is_err());
        assert!(cache
            .lookup(&source, 4, deadline, &crate::Cancellation::new())
            .is_err());
        let hard = temp.path().join("hard");
        std::fs::hard_link(&path, &hard).unwrap();
        assert!(cache
            .lookup(&source, 5, deadline, &crate::Cancellation::new())
            .is_err());
        std::fs::remove_file(&hard).unwrap();
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&hard, &path).unwrap();
        assert!(cache
            .lookup(&source, 5, deadline, &crate::Cancellation::new())
            .is_err());
        std::fs::set_permissions(cache.directory(), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        assert!(cache.verify().is_err());
    }
    fn manifest() -> serde_json::Value {
        serde_json::json!({"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
            "config":{"mediaType":"application/vnd.smolmachines.machine.config.v1+json","digest":format!("sha256:{}", "b".repeat(64)),"size":2},
            "layers":[{"mediaType":"application/vnd.smolmachines.smolmachine.v1","digest":format!("sha256:{}", "a".repeat(64)),"size":123}]})
    }
    fn pinned(value: &serde_json::Value) -> (RegistryArtifactSource, Vec<u8>) {
        let bytes = serde_json::to_vec(value).unwrap();
        (
            RegistryArtifactSource {
                reference: format!(
                    "registry.example.com/team/app@sha256:{}",
                    hex::encode(Sha256::digest(&bytes))
                ),
                platform: "linux/arm64".into(),
                content_sha256: "a".repeat(64),
            },
            bytes,
        )
    }
    #[test]
    fn registry_descriptor_binds_distinct_manifest_and_content() {
        let (source, bytes) = pinned(&manifest());
        let descriptor = source.verify_manifest(&bytes, 123).unwrap();
        assert_eq!(descriptor.size(), 123);
        assert_eq!(
            descriptor.digest(),
            format!("sha256:{}", source.content_sha256)
        );
        assert!(source.verify_manifest(&bytes, 122).is_err());
        assert!(source.verify_manifest(b"{}", 123).is_err());
        let mut changed = source.clone();
        changed.content_sha256 = "c".repeat(64);
        assert!(changed.verify_manifest(&bytes, 123).is_err());
        assert!(source
            .verify_manifest(&vec![0; OCI_METADATA_BYTES + 1], 123)
            .is_err());
    }
    #[test]
    fn registry_descriptor_rejects_index_mixed_layers_and_invalid_metadata() {
        for field in [
            "schemaVersion",
            "mediaType",
            "artifactType",
            "config",
            "layers",
        ] {
            let mut value = manifest();
            value[field] = match field {
                "schemaVersion" => serde_json::json!(1),
                "mediaType" => serde_json::json!("application/vnd.oci.image.index.v1+json"),
                "artifactType" => serde_json::json!("wrong"),
                "config" => {
                    serde_json::json!({"mediaType":"application/vnd.smolmachines.machine.config.v1+json","digest":"sha256:../bad","size":2})
                }
                _ => serde_json::json!([]),
            };
            let (source, bytes) = pinned(&value);
            assert!(source.verify_manifest(&bytes, 123).is_err(), "{field}");
        }
        let mut value = manifest();
        let extra = value["layers"][0].clone();
        value["layers"].as_array_mut().unwrap().push(extra);
        let (source, bytes) = pinned(&value);
        assert!(source.verify_manifest(&bytes, 123).is_err());
    }
    #[test]
    fn registry_identity_excludes_credentials_and_invalid_references() {
        let (mut source, _) = pinned(&manifest());
        let mut value = serde_json::to_value(&source).unwrap();
        value["identity_token"] = serde_json::json!("private");
        assert!(serde_json::from_value::<RegistryArtifactSource>(value).is_err());
        source.reference = "registry.example.com/team/app:latest".into();
        assert!(source.validate().is_err());
        source.content_sha256 = "A".repeat(64);
        assert!(source.validate().is_err());
    }

    #[test]
    fn registry_descriptor_rejects_malformed_sizes_types_and_duplicate_fields() {
        for (section, field, invalid) in [
            ("config", "size", serde_json::json!(0)),
            ("config", "size", serde_json::json!(OCI_METADATA_BYTES + 1)),
            (
                "config",
                "mediaType",
                serde_json::json!("application/vnd.oci.image.config.v1+json"),
            ),
            ("layers", "size", serde_json::json!(0)),
            ("layers", "size", serde_json::json!(-1)),
            (
                "layers",
                "mediaType",
                serde_json::json!("application/vnd.oci.image.layer.v1.tar"),
            ),
            (
                "layers",
                "digest",
                serde_json::json!(format!("sha256:{}", "c".repeat(64))),
            ),
        ] {
            let mut value = manifest();
            if section == "layers" {
                value[section][0][field] = invalid;
            } else {
                value[section][field] = invalid;
            }
            let (source, bytes) = pinned(&value);
            assert!(
                source.verify_manifest(&bytes, 123).is_err(),
                "{section}.{field}"
            );
        }
        let (mut source, bytes) = pinned(&manifest());
        let duplicate = String::from_utf8(bytes)
            .unwrap()
            .replacen("{", "{\"schemaVersion\":2,", 1)
            .into_bytes();
        source.reference = format!(
            "registry.example.com/team/app@sha256:{}",
            hex::encode(Sha256::digest(&duplicate))
        );
        assert!(source.verify_manifest(&duplicate, 123).is_err());
    }
}
