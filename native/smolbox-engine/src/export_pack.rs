//! Bounded standalone bare/container packs using the upstream format, without implicit SDK
//! cache locks, temporary machines, helper processes or a second domain owner.
use crate::export_assets::QualifiedExportAssets;
use crate::export_staging::{ExportStagedFile, Stage};
use crate::{
    Engine, Error, ErrorCode, ExportDiskDigest, MaterializedExportDisks, ReadBudget, Result,
};
use sha2::{Digest, Sha256};
use smolvm_pack::format::{AssetEntry, PackFooter, PackManifest, PackMode};
use std::io::{Read, Write};

const MANIFEST_BYTES: usize = 1024 * 1024;
const ARTIFACT: &str = "artifact.smolmachine";

/// Private, verified scratch artifact. This is not a registry publication receipt.
/// Its source gate and whole-job allowances remain held until explicit disposal.
pub struct PackedExport {
    artifact: ExportStagedFile,
    materialized: Materialized,
}
enum Materialized {
    Bare(Box<MaterializedExportDisks>),
    Container(crate::export_retention::PackedConversion),
}
impl std::fmt::Debug for PackedExport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PackedExport")
            .field("size_bytes", &self.artifact.size_bytes)
            .finish_non_exhaustive()
    }
}
impl PackedExport {
    pub(crate) fn new(materialized: MaterializedExportDisks, artifact: ExportStagedFile) -> Self {
        Self {
            artifact,
            materialized: Materialized::Bare(Box::new(materialized)),
        }
    }
    pub(crate) fn new_container(
        materialized: crate::export_retention::PackedConversion,
        artifact: ExportStagedFile,
    ) -> Self {
        Self {
            artifact,
            materialized: Materialized::Container(materialized),
        }
    }
    /// One publication attempt; no auth retry, tag replacement, upload restart
    /// or receipt reconstruction from registry inventory is authorized here.
    pub fn publish(
        mut self,
        engine: &Engine,
        destination: &crate::ApprovedExportDestination,
        tag: &str,
        credential: crate::RegistryPublishCredential,
    ) -> Result<crate::PublishedExport> {
        let publication = match &mut self.materialized {
            Materialized::Bare(value) => {
                value.publish(engine, &self.artifact, destination, tag, &credential)?
            }
            Materialized::Container(value) => {
                value.publish(engine, &self.artifact, destination, tag, &credential)?
            }
        };
        Ok(crate::PublishedExport {
            packed: self,
            publication,
        })
    }
    pub fn artifact(&self) -> &ExportStagedFile {
        &self.artifact
    }
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        match &self.materialized {
            Materialized::Bare(value) => value.recheck(engine),
            Materialized::Container(value) => value.recheck(engine),
        }
    }
    pub fn read_at(&self, offset: u64, bytes: &mut [u8]) -> Result<()> {
        match &self.materialized {
            Materialized::Bare(value) => value.read_artifact_at(offset, bytes),
            Materialized::Container(value) => value.read_at(offset, bytes),
        }
    }
    pub fn close(self, budget: &ReadBudget) -> Result<crate::ExportStageCleanup> {
        match self.materialized {
            Materialized::Bare(value) => (*value).close(budget),
            Materialized::Container(value) => value.close(budget),
        }
    }
}

