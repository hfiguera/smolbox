//! Descriptor-bound bare disk reads. These are not packed artifacts or publication proofs.
use crate::disk_geometry::ExportDisk;
use crate::{Engine, Error, ErrorCode, ExportSourceMode, QualifiedExportSource, Result};
use sha2::{Digest, Sha256};
use std::io::Write;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportDiskKind {
    Storage,
    Overlay,
}

#[derive(Clone, PartialEq, Eq)]
pub struct ExportDiskDigest {
    pub size_bytes: u64,
    pub sha256: String,
}
impl std::fmt::Debug for ExportDiskDigest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExportDiskDigest")
            .field("size_bytes", &self.size_bytes)
            .finish_non_exhaustive()
    }
}

pub struct PreparedExportDisks {
    storage: ExportDisk,
    overlay: ExportDisk,
    // Source gate, work budget and domain outlive every disk descriptor.
    source: QualifiedExportSource,
}
impl std::fmt::Debug for PreparedExportDisks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedExportDisks")
            .finish_non_exhaustive()
    }
}
impl QualifiedExportSource {
    pub fn prepare_bare_disks(mut self, engine: &Engine) -> Result<PreparedExportDisks> {
        let record = self.checked_record(engine)?;
        if self.mode() != ExportSourceMode::Bare {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        self.promote_disks()?;
        let storage = ExportDisk::capture(
            self.directory(),
            smolvm::storage::STORAGE_DISK_FILENAME,
            record
                .storage_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            self.budget(),
        )?;
        let overlay = ExportDisk::capture(
            self.directory(),
            smolvm::storage::OVERLAY_DISK_FILENAME,
            record
                .overlay_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            self.budget(),
        )?;
        let disks = PreparedExportDisks {
            storage,
            overlay,
            source: self,
        };
        disks.recheck(engine)?;
        Ok(disks)
    }
}
pub struct MaterializedExportDisks {
    files: Vec<crate::export_staging::ExportStagedFile>,
    stage: crate::export_staging::Stage,
    disks: PreparedExportDisks,
}
impl std::fmt::Debug for MaterializedExportDisks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MaterializedExportDisks")
            .finish_non_exhaustive()
    }
}
impl MaterializedExportDisks {
    pub(crate) fn publish(
        &mut self,
        engine: &Engine,
        artifact: &crate::ExportStagedFile,
        destination: &crate::ApprovedExportDestination,
        tag: &str,
        credential: &crate::RegistryPublishCredential,
    ) -> Result<crate::ExportPublication> {
        self.recheck(engine)?;
        let budget = self.disks.source.budget();
        let plan = crate::export_publication::Plan::from_artifact(
            &self.stage,
            artifact,
            destination,
            tag,
            budget,
        )?;
        crate::export_publication::publish(
            &mut self.stage,
            artifact,
            &plan,
            destination,
            credential,
            budget,
            || self.disks.recheck(engine),
        )
    }
    /// Pack with the immutable asset catalog installed from the approved package.
    /// The request supplies no host asset paths or independently asserted digest.
    pub fn pack(self, engine: &Engine, max_artifact_bytes: u64) -> Result<crate::PackedExport> {
        let assets = engine.export_asset_approval()?;
        self.pack_with_assets(engine, assets, max_artifact_bytes)
    }
    /// Construct a standalone VM-mode pack from qualified operator assets. The
    /// existing staging grant must cover both raw disks and the artifact cap.
    pub(crate) fn pack_with_assets(
        mut self,
        engine: &Engine,
        assets: &crate::ApprovedExportAssets,
        max_artifact_bytes: u64,
    ) -> Result<crate::PackedExport> {
        self.recheck(engine)?;
        let record = self.disks.source.checked_record(engine)?;
        // Qualify and retain the three asset descriptors only inside the
        // existing whole-job FD allowance. No public detached FD grant exists.
        let assets = assets.qualify(self.disks.source.budget())?;
        let manifest = crate::export_pack::manifest(&record, &self.files, &assets)?;
        let artifact = crate::export_pack::pack(
            &mut self.stage,
            &self.files,
            &assets,
            &manifest,
            max_artifact_bytes,
            self.disks.source.budget(),
        )?;
        self.recheck(engine)?;
        Ok(crate::PackedExport::new(self, artifact))
    }
    pub(crate) fn read_artifact_at(&self, offset: u64, bytes: &mut [u8]) -> Result<()> {
        self.stage.read_at(
            "artifact.smolmachine",
            offset,
            bytes,
            self.disks.source.budget(),
        )
    }
    pub fn files(&self) -> &[crate::export_staging::ExportStagedFile] {
        &self.files
    }
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        self.disks.recheck(engine)?;
        self.stage.verify()
    }
    pub fn read_at(&self, kind: ExportDiskKind, offset: u64, bytes: &mut [u8]) -> Result<()> {
        let name = match kind {
            ExportDiskKind::Storage => "storage.raw",
            ExportDiskKind::Overlay => "overlay.raw",
        };
        self.stage
            .read_at(name, offset, bytes, self.disks.source.budget())
    }
    pub fn close(self, budget: &crate::ReadBudget) -> Result<crate::ExportStageCleanup> {
        self.stage.close(budget)
    }
}

