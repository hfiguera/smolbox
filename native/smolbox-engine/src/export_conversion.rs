//! Explicit operator resource bounds for an enrolled container conversion VM.
//! These plans are not VM enrollment, scratch ownership or collection evidence.
use crate::{Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};
const GIB: u64 = 1 << 30;

/// Exact qualified imported-input sizes. This grants no source or VM ownership.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImportedConversionAllowance {
    pub source_sha256: String,
    pub tar_bytes: u64,
    pub max_layer_tar_bytes: u64,
    pub expanded_bytes: u64,
    pub entries: u64,
}
impl ImportedConversionAllowance {
    pub(crate) fn validate(&self) -> Result<()> {
        if !crate::domain::valid_hex(&self.source_sha256, 64)
            || self.tar_bytes == 0
            || self.tar_bytes > 128 * GIB
            || self.max_layer_tar_bytes == 0
            || self.max_layer_tar_bytes > self.tar_bytes
            || self.expanded_bytes > 128 * GIB
            || self.entries > 200_000
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        Ok(())
    }
    fn storage_gib(&self) -> Result<u64> {
        self.validate()?;
        // All extracted layers coexist, but raw parts for just one layer do.
        // Allow block rounding, inodes, bounded xattrs and ext4 metadata in
        // addition to logical (including sparse) content; retain a GiB reserve.
        let contents = self
            .expanded_bytes
            .checked_add(self.max_layer_tar_bytes)
            .ok_or(Error::before(ErrorCode::Admission))?;
        contents
            .checked_add(contents.div_ceil(10))
            .and_then(|n| n.checked_add(self.entries.checked_mul(32 * 1024)?))
            .and_then(|n| n.checked_add(GIB))
            .map(|n| n.div_ceil(GIB))
            .ok_or(Error::before(ErrorCode::Admission))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportConversionResources {
    pub slots: u64,
    pub cpus: u64,
    pub memory_mb: u64,
    pub disk_gb: u64,
}
impl ExportConversionResources {
    pub fn validate(&self) -> Result<()> {
        if !(1..=1048576).contains(&self.slots)
            || !(4..=1048576).contains(&self.cpus)
            || !(1152..=1048576).contains(&self.memory_mb)
            || !(64..=1048576).contains(&self.disk_gb)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn plan(
        &self,
        source_storage_bytes: u64,
        max_artifact_bytes: u64,
        max_staging_bytes: u64,
    ) -> Result<ExportConversionBudget> {
        self.validate()?;
        if source_storage_bytes == 0
            || !source_storage_bytes.is_multiple_of(GIB)
            || source_storage_bytes > crate::JOB_EXPORT_STAGING_BYTES
            || max_artifact_bytes == 0
            || max_staging_bytes > crate::JOB_EXPORT_STAGING_BYTES
            || max_staging_bytes
                > self
                    .disk_gb
                    .checked_mul(GIB)
                    .ok_or(Error::before(ErrorCode::Admission))?
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        // Registry conversion binds the source's cached directories and streams
        // its merged tree to the host. It does not extract or repull layers onto
        // helper storage, so reserve an explicit raw metadata disk instead of
        // the SDK convenience collector's heuristic expansion disk. COW/source
        // and fresh root allowances include conservative QCOW metadata room.
        let storage_gib = 1u64;
        let private_disk_bytes = storage_gib
            .checked_mul(GIB)
            .and_then(|n| n.checked_add(2 * GIB))
            .and_then(|n| n.checked_add(source_storage_bytes.checked_mul(2)?))
            .ok_or(Error::before(ErrorCode::Admission))?;
        let max_flattened_bytes = max_staging_bytes
            .checked_sub(private_disk_bytes)
            .and_then(|n| n.checked_sub(max_artifact_bytes))
            .filter(|n| *n > 0)
            .ok_or(Error::before(ErrorCode::Admission))?;
        Ok(ExportConversionBudget {
            cpus: 4,
            // Leave 128 MiB in the existing operator grant for host conversion
            // work; bound guest memory without consulting process-global env.
            memory_mib: (self.memory_mb - 128).min(4096) as u32,
            storage_gib,
            overlay_gib: 1,
            source_storage_bytes,
            private_disk_bytes,
            max_flattened_bytes,
            max_artifact_bytes,
            max_staging_bytes,
            shared_output_bytes: None,
            imported: None,
            approval_sha256: crate::material::hash(&(
                "smolbox-export-conversion-resources-v1",
                self,
            ))?,
        })
    }
    /// Tar and artifact share the remaining grant. Individual maxima are bounds,
    /// not promised allocation; actual tar bytes determine the packing cap.
    pub fn shared_plan(
        &self,
        source_storage_bytes: u64,
        max_artifact_bytes: u64,
        max_staging_bytes: u64,
    ) -> Result<ExportConversionBudget> {
        if max_artifact_bytes == 0 || max_artifact_bytes >= max_staging_bytes {
            return Err(Error::before(ErrorCode::Admission));
        }
        let mut plan = self.plan(source_storage_bytes, 1, max_staging_bytes)?;
        plan.max_artifact_bytes = max_artifact_bytes;
        plan.shared_output_bytes = Some(max_staging_bytes - plan.private_disk_bytes);
        plan.approval_sha256 =
            crate::material::hash(&("smolbox-export-shared-conversion-resources-v1", self))?;
        Ok(plan)
    }
    pub(crate) fn imported_plan(
        &self,
        source: u64,
        artifact: u64,
        staging: u64,
        imported: &ImportedConversionAllowance,
        shared: bool,
    ) -> Result<ExportConversionBudget> {
        let mut plan = if shared {
            self.shared_plan(source, artifact, staging)?
        } else {
            self.plan(source, artifact, staging)?
        };
        let storage = imported.storage_gib()?;
        let extra = (storage - 1)
            .checked_mul(GIB)
            .ok_or(Error::before(ErrorCode::Admission))?;
        plan.private_disk_bytes = plan
            .private_disk_bytes
            .checked_add(extra)
            .ok_or(Error::before(ErrorCode::Admission))?;
        plan.max_flattened_bytes = plan
            .max_flattened_bytes
            .checked_sub(extra)
            .filter(|n| *n > 0)
            .ok_or(Error::before(ErrorCode::Admission))?;
        plan.storage_gib = storage;
        if shared {
            plan.shared_output_bytes = Some(staging - plan.private_disk_bytes);
        }
        plan.imported = Some(imported.clone());
        plan.approval_sha256 = crate::material::hash(&(
            "smolbox-export-imported-conversion-resources-v1",
            self,
            imported,
            shared,
        ))?;
        Ok(plan)
    }
    pub(crate) fn rebuild(&self, plan: &ExportConversionBudget) -> Result<ExportConversionBudget> {
        if let Some(imported) = &plan.imported {
            self.imported_plan(
                plan.source_storage_bytes,
                plan.max_artifact_bytes,
                plan.max_staging_bytes,
                imported,
                plan.shared_output_bytes.is_some(),
            )
        } else if plan.shared_output_bytes.is_some() {
            self.shared_plan(
                plan.source_storage_bytes,
                plan.max_artifact_bytes,
                plan.max_staging_bytes,
            )
        } else {
            self.plan(
                plan.source_storage_bytes,
                plan.max_artifact_bytes,
                plan.max_staging_bytes,
            )
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportConversionBudget {
    pub cpus: u8,
    pub memory_mib: u32,
    pub storage_gib: u64,
    pub overlay_gib: u64,
    pub source_storage_bytes: u64,
    pub private_disk_bytes: u64,
    pub max_flattened_bytes: u64,
    pub max_artifact_bytes: u64,
    pub max_staging_bytes: u64,
    pub approval_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shared_output_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub imported: Option<ImportedConversionAllowance>,
}
impl ExportConversionBudget {
    pub(crate) fn artifact_limit(&self, layer_bytes: u64) -> Result<u64> {
        if layer_bytes == 0 || layer_bytes > self.max_flattened_bytes {
            return Err(Error::before(ErrorCode::Admission));
        }
        self.max_staging_bytes
            .checked_sub(self.private_disk_bytes)
            .and_then(|n| n.checked_sub(layer_bytes))
            .map(|n| n.min(self.max_artifact_bytes))
            .filter(|n| *n > 0)
            .ok_or(Error::before(ErrorCode::Admission))
    }
    /// Explicit offline SDK launch values. Device/UID grants and enrollment are
    /// supplied separately by the owner; this does not authorize a launch.
    pub fn vm_resources(&self) -> smolvm::agent::VmResources {
        smolvm::agent::VmResources {
            cpus: self.cpus,
            memory_mib: self.memory_mib,
            storage_gib: Some(self.storage_gib),
            overlay_gib: Some(self.overlay_gib),
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn grant() -> ExportConversionResources {
        ExportConversionResources {
            slots: 1,
            cpus: 4,
            memory_mb: 4608,
            disk_gb: 128,
        }
    }
    #[test]
    fn imported_budget_funds_coexisting_expansion_largest_tar_and_filesystem_overhead() {
        let allowance = ImportedConversionAllowance {
            source_sha256: "a".repeat(64),
            tar_bytes: 6 * GIB,
            max_layer_tar_bytes: 5 * GIB,
            expanded_bytes: 7 * GIB,
            entries: 200_000,
        };
        let storage = allowance.storage_gib().unwrap();
        assert!(storage * GIB > allowance.expanded_bytes + allowance.max_layer_tar_bytes + 6 * GIB);
        for shared in [false, true] {
            let plan = grant()
                .imported_plan(GIB, GIB, 128 * GIB, &allowance, shared)
                .unwrap();
            assert_eq!(plan.storage_gib, storage);
            assert_eq!(grant().rebuild(&plan).unwrap(), plan);
            assert_eq!(plan.private_disk_bytes, (storage + 4) * GIB);
            let tar = plan.max_flattened_bytes;
            assert!(
                plan.private_disk_bytes + tar + plan.artifact_limit(tar).unwrap()
                    <= plan.max_staging_bytes
            );
            let mut changed = plan.clone();
            changed.imported.as_mut().unwrap().expanded_bytes += GIB;
            assert_ne!(grant().rebuild(&changed).unwrap(), plan);
            let json = serde_json::to_value(&plan).unwrap();
            assert!(json.get("imported").is_some());
            assert_eq!(
                serde_json::from_value::<ExportConversionBudget>(json).unwrap(),
                plan
            );
        }
        let mut too_big = allowance.clone();
        too_big.expanded_bytes = 128 * GIB;
        assert!(grant()
            .imported_plan(GIB, GIB, 128 * GIB, &too_big, true)
            .is_err());
        too_big.entries = 200_001;
        assert!(too_big.validate().is_err());
        let legacy = serde_json::to_value(grant().plan(GIB, GIB, 128 * GIB).unwrap()).unwrap();
        assert!(legacy.get("imported").is_none());
    }
    #[test]
    fn shared_outputs_trade_actual_tar_and_pack_bytes_without_partitioning_the_grant() {
        let grant = grant();
        let shared = grant.shared_plan(GIB, 127 * GIB, 128 * GIB).unwrap();
        assert_eq!(shared.private_disk_bytes, 5 * GIB);
        assert_eq!(shared.shared_output_bytes, Some(123 * GIB));
        assert_eq!(shared.max_flattened_bytes, 123 * GIB - 1);
        assert!(grant.plan(GIB, 127 * GIB, 128 * GIB).is_err());
        for tar in [1, GIB, 62 * GIB, 100 * GIB, shared.max_flattened_bytes] {
            let cap = shared.artifact_limit(tar).unwrap();
            assert_eq!(
                cap + tar + shared.private_disk_bytes,
                shared.max_staging_bytes
            );
            assert!(cap <= shared.max_artifact_bytes);
        }
        assert!(shared.artifact_limit(0).is_err());
        assert!(shared.artifact_limit(123 * GIB).is_err());
        let legacy = grant.plan(GIB, 30 * GIB, 128 * GIB).unwrap();
        let json = serde_json::to_value(&legacy).unwrap();
        assert!(json.get("shared_output_bytes").is_none());
        assert_eq!(legacy, serde_json::from_value(json).unwrap());
        assert_ne!(legacy.approval_sha256, shared.approval_sha256);
    }
    #[test]
    fn conversion_budgets_all_private_disks_flattened_tar_and_pack_within_operator_grant() {
        let plan = grant().plan(GIB, 30 * GIB, 128 * GIB).unwrap();
        assert_eq!(plan.storage_gib, 1);
        assert_eq!(plan.memory_mib, 4096);
        assert_eq!(plan.private_disk_bytes, 5 * GIB);
        assert_eq!(plan.max_flattened_bytes, 93 * GIB);
        let vm = plan.vm_resources();
        assert_eq!(
            (vm.cpus, vm.memory_mib, vm.storage_gib, vm.overlay_gib),
            (4, 4096, Some(1), Some(1))
        );
        assert!(!vm.network && !vm.gpu && !vm.cuda && !vm.nested_virt && !vm.rosetta);
        assert!(vm.disks.is_empty() && vm.allowed_cidrs.is_none() && vm.network_backend.is_none());
        assert_eq!(
            plan.private_disk_bytes + plan.max_flattened_bytes + plan.max_artifact_bytes,
            plan.max_staging_bytes
        );
        let mut small = grant();
        small.memory_mb = 1152;
        assert_eq!(small.plan(GIB, GIB, 128 * GIB).unwrap().memory_mib, 1024);
        assert_ne!(
            plan.approval_sha256,
            small
                .plan(GIB, 30 * GIB, 128 * GIB)
                .unwrap()
                .approval_sha256
        );
        small.disk_gb = 64;
        let minimum = small.plan(GIB, GIB, 64 * GIB).unwrap();
        assert_eq!(minimum.max_flattened_bytes, 58 * GIB);
        assert_eq!(
            grant().plan(32 * GIB, GIB, 256 * GIB).unwrap_err().code,
            ErrorCode::Admission
        );
        let mut larger = grant();
        larger.disk_gb = 256;
        assert_eq!(
            larger.plan(32 * GIB, GIB, 256 * GIB).unwrap().storage_gib,
            1
        );
    }
    #[test]
    fn invalid_underfunded_and_overflowing_conversion_never_produce_a_plan() {
        for (source, artifact, staging) in [
            (0, GIB, 128 * GIB),
            (1, GIB, 128 * GIB),
            (GIB, 0, 128 * GIB),
            (GIB, 123 * GIB, 128 * GIB),
            (GIB, GIB, 129 * GIB),
            (u64::MAX, GIB, u64::MAX),
        ] {
            assert!(grant().plan(source, artifact, staging).is_err());
        }
        for (slots, cpus, memory_mb, disk_gb) in [
            (0, 4, 4608, 128),
            (1, 3, 4608, 128),
            (1, 4, 1151, 128),
            (1, 4, 4608, 63),
            (1, 4, u64::MAX, 128),
        ] {
            assert!(ExportConversionResources {
                slots,
                cpus,
                memory_mb,
                disk_gb
            }
            .validate()
            .is_err());
        }
        let mut unknown = serde_json::to_value(grant()).unwrap();
        unknown["network"] = serde_json::json!(true);
        assert!(serde_json::from_value::<ExportConversionResources>(unknown).is_err());
    }
}
