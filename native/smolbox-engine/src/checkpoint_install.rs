//! Install only into a fresh ticketed SmolBox directory. No SDK record creation.
use crate::checkpoint_materialize::{FileVersion, Proof as MaterialProof};
use crate::transfer_worker::{Blob, Request};
use crate::{Error, ErrorCode, ReadBudget, Resources, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolvm_pack::format::PackManifest;
use std::collections::BTreeMap;
use std::fs::{File, Metadata as FsMetadata};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub(crate) const METADATA_BYTES: u64 = 2 * 1024 * 1024;
pub(crate) const TICKET: &str = "smolbox.checkpoint-create-v1.json";

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Ticket {
    pub schema: u8,
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub source_sha256: String,
    pub material_sha256: String,
}
impl Ticket {
    pub(crate) fn validate(&self) -> Result<()> {
        if self.schema != 1
            || !crate::domain::valid_id(&self.name)
            || !crate::domain::valid_hex(&self.owner_token, 64)
            || !crate::domain::valid_hex(&self.incarnation, 32)
            || !crate::domain::valid_hex(&self.source_sha256, 64)
            || !crate::domain::valid_hex(&self.material_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn publish(&self, directory: &Path) -> Result<String> {
        self.validate()?;
        crate::host::private_directory(directory)?;
        let bytes = serde_json::to_vec(self).map_err(|_| Error::before(ErrorCode::Validation))?;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o400)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(directory.join(TICKET))
            .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
        std::io::Write::write_all(&mut file, &bytes)
            .and_then(|()| file.sync_all())
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        File::open(directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        Ok(hex::encode(Sha256::digest(bytes)))
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Expected {
    pub metadata_sha256: String,
    pub ticket_sha256: String,
}
impl Expected {
    pub(crate) fn validate(&self) -> Result<()> {
        if !crate::domain::valid_hex(&self.metadata_sha256, 64)
            || !crate::domain::valid_hex(&self.ticket_sha256, 64)
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
    pub inventory_sha256: String,
    pub storage_gib: u64,
    pub overlay_gib: u64,
}
impl Proof {
    pub(crate) fn matches(&self, expected: &Expected) -> bool {
        &self.expected == expected
            && crate::domain::valid_hex(&self.inventory_sha256, 64)
            && (1..=1024).contains(&self.storage_gib)
            && (1..=1024).contains(&self.overlay_gib)
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Metadata {
    schema: u8,
    root: PathBuf,
    root_device: u64,
    root_inode: u64,
    target: PathBuf,
    target_device: u64,
    target_inode: u64,
    material: MaterialProof,
    ticket_sha256: String,
    manifest: PackManifest,
    deadline_ns: u64,
}
impl Metadata {
    pub(crate) fn new(
        root: &Path,
        target: &Path,
        material: &MaterialProof,
        manifest: &PackManifest,
        ticket_sha256: String,
        deadline: Instant,
    ) -> Result<(Self, Expected)> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() || remaining > Duration::from_secs(86_400) {
            return Err(Error::before(ErrorCode::State));
        }
        let root_metadata =
            std::fs::symlink_metadata(root).map_err(|_| Error::before(ErrorCode::Ownership))?;
        let target_metadata =
            std::fs::symlink_metadata(target).map_err(|_| Error::before(ErrorCode::Ownership))?;
        let metadata = Self {
            schema: 1,
            root: root.into(),
            root_device: root_metadata.dev(),
            root_inode: root_metadata.ino(),
            target: target.into(),
            target_device: target_metadata.dev(),
            target_inode: target_metadata.ino(),
            material: material.clone(),
            ticket_sha256: ticket_sha256.clone(),
            manifest: manifest.clone(),
            deadline_ns: crate::buffered::monotonic_ns()?
                .checked_add(remaining.as_nanos() as u64)
                .ok_or(Error::before(ErrorCode::Validation))?,
        };
        let expected = Expected {
            metadata_sha256: hex::encode(Sha256::digest(metadata.encode()?)),
            ticket_sha256,
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
    fn resources(&self) -> Result<Resources> {
        let checkpoint = self
            .manifest
            .checkpoint
            .as_ref()
            .ok_or(Error::before(ErrorCode::Validation))?;
        let resources = Resources {
            cpus: checkpoint.cpus,
            memory_mib: checkpoint.memory_mib,
            storage_gib: checkpoint
                .storage_gib
                .ok_or(Error::before(ErrorCode::Validation))?,
            overlay_gib: checkpoint
                .overlay_gib
                .ok_or(Error::before(ErrorCode::Validation))?,
        };
        resources.validate()?;
        Ok(resources)
    }
    fn verify_target(&self, uid: u32) -> Result<()> {
        crate::host::private_directory(&self.root)?;
        crate::host::private_directory(&self.target)?;
        let root = std::fs::symlink_metadata(&self.root)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let target = std::fs::symlink_metadata(&self.target)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if self.schema != 1
            || root.uid() != uid
            || target.uid() != uid
            || (root.dev(), root.ino()) != (self.root_device, self.root_inode)
            || (target.dev(), target.ino()) != (self.target_device, self.target_inode)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut file = crate::artifact::open_regular(&self.target.join(TICKET))?;
        let metadata = file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if metadata.uid() != uid || metadata.mode() & 0o777 != 0o400 || metadata.len() > 4096 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(4097)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if hex::encode(Sha256::digest(&bytes)) != self.ticket_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let ticket: Ticket =
            serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
        ticket.validate()?;
        if ticket.source_sha256 != self.material.expected.source_sha256
            || ticket.material_sha256 != self.material.material_sha256
            || self.target.file_name().and_then(|name| name.to_str())
                != Some(smolvm::agent::vm_dir_hash(&ticket.name).as_str())
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
        || metadata.ticket_sha256 != expected.ticket_sha256
        || request.staging.parent() != Some(metadata.root.as_path())
        || request.socket.parent() != Some(metadata.target.as_path())
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let budget = ReadBudget::for_checkpoint_work(
        Duration::from_nanos(
            metadata
                .deadline_ns
                .saturating_sub(crate::buffered::monotonic_ns()?),
        ),
        crate::Cancellation::default(),
    )?;
    metadata.verify_target(request.owner.uid)?;
    budget.check()?;
    if std::fs::read_dir(&metadata.target)
        .map_err(|_| Error::before(ErrorCode::Ownership))?
        .any(|entry| entry.is_err() || entry.is_ok_and(|entry| entry.file_name() != TICKET))
    {
        return Err(Error::before(ErrorCode::Conflict));
    }
    let resources = metadata.resources()?;
    let material_root = metadata.root.join("materialized");
    let actual = crate::checkpoint_materialize::material_proof(
        &material_root,
        &metadata.manifest,
        resources,
        metadata.material.expected.clone(),
        &budget,
    )?;
    if actual != metadata.material {
        return Err(Error::before(ErrorCode::Ownership));
    }
    verify_input_capacities(&material_root, &metadata.manifest, resources)?;
    let checkpoint = metadata.manifest.checkpoint.as_ref().unwrap();
    smolvm::portable_checkpoint::install(&material_root, &metadata.target, checkpoint)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    smolvm::portable_checkpoint::discard_transport_pack(&metadata.target)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    budget
        .check()
        .map_err(|error| Error::uncertain(error.code))?;
    metadata
        .verify_target(request.owner.uid)
        .map_err(|error| Error::uncertain(error.code))?;
    installed_proof(&metadata.target, resources, expected.clone(), &budget)
}

fn virtual_bytes(path: &Path, format: &str) -> Result<u64> {
    let mut file = crate::artifact::open_regular(path)?;
    let metadata = file
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    match format {
        "raw" => Ok(metadata.len()),
        "qcow2" => {
            let mut bytes = [0; 32];
            file.read_exact(&mut bytes)
                .map_err(|_| Error::before(ErrorCode::Validation))?;
            if &bytes[..4] != b"QFI\xfb"
                || !matches!(u32::from_be_bytes(bytes[4..8].try_into().unwrap()), 2 | 3)
            {
                return Err(Error::before(ErrorCode::Validation));
            }
            Ok(u64::from_be_bytes(bytes[24..32].try_into().unwrap()))
        }
        _ => Err(Error::before(ErrorCode::Validation)),
    }
}
pub(crate) fn verify_input_capacities(
    root: &Path,
    manifest: &PackManifest,
    resources: Resources,
) -> Result<()> {
    let disks = &manifest
        .checkpoint
        .as_ref()
        .ok_or(Error::before(ErrorCode::Validation))?
        .disks;
    if disks.len() != 2 {
        return Err(Error::before(ErrorCode::Validation));
    }
    for (disk, role, gib) in [
        (&disks[0], "storage", resources.storage_gib),
        (&disks[1], "overlay", resources.overlay_gib),
    ] {
        let top = disk
            .files
            .first()
            .ok_or(Error::before(ErrorCode::Validation))?;
        if disk.role != role
            || virtual_bytes(&root.join(&top.asset.path), &top.format)? != gib << 30
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
    }
    Ok(())
}
pub(crate) fn installed_proof(
    root: &Path,
    resources: Resources,
    expected: Expected,
    budget: &ReadBudget,
) -> Result<Proof> {
    budget.check()?;
    crate::host::private_directory(root)?;
    if smolvm::portable_checkpoint::pending_dir(root).is_none() {
        return Err(Error::before(ErrorCode::Ownership));
    }
    for (role, raw_name, gib) in [
        (
            "storage",
            smolvm::storage::STORAGE_DISK_FILENAME,
            resources.storage_gib,
        ),
        (
            "overlay",
            smolvm::storage::OVERLAY_DISK_FILENAME,
            resources.overlay_gib,
        ),
    ] {
        let (path, format) = smolvm::agent::resolve_disk_image(root, raw_name);
        let format = match format {
            smolvm::storage::DiskFormat::Raw => "raw",
            smolvm::storage::DiskFormat::Qcow2 => "qcow2",
        };
        if virtual_bytes(&path, format)? != gib << 30
            || !root.join(format!("{role}.formatted")).is_file()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    let mut directories = vec![root.to_path_buf()];
    let mut files = BTreeMap::new();
    let mut count = 0;
    while let Some(directory) = directories.pop() {
        for entry in
            std::fs::read_dir(directory).map_err(|_| Error::before(ErrorCode::Ownership))?
        {
            budget.check()?;
            count += 1;
            if count > 512 {
                return Err(Error::before(ErrorCode::Validation));
            }
            let entry = entry.map_err(|_| Error::before(ErrorCode::Ownership))?;
            let metadata = std::fs::symlink_metadata(entry.path())
                .map_err(|_| Error::before(ErrorCode::Ownership))?;
            if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o022 != 0 {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if metadata.is_dir() {
                directories.push(entry.path());
            } else if metadata.is_file() {
                let path = entry
                    .path()
                    .strip_prefix(root)
                    .map_err(|_| Error::before(ErrorCode::Ownership))?
                    .to_path_buf();
                // These control files have independent receipt/hash validation;
                // they are added after SDK installation and are not restore bytes.
                if matches!(
                    path.to_str(),
                    Some(
                        "smolbox.incarnation"
                            | "smolbox.material-v2.json"
                            | "smolbox.checkpoint-start-v1.json"
                    )
                ) {
                    continue;
                }
                files.insert(path, FileVersion::of(&metadata));
            } else {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
    }
    let metadata: FsMetadata =
        std::fs::symlink_metadata(root).map_err(|_| Error::before(ErrorCode::Ownership))?;
    Ok(Proof {
        expected,
        device: metadata.dev(),
        inode: metadata.ino(),
        storage_gib: resources.storage_gib,
        overlay_gib: resources.overlay_gib,
        inventory_sha256: hex::encode(Sha256::digest(
            serde_json::to_vec(&files).map_err(|_| Error::before(ErrorCode::Validation))?,
        )),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn fresh_ticket_is_noclobber_and_binds_name_owner_source_and_original_directory() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let name = "checkpoint-model";
        let target = root.join(smolvm::agent::vm_dir_hash(name));
        std::fs::create_dir(&target).unwrap();
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o700)).unwrap();
        let ticket = Ticket {
            schema: 1,
            name: name.into(),
            owner_token: "a".repeat(64),
            incarnation: "b".repeat(32),
            source_sha256: "c".repeat(64),
            material_sha256: "d".repeat(64),
        };
        assert_eq!(ticket.publish(&target).unwrap().len(), 64);
        assert!(ticket.publish(&target).is_err());
        let before = std::fs::read(target.join(TICKET)).unwrap();
        let mut crossed = ticket;
        crossed.owner_token = "other".into();
        assert!(crossed.publish(&target).is_err());
        assert_eq!(std::fs::read(target.join(TICKET)).unwrap(), before);
    }
    #[test]
    fn captured_top_capacity_checks_are_readonly_and_reject_crossed_profiles_or_invalid_qcow() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let (approval, mut manifest, _) = crate::checkpoint::tests::payload_fixture();
        for disk in &manifest.checkpoint.as_ref().unwrap().disks {
            let path = root.join(&disk.files[0].asset.path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            File::create(path).unwrap().set_len(1 << 30).unwrap();
        }
        verify_input_capacities(&root, &manifest, approval.resources).unwrap();
        let mut crossed = approval.resources;
        crossed.storage_gib = 2;
        assert!(verify_input_capacities(&root, &manifest, crossed).is_err());
        manifest.checkpoint.as_mut().unwrap().disks[0].files[0].format = "qcow2".into();
        assert!(verify_input_capacities(&root, &manifest, approval.resources).is_err());
        assert_eq!(
            std::fs::metadata(root.join("checkpoint/disks/storage/0"))
                .unwrap()
                .len(),
            1 << 30
        );
    }
}