impl Engine {
    /// Read-only feasibility under a short original budget; no scratch, registry
    /// mutation, source record change or allocation promise is produced.
    pub fn qualify_bare_export(
        &self,
        receipt: &crate::CreationReceipt,
        max_artifact_bytes: u64,
        max_staging_bytes: u64,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        let disks = self
            .qualify_export_source(receipt, budget)?
            .prepare_bare_disks(self)?;
        if max_artifact_bytes == 0
            || max_staging_bytes > crate::jobs::JOB_EXPORT_STAGING_BYTES
            || disks
                .len(ExportDiskKind::Storage)
                .checked_add(disks.len(ExportDiskKind::Overlay))
                .and_then(|bytes| bytes.checked_add(max_artifact_bytes))
                .is_none_or(|bytes| bytes > max_staging_bytes)
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        let _assets = self.export_asset_approval()?.qualify(budget)?;
        disks.recheck(self)
    }
}
impl PreparedExportDisks {
    pub fn materialize(
        mut self,
        engine: &Engine,
        operation_id: &str,
        request_sha256: &str,
        max_bytes: u64,
    ) -> Result<MaterializedExportDisks> {
        self.recheck(engine)?;
        let needed = self
            .len(ExportDiskKind::Storage)
            .checked_add(self.len(ExportDiskKind::Overlay))
            .ok_or(Error::before(ErrorCode::Admission))?;
        if max_bytes < needed {
            return Err(Error::before(ErrorCode::Admission));
        }
        self.source.promote_stage()?;
        let mut stage = engine.export_staging.create(
            self.source.receipt(),
            operation_id,
            request_sha256,
            max_bytes,
            self.source.budget(),
        )?;
        let mut files = Vec::new();
        for (kind, name) in [
            (ExportDiskKind::Storage, "storage.raw"),
            (ExportDiskKind::Overlay, "overlay.raw"),
        ] {
            let mut writer = stage.file(name, self.len(kind), self.source.budget())?;
            let digest = self.copy_raw_to(engine, kind, &mut writer)?;
            files.push(writer.finish(&digest)?);
        }
        self.recheck(engine)?;
        stage.ready(files.clone())?;
        Ok(MaterializedExportDisks {
            files,
            stage,
            disks: self,
        })
    }

