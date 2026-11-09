//! Operator-selected idle checkpoint approval. Header validation is not ownership
//! or an attestation of captured processes; SDK CPU compatibility stays separate.
use crate::{Error, ErrorCode, Resources, Result};
use smolvm_pack::format::{CheckpointLayout, PackManifest, PackMode, PortableCheckpointManifest};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;

/// Checkpoint artifact allowance is separate from the ordinary pack input cap.
/// Match the public checkpoint publication policy's 64-GiB upper bound.
pub const CHECKPOINT_ARTIFACT_BYTES: u64 = 64 * 1024 * 1024 * 1024;
pub const CHECKPOINT_DISK_FILES: usize = 64;
pub(crate) const HISTORY_ENTRIES: usize = 32_768;
pub(crate) const HISTORY_INDEX_BYTES: u64 = 8 * 1024 * 1024;
pub(crate) const HISTORY_INDEX_TOTAL_BYTES: u64 = 16 * 1024 * 1024;
pub(crate) const HISTORY_OBJECT_BYTES: u64 = 1024 * 1024;
pub(crate) const HISTORY_OBJECT_PACKED_BYTES: u64 = HISTORY_OBJECT_BYTES + 128 * 1024;
pub(crate) const HISTORY_STAGING_BYTES: u64 =
    HISTORY_ENTRIES as u64 * HISTORY_OBJECT_PACKED_BYTES + HISTORY_INDEX_TOTAL_BYTES;

#[derive(Clone)]
pub struct ApprovedCheckpointArtifact {
    pub path: std::path::PathBuf,
    pub sha256: String,
    pub max_bytes: u64,
    pub guest_platform: String,
}

/// Approval asserts idle captured RAM and no credentials/external dependencies.
/// It grants neither existing-machine authority nor permission to replay restore.
#[derive(Clone)]
pub struct ApprovedCheckpoint {
    pub artifact: ApprovedCheckpointArtifact,
    pub sdk_version: String,
    pub host_platform: String,
    pub resources: Resources,
}
impl std::fmt::Debug for ApprovedCheckpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApprovedCheckpoint")
            .field("sdk_version", &self.sdk_version)
            .field("host_platform", &self.host_platform)
            .finish_non_exhaustive()
    }
}
impl ApprovedCheckpoint {
    pub fn validate(&self) -> Result<()> {
        if !self.artifact.path.is_absolute()
            || !crate::domain::valid_hex(&self.artifact.sha256, 64)
            || self.artifact.max_bytes == 0
            || self.artifact.max_bytes > CHECKPOINT_ARTIFACT_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.resources.validate()?;
        if self.sdk_version != smolvm::VERSION
            || !matches!(self.host_platform.as_str(), "linux/amd64" | "darwin/arm64")
            || self.host_platform != smolvm::platform::Platform::current().host_oci_platform()
            || self.artifact.guest_platform != crate::oci::native_oci_platform()
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        Ok(())
    }

