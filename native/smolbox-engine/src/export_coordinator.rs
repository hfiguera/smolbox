//! Transport-independent export orchestration. Source records select the path;
//! neither caller metadata nor filesystem inventory supplies ownership.
use crate::{
    ContainerExportIntent, CreationReceipt, Engine, Error, ErrorCode, ExportConversionResources,
    ExportDiskKind, ExportSourceMode, PackedExport, ReadBudget, Result,
};

fn bare_limit(disks: &crate::PreparedExportDisks, artifact: u64, staging: u64) -> Result<u64> {
    if artifact == 0 || artifact >= staging || staging > crate::JOB_EXPORT_STAGING_BYTES {
        return Err(Error::before(ErrorCode::Admission));
    }
    disks
        .len(ExportDiskKind::Storage)
        .checked_add(disks.len(ExportDiskKind::Overlay))
        .and_then(|raw| staging.checked_sub(raw))
        .map(|left| left.min(artifact))
        .filter(|n| *n > 0)
        .ok_or(Error::before(ErrorCode::Admission))
}
impl Engine {
    /// Read-only preflight, including actual source mode, geometry, assets and
    /// explicit conversion funding. Does not allocate scratch or dispatch SDK work.
    pub fn qualify_export(
        &self,
        receipt: &CreationReceipt,
        artifact: u64,
        staging: u64,
        conversion: Option<&ExportConversionResources>,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        let source = self.qualify_export_source(receipt, budget)?;
        match source.mode() {
            ExportSourceMode::Bare => {
                let disks = source.prepare_bare_disks(self)?;
                bare_limit(&disks, artifact, staging)?;
                self.export_asset_approval()?.qualify(budget)?;
                disks.recheck(self)
            }
            ExportSourceMode::Container => {
                let source = source.prepare_container_export(self)?;
                source.resource_plan(
                    conversion.ok_or(Error::before(ErrorCode::Unsupported))?,
                    artifact,
                    staging,
                    true,
                )?;
                self.export_asset_approval()?.qualify(budget)?;
                self.export_sdk_library()?;
                self.export_manager_rootfs()?;
                if smolvm::agent::vm_cache_root() != self.binding().vm_root {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                source.recheck(self)
            }
        }
    }
    /// One exact admitted attempt. Errors after scratch entry remain uncertain;
    /// the registry retains original helper/source leases for explicit resolution.
    pub fn pack_export(
        &self,
        receipt: &CreationReceipt,
        intent: &ContainerExportIntent,
        conversion: Option<&ExportConversionResources>,
        budget: &ReadBudget,
    ) -> Result<PackedExport> {
        budget.check()?;
        self.check_export_intent(
            receipt,
            &intent.operation_id,
            &intent.request_sha256,
            intent.max_staging_bytes,
            &intent.request_identity_sha256,
            budget,
        )?;
        let source = self.qualify_export_source(receipt, budget)?;
        match source.mode() {
            ExportSourceMode::Bare => {
                let disks = source.prepare_bare_disks(self)?;
                let maximum =
                    bare_limit(&disks, intent.max_artifact_bytes, intent.max_staging_bytes)?;
                disks
                    .materialize(
                        self,
                        &intent.operation_id,
                        &intent.request_sha256,
                        intent.max_staging_bytes,
                    )
                    .and_then(|materialized| materialized.pack(self, maximum))
                    .map_err(|e| Error::uncertain(e.code))
            }
            ExportSourceMode::Container => {
                let source = source.prepare_container_export(self)?;
                let grant = conversion.ok_or(Error::before(ErrorCode::Unsupported))?;
                let scratch = source
                    .prepare_shared_conversion_scratch(self, grant, intent)
                    .map_err(|e| Error::uncertain(e.code))?;
                let retained = scratch
                    .initialize_sdk_storage(self)
                    .map_err(|e| Error::uncertain(e.code))?;
                let result = (|| {
                    retained.start_manager(self)?;
                    let output = retained.run_conversion(self)?;
                    retained.register_conversion(self, output)?;
                    retained.collect_manager(self, budget)?;
                    retained.pack(self)
                })();
                result.map_err(|e| Error::uncertain(e.code))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Cancellation;
    use std::time::Duration;
    const GIB: u64 = 1 << 30;
    fn fixture(image: bool) -> (tempfile::TempDir, Engine, CreationReceipt) {
        let temp = tempfile::tempdir().unwrap();
        let (engine, source) = crate::export_source::tests::fixture(temp.path(), image);
        let root = engine.vm_directory(&source.name);
        let overlay = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(overlay, root.join(smolvm::storage::OVERLAY_DISK_FILENAME)).unwrap();
        crate::disk_geometry::tests::raw(&root);
        (temp, engine, source)
    }
    fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(30), Cancellation::default()).unwrap()
    }
    #[test]
    fn actual_bare_geometry_clamps_artifact_upper_bound_without_claiming_allocation() {
        let (_temp, engine, source) = fixture(false);
        let disks = engine
            .qualify_export_source(&source, &budget())
            .unwrap()
            .prepare_bare_disks(&engine)
            .unwrap();
        assert_eq!(bare_limit(&disks, 127 * GIB, 128 * GIB).unwrap(), 126 * GIB);
        assert_eq!(bare_limit(&disks, GIB, 128 * GIB).unwrap(), GIB);
        assert!(bare_limit(&disks, GIB, 2 * GIB).is_err());
        assert!(bare_limit(&disks, 128 * GIB, 128 * GIB).is_err());
    }
    #[test]
    fn preflight_is_readonly_and_rejects_missing_grant_assets_or_expired_budget() {
        for image in [false, true] {
            let (_temp, engine, source) = fixture(image);
            let before = engine.jobs.counts();
            let error = engine
                .qualify_export(&source, 127 * GIB, 128 * GIB, None, &budget())
                .unwrap_err();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(error.code, ErrorCode::Unsupported);
            let grant = ExportConversionResources {
                slots: 1,
                cpus: 4,
                memory_mb: 4608,
                disk_gb: 128,
            };
            assert!(engine
                .qualify_export(&source, 127 * GIB, 128 * GIB, Some(&grant), &budget())
                .is_err());
            let canceled = budget();
            canceled.cancel.cancel();
            assert!(engine
                .qualify_export(&source, GIB, 128 * GIB, Some(&grant), &canceled)
                .is_err());
            assert_eq!(engine.jobs.counts(), before);
            assert!(engine.available());
        }
    }
    #[test]
    fn orchestrated_container_never_enters_sdk_from_database_only_fixture_and_keeps_cleanup_authority(
    ) {
        // Namespace rejection is mandatory before every SDK call; this test may
        // create only private scratch and must never start a manager or VM.
        let (_temp, engine, source) = fixture(true);
        let request = "c".repeat(64);
        let identity = "d".repeat(64);
        let intent = ContainerExportIntent {
            operation_id: "coordinated".into(),
            request_sha256: request.clone(),
            request_identity_sha256: identity.clone(),
            max_artifact_bytes: 127 * GIB,
            max_staging_bytes: 128 * GIB,
        };
        let grant = ExportConversionResources {
            slots: 1,
            cpus: 4,
            memory_mb: 4608,
            disk_gb: 128,
        };
        assert!(engine
            .pack_export(&source, &intent, Some(&grant), &budget())
            .is_err());
        assert_eq!(engine.jobs.counts().export_staging, 0);
        engine
            .admit_export_intent(
                &source,
                &intent.operation_id,
                &request,
                intent.max_staging_bytes,
                &identity,
                &budget(),
            )
            .unwrap();
        let error = engine
            .pack_export(&source, &intent, Some(&grant), &budget())
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        assert_eq!(engine.jobs.counts().export_staging, 128 * GIB);
        assert_eq!(engine.jobs.counts().children, 0);
        engine
            .cleanup_export_staging(&source, &intent.operation_id, &request, true, &budget())
            .unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert!(engine.db.get_vm(&source.name).unwrap().is_some());
    }
}