pub(crate) fn manifest(
    record: &smolvm::config::VmRecord,
    files: &[ExportStagedFile],
    assets: &QualifiedExportAssets,
) -> Result<PackManifest> {
    // Container flattening has a separate source/metadata contract.
    if record.image.is_some() {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    let mut manifest = PackManifest::new(
        // A VM pack has no image to mount. A nonempty name makes the SDK
        // look for bundled image layers when the exported VM boots.
        String::new(),
        "none".into(),
        crate::oci::native_oci_platform().into(),
        smolvm::platform::Platform::current()
            .host_oci_platform()
            .into(),
    );
    smolvm::pack_export::seed_manifest_from_vm(
        &mut manifest,
        record,
        &smolvm::pack_export::FromVmAssets {
            mode: PackMode::Vm,
            image: None,
            image_env: vec![],
            image_user: None,
            layer_bytes: 0,
        },
    );
    manifest.cpus = record.cpus;
    manifest.mem = record.mem;
    for (name, size) in assets.entries() {
        let entry = AssetEntry {
            path: name.clone(),
            size,
        };
        if name == "agent-rootfs.tar" {
            manifest.assets.agent_rootfs = entry;
        } else {
            manifest.assets.libraries.push(entry);
        }
    }
    for (name, path) in [
        ("storage.raw", "storage.ext4"),
        ("overlay.raw", "overlay.raw"),
    ] {
        let file = files
            .iter()
            .find(|file| file.name == name)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let entry = AssetEntry {
            path: path.into(),
            size: file.size_bytes,
        };
        if name == "storage.raw" {
            manifest.assets.storage_template = Some(entry);
            manifest.assets.storage_logical_size = Some(file.size_bytes);
        } else {
            manifest.assets.overlay_template = Some(entry);
            manifest.assets.overlay_logical_size = Some(file.size_bytes);
        }
    }
    Ok(manifest)
}

pub(crate) fn container_manifest(
    record: &smolvm::config::VmRecord,
    plan: &crate::ContainerExportPlan,
    layer: &ExportStagedFile,
    assets: &QualifiedExportAssets,
) -> Result<PackManifest> {
    plan.validate(record)?;
    if layer.name != "layer.tar"
        || layer.size_bytes == 0
        || !crate::domain::valid_hex(&layer.sha256, 64)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut manifest = plan.seed_manifest(record, layer.size_bytes)?;
    for (name, size) in assets.entries() {
        let entry = AssetEntry {
            path: name.clone(),
            size,
        };
        if name == "agent-rootfs.tar" {
            manifest.assets.agent_rootfs = entry;
        } else {
            manifest.assets.libraries.push(entry);
        }
    }
    manifest.assets.layers = vec![smolvm_pack::format::LayerEntry {
        digest: format!("sha256:{}", layer.sha256),
        path: format!("layers/{}.tar", layer.sha256),
        size: layer.size_bytes,
    }];
    Ok(manifest)
}

pub(crate) fn pack(
    stage: &mut Stage,
    files: &[ExportStagedFile],
    assets: &QualifiedExportAssets,
    manifest: &PackManifest,
    max_bytes: u64,
    budget: &ReadBudget,
) -> Result<ExportStagedFile> {
    budget.check()?;
    assets.verify()?;
    // Bound metadata before irreversible staging entry; machine metadata is also
    // independently bounded by source qualification.
    let json = manifest
        .to_json()
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    if json.len() > MANIFEST_BYTES || max_bytes <= (json.len() + smolvm_pack::FOOTER_SIZE) as u64 {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    if matches!(manifest.mode, PackMode::Container) {
        let layer = stage.container_layer()?;
        let Some(entry) = manifest.assets.layers.first() else {
            return Err(Error::before(ErrorCode::Ownership));
        };
        if files != [layer.clone()]
            || manifest.assets.layers.len() != 1
            || entry.digest != format!("sha256:{}", layer.sha256)
            || entry.path != format!("layers/{}.tar", layer.sha256)
            || entry.size != layer.size_bytes
            || manifest.image_size != layer.size_bytes
            || manifest.assets.storage_template.is_some()
            || manifest.assets.overlay_template.is_some()
            || manifest.assets.workspace_seed.is_some()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        stage.begin_container_pack(max_bytes)?;
    } else {
        stage.begin_pack()?;
    }
    let packed = (|| -> std::io::Result<_> {
        let writer = stage.file(ARTIFACT, max_bytes, budget).map_err(io)?;
        let mut output = DigestWriter {
            inner: writer,
            sha: Sha256::new(),
            crc: crc32fast::Hasher::new(),
            bytes: 0,
        };
        {
            let mut encoder = zstd::stream::Encoder::new(&mut output, 1)?;
            // Single-thread streaming: no implicit global compression permit,
            // worker queue or SDK-created scratch. Keep the window finite.
            encoder.window_log(20)?;
            let mut archive = tar::Builder::new(encoder);
            for (name, size) in assets.entries() {
                append(
                    &mut archive,
                    &name,
                    size,
                    assets.reader(&name, budget).map_err(io)?,
                )?;
            }
            if matches!(manifest.mode, PackMode::Container) {
                let layer = &files[0];
                append(
                    &mut archive,
                    &manifest.assets.layers[0].path,
                    layer.size_bytes,
                    DiskReader {
                        stage,
                        name: "layer.tar",
                        position: 0,
                        size: layer.size_bytes,
                        budget,
                    },
                )?;
            } else {
                // The SDK mounts this directory for any imported sidecar,
                // even when a VM-mode artifact has no image layers.
                let mut layers = tar::Header::new_gnu();
                layers.set_entry_type(tar::EntryType::Directory);
                layers.set_size(0);
                layers.set_mode(0o755);
                layers.set_uid(0);
                layers.set_gid(0);
                layers.set_mtime(0);
                archive.append_data(&mut layers, "layers", std::io::empty())?;
                for (name, path) in [
                    ("storage.raw", "storage.ext4"),
                    ("overlay.raw", "overlay.raw"),
                ] {
                    let file = files
                        .iter()
                        .find(|file| file.name == name)
                        .ok_or_else(|| std::io::Error::other("export input"))?;
                    append(
                        &mut archive,
                        path,
                        file.size_bytes,
                        DiskReader {
                            stage,
                            name,
                            position: 0,
                            size: file.size_bytes,
                            budget,
                        },
                    )?;
                }
            }
            let encoder = archive.into_inner()?;
            encoder.finish()?;
        }
        let assets_size = output.bytes;
        output.write_all(&json)?;
        let footer = PackFooter {
            stub_size: 0,
            assets_offset: 0,
            assets_size,
            manifest_offset: assets_size,
            manifest_size: json.len() as u64,
            checksum: output.crc.clone().finalize(),
        };
        // CRC covers the compressed assets and manifest; SHA covers the footer too.
        output.write_all(&footer.to_bytes())?;
        output.flush()?;
        let digest = ExportDiskDigest {
            size_bytes: output.bytes,
            sha256: format!("{:x}", output.sha.finalize()),
        };
        output.inner.finish(&digest).map_err(io)
    })();
    // Preserve the original cancellation/deadline classification at collection.
    budget.check()?;
    let file = packed.map_err(|_| Error::before(ErrorCode::Io))?;
    assets.rehash(budget)?;
    budget.check()?;
    stage.packed(file.clone())?;
    Ok(file)
}
fn io(_: Error) -> std::io::Error {
    std::io::Error::other("export authority or budget")
}
fn append<W: Write>(
    archive: &mut tar::Builder<W>,
    name: &str,
    size: u64,
    reader: impl Read,
) -> std::io::Result<()> {
    let mut header = tar::Header::new_gnu();
    header.set_entry_type(tar::EntryType::Regular);
    header.set_size(size);
    header.set_mode(0o644);
    header.set_uid(0);
    header.set_gid(0);
    header.set_mtime(0);
    archive.append_data(&mut header, name, reader)
}
struct DiskReader<'a> {
    stage: &'a Stage,
    name: &'a str,
    position: u64,
    size: u64,
    budget: &'a ReadBudget,
}
impl Read for DiskReader<'_> {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        self.budget.check().map_err(io)?;
        let take = (self.size - self.position)
            .min(bytes.len() as u64)
            .min(64 * 1024) as usize;
        if take > 0 {
            self.stage
                .read_at(self.name, self.position, &mut bytes[..take], self.budget)
                .map_err(io)?;
            self.position += take as u64;
        }
        Ok(take)
    }
}
struct DigestWriter<W> {
    inner: W,
    sha: Sha256,
    crc: crc32fast::Hasher,
    bytes: u64,
}
impl<W: Write> Write for DigestWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let count = self.inner.write(bytes)?;
        self.sha.update(&bytes[..count]);
        self.crc.update(&bytes[..count]);
        self.bytes += count as u64;
        Ok(count)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::export_assets::tests::{budget, fixture as asset_fixture};
    use crate::{Cancellation, CreationReceipt};
    use std::collections::BTreeMap;
    use std::time::Duration;
    const MAX: u64 = 256 * 1024;
    pub(crate) fn fixture() -> (
        tempfile::TempDir,
        Engine,
        CreationReceipt,
        Stage,
        Vec<ExportStagedFile>,
        QualifiedExportAssets,
        PackManifest,
    ) {
        fixture_with_storage(b"storage\0\x80", MAX)
    }
    pub(crate) fn fixture_with_storage(
        storage: &[u8],
        maximum: u64,
    ) -> (
        tempfile::TempDir,
        Engine,
        CreationReceipt,
        Stage,
        Vec<ExportStagedFile>,
        QualifiedExportAssets,
        PackManifest,
    ) {
        let temp = tempfile::tempdir().unwrap();
        let (engine, source) = crate::export_source::tests::fixture(temp.path(), false);
        let approved = asset_fixture(&temp.path().join("approved-assets"));
        let assets = approved.qualify(&budget()).unwrap();
        let mut stage = engine
            .export_staging
            .create(&source, "pack", &"f".repeat(64), maximum, &budget())
            .unwrap();
        let mut files = vec![];
        for (name, bytes) in [
            ("storage.raw", storage),
            ("overlay.raw", b"root\xff\0".as_slice()),
        ] {
            let mut writer = stage.file(name, bytes.len() as u64, &budget()).unwrap();
            writer.write_all(bytes).unwrap();
            files.push(
                writer
                    .finish(&ExportDiskDigest {
                        size_bytes: bytes.len() as u64,
                        sha256: format!("{:x}", Sha256::digest(bytes)),
                    })
                    .unwrap(),
            );
        }
        stage.ready(files.clone()).unwrap();
        let record = engine.db.get_vm(&source.name).unwrap().unwrap();
        let manifest = manifest(&record, &files, &assets).unwrap();
        (temp, engine, source, stage, files, assets, manifest)
    }
    pub(crate) fn container_fixture() -> (
        tempfile::TempDir,
        Engine,
        CreationReceipt,
        Stage,
        Vec<ExportStagedFile>,
        QualifiedExportAssets,
        PackManifest,
    ) {
        let (temp, engine, source, stage, layer) =
            crate::export_staging::layer::tests::ready_fixture();
        let approved = asset_fixture(&temp.path().join("approved-container-assets"));
        let assets = approved.qualify(&budget()).unwrap();
        let record = crate::export_container::tests::record();
        let plan = crate::export_container::tests::plan(&record);
        let manifest = container_manifest(&record, &plan, &layer, &assets).unwrap();
        (temp, engine, source, stage, vec![layer], assets, manifest)
    }
    #[test]
    fn container_sidecar_matches_upstream_footer_content_digest_and_digest_named_layer() {
        let (_temp, engine, _source, mut stage, files, assets, manifest) = container_fixture();
        let file = pack(&mut stage, &files, &assets, &manifest, MAX, &budget()).unwrap();
        let mut bytes = vec![0; file.size_bytes as usize];
        stage.read_at(ARTIFACT, 0, &mut bytes, &budget()).unwrap();
        assert_eq!(hex::encode(Sha256::digest(&bytes)), file.sha256);
        let mut output = tempfile::NamedTempFile::new().unwrap();
        output.write_all(&bytes).unwrap();
        let footer = smolvm_pack::packer::read_footer_from_sidecar(output.path()).unwrap();
        assert!(smolvm_pack::packer::verify_sidecar_checksum(output.path(), &footer).unwrap());
        let decoded = PackManifest::from_json(
            &bytes[footer.manifest_offset as usize
                ..(footer.manifest_offset + footer.manifest_size) as usize],
        )
        .unwrap();
        assert!(matches!(decoded.mode, PackMode::Container));
        assert_eq!(decoded.image_size, files[0].size_bytes);
        assert_eq!(
            decoded.env,
            vec!["IMAGE_ONLY=private-env-value", "PATH=/custom"]
        );
        assert_eq!(decoded.user.as_deref(), Some("1000"));
        assert!(
            decoded.assets.storage_template.is_none()
                && decoded.assets.overlay_template.is_none()
                && decoded.assets.workspace_seed.is_none()
        );
        assert_eq!(decoded.assets.layers.len(), 1);
        assert_eq!(
            decoded.assets.layers[0].digest,
            format!("sha256:{}", files[0].sha256)
        );
        let expected_path = format!("layers/{}.tar", files[0].sha256);
        assert_eq!(decoded.assets.layers[0].path, expected_path);
        let mut archive = tar::Archive::new(
            zstd::stream::Decoder::new(&bytes[..footer.assets_size as usize]).unwrap(),
        );
        let mut entries = BTreeMap::new();
        for entry in archive.entries().unwrap() {
            let mut entry = entry.unwrap();
            assert!(entry.header().entry_type().is_file());
            let name = entry.path().unwrap().to_str().unwrap().to_owned();
            let mut data = Vec::new();
            entry.read_to_end(&mut data).unwrap();
            entries.insert(name, data);
        }
        assert_eq!(entries.len(), 4);
        assert_eq!(entries[&expected_path], b"private layer bytes");
        assert!(pack(&mut stage, &files, &assets, &manifest, MAX, &budget()).is_err());
        stage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
    }
    #[test]
    fn container_manifest_mismatch_and_partial_output_never_promote_or_replay() {
        for variant in 0..4 {
            let (_temp, engine, source, mut stage, files, assets, mut manifest) =
                container_fixture();
            match variant {
                0 => manifest.assets.layers[0].path = "layers/foreign.tar".into(),
                1 => manifest.assets.layers[0].digest = format!("sha256:{}", "e".repeat(64)),
                2 => manifest.image_size += 1,
                _ => {}
            }
            let max = if variant == 3 {
                manifest.to_json().unwrap().len() as u64 + smolvm_pack::FOOTER_SIZE as u64 + 1
            } else {
                MAX
            };
            assert!(pack(&mut stage, &files, &assets, &manifest, max, &budget()).is_err());
            assert!(stage.read_at(ARTIFACT, 0, &mut [0; 1], &budget()).is_err());
            if variant == 3 {
                assert!(pack(&mut stage, &files, &assets, &manifest, MAX, &budget()).is_err());
            }
            drop(stage);
            engine
                .cleanup_export_staging(&source, "launch-model", &"d".repeat(64), true, &budget())
                .unwrap();
            assert_eq!(engine.jobs.counts().export_staging, 0);
        }
    }
    #[test]
    fn standalone_pack_matches_sdk_footer_checksum_manifest_and_binary_tar_entries() {
        let (_temp, engine, _source, mut stage, files, assets, manifest) = fixture();
        let file = pack(&mut stage, &files, &assets, &manifest, MAX - 32, &budget()).unwrap();
        let mut bytes = vec![0; file.size_bytes as usize];
        stage.read_at(ARTIFACT, 0, &mut bytes, &budget()).unwrap();
        assert_eq!(format!("{:x}", Sha256::digest(&bytes)), file.sha256);
        let mut output = tempfile::NamedTempFile::new().unwrap();
        output.write_all(&bytes).unwrap();
        let footer = smolvm_pack::packer::read_footer_from_sidecar(output.path()).unwrap();
        assert_eq!(footer.stub_size, 0);
        assert_eq!(footer.assets_offset, 0);
        assert_eq!(footer.manifest_offset, footer.assets_size);
        assert_eq!(
            footer.manifest_offset + footer.manifest_size + smolvm_pack::FOOTER_SIZE as u64,
            file.size_bytes
        );
        assert!(smolvm_pack::packer::verify_sidecar_checksum(output.path(), &footer).unwrap());
        let decoded = PackManifest::from_json(
            &bytes[footer.manifest_offset as usize
                ..(footer.manifest_offset + footer.manifest_size) as usize],
        )
        .unwrap();
        assert!(matches!(decoded.mode, PackMode::Vm));
        assert!(decoded.image.is_empty());
        assert_eq!(decoded.digest, "none");
        assert_eq!(decoded.env, manifest.env);
        assert_eq!(decoded.env, vec!["SECRET=private-env-value"]);
        assert_eq!(decoded.cpus, manifest.cpus);
        assert_eq!(decoded.mem, manifest.mem);
        assert_eq!(decoded.smolvm_version, "1.22.0");
        assert_eq!(
            decoded.assets.storage_template.unwrap().path,
            "storage.ext4"
        );
        assert_eq!(decoded.assets.overlay_template.unwrap().path, "overlay.raw");
        assert!(decoded.checkpoint.is_none());
        let decoder = zstd::stream::Decoder::new(&bytes[..footer.assets_size as usize]).unwrap();
        let mut archive = tar::Archive::new(decoder);
        let mut extracted = BTreeMap::new();
        let mut has_layers_directory = false;
        for entry in archive.entries().unwrap() {
            let mut entry = entry.unwrap();
            assert_eq!(entry.header().uid().unwrap(), 0);
            assert_eq!(entry.header().mtime().unwrap(), 0);
            let path = entry.path().unwrap().to_str().unwrap().to_owned();
            if path == "layers" {
                assert!(!has_layers_directory);
                assert!(entry.header().entry_type().is_dir());
                assert_eq!(entry.size(), 0);
                has_layers_directory = true;
                continue;
            }
            assert!(entry.header().entry_type().is_file());
            let mut content = vec![];
            entry.read_to_end(&mut content).unwrap();
            extracted.insert(path, content);
        }
        assert!(has_layers_directory);
        assert_eq!(extracted.len(), 5);
        assert_eq!(extracted["storage.ext4"], b"storage\0\x80");
        assert_eq!(extracted["overlay.raw"], b"root\xff\0");
        assert_eq!(extracted["agent-rootfs.tar"], b"synthetic agent-rootfs.tar");
        assert!(pack(&mut stage, &files, &assets, &manifest, MAX - 32, &budget()).is_err());
        assert_eq!(engine.jobs.counts().export_staging, MAX);
        stage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
    }
    #[test]
    fn preserves_resource_workload_user_network_and_secret_reference_metadata() {
        let (_temp, engine, source, stage, files, assets, _) = fixture();
        let mut record = engine.db.get_vm(&source.name).unwrap().unwrap();
        record.cpus = 3;
        record.mem = 4096;
        record.entrypoint = vec!["service".into()];
        record.cmd = vec!["--foreground".into()];
        record.workdir = Some("/work".into());
        record.user = Some("123:456".into());
        record.env = vec![
            ("PATH".into(), "/bin".into()),
            ("VALUE".into(), "a=b".into()),
        ];
        record.network = true;
        record
            .secret_refs
            .insert("TOKEN".into(), smolvm::secrets::env_ref("OPERATOR_ENV"));
        let packed = manifest(&record, &files, &assets).unwrap();
        assert_eq!(packed.cpus, 3);
        assert_eq!(packed.mem, 4096);
        assert_eq!(packed.entrypoint, record.entrypoint);
        assert_eq!(packed.cmd, record.cmd);
        assert_eq!(packed.user, record.user);
        assert_eq!(packed.workdir, record.workdir);
        assert_eq!(packed.env, vec!["PATH=/bin", "VALUE=a=b"]);
        assert_eq!(
            serde_json::to_value(packed.secret_refs).unwrap(),
            serde_json::to_value(&record.secret_refs).unwrap()
        );
        assert!(packed.network);
        assert!(packed.assets.layers.is_empty());
        assert!(packed.assets.workspace_seed.is_none());
        record.image = Some("image@sha256:invalid".into());
        assert!(manifest(&record, &files, &assets).is_err());
        stage.close(&budget()).unwrap();
    }
    #[test]
    fn output_bounds_and_original_cancellation_never_promote_or_replay_partial_packs() {
        // Deterministic local writer limits, no process/VM loss or interruption.
        for cap_kind in 0..3 {
            let (_temp, engine, source, mut stage, files, assets, manifest) = fixture();
            let before = engine.jobs.counts().export_staging;
            let cap = match cap_kind {
                0 => 1,
                1 => MAX,
                _ => manifest.to_json().unwrap().len() as u64 + smolvm_pack::FOOTER_SIZE as u64 + 1,
            };
            assert!(pack(&mut stage, &files, &assets, &manifest, cap, &budget()).is_err());
            assert!(stage.read_at(ARTIFACT, 0, &mut [0; 1], &budget()).is_err());
            assert_eq!(engine.jobs.counts().export_staging, before);
            drop(stage);
            engine
                .cleanup_export_staging(&source, "pack", &"f".repeat(64), true, &budget())
                .unwrap();
            assert_eq!(engine.jobs.counts().export_staging, 0);
        }
        let (_temp, _engine, _source, mut stage, files, assets, manifest) = fixture();
        let cancel = Cancellation::default();
        let work = ReadBudget::for_export_work(Duration::from_secs(30), cancel.clone()).unwrap();
        cancel.cancel();
        assert_eq!(
            pack(&mut stage, &files, &assets, &manifest, MAX - 32, &work)
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        stage.close(&budget()).unwrap();
    }
}
