//! Read-only qualification of an imported container's original sidecar. Neither
//! SDK layer-cache inventory nor a current caller path supplies source authority.
use crate::{
    Engine, Error, ErrorCode, ExportSourceMode, QualifiedExportSource, ReadBudget, Result,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolvm_pack::format::PackMode;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// Bottom-to-top layer metadata read from a content-verified original sidecar.
/// These values describe inputs; they do not authorize a helper or publication.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImportedContainerLayer {
    pub digest: String,
    pub path: String,
    pub tar_bytes: u64,
    /// Sum of nested logical entry sizes, including sparse holes. Filesystem
    /// block/inode overhead still needs separate helper-disk admission.
    pub expanded_bytes: u64,
    pub entries: u64,
}

/// Retains the original source gate, job, domain, cache directory and sidecar FD.
/// Qualification performs no extraction, SDK mutation, cache repair or VM launch.
pub struct QualifiedImportedContainerExport {
    pack: Pack,
    source: QualifiedExportSource,
}
impl std::fmt::Debug for QualifiedImportedContainerExport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QualifiedImportedContainerExport")
            .field("layers", &self.pack.layers.len())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
struct Version(u64, u64, u64, u32, i64, i64, i64, i64);
impl Version {
    fn of(file: &File) -> Result<Self> {
        let m = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if !m.is_file()
            || m.uid() != unsafe { libc::geteuid() }
            || m.mode() & 0o7777 != 0o400
            || m.nlink() != 1
            || m.len() == 0
            || m.len() > crate::JOB_REGISTRY_STAGING_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(Self(
            m.dev(),
            m.ino(),
            m.len(),
            m.mode(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
        ))
    }
}
pub(crate) struct Pack {
    root: crate::export_source::Root,
    path: PathBuf,
    file: File,
    version: Version,
    sha256: String,
    image: String,
    layers: Vec<ImportedContainerLayer>,
    manifest: smolvm_pack::format::PackManifest,
    assets_bytes: u64,
    resources: crate::Resources,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Snapshot {
    path: PathBuf,
    version: Version,
    cache_identity: (u64, u64, u32, u32),
    sha256: String,
    #[serde(deserialize_with = "layer_list")]
    pub(crate) layers: Vec<ImportedContainerLayer>,
}
impl std::fmt::Debug for Snapshot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ImportedConversionInput")
            .finish_non_exhaustive()
    }
}
fn layer_list<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<Vec<ImportedContainerLayer>, D::Error> {
    struct Layers;
    impl<'de> serde::de::Visitor<'de> for Layers {
        type Value = Vec<ImportedContainerLayer>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("at most 256 imported layers")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut sequence: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            if sequence.size_hint().is_some_and(|n| n > 256) {
                return Err(serde::de::Error::custom("imported layer limit"));
            }
            let mut layers = Vec::new();
            while let Some(layer) = sequence.next_element()? {
                if layers.len() == 256 {
                    return Err(serde::de::Error::custom("imported layer limit"));
                }
                layers.push(layer);
            }
            Ok(layers)
        }
    }
    decoder.deserialize_seq(Layers)
}
impl Snapshot {
    pub(crate) fn validate(&self, record: &smolvm::config::VmRecord) -> Result<()> {
        if record.source_smolmachine.as_deref().map(Path::new) != Some(self.path.as_path())
            || record.image.is_none()
            || !self.path.is_absolute()
            || !crate::domain::valid_hex(&self.sha256, 64)
            || self.path.file_name().and_then(|s| s.to_str())
                != Some(format!("{}.smolmachine", self.sha256).as_str())
            || self.layers.is_empty()
            || self.layers.len() > 256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut seen = std::collections::BTreeSet::new();
        for layer in &self.layers {
            let digest = layer
                .digest
                .strip_prefix("sha256:")
                .ok_or(Error::before(ErrorCode::Validation))?;
            if !crate::domain::valid_hex(digest, 64)
                || layer.path != format!("layers/{digest}.tar")
                || layer.tar_bytes == 0
                || !seen.insert(&layer.digest)
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        self.allowance().map(|_| ())
    }
    pub(crate) fn allowance(&self) -> Result<crate::ImportedConversionAllowance> {
        let add = |a: u64, b| a.checked_add(b).ok_or(Error::before(ErrorCode::Admission));
        let allowance = crate::ImportedConversionAllowance {
            source_sha256: self.sha256.clone(),
            tar_bytes: self.layers.iter().try_fold(0, |n, l| add(n, l.tar_bytes))?,
            max_layer_tar_bytes: self.layers.iter().map(|l| l.tar_bytes).max().unwrap_or(0),
            expanded_bytes: self
                .layers
                .iter()
                .try_fold(0, |n, l| add(n, l.expanded_bytes))?,
            entries: self.layers.iter().try_fold(0, |n, l| add(n, l.entries))?,
        };
        allowance.validate()?;
        Ok(allowance)
    }
}
fn open(path: &Path) -> Result<File> {
    crate::host::unredirected(path)?;
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Ownership))
}
impl Pack {
    pub(crate) fn verify(&self, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        self.root.verify()?;
        if Version::of(&self.file)? != self.version
            || Version::of(&open(&self.path)?)? != self.version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()
    }
    pub(crate) fn qualify(
        engine: &Engine,
        record: &smolvm::config::VmRecord,
        budget: &ReadBudget,
    ) -> Result<Self> {
        budget.check()?;
        engine.domain.verify()?;
        let path = Path::new(
            record
                .source_smolmachine
                .as_deref()
                .ok_or(Error::before(ErrorCode::Unsupported))?,
        );
        let sha256 = path
            .file_name()
            .and_then(|s| s.to_str())
            .and_then(|s| s.strip_suffix(".smolmachine"))
            .filter(|s| crate::domain::valid_hex(s, 64))
            .ok_or(Error::before(ErrorCode::Ownership))?;
        // These are the two engine-owned creation caches. The exact path was
        // authenticated by the original material receipt before reaching here;
        // its basename alone would never authorize an arbitrary input artifact.
        let cache = ["artifacts", "registry-blobs"]
            .into_iter()
            .map(|name| engine.domain.directory.join(name))
            .find(|root| path == root.join(format!("{sha256}.smolmachine")))
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let root = crate::export_source::Root::open(&cache)?;
        let pack = Self::load(path, root, sha256, record, budget)?;
        engine.domain.verify()?;
        Ok(pack)
    }
    fn load(
        path: &Path,
        root: crate::export_source::Root,
        sha256: &str,
        record: &smolvm::config::VmRecord,
        budget: &ReadBudget,
    ) -> Result<Self> {
        budget.check()?;
        let mut file = open(path)?;
        let version = Version::of(&file)?;
        let footer = smolvm_pack::packer::read_footer_from_file(&mut file)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        // Includes exact sidecar layout and a 1-MiB manifest allocation bound.
        let manifest = crate::artifact::read_manifest(&mut file, &footer)?;
        let image = record
            .image
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        if manifest.mode != PackMode::Container || &manifest.image != image {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let resources = crate::Resources {
            cpus: record.cpus,
            memory_mib: record.mem,
            storage_gib: record
                .storage_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            overlay_gib: record
                .overlay_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
        };
        resources.validate()?;
        crate::artifact::validate_manifest(
            &manifest,
            &crate::ApprovedArtifact {
                path: path.into(),
                sha256: sha256.into(),
                max_bytes: version.2,
                guest_platform: crate::oci::native_oci_platform().into(),
            },
            resources,
        )?;
        // Only the outer asset inventory is needed for the second streaming
        // pass. Do not retain a duplicate baked environment/workload manifest.
        let mut inventory = smolvm_pack::format::PackManifest::new(
            String::new(),
            String::new(),
            String::new(),
            String::new(),
        );
        inventory.assets = manifest.assets.clone();
        let mut pack = Self {
            root,
            path: path.into(),
            file,
            version,
            sha256: sha256.into(),
            image: image.clone(),
            layers: Vec::new(),
            manifest: inventory,
            assets_bytes: footer.assets_size,
            resources,
        };
        pack.verify(budget)?;
        pack.rehash(
            footer.manifest_offset + footer.manifest_size,
            footer.checksum,
            budget,
        )?;
        pack.layers = crate::archive::inspect_container_layers(
            Reader {
                pack: &pack,
                budget,
                position: 0,
                end: footer.assets_size,
            },
            &manifest,
            resources,
            budget,
        )?;
        pack.verify(budget)?;
        Ok(pack)
    }
    pub(crate) fn snapshot(&self, budget: &ReadBudget) -> Result<Snapshot> {
        self.verify(budget)?;
        let cache = self
            .root
            .descriptor()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        Ok(Snapshot {
            path: self.path.clone(),
            version: self.version,
            cache_identity: (cache.dev(), cache.ino(), cache.uid(), cache.mode()),
            sha256: self.sha256.clone(),
            layers: self.layers.clone(),
        })
    }
    pub(crate) fn from_snapshot(
        snapshot: &Snapshot,
        record: &smolvm::config::VmRecord,
        budget: &ReadBudget,
    ) -> Result<Self> {
        snapshot.validate(record)?;
        budget.check()?;
        let root = crate::export_source::Root::open(
            snapshot
                .path
                .parent()
                .ok_or(Error::before(ErrorCode::Ownership))?,
        )?;
        let cache = root
            .descriptor()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if (cache.dev(), cache.ino(), cache.uid(), cache.mode()) != snapshot.cache_identity
            || Version::of(&open(&snapshot.path)?)? != snapshot.version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let pack = Self::load(&snapshot.path, root, &snapshot.sha256, record, budget)?;
        if &pack.snapshot(budget)? != snapshot {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(pack)
    }
    pub(crate) fn stream_layers(
        &self,
        budget: &ReadBudget,
        consume: &mut crate::archive::LayerConsumer<'_>,
    ) -> Result<()> {
        self.verify(budget)?;
        crate::archive::stream_container_layers(
            Reader {
                pack: self,
                budget,
                position: 0,
                end: self.assets_bytes,
            },
            &self.manifest,
            self.resources,
            budget,
            consume,
        )?;
        self.verify(budget)
    }
    fn rehash(&self, body: u64, checksum: u32, budget: &ReadBudget) -> Result<()> {
        self.verify(budget)?;
        let mut sha = Sha256::new();
        let mut crc = crc32fast::Hasher::new();
        let mut buffer = [0; 64 * 1024];
        let mut position = 0;
        while position < self.version.2 {
            budget.check()?;
            let count = (self.version.2 - position).min(buffer.len() as u64) as usize;
            self.file
                .read_exact_at(&mut buffer[..count], position)
                .map_err(|_| Error::before(ErrorCode::Io))?;
            sha.update(&buffer[..count]);
            let covered = body.saturating_sub(position).min(count as u64) as usize;
            crc.update(&buffer[..covered]);
            position += count as u64;
        }
        self.verify(budget)?;
        if hex::encode(sha.finalize()) != self.sha256 || crc.finalize() != checksum {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
struct Reader<'a> {
    pack: &'a Pack,
    budget: &'a ReadBudget,
    position: u64,
    end: u64,
}
impl Read for Reader<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.pack
            .verify(self.budget)
            .map_err(|_| std::io::Error::other("imported export source"))?;
        let count = (self.end - self.position)
            .min(buffer.len() as u64)
            .min(64 * 1024) as usize;
        self.pack
            .file
            .read_exact_at(&mut buffer[..count], self.position)?;
        self.position += count as u64;
        Ok(count)
    }
}
impl QualifiedExportSource {
    pub fn qualify_imported_container_export(
        mut self,
        engine: &Engine,
    ) -> Result<QualifiedImportedContainerExport> {
        let record = self.checked_record(engine)?;
        if self.mode() != ExportSourceMode::Container || record.source_smolmachine.is_none() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        // Promote this original job before retaining the extra directory/file
        // descriptors; do not acquire a second work job while holding the gate.
        self.promote_disks()?;
        let pack = Pack::qualify(engine, &record, self.budget())?;
        let qualified = QualifiedImportedContainerExport { pack, source: self };
        qualified.recheck(engine)?;
        Ok(qualified)
    }
}
impl QualifiedImportedContainerExport {
    pub fn layers(&self) -> &[ImportedContainerLayer] {
        &self.pack.layers
    }
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        let record = self.source.checked_record(engine)?;
        engine.domain.verify()?;
        if record.source_smolmachine.as_deref().map(Path::new) != Some(self.pack.path.as_path())
            || record.image.as_deref() != Some(self.pack.image.as_str())
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.pack.verify(self.source.budget())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{Cancellation, CreationReceipt, Dispatch};
    use smolvm_pack::format::{AssetEntry, LayerEntry, PackFooter, PackManifest};
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::time::Duration;

    fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(30), Cancellation::default()).unwrap()
    }
    fn tar(files: &[(String, Vec<u8>)]) -> Vec<u8> {
        let mut builder = tar::Builder::new(Vec::new());
        for (path, bytes) in files {
            let mut header = tar::Header::new_gnu();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder
                .append_data(&mut header, path, bytes.as_slice())
                .unwrap();
        }
        builder.into_inner().unwrap()
    }
    pub(crate) fn payload() -> (PackManifest, Vec<(String, Vec<u8>)>) {
        let first = tar(&[("etc/first".into(), b"first".to_vec())]);
        let second = tar(&[("etc/second".into(), b"second".to_vec())]);
        let mut manifest = PackManifest::new(
            "imported image metadata, never a host path".into(),
            "none".into(),
            crate::oci::native_oci_platform().into(),
            "fixture".into(),
        );
        manifest.assets.agent_rootfs = AssetEntry {
            path: "agent-rootfs.tar".into(),
            size: first.len() as u64,
        };
        manifest.env = vec!["BAKED_SECRET=must-not-become-record-env".into()];
        let mut files = vec![("agent-rootfs.tar".into(), first.clone())];
        for bytes in [first, second] {
            let sha = hex::encode(Sha256::digest(&bytes));
            let path = format!("layers/{sha}.tar");
            manifest.assets.layers.push(LayerEntry {
                path: path.clone(),
                digest: format!("sha256:{sha}"),
                size: bytes.len() as u64,
            });
            files.push((path, bytes));
        }
        // Physical archive order must not decide overlay precedence.
        files.reverse();
        (manifest, files)
    }
    pub(crate) fn sidecar(manifest: &PackManifest, files: &[(String, Vec<u8>)]) -> Vec<u8> {
        let mut bytes = zstd::encode_all(tar(files).as_slice(), 1).unwrap();
        let assets_size = bytes.len() as u64;
        let json = manifest.to_json().unwrap();
        bytes.extend_from_slice(&json);
        let footer = PackFooter {
            stub_size: 0,
            assets_offset: 0,
            assets_size,
            manifest_offset: assets_size,
            manifest_size: json.len() as u64,
            checksum: crc32fast::hash(&bytes),
        };
        bytes.extend_from_slice(&footer.to_bytes());
        bytes
    }
    pub(crate) fn fixture(
        root: &Path,
        cache: &str,
        bytes: &[u8],
        image: &str,
    ) -> (Engine, CreationReceipt, PathBuf) {
        let root = root.canonicalize().unwrap();
        let path = root.join("private").join(cache).join(format!(
            "{}.smolmachine",
            hex::encode(Sha256::digest(bytes))
        ));
        let (engine, receipt) =
            crate::export_source::tests::fixture_record(&root, true, |record| {
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                std::fs::set_permissions(
                    path.parent().unwrap(),
                    std::fs::Permissions::from_mode(0o700),
                )
                .unwrap();
                std::fs::write(&path, bytes).unwrap();
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
                record.image = Some(image.into());
                record.source_smolmachine = Some(path.to_str().unwrap().into());
            });
        (engine, receipt, path)
    }
    fn qualify(
        engine: &Engine,
        receipt: &CreationReceipt,
        b: &ReadBudget,
    ) -> Result<QualifiedImportedContainerExport> {
        engine
            .qualify_export_source(receipt, b)?
            .qualify_imported_container_export(engine)
    }