    /// Validate managed restore eligibility without opening or changing SDK state.
    /// The bounded artifact reader and public SDK compatibility validator must
    /// still verify bytes, CPU contract and layout before materialization.
    pub fn validate_manifest<'a>(
        &self,
        manifest: &'a PackManifest,
    ) -> Result<&'a PortableCheckpointManifest> {
        self.validate()?;
        let checkpoint = manifest
            .checkpoint
            .as_ref()
            .ok_or(Error::before(ErrorCode::Validation))?;
        let version = match checkpoint.payload {
            CheckpointLayout::Assets => smolvm::portable_checkpoint::FORMAT_VERSION,
            CheckpointLayout::Chunked => smolvm::portable_checkpoint::HISTORY_FORMAT_VERSION,
        };
        let network_ok = checkpoint.network.as_ref().is_some_and(|network| {
            !network.enabled
                && network.ports.is_empty()
                && network.udp_ports.is_empty()
                && network.backend.is_none()
                && network.dns.is_none()
                && network.dns_options.is_empty()
                && network.network_name.is_none()
                && network.guest_subnet.is_none()
                && network.allowed_cidrs.as_ref().is_none_or(Vec::is_empty)
                && network.dns_filter_hosts.as_ref().is_none_or(Vec::is_empty)
                && network.egress_rules.is_empty()
                && !network.mediated_egress_required
                && network.block_private.is_none()
                && network.credential_policy.is_none()
                && network.credential_placeholders.is_empty()
        });
        if manifest.mode != PackMode::Vm
            || manifest.platform != self.artifact.guest_platform
            || manifest.host_platform != self.host_platform
            || manifest.smolvm_version != self.sdk_version
            || manifest.cpus != self.resources.cpus
            || manifest.mem != self.resources.memory_mib
            || manifest.network
            || manifest.gpu
            || manifest.cuda
            || !manifest.secret_refs.is_empty()
            || !manifest.assets.layers.is_empty()
            || manifest.assets.workspace_seed.is_some()
            || checkpoint.version != version
            || checkpoint.runtime_abi != smolvm::portable_checkpoint::RUNTIME_ABI
            || checkpoint.host_platform != self.host_platform
            || checkpoint.device_profile != smolvm::portable_checkpoint::DEVICE_PROFILE
            || checkpoint.cpus != self.resources.cpus
            || checkpoint.memory_mib != self.resources.memory_mib
            || checkpoint.storage_gib != Some(self.resources.storage_gib)
            || checkpoint.overlay_gib != Some(self.resources.overlay_gib)
            || checkpoint.workload.is_some()
            || !checkpoint.host_mounts.is_empty()
            || checkpoint.packed_layers.is_some()
            || checkpoint.host_image.is_some()
            || checkpoint.credential_ca.is_some()
            || checkpoint.base.is_some()
            || checkpoint.cache_disk.is_some()
            || checkpoint.nested_virt
            || !checkpoint.settings.is_empty()
            || !matches!(checkpoint.disk_durability.as_deref(), None | Some("full"))
            || !network_ok
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        Ok(checkpoint)
    }

    /// Leave CPU migration/hypervisor compatibility to the verified SDK. This
    /// checks eligibility first and does not restore, reserve or mint a receipt.
    pub fn validate_compatibility(&self, manifest: &PackManifest) -> Result<()> {
        let checkpoint = self.validate_manifest(manifest)?;
        smolvm::portable_checkpoint::validate_compatibility(checkpoint)
            .map_err(|_| Error::before(ErrorCode::Unsupported))
    }

    /// Validate the compressed assets without extraction or existing-machine
    /// authority. History envelopes are bounded here; their index/reference
    /// semantics must additionally pass public SDK store validation on restore.
    pub fn validate_payload(
        &self,
        manifest: &PackManifest,
        input: impl Read,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.validate_manifest(manifest)?;
        crate::archive::validate_checkpoint_assets(input, manifest, self.resources, budget)
    }
}

impl crate::Engine {
    /// Read-only, bounded operator-artifact inspection. Its result grants no
    /// creation/restore authority, owns no cache and cannot enable a capability.
    /// Collection retains native admission if an SDK checksum read outlives the
    /// caller; it does not start a VM or touch SDK records.
    pub fn inspect_checkpoint_artifact(
        &self,
        approval: ApprovedCheckpoint,
        budget: crate::ReadBudget,
    ) -> Result<PackManifest> {
        approval.validate()?;
        budget.check()?;
        let permit = self
            .jobs
            .acquire(crate::jobs::Demand::checkpoint_inspection())?;
        self.domain.verify()?;
        let domain = self.domain.clone();
        crate::oci_start::observe_readonly(
            self.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _permit = permit;
                domain.verify()?;
                let manifest = inspect_artifact(&approval, &budget)?;
                domain.verify()?;
                budget.check()?;
                Ok(manifest)
            },
        )
    }
}