    pub fn len(&self, kind: ExportDiskKind) -> u64 {
        self.disk(kind).len()
    }
    pub fn read_at(&self, kind: ExportDiskKind, offset: u64, bytes: &mut [u8]) -> Result<()> {
        self.disk(kind).read_at(offset, bytes, self.source.budget())
    }
    /// Stream exact logical disk bytes to a coordinator-owned sink. A digest is
    /// issued only after full transfer and source/disk rechecks; it is not a pack
    /// or registry receipt. Error/cancellation leaves this lease retained.
    pub fn copy_raw_to(
        &self,
        engine: &Engine,
        kind: ExportDiskKind,
        output: &mut impl Write,
    ) -> Result<ExportDiskDigest> {
        self.recheck(engine)?;
        let length = self.len(kind);
        let mut hash = Sha256::new();
        let mut buffer = vec![0; 64 * 1024];
        let mut offset = 0;
        while offset < length {
            let take = (length - offset).min(buffer.len() as u64) as usize;
            self.read_at(kind, offset, &mut buffer[..take])?;
            output
                .write_all(&buffer[..take])
                .map_err(|_| Error::before(ErrorCode::Io))?;
            self.source.budget().check()?;
            hash.update(&buffer[..take]);
            offset += take as u64;
        }
        self.recheck(engine)?;
        Ok(ExportDiskDigest {
            size_bytes: length,
            sha256: format!("{:x}", hash.finalize()),
        })
    }

    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        self.source.recheck(engine)?;
        self.storage.verify(self.source.budget())?;
        self.overlay.verify(self.source.budget())?;
        self.source.recheck(engine)
    }
    fn disk(&self, kind: ExportDiskKind) -> &ExportDisk {
        match kind {
            ExportDiskKind::Storage => &self.storage,
            ExportDiskKind::Overlay => &self.overlay,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Cancellation, CreationReceipt, ReadBudget};
    use std::fs::OpenOptions;
    use std::os::unix::fs::{FileExt, PermissionsExt};
    use std::time::Duration;
    const GIB: u64 = 1 << 30;
    const CLUSTER: u64 = 1 << 16;

    fn fixture(version: Option<u32>, backed: bool) -> (tempfile::TempDir, Engine, CreationReceipt) {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(temp.path(), false);
        let root = engine.vm_directory(&receipt.name);
        let overlay = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(overlay, root.join(smolvm::storage::OVERLAY_DISK_FILENAME)).unwrap();
        match version {
            Some(version) if backed => {
                crate::disk_geometry::tests::backed_qcow(&root, version);
            }
            Some(version) => {
                crate::disk_geometry::tests::qcow(&root, version);
            }
            None => {
                crate::disk_geometry::tests::raw(&root);
            }
        }
        (temp, engine, receipt)
    }
    fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(3600), Cancellation::default()).unwrap()
    }
    fn prepare(engine: &Engine, receipt: &CreationReceipt) -> PreparedExportDisks {
        engine
            .qualify_export_source(receipt, &budget())
            .unwrap()
            .prepare_bare_disks(engine)
            .unwrap()
    }
    fn writable(path: &std::path::Path) -> std::fs::File {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .unwrap()
    }
    #[test]
    fn raw_and_qcow_views_retain_source_capacity_and_read_sparse_logical_bytes() {
        for version in [None, Some(2), Some(3)] {
            let (_temp, engine, receipt) = fixture(version, false);
            let disks = prepare(&engine, &receipt);
            assert_eq!(disks.len(ExportDiskKind::Storage), GIB);
            assert_eq!(disks.len(ExportDiskKind::Overlay), GIB);
            assert_eq!(engine.jobs.counts().work, 1);
            assert_eq!(engine.jobs.counts().work_descriptors, 12);
            let observer =
                ReadBudget::new(Duration::from_secs(2), Cancellation::default()).unwrap();
            assert_eq!(engine.inventory(&observer).unwrap().count, 1);
            assert_eq!(engine.jobs.counts().work, 1);
            let mut sb = [0; 1024];
            disks
                .read_at(ExportDiskKind::Storage, 1024, &mut sb)
                .unwrap();
            assert_eq!(&sb[56..58], &0xef53u16.to_le_bytes());
            let mut zero = [255; 4096];
            disks
                .read_at(ExportDiskKind::Storage, GIB - 4096, &mut zero)
                .unwrap();
            assert!(zero.iter().all(|value| *value == 0));
            assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
            disks.recheck(&engine).unwrap();
            drop(disks);
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }
    #[test]
    fn backing_inheritance_cluster_boundaries_and_explicit_zero_are_distinct() {
        for explicit_zero in [false, true] {
            let (_temp, engine, receipt) = fixture(Some(3), true);
            let root = engine.vm_directory(&receipt.name);
            let base = writable(&root.join("base-3.ext4"));
            base.write_all_at(b"BASE", 2 * CLUSTER).unwrap();
            base.write_all_at(&[3, 4], CLUSTER).unwrap();
            let top = writable(&root.join("storage.qcow2"));
            let mut first = vec![0; CLUSTER as usize];
            base.read_exact_at(&mut first, 0).unwrap();
            first[CLUSTER as usize - 2..].copy_from_slice(&[1, 2]);
            top.write_all_at(&first, 5 * CLUSTER).unwrap();
            top.write_all_at(&((1u64 << 63) | (5 * CLUSTER)).to_be_bytes(), 2 * CLUSTER)
                .unwrap();
            top.write_all_at(&1u16.to_be_bytes(), 4 * CLUSTER + 5 * 2)
                .unwrap();
            if explicit_zero {
                top.write_all_at(&1u64.to_be_bytes(), 2 * CLUSTER + 2 * 8)
                    .unwrap();
            }
            let disks = prepare(&engine, &receipt);
            let mut inherited = [0; 4];
            disks
                .read_at(ExportDiskKind::Storage, 2 * CLUSTER, &mut inherited)
                .unwrap();
            assert_eq!(inherited, if explicit_zero { [0; 4] } else { *b"BASE" });
            disks
                .read_at(ExportDiskKind::Storage, CLUSTER - 2, &mut inherited)
                .unwrap();
            assert_eq!(inherited, [1, 2, 3, 4]);
        }
    }
    #[test]
    fn payload_writes_and_substituted_backings_cannot_keep_export_authority() {
        for backing in [false, true] {
            let (_temp, engine, receipt) = fixture(if backing { Some(3) } else { None }, backing);
            let root = engine.vm_directory(&receipt.name);
            let path = root.join(if backing {
                "base-3.ext4"
            } else {
                "storage.raw"
            });
            drop(writable(&path));
            let disks = prepare(&engine, &receipt);
            writable(&path)
                .write_all_at(b"changed", 128 * 1024)
                .unwrap();
            assert!(disks
                .read_at(ExportDiskKind::Storage, 0, &mut [0; 32])
                .is_err());
            assert!(disks.recheck(&engine).is_err());
            assert_eq!(engine.jobs.counts().work, 1);
            drop(disks);
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
        let (_temp, engine, receipt) = fixture(Some(3), true);
        let disks = prepare(&engine, &receipt);
        let path = engine.vm_directory(&receipt.name).join("base-3.ext4");
        std::fs::rename(&path, path.with_file_name("retained-base")).unwrap();
        std::fs::write(&path, b"foreign").unwrap();
        assert!(disks
            .read_at(ExportDiskKind::Storage, 0, &mut [0; 1])
            .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"foreign");
    }
    #[test]
    fn ranges_cancellation_and_failed_output_never_issue_a_digest_or_release_the_lease() {
        let (_temp, engine, receipt) = fixture(Some(3), false);
        let cancel = Cancellation::default();
        let work = ReadBudget::for_export_work(Duration::from_secs(60), cancel.clone()).unwrap();
        let disks = engine
            .qualify_export_source(&receipt, &work)
            .unwrap()
            .prepare_bare_disks(&engine)
            .unwrap();
        for (offset, size) in [(0, 0), (GIB, 1), (u64::MAX, 2), (0, 256 * 1024 + 1)] {
            assert!(disks
                .read_at(ExportDiskKind::Storage, offset, &mut vec![0; size])
                .is_err());
        }
        struct Refuse;
        impl Write for Refuse {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::other("modeled sink refusal"))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        assert!(disks
            .copy_raw_to(&engine, ExportDiskKind::Storage, &mut Refuse)
            .is_err());
        assert_eq!(engine.jobs.counts().work, 1);
        cancel.cancel();
        assert!(disks
            .copy_raw_to(&engine, ExportDiskKind::Storage, &mut std::io::sink())
            .is_err());
        assert_eq!(engine.jobs.counts().work, 1);
        drop(disks);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn complete_host_conversion_has_exact_logical_size_and_independent_known_digest() {
        // One sparse synthetic GiB; no VM, process or host conversion executable.
        let (_temp, engine, receipt) = fixture(Some(3), false);
        let disks = prepare(&engine, &receipt);
        let digest = disks
            .copy_raw_to(&engine, ExportDiskKind::Storage, &mut std::io::sink())
            .unwrap();
        assert_eq!(digest.size_bytes, GIB);
        // Independently computed from zeros plus the fixture's ext4 superblock.
        assert_eq!(
            digest.sha256,
            "f3af519ff8c88392ad71bf53169fa45007951d8d5fa292dcfd4e59883a8b526c"
        );
    }
    #[test]
    fn missing_companion_or_container_preparation_rejects_before_any_dispatch() {
        let (_temp, engine, receipt) = fixture(None, false);
        std::fs::remove_file(
            engine
                .vm_directory(&receipt.name)
                .join(smolvm::storage::OVERLAY_DISK_FILENAME),
        )
        .unwrap();
        assert!(engine
            .qualify_export_source(&receipt, &budget())
            .unwrap()
            .prepare_bare_disks(&engine)
            .is_err());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(temp.path(), true);
        assert!(engine
            .qualify_export_source(&receipt, &budget())
            .unwrap()
            .prepare_bare_disks(&engine)
            .is_err());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn export_preserves_opaque_disk_bytes_while_growth_keeps_ext4_validation() {
        for version in [None, Some(3)] {
            let (_temp, engine, receipt) = fixture(version, false);
            let root = engine.vm_directory(&receipt.name);
            let path = root.join(if version.is_some() {
                "storage.qcow2"
            } else {
                "storage.raw"
            });
            let file = writable(&path);
            let physical = if version.is_some() {
                5 * CLUSTER + 1024
            } else {
                1024
            };
            file.write_all_at(&[0x5a; 1024], physical).unwrap();
            if version.is_none() {
                file.write_all_at(b"QFI\xfb", 0).unwrap();
            }
            assert!(crate::disk_geometry::DiskGeometry::capture_with_budget(
                &root,
                "storage.raw",
                1,
                &budget()
            )
            .is_err());
            let disks = prepare(&engine, &receipt);
            let mut opaque = [0; 1024];
            disks
                .read_at(ExportDiskKind::Storage, 1024, &mut opaque)
                .unwrap();
            assert_eq!(opaque, [0x5a; 1024]);
            disks.recheck(&engine).unwrap();
        }
    }
    #[test]
    fn ordinary_bare_materialization_is_sparse_owned_rehashed_and_explicitly_cleaned() {
        // Ordinary local sparse files only: no SDK VM or helper process.
        let (temp, mut engine, receipt) = fixture(Some(3), false);
        let assets = crate::export_assets::tests::fixture(&temp.path().join("pack-assets"));
        crate::machine::tests::test_export_host(
            &mut engine,
            &std::fs::canonicalize(temp.path().join("pack-assets")).unwrap(),
        );
        engine
            .prepare_export_assets(assets, &"c".repeat(64), &budget())
            .unwrap();
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        engine
            .admit_export_intent(
                &receipt,
                "materialize",
                &"e".repeat(64),
                2 * GIB + 4 * 1024 * 1024,
                &"f".repeat(64),
                &budget(),
            )
            .unwrap();
        let disks = prepare(&engine, &receipt);
        let material = disks
            .materialize(
                &engine,
                "materialize",
                &"e".repeat(64),
                2 * GIB + 4 * 1024 * 1024,
            )
            .unwrap();
        assert_eq!(material.files().len(), 2);
        for file in material.files() {
            assert_eq!(file.size_bytes, GIB);
            assert_eq!(
                file.sha256,
                "f3af519ff8c88392ad71bf53169fa45007951d8d5fa292dcfd4e59883a8b526c"
            );
        }
        assert_eq!(
            engine.jobs.counts().export_staging,
            2 * GIB + 4 * 1024 * 1024
        );
        let mut sb = [0; 1024];
        material
            .read_at(ExportDiskKind::Storage, 1024, &mut sb)
            .unwrap();
        assert_eq!(&sb[56..58], &0xef53u16.to_le_bytes());
        let mut tail = [255; 32];
        material
            .read_at(ExportDiskKind::Overlay, GIB - 32, &mut tail)
            .unwrap();
        assert_eq!(tail, [0; 32]);
        assert_eq!(
            before,
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap()
        );
        material.recheck(&engine).unwrap();
        let packed = material.pack(&engine, 4 * 1024 * 1024).unwrap();
        packed.recheck(&engine).unwrap();
        let size = packed.artifact().size_bytes;
        assert!(size > smolvm_pack::FOOTER_SIZE as u64 && size <= 4 * 1024 * 1024);
        let mut footer_bytes = [0; smolvm_pack::FOOTER_SIZE];
        packed
            .read_at(size - smolvm_pack::FOOTER_SIZE as u64, &mut footer_bytes)
            .unwrap();
        let footer = smolvm_pack::PackFooter::from_bytes(&footer_bytes).unwrap();
        assert_eq!(
            footer.assets_size + footer.manifest_size + smolvm_pack::FOOTER_SIZE as u64,
            size
        );
        assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
        assert_eq!(
            before,
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap()
        );
        let peer = crate::export_publication::tests::Peer::new(
            crate::export_publication::tests::Fault::None,
            None,
        );
        let published = packed
            .publish(
                &engine,
                &peer.destination,
                "release",
                crate::export_publication::tests::Peer::credential(),
            )
            .unwrap();
        published.recheck(&engine).unwrap();
        published.publication().validate(engine.binding()).unwrap();
        assert_eq!(published.publication().identity.size_bytes, size);
        assert!(published.publication().source == receipt);
        assert!(
            engine
                .inspect_export_publication(&receipt, "materialize", &"e".repeat(64), &budget())
                .unwrap()
                .as_ref()
                == Some(published.publication())
        );
        assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
        assert!(engine.jobs.counts().export_staging > 0);
        let proof = published.close(&budget()).unwrap();
        assert_eq!(proof.operation_id, "materialize");
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
}