    #[test]
    fn both_creation_caches_qualify_original_layers_without_sdk_cache_or_mutation() {
        for cache in ["artifacts", "registry-blobs"] {
            let temp = tempfile::tempdir().unwrap();
            let (manifest, files) = payload();
            let bytes = sidecar(&manifest, &files);
            let (engine, receipt, path) = fixture(temp.path(), cache, &bytes, &manifest.image);
            let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
            let qualified = qualify(&engine, &receipt, &budget()).unwrap();
            assert_eq!(qualified.layers().len(), 2);
            assert_eq!(
                qualified.layers()[0].digest,
                manifest.assets.layers[0].digest
            );
            assert_eq!(
                qualified.layers()[1].digest,
                manifest.assets.layers[1].digest
            );
            assert_eq!(qualified.layers()[0].expanded_bytes, 5);
            assert_eq!(qualified.layers()[1].expanded_bytes, 6);
            assert_eq!(qualified.layers()[0].entries, 1);
            assert_eq!(
                qualified.layers()[0].tar_bytes,
                manifest.assets.layers[0].size
            );
            assert_eq!(std::fs::read(path).unwrap(), bytes);
            assert_eq!(engine.jobs.counts().work, 1);
            assert_eq!(engine.jobs.counts().children, 0);
            assert_eq!(engine.jobs.counts().descriptors, 12);
            assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
            qualified.recheck(&engine).unwrap();
            let debug = format!("{qualified:?}");
            assert!(!debug.contains("SECRET"));
            assert!(!debug.contains(&receipt.owner_token));
            assert!(!debug.contains(".smolmachine"));
            assert_eq!(
                serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
                before
            );
            assert!(!engine.vm_directory(&receipt.name).join("layers").exists());
            drop(qualified);
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }

    #[test]
    fn material_receipt_must_authorize_exact_import_path_before_any_file_qualification() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(temp.path(), true);
        let source = engine.qualify_export_source(&receipt, &budget()).unwrap();
        assert_eq!(
            source
                .qualify_imported_container_export(&engine)
                .unwrap_err()
                .code,
            ErrorCode::Unsupported
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        // An inventory edit cannot supply the source that the receipt omitted.
        let mut record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        record.source_smolmachine = Some("/foreign/approved-looking.smolmachine".into());
        engine
            .db
            .update_vm(&receipt.name, |row| *row = record)
            .unwrap();
        assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
        assert!(!engine.domain.directory.join("artifacts").exists());
    }

    #[test]
    fn cache_basename_is_integrity_evidence_only_after_original_material_and_root_checks() {
        let (manifest, files) = payload();
        let bytes = sidecar(&manifest, &files);
        for cache in ["other", "artifacts/../registry-blobs"] {
            let temp = tempfile::tempdir().unwrap();
            let (engine, receipt, _) = fixture(temp.path(), cache, &bytes, &manifest.image);
            assert_eq!(
                qualify(&engine, &receipt, &budget()).unwrap_err().code,
                ErrorCode::Ownership
            );
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt, path) = fixture(temp.path(), "artifacts", &bytes, &manifest.image);
        std::fs::remove_file(&path).unwrap();
        let foreign = temp.path().join("foreign");
        std::fs::write(&foreign, &bytes).unwrap();
        symlink(foreign, &path).unwrap();
        assert!(qualify(&engine, &receipt, &budget()).is_err());
    }

    #[test]
    fn retained_input_rejects_replacement_modification_links_permissions_and_domain_changes() {
        for change in [
            "replace", "write", "link", "mode", "cache", "domain", "binding", "lock",
        ] {
            let temp = tempfile::tempdir().unwrap();
            let (manifest, files) = payload();
            let bytes = sidecar(&manifest, &files);
            let (engine, receipt, path) =
                fixture(temp.path(), "registry-blobs", &bytes, &manifest.image);
            let qualified = qualify(&engine, &receipt, &budget()).unwrap();
            match change {
                "replace" => {
                    std::fs::rename(&path, path.with_extension("original")).unwrap();
                    std::fs::write(&path, &bytes).unwrap();
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400))
                        .unwrap();
                }
                "write" => {
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
                        .unwrap();
                    OpenOptions::new()
                        .write(true)
                        .open(&path)
                        .unwrap()
                        .write_all_at(b"x", 0)
                        .unwrap();
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400))
                        .unwrap();
                }
                "link" => std::fs::hard_link(&path, path.with_extension("linked")).unwrap(),
                "mode" => {
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap()
                }
                "cache" => {
                    let cache = path.parent().unwrap();
                    std::fs::rename(cache, cache.with_extension("original")).unwrap();
                    std::fs::create_dir(cache).unwrap();
                }
                "domain" => {
                    let other = tempfile::tempdir().unwrap();
                    let other_engine = crate::machine::tests::test_engine(other.path());
                    assert!(qualified.recheck(&other_engine).is_err());
                    continue;
                }
                "binding" | "lock" => {
                    let path = engine.domain.directory.join(format!("domain.{change}"));
                    let original = std::fs::read(&path).unwrap();
                    std::fs::rename(&path, path.with_extension("original")).unwrap();
                    std::fs::write(&path, original).unwrap();
                }
                _ => unreachable!(),
            }
            assert!(qualified.recheck(&engine).is_err());
            // Retained authority still prevents a second source job.
            assert_eq!(engine.jobs.counts().work, 1);
        }
    }

    #[test]
    fn content_footer_layer_hashes_and_inventory_must_each_match() {
        for change in [
            "sha",
            "crc",
            "layer",
            "missing",
            "extra",
            "duplicate",
            "truncated",
        ] {
            let (mut manifest, mut files) = payload();
            match change {
                "layer" => {
                    let old = manifest.assets.layers[0].path.clone();
                    let new = format!("layers/{}.tar", "f".repeat(64));
                    files.iter_mut().find(|(p, _)| p == &old).unwrap().0 = new.clone();
                    manifest.assets.layers[0].path = new;
                    manifest.assets.layers[0].digest = format!("sha256:{}", "f".repeat(64));
                }
                "missing" => {
                    files.remove(0);
                }
                "extra" => files.push(("layers/hidden.tar".into(), b"hidden".to_vec())),
                "duplicate" => files.push(files[0].clone()),
                _ => {}
            }
            let mut bytes = sidecar(&manifest, &files);
            if change == "crc" {
                let n = bytes.len() - smolvm_pack::format::FOOTER_SIZE;
                bytes[n + 52] ^= 1;
            } else if change == "truncated" {
                bytes.pop();
            }
            let temp = tempfile::tempdir().unwrap();
            let (engine, receipt, path) =
                fixture(temp.path(), "artifacts", &bytes, &manifest.image);
            if change == "sha" {
                // Valid CRC/layout, but bytes no longer match the receipt-bound key.
                manifest.env.clear();
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
                std::fs::write(&path, sidecar(&manifest, &files)).unwrap();
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
            }
            let error = qualify(&engine, &receipt, &budget()).unwrap_err();
            assert_eq!(error.dispatch, Dispatch::NotDispatched, "{change}");
            assert_eq!(
                engine.jobs.counts(),
                crate::jobs::Counts::default(),
                "{change}"
            );
        }
    }

    #[test]
    fn manifest_source_platform_and_managed_pack_restrictions_are_preserved() {
        for change in [
            "image",
            "platform",
            "mode",
            "checkpoint",
            "workspace",
            "secret",
        ] {
            let (mut manifest, files) = payload();
            let image = manifest.image.clone();
            match change {
                "image" => manifest.image = "unrelated".into(),
                "platform" => {
                    manifest.platform = if crate::oci::native_oci_platform() == "linux/arm64" {
                        "linux/amd64"
                    } else {
                        "linux/arm64"
                    }
                    .into()
                }
                "mode" => manifest.mode = PackMode::Vm,
                "checkpoint" => {
                    manifest.checkpoint = crate::checkpoint::tests::payload_fixture().1.checkpoint
                }
                "workspace" => {
                    manifest.assets.workspace_seed = Some(AssetEntry {
                        path: "workspace.tar".into(),
                        size: 1,
                    })
                }
                "secret" => {
                    manifest.secret_refs.insert(
                        "KEY".into(),
                        smolvm_protocol::SecretRef {
                            from_env: Some("KEY".into()),
                            from_file: None,
                        },
                    );
                }
                _ => unreachable!(),
            }
            let temp = tempfile::tempdir().unwrap();
            let (engine, receipt, _) = fixture(
                temp.path(),
                "artifacts",
                &sidecar(&manifest, &files),
                &image,
            );
            assert!(qualify(&engine, &receipt, &budget()).is_err(), "{change}");
        }
    }

    #[test]
    fn source_budget_remains_absolute_and_cancellation_does_not_acquire_another_job() {
        let temp = tempfile::tempdir().unwrap();
        let (manifest, files) = payload();
        let (engine, receipt, _) = fixture(
            temp.path(),
            "artifacts",
            &sidecar(&manifest, &files),
            &manifest.image,
        );
        let b = budget();
        let qualified = qualify(&engine, &receipt, &b).unwrap();
        b.cancel.cancel();
        assert_eq!(
            qualified.recheck(&engine).unwrap_err().code,
            ErrorCode::State
        );
        assert_eq!(engine.jobs.counts().work, 1);
        drop(qualified);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn worker_snapshot_reopens_only_original_version_and_streams_exact_layers_without_host_copies()
    {
        let temp = tempfile::tempdir().unwrap();
        let (manifest, files) = payload();
        let (engine, receipt, path) = fixture(
            temp.path(),
            "artifacts",
            &sidecar(&manifest, &files),
            &manifest.image,
        );
        let qualified = qualify(&engine, &receipt, &budget()).unwrap();
        let snapshot = qualified.pack.snapshot(&budget()).unwrap();
        let record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        let worker = Pack::from_snapshot(&snapshot, &record, &budget()).unwrap();
        let mut streamed = Vec::new();
        worker
            .stream_layers(&budget(), &mut |path, size, input| {
                let mut bytes = Vec::new();
                input.read_to_end(&mut bytes)?;
                assert_eq!(bytes.len() as u64, size);
                streamed.push((path.to_owned(), bytes));
                Ok(())
            })
            .unwrap();
        assert_eq!(
            streamed,
            files
                .iter()
                .filter(|(p, _)| p.starts_with("layers/"))
                .cloned()
                .collect::<Vec<_>>()
        );
        assert!(worker
            .stream_layers(&budget(), &mut |_, _, _| Ok(()))
            .is_err());
        let mut reordered = snapshot.clone();
        reordered.layers.reverse();
        assert!(Pack::from_snapshot(&reordered, &record, &budget()).is_err());
        let cache = path.parent().unwrap();
        std::fs::set_permissions(cache, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(Pack::from_snapshot(&snapshot, &record, &budget()).is_err());
        std::fs::set_permissions(cache, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut excessive = serde_json::to_value(&snapshot).unwrap();
        excessive["layers"] = serde_json::json!(vec![snapshot.layers[0].clone(); 257]);
        assert!(serde_json::from_value::<Snapshot>(excessive).is_err());
        std::fs::rename(&path, path.with_extension("original")).unwrap();
        std::fs::write(
            &path,
            std::fs::read(path.with_extension("original")).unwrap(),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert!(Pack::from_snapshot(&snapshot, &record, &budget()).is_err());
    }

    #[test]
    fn sparse_layer_expansion_is_counted_logically_and_capped_without_extraction() {
        for logical in [1 << 20, 1u64 << 40] {
            let mut header = tar::Header::new_gnu();
            header.set_path("sparse").unwrap();
            header.set_entry_type(tar::EntryType::GNUSparse);
            header.set_size(0);
            header.set_mode(0o644);
            let gnu = header.as_gnu_mut().unwrap();
            gnu.set_real_size(logical);
            gnu.sparse[0].set_offset(logical);
            gnu.sparse[0].set_length(0);
            header.set_cksum();
            let mut layer = header.as_bytes().to_vec();
            layer.extend_from_slice(&[0; 1024]);
            let digest = hex::encode(Sha256::digest(&layer));
            let (mut manifest, mut files) = payload();
            files.retain(|(path, _)| path == "agent-rootfs.tar");
            let path = format!("layers/{digest}.tar");
            manifest.assets.layers = vec![LayerEntry {
                path: path.clone(),
                digest: format!("sha256:{digest}"),
                size: layer.len() as u64,
            }];
            files.push((path, layer));
            let temp = tempfile::tempdir().unwrap();
            let (engine, receipt, _) = fixture(
                temp.path(),
                "artifacts",
                &sidecar(&manifest, &files),
                &manifest.image,
            );
            let result = qualify(&engine, &receipt, &budget());
            if logical == 1 << 20 {
                let qualified = result.unwrap();
                assert_eq!(qualified.layers()[0].expanded_bytes, logical);
                assert_eq!(qualified.layers()[0].tar_bytes, 1536);
            } else {
                assert_eq!(result.unwrap_err().code, ErrorCode::Validation);
            }
        }
    }
}