pub(crate) fn inspect_artifact(
    approval: &ApprovedCheckpoint,
    budget: &crate::ReadBudget,
) -> Result<PackManifest> {
    approval.validate()?;
    budget.check()?;
    let mut file = crate::artifact::open_regular(&approval.artifact.path)?;
    let original = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    let length = original.len();
    if length == 0 || length > approval.artifact.max_bytes {
        return Err(Error::before(ErrorCode::Validation));
    }
    let digest = crate::artifact::copy_hash(
        &mut Budgeted {
            input: &mut file,
            budget,
        },
        &mut std::io::sink(),
        approval.artifact.max_bytes,
    );
    budget.check()?;
    if digest? != approval.artifact.sha256 {
        return Err(Error::before(ErrorCode::Validation));
    }
    verify_input(&file, &approval.artifact.path, &original)?;
    let footer = smolvm_pack::packer::read_footer_from_file(&mut file)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    let manifest = crate::artifact::read_manifest(&mut file, &footer)?;
    approval.validate_compatibility(&manifest)?;
    budget.check()?;
    // The descriptor-based public API cannot reopen a substituted operator path.
    // Footer ranges have already been bounded against this descriptor's length.
    let checksum_ok = smolvm_pack::packer::verify_sidecar_checksum_file(&mut file, &footer)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    budget.check()?;
    verify_input(&file, &approval.artifact.path, &original)?;
    if !checksum_ok {
        return Err(Error::before(ErrorCode::Validation));
    }
    file.seek(SeekFrom::Start(footer.assets_offset))
        .map_err(|_| Error::before(ErrorCode::Io))?;
    approval.validate_payload(&manifest, (&mut file).take(footer.assets_size), budget)?;
    budget.check()?;
    verify_input(&file, &approval.artifact.path, &original)?;
    Ok(manifest)
}

pub(crate) fn verify_input(
    file: &std::fs::File,
    path: &std::path::Path,
    original: &std::fs::Metadata,
) -> Result<()> {
    let current = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    let named = std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Io))?;
    let version = |metadata: &std::fs::Metadata| {
        (
            metadata.dev(),
            metadata.ino(),
            metadata.len(),
            metadata.mode(),
            metadata.uid(),
            metadata.gid(),
            metadata.mtime(),
            metadata.mtime_nsec(),
            metadata.ctime(),
            metadata.ctime_nsec(),
        )
    };
    if !named.is_file()
        || version(&current) != version(original)
        || version(&named) != version(original)
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(())
}

