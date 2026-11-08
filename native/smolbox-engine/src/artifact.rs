use crate::domain::valid_hex;
use crate::{Error, ErrorCode, Resources, Result};
use sha2::{Digest, Sha256};
use smolvm_pack::format::{PackManifest, PackMode};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// Selected from the caller's approval catalog, never resolved from a registry.
#[derive(Clone)]
pub struct ApprovedArtifact {
    pub path: PathBuf,
    pub sha256: String,
    pub max_bytes: u64,
    pub guest_platform: String,
}

impl std::fmt::Debug for ApprovedArtifact {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApprovedArtifact")
            .field("sha256", &self.sha256)
            .field("guest_platform", &self.guest_platform)
            .finish_non_exhaustive()
    }
}

pub(crate) struct PreparedArtifact {
    pub path: PathBuf,
    pub manifest: PackManifest,
    pub verified: smolvm::portable_checkpoint::VerifiedSidecar,
}

impl ApprovedArtifact {
    pub(crate) fn validate(&self) -> Result<()> {
        if !self.path.is_absolute()
            || !valid_hex(&self.sha256, 64)
            || self.max_bytes == 0
            || self.max_bytes > 32 * 1024 * 1024 * 1024
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }

    pub(crate) fn prepare(&self, cache: &Path, resources: Resources) -> Result<PreparedArtifact> {
        resources.validate()?;
        self.validate()?;
        std::fs::create_dir_all(cache).map_err(|_| Error::before(ErrorCode::Io))?;
        let path = cache.join(format!("{}.smolmachine", self.sha256));
        if !path.exists() {
            let mut source = open_regular(&self.path)?;
            let mut staged =
                tempfile::NamedTempFile::new_in(cache).map_err(|_| Error::before(ErrorCode::Io))?;
            let actual = copy_hash(&mut source, &mut staged, self.max_bytes)?;
            if actual != self.sha256 {
                return Err(Error::before(ErrorCode::Validation));
            }
            staged
                .as_file()
                .sync_all()
                .map_err(|_| Error::before(ErrorCode::Io))?;
            staged
                .as_file()
                .set_permissions(std::fs::Permissions::from_mode(0o400))
                .map_err(|_| Error::before(ErrorCode::Io))?;
            staged
                .persist_noclobber(&path)
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            File::open(cache)
                .and_then(|f| f.sync_all())
                .map_err(|_| Error::before(ErrorCode::Io))?;
        }
        // Rehash existing cached data too. A filename is not integrity evidence.
        let verified = smolvm::portable_checkpoint::verify_sidecar_pinned(&path)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        let mut file = open_regular(&path)?;
        let actual = copy_hash(&mut file, &mut std::io::sink(), self.max_bytes)?;
        if actual != self.sha256 || !verified.covers(&path) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let manifest = read_manifest(&mut file, verified.footer())?;
        validate_manifest(&manifest, self, resources)?;
        let footer = verified.footer();
        file.seek(SeekFrom::Start(footer.assets_offset))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        crate::archive::validate_assets(file.take(footer.assets_size), &manifest, resources)?;
        if !verified.covers(&path) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(PreparedArtifact {
            path,
            manifest,
            verified,
        })
    }
}

/// Bound the SDK footer before invoking its public typed manifest parser.
pub(crate) fn read_manifest(
    file: &mut File,
    footer: &smolvm_pack::format::PackFooter,
) -> Result<PackManifest> {
    validate_sidecar_layout(
        footer,
        file.metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?
            .len(),
    )?;
    if footer.manifest_size == 0 || footer.manifest_size > 1024 * 1024 {
        return Err(Error::before(ErrorCode::Validation));
    }
    file.seek(SeekFrom::Start(footer.manifest_offset))
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let mut bytes = vec![0; footer.manifest_size as usize];
    file.read_exact(&mut bytes)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    PackManifest::from_json(&bytes).map_err(|_| Error::before(ErrorCode::Validation))
}

fn validate_sidecar_layout(footer: &smolvm_pack::format::PackFooter, length: u64) -> Result<()> {
    // SDK materialize_pack_layers reads sidecar assets at byte zero. Embedded
    // executable packs, gaps and undeclared suffixes are not sidecar inputs.
    if footer.stub_size != 0
        || footer.assets_offset != 0
        || footer.manifest_offset != footer.assets_size
        || footer
            .manifest_offset
            .checked_add(footer.manifest_size)
            .and_then(|end| end.checked_add(smolvm_pack::format::FOOTER_SIZE as u64))
            != Some(length)
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(())
}

fn open_regular(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    if !file
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?
        .is_file()
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(file)
}

fn copy_hash(source: &mut impl Read, destination: &mut impl Write, cap: u64) -> Result<String> {
    let mut hash = Sha256::new();
    let mut count = 0u64;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let size = source
            .read(&mut buffer)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if size == 0 {
            break;
        }
        count = count
            .checked_add(size as u64)
            .ok_or(Error::before(ErrorCode::Validation))?;
        if count > cap {
            return Err(Error::before(ErrorCode::Validation));
        }
        hash.update(&buffer[..size]);
        destination
            .write_all(&buffer[..size])
            .map_err(|_| Error::before(ErrorCode::Io))?;
    }
    Ok(hex::encode(hash.finalize()))
}