pub(crate) struct Budgeted<'a, R> {
    pub(crate) input: R,
    pub(crate) budget: &'a crate::ReadBudget,
}
impl<R: Read> Read for Budgeted<'_, R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.budget
            .check()
            .map_err(|_| std::io::Error::other("checkpoint read budget"))?;
        self.input.read(buffer)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;
    use sha2::{Digest, Sha256};

    /// Pure artifact inspection: never opens an SDK database, domain or VM.
    #[test]
    #[ignore = "requires an explicitly supplied ordinary SDK checkpoint fixture"]
    fn inspect_operator_checkpoint_fixture_without_native_state() {
        let path = std::path::PathBuf::from(
            std::env::var_os("SMOLBOX_CHECKPOINT_FIXTURE").expect("explicit checkpoint fixture"),
        );
        let expected =
            std::env::var("SMOLBOX_CHECKPOINT_FIXTURE_SHA256").expect("explicit checkpoint digest");
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(hex::encode(Sha256::digest(&bytes)), expected);
        let manifest = smolvm_pack::packer::read_manifest_from_sidecar(&path).unwrap();
        let header = manifest.checkpoint.as_ref().unwrap();
        let approval = ApprovedCheckpoint {
            artifact: ApprovedCheckpointArtifact {
                path: path.clone(),
                sha256: expected,
                max_bytes: bytes.len() as u64,
                guest_platform: manifest.platform.clone(),
            },
            sdk_version: smolvm::VERSION.into(),
            host_platform: manifest.host_platform.clone(),
            resources: Resources {
                cpus: header.cpus,
                memory_mib: header.memory_mib,
                storage_gib: header.storage_gib.unwrap(),
                overlay_gib: header.overlay_gib.unwrap(),
            },
        };
        approval
            .validate_compatibility(&manifest)
            .expect("compatible header");
        eprintln!("header compatibility passed");
        let budget = crate::ReadBudget::for_checkpoint_work(
            std::time::Duration::from_secs(120),
            crate::Cancellation::default(),
        )
        .unwrap();
        super::inspect_artifact(&approval, &budget).expect("bounded complete checkpoint input");
        eprintln!("bounded complete checkpoint input passed; native state unopened");
    }

    fn archive(files: &[(String, Vec<u8>)]) -> Vec<u8> {
        let mut builder = tar::Builder::new(Vec::new());
        for (path, bytes) in files {
            let mut header = tar::Header::new_gnu();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o600);
            header.set_cksum();
            builder
                .append_data(&mut header, path, bytes.as_slice())
                .unwrap();
        }
        builder.into_inner().unwrap()
    }

    pub(crate) fn payload_fixture() -> (ApprovedCheckpoint, PackManifest, Vec<(String, Vec<u8>)>) {
        let (approval, mut manifest) = fixture();
        // The SDK recognizes a cached agent rootfs by its sbin/init entry.
        let rootfs = archive(&[("sbin/init".into(), b"fixture".to_vec())]);
        manifest.assets.agent_rootfs = smolvm_pack::format::AssetEntry {
            path: "agent-rootfs.tar".into(),
            size: rootfs.len() as u64,
        };
        let mut files = vec![("agent-rootfs.tar".into(), rootfs)];
        let checkpoint = manifest.checkpoint.as_mut().unwrap();
        for (asset, path, bytes) in [
            (
                &mut checkpoint.state,
                "checkpoint/checkpoint.bin",
                b"state".as_slice(),
            ),
            (
                &mut checkpoint.memory,
                "checkpoint/memory.bin",
                b"memory".as_slice(),
            ),
            (
                &mut checkpoint.layout,
                "checkpoint/manifest.bin",
                b"layout".as_slice(),
            ),
        ] {
            asset.path = path.into();
            asset.size = bytes.len() as u64;
            asset.sha256 = hex::encode(Sha256::digest(bytes));
            files.push((path.into(), bytes.to_vec()));
        }
        checkpoint.disks = ["storage", "overlay"]
            .into_iter()
            .map(|role| {
                let path = format!("checkpoint/disks/{role}/0");
                let bytes = vec![0; 2048];
                let digest = hex::encode(Sha256::digest(&bytes));
                files.push((path.clone(), bytes));
                smolvm_pack::format::CheckpointDisk {
                    role: role.into(),
                    files: vec![smolvm_pack::format::CheckpointDiskFile {
                        asset: smolvm_pack::format::CheckpointAsset {
                            path,
                            size: 2048,
                            sha256: digest,
                        },
                        target: format!("{role}.raw"),
                        format: "raw".into(),
                    }],
                }
            })
            .collect();
        (approval, manifest, files)
    }

    fn validate_files(
        approval: &ApprovedCheckpoint,
        manifest: &PackManifest,
        files: &[(String, Vec<u8>)],
    ) -> Result<()> {
        let payload = zstd::encode_all(archive(files).as_slice(), 1).unwrap();
        approval.validate_payload(
            manifest,
            payload.as_slice(),
            &crate::ReadBudget::for_checkpoint_work(
                std::time::Duration::from_secs(30),
                crate::Cancellation::default(),
            )
            .unwrap(),
        )
    }

    #[test]
    fn documented_disk_chain_depth_and_top_level_targets_match_current_sdk_contract() {
        let (approval, mut manifest, _) = payload_fixture();
        let checkpoint = manifest.checkpoint.as_mut().unwrap();
        let original = checkpoint.disks[0].files[0].clone();
        checkpoint.disks[0].files = (0..CHECKPOINT_DISK_FILES)
            .map(|index| {
                let format = if index + 1 == CHECKPOINT_DISK_FILES {
                    "raw"
                } else {
                    "qcow2"
                };
                let mut file = original.clone();
                file.asset.path = format!("checkpoint/disks/storage/{index}");
                file.format = format.into();
                file.target = if index == 0 {
                    format!("storage.{format}")
                } else {
                    format!(".smolcheckpoint-storage-{index}.{format}")
                };
                file
            })
            .collect();
        assert!(crate::archive::checkpoint_expected_files(&manifest, approval.resources).is_ok());
        let mut extra = original;
        extra.asset.path = format!("checkpoint/disks/storage/{CHECKPOINT_DISK_FILES}");
        extra.target = format!(".smolcheckpoint-storage-{CHECKPOINT_DISK_FILES}.raw");
        manifest.checkpoint.as_mut().unwrap().disks[0]
            .files
            .push(extra);
        assert!(crate::archive::checkpoint_expected_files(&manifest, approval.resources).is_err());
    }

    #[test]
    fn classic_payload_requires_exact_inventory_hashes_and_bounded_disk_topology() {
        let (approval, mut manifest, files) = payload_fixture();
        validate_files(&approval, &manifest, &files).unwrap();
        assert!(validate_files(&approval, &manifest, &files[..files.len() - 1]).is_err());
        let mut duplicate = files.clone();
        duplicate.push(files[1].clone());
        assert!(validate_files(&approval, &manifest, &duplicate).is_err());
        let mut hidden = files.clone();
        hidden.push(("checkpoint/hidden".into(), b"hidden".to_vec()));
        assert!(validate_files(&approval, &manifest, &hidden).is_err());
        let mut changed = files.clone();
        changed[1].1[0] ^= 1;
        assert!(validate_files(&approval, &manifest, &changed).is_err());
        let checkpoint = manifest.checkpoint.as_mut().unwrap();
        checkpoint.state.size = 64 * 1024 * 1024 + 1;
        assert!(validate_files(&approval, &manifest, &files).is_err());
        manifest.checkpoint.as_mut().unwrap().state.size = files[1].1.len() as u64;
        manifest.checkpoint.as_mut().unwrap().disks[0].files[0].target = "storage.ext4".into();
        assert!(validate_files(&approval, &manifest, &files).is_err());
        manifest.checkpoint.as_mut().unwrap().disks[0].files[0].target = "storage.raw".into();
        manifest.checkpoint.as_mut().unwrap().memory.sha256.clear();
        manifest.checkpoint.as_mut().unwrap().disks[0].files[0]
            .asset
            .sha256
            .clear();
        validate_files(&approval, &manifest, &files).unwrap(); // SDK sparse payloads use container integrity.
        manifest.checkpoint.as_mut().unwrap().state.sha256.clear();
        assert!(validate_files(&approval, &manifest, &files).is_err());
    }

    #[test]
    fn history_envelope_requires_indexes_unique_content_hashes_and_bounded_objects() {
        let (approval, mut manifest) = fixture();
        let checkpoint = manifest.checkpoint.as_mut().unwrap();
        checkpoint.payload = CheckpointLayout::Chunked;
        checkpoint.version = smolvm::portable_checkpoint::HISTORY_FORMAT_VERSION;
        let head = smolvm_pack::format::CheckpointLineage {
            id: "1".repeat(32),
            parent: Some("2".repeat(32)),
            machine: "idle".into(),
            created_at: "2026-10-14T00:00:00Z".into(),
        };
        let ancestor = smolvm_pack::format::CheckpointLineage {
            id: "2".repeat(32),
            parent: None,
            ..head.clone()
        };
        checkpoint.lineage = Some(head.clone());
        checkpoint.history = vec![
            smolvm_pack::format::CheckpointGeneration {
                lineage: head,
                data_bytes: 1024,
            },
            smolvm_pack::format::CheckpointGeneration {
                lineage: ancestor,
                data_bytes: 1024,
            },
        ];
        let bytes = b"object payload";
        let path = format!("objects/{}", hex::encode(Sha256::digest(bytes)));
        // Index semantics are intentionally not attested by envelope validation.
        let files = vec![
            ("checkpoint.json".into(), b"{}".to_vec()),
            (
                format!("generations/{}/checkpoint.json", "2".repeat(32)),
                b"{}".to_vec(),
            ),
            (path, zstd::encode_all(bytes.as_slice(), 1).unwrap()),
        ];
        validate_files(&approval, &manifest, &files).unwrap();
        assert!(validate_files(&approval, &manifest, &files[1..]).is_err());
        let mut duplicate = files.clone();
        duplicate.push(files[2].clone());
        assert!(validate_files(&approval, &manifest, &duplicate).is_err());
        let mut changed = files.clone();
        changed[2].1 = zstd::encode_all(b"other".as_slice(), 1).unwrap();
        assert!(validate_files(&approval, &manifest, &changed).is_err());
        let mut bomb = files.clone();
        bomb[2].1 = zstd::encode_all(vec![0; 1024 * 1024 + 1].as_slice(), 1).unwrap();
        assert!(validate_files(&approval, &manifest, &bomb).is_err());
        let mut oversized = files.clone();
        oversized[0].1 = vec![0; 8 * 1024 * 1024 + 1];
        assert!(validate_files(&approval, &manifest, &oversized).is_err());
        manifest.checkpoint.as_mut().unwrap().history[1].lineage.id = "1".repeat(32);
        assert!(validate_files(&approval, &manifest, &files).is_err());
    }

    #[test]
    fn cancelled_checkpoint_reads_reject_before_consuming_artifact_or_payload() {
        struct Unread;
        impl Read for Unread {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                panic!("cancelled request consumed bytes")
            }
        }
        let (approval, manifest, _) = payload_fixture();
        let cancel = crate::Cancellation::default();
        let budget = crate::ReadBudget::for_checkpoint_work(
            std::time::Duration::from_secs(3600),
            cancel.clone(),
        )
        .unwrap();
        cancel.cancel();
        assert_eq!(
            approval
                .validate_payload(&manifest, Unread, &budget)
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        assert_eq!(
            inspect_artifact(&approval, &budget).unwrap_err().code,
            ErrorCode::State
        );
        assert!(crate::ReadBudget::new(
            std::time::Duration::from_secs(3600),
            crate::Cancellation::default()
        )
        .is_err());
        assert!(crate::ReadBudget::for_checkpoint_work(
            std::time::Duration::from_secs(86_401),
            crate::Cancellation::default()
        )
        .is_err());
    }

    #[test]
    fn ordinary_sidecar_inspection_checks_whole_file_identity_without_extracting_or_restoring() {
        let temp = tempfile::tempdir().unwrap();
        let staging = temp.path().join("assets");
        std::fs::create_dir(&staging).unwrap();
        let (mut approval, mut manifest, files) = payload_fixture();
        manifest.checkpoint.as_mut().unwrap().cpu_contract =
            smolvm_pack::format::CheckpointCpuContract::ExactV1 {
                fingerprint: smolvm::portable_checkpoint::cpu_fingerprint().unwrap(),
            };
        for (path, bytes) in files {
            let path = staging.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, bytes).unwrap();
        }
        let path = temp.path().join("idle.smolcheckpoint");
        smolvm_pack::packer::Packer::new(manifest.clone())
            .with_asset_collector(smolvm_pack::assets::AssetCollector::new(staging).unwrap())
            .pack_artifact(&path)
            .unwrap();
        let bytes = std::fs::read(&path).unwrap();
        approval.artifact.path = path.clone();
        approval.artifact.sha256 = hex::encode(Sha256::digest(&bytes));
        approval.artifact.max_bytes = bytes.len() as u64;
        let budget = crate::ReadBudget::for_checkpoint_work(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        let inspected = inspect_artifact(&approval, &budget).unwrap();
        assert_eq!(inspected.checkpoint, manifest.checkpoint);
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        // Only operator fixture inputs exist: no materialization or machine row.
        assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 2);
        approval.artifact.sha256 = "0".repeat(64);
        assert_eq!(
            inspect_artifact(&approval, &budget).unwrap_err().dispatch,
            crate::Dispatch::NotDispatched
        );
        approval.artifact.sha256 = hex::encode(Sha256::digest(&bytes));
        approval.artifact.max_bytes -= 1;
        assert!(inspect_artifact(&approval, &budget).is_err());
        approval.artifact.max_bytes += 1;
        let mut footer_input = crate::artifact::open_regular(&path).unwrap();
        let mut bad_footer = smolvm_pack::packer::read_footer_from_file(&mut footer_input).unwrap();
        bad_footer.checksum ^= 1;
        let mut corrupt = bytes.clone();
        let footer_offset = corrupt.len() - smolvm_pack::format::FOOTER_SIZE;
        corrupt[footer_offset..].copy_from_slice(&bad_footer.to_bytes());
        std::fs::write(&path, &corrupt).unwrap();
        approval.artifact.sha256 = hex::encode(Sha256::digest(&corrupt));
        assert!(inspect_artifact(&approval, &budget).is_err()); // SHA approval alone cannot bypass SDK checksum.
        std::fs::write(&path, &bytes).unwrap();
        approval.artifact.sha256 = hex::encode(Sha256::digest(&bytes));
        let link = temp.path().join("alias.smolcheckpoint");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        approval.artifact.path = link;
        assert!(inspect_artifact(&approval, &budget).is_err());
    }

    #[test]
    fn descriptor_and_named_path_versions_must_both_match_original_input() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("input");
        std::fs::write(&path, b"original").unwrap();
        let file = crate::artifact::open_regular(&path).unwrap();
        let original = file.metadata().unwrap();
        verify_input(&file, &path, &original).unwrap();
        let replacement = temp.path().join("replacement");
        std::fs::write(&replacement, b"original").unwrap();
        std::fs::rename(&replacement, &path).unwrap();
        assert!(verify_input(&file, &path, &original).is_err());
        let replacement_file = crate::artifact::open_regular(&path).unwrap();
        let replacement_version = replacement_file.metadata().unwrap();
        std::fs::write(&path, b"changed length").unwrap();
        assert!(verify_input(&replacement_file, &path, &replacement_version).is_err());
    }

    fn fixture() -> (ApprovedCheckpoint, PackManifest) {
        let host = smolvm::platform::Platform::current()
            .host_oci_platform()
            .to_string();
        let guest = crate::oci::native_oci_platform();
        let approval = ApprovedCheckpoint {
            artifact: ApprovedCheckpointArtifact {
                path: "/operator/idle.checkpoint".into(),
                sha256: "a".repeat(64),
                max_bytes: 1024,
                guest_platform: guest.into(),
            },
            sdk_version: smolvm::VERSION.into(),
            host_platform: host.clone(),
            resources: Resources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: 1,
                overlay_gib: 1,
            },
        };
        let mut manifest = PackManifest::new(
            "vm://idle".into(),
            "sha256:idle".into(),
            guest.into(),
            "idle".into(),
        );
        manifest.mode = PackMode::Vm;
        manifest.host_platform = host.clone();
        manifest.smolvm_version = smolvm::VERSION.into();
        manifest.cpus = 1;
        manifest.mem = 512;
        let asset = |path: &str| json!({"path":path,"size":1024,"sha256":"b".repeat(64)});
        manifest.checkpoint = Some(serde_json::from_value(json!({
            "version":smolvm::portable_checkpoint::FORMAT_VERSION,
            "runtime_abi":smolvm::portable_checkpoint::RUNTIME_ABI,
            "host_platform":host,"cpu_contract":{"kind":"exact-v1","fingerprint":"c".repeat(64)},
            "cpus":1,"memory_mib":512,"storage_gib":1,"overlay_gib":1,
            "device_profile":smolvm::portable_checkpoint::DEVICE_PROFILE,
            "state":asset("checkpoint/state.bin"),"memory":asset("checkpoint/memory.bin"),
            "layout":asset("checkpoint/layout.json"),"disks":[],"network":{"enabled":false}
        })).unwrap());
        (approval, manifest)
    }

    #[test]
    fn idle_approval_preserves_exact_profile_and_both_sdk_checkpoint_layout_versions() {
        let (mut approval, mut manifest) = fixture();
        approval.artifact.max_bytes = CHECKPOINT_ARTIFACT_BYTES;
        approval.validate().unwrap();
        approval.artifact.max_bytes += 1;
        assert!(approval.validate().is_err());
        approval.artifact.max_bytes = CHECKPOINT_ARTIFACT_BYTES;
        let expected = manifest.checkpoint.as_ref().unwrap().cpu_contract.clone();
        let accepted = approval.validate_manifest(&manifest).unwrap();
        assert_eq!(accepted.cpu_contract, expected); // No invented CPU compatibility.
        let checkpoint = manifest.checkpoint.as_mut().unwrap();
        checkpoint.payload = CheckpointLayout::Chunked;
        checkpoint.version = smolvm::portable_checkpoint::HISTORY_FORMAT_VERSION;
        assert!(approval.validate_manifest(&manifest).is_ok());
        manifest.checkpoint.as_mut().unwrap().version -= 1;
        assert_eq!(
            approval
                .validate_manifest(&manifest)
                .err()
                .unwrap()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        assert!(!format!("{approval:?}").contains("/operator"));
    }

    #[test]
    fn crossed_platform_sdk_allocations_and_device_dependencies_reject_without_file_access() {
        let (approval, manifest) = fixture();
        let original = serde_json::to_value(&manifest).unwrap();
        for (field, value) in [
            ("cpus", json!(2)),
            ("memory_mib", json!(1024)),
            ("storage_gib", json!(2)),
            ("overlay_gib", json!(2)),
            ("host_platform", json!("other")),
            ("runtime_abi", json!("other")),
            ("device_profile", json!("smolvm-packed-layers-v1")),
            (
                "credential_ca",
                json!({"path":"ca","size":1,"sha256":"d".repeat(64)}),
            ),
            (
                "packed_layers",
                json!({"artifact_sha256":"e".repeat(64),"footer_checksum":1}),
            ),
            (
                "workload",
                json!({"image":"registry.example/app", "overlay_owner":"foreign", "restart_policy":"never"}),
            ),
            ("network", serde_json::Value::Null),
            ("network", json!({"enabled":true})),
            ("network", json!({"ports":[{"host":8080,"guest":80}]})),
        ] {
            let mut value_manifest = original.clone();
            value_manifest["checkpoint"][field] = value;
            let changed: PackManifest = serde_json::from_value(value_manifest).unwrap();
            assert!(approval.validate_manifest(&changed).is_err(), "{field}");
        }
        for (field, value) in [
            ("mode", json!("container")),
            ("gpu", json!(true)),
            ("cuda", json!(true)),
            ("network", json!(true)),
            ("smolvm_version", json!("1.16.1")),
            ("mem", json!(256)),
        ] {
            let mut changed = original.clone();
            changed[field] = value;
            assert!(
                approval
                    .validate_manifest(&serde_json::from_value(changed).unwrap())
                    .is_err(),
                "{field}"
            );
        }
        let mut old = approval.clone();
        old.sdk_version = "1.16.1".into();
        assert!(old.validate_manifest(&manifest).is_err());
    }
}