pub(crate) fn validate_manifest(
    manifest: &PackManifest,
    approved: &ApprovedArtifact,
    resources: Resources,
) -> Result<()> {
    if manifest.platform != approved.guest_platform
        || manifest.checkpoint.is_some()
        || !manifest.secret_refs.is_empty()
        || manifest.gpu
        || manifest.cuda
        || manifest.assets.workspace_seed.is_some()
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    smolvm::platform::ensure_artifact_arch_matches_host(&manifest.platform)
        .map_err(|_| Error::before(ErrorCode::Unsupported))?;
    match manifest.mode {
        PackMode::Container => {
            if manifest.image.is_empty()
                || manifest.image.starts_with("vm://")
                || manifest.assets.layers.is_empty()
                || manifest.assets.overlay_template.is_some()
            {
                return Err(Error::before(ErrorCode::Unsupported));
            }
        }
        PackMode::Vm => {
            // Logical sizes take precedence in upstream seeding. Require the
            // actual disk topology to agree with the admitted resources.
            if manifest.assets.overlay_template.is_none()
                || manifest.assets.storage_template.is_none()
                || vm_disk_size(
                    manifest.assets.overlay_logical_size,
                    manifest.assets.overlay_template.as_ref(),
                ) != Some(resources.overlay_gib << 30)
                || vm_disk_size(
                    manifest.assets.storage_logical_size,
                    manifest.assets.storage_template.as_ref(),
                ) != Some(resources.storage_gib << 30)
            {
                return Err(Error::before(ErrorCode::Unsupported));
            }
        }
    }
    Ok(())
}

fn vm_disk_size(
    logical: Option<u64>,
    asset: Option<&smolvm_pack::format::AssetEntry>,
) -> Option<u64> {
    // The SDK omits overlay_logical_size when the packed file already has its
    // full backing length. Truncated files still need an explicit logical size.
    logical.or_else(|| asset.map(|asset| asset.size))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecar_layout_matches_the_sdk_creation_reader() {
        let mut footer = smolvm_pack::format::PackFooter {
            stub_size: 0,
            assets_offset: 0,
            assets_size: 1024,
            manifest_offset: 1024,
            manifest_size: 256,
            checksum: 0,
        };
        let length = 1024 + 256 + smolvm_pack::format::FOOTER_SIZE as u64;
        validate_sidecar_layout(&footer, length).unwrap();
        assert!(validate_sidecar_layout(&footer, length + 1).is_err());
        footer.assets_offset = 64;
        assert!(validate_sidecar_layout(&footer, length).is_err());
        footer.assets_offset = 0;
        footer.stub_size = 64;
        assert!(validate_sidecar_layout(&footer, length).is_err());
        footer.stub_size = 0;
        footer.manifest_offset += 1;
        assert!(validate_sidecar_layout(&footer, length + 1).is_err());
    }

    #[test]
    fn vm_geometry_and_deferred_features_fail_before_native_creation() {
        let platform = if std::env::consts::ARCH == "aarch64" {
            "linux/arm64"
        } else {
            "linux/amd64"
        };
        let approved = ApprovedArtifact {
            path: "/approved.smolmachine".into(),
            sha256: "a".repeat(64),
            max_bytes: 1024,
            guest_platform: platform.into(),
        };
        let resources = Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let mut manifest = PackManifest::new(
            "vm://proof".into(),
            "sha256:proof".into(),
            platform.into(),
            "proof".into(),
        );
        manifest.mode = PackMode::Vm;
        manifest.assets.overlay_template = Some(smolvm_pack::format::AssetEntry {
            path: "overlay.ext4.zst".into(),
            size: 1024,
        });
        manifest.assets.storage_template = Some(smolvm_pack::format::AssetEntry {
            path: "storage.ext4.zst".into(),
            size: 1024,
        });
        manifest.assets.overlay_logical_size = Some(1 << 30);
        manifest.assets.storage_logical_size = Some(2 << 30);
        let rejected = validate_manifest(&manifest, &approved, resources).unwrap_err();
        assert_eq!(rejected.dispatch, crate::Dispatch::NotDispatched);
        manifest.assets.storage_logical_size = Some(1 << 30);
        validate_manifest(&manifest, &approved, resources).unwrap();
        manifest.assets.overlay_logical_size = None;
        manifest.assets.overlay_template.as_mut().unwrap().size = 1 << 30;
        validate_manifest(&manifest, &approved, resources).unwrap();
        manifest.assets.overlay_template.as_mut().unwrap().size = 1024;
        assert!(validate_manifest(&manifest, &approved, resources).is_err());
        manifest.assets.overlay_logical_size = Some(1 << 30);
        manifest.gpu = true;
        assert_eq!(
            validate_manifest(&manifest, &approved, resources)
                .unwrap_err()
                .code,
            ErrorCode::Unsupported
        );
        manifest.gpu = false;
        manifest.assets.storage_template = None;
        assert!(validate_manifest(&manifest, &approved, resources).is_err());
    }

    #[test]
    fn artifact_copy_is_bounded_and_digest_is_over_actual_bytes() {
        let data = vec![7u8; 128 * 1024 + 1];
        assert!(copy_hash(&mut data.as_slice(), &mut std::io::sink(), 128 * 1024).is_err());
        assert_eq!(
            copy_hash(
                &mut data.as_slice(),
                &mut std::io::sink(),
                data.len() as u64
            )
            .unwrap(),
            hex::encode(Sha256::digest(data))
        );
    }
}
