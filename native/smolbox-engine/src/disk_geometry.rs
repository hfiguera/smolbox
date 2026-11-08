//! Descriptor-bound stopped-growth postconditions. SDK return is not geometry.
use crate::host::unredirected;
use crate::{Cancellation, Error, ErrorCode, ReadBudget, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolvm::storage::DiskFormat;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const GIB: u64 = 1 << 30;
const MAX_BYTES: u64 = 64 * GIB;
const MAX_BACKING_NAME: u64 = 1023;
const MAX_BACKINGS: usize = 8;

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stamp {
    device: u64,
    inode: u64,
    uid: u32,
    mode: u32,
    links: u64,
}
impl Stamp {
    fn of(file: &File) -> Result<Self> {
        let m = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        Self::metadata(&m)
    }

    fn metadata(m: &std::fs::Metadata) -> Result<Self> {
        if !m.is_file()
            || m.uid() != unsafe { libc::geteuid() }
            || m.nlink() != 1
            || m.mode() & 0o022 != 0
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(Self {
            device: m.dev(),
            inode: m.ino(),
            uid: m.uid(),
            mode: m.mode(),
            links: m.nlink(),
        })
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "format", deny_unknown_fields)]
enum Layout {
    Raw {
        filesystem_bytes: u64,
        superblock_sha256: [u8; 32],
    },
    Qcow {
        version: u32,
        host_bytes: u64,
        header_sha256: [u8; 32],
        backing_sha256: [u8; 32],
        tables_sha256: [u8; 32],
        filesystem_bytes: u64,
        superblock_sha256: [u8; 32],
        backings: Vec<BackingWitness>,
    },
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileVersion {
    stamp: Stamp,
    length: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
}
impl FileVersion {
    fn of(file: &File) -> Result<Self> {
        let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        Ok(Self {
            stamp: Stamp::metadata(&metadata)?,
            length: metadata.len(),
            mtime: (metadata.mtime(), metadata.mtime_nsec()),
            ctime: (metadata.ctime(), metadata.ctime_nsec()),
        })
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BackingWitness {
    path: PathBuf,
    parent: (u64, u64, u32, u32),
    version: FileVersion,
    virtual_bytes: u64,
    layout: Layout,
}

/// Private parent-produced witness. Reopening compares it with the original
/// snapshot; current inventory alone cannot grant a worker mutation authority.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct GeometryWitness {
    directory: PathBuf,
    raw_name: String,
    directory_identity: (u64, u64),
    stamp: Stamp,
    layout: Layout,
    bytes: u64,
}
impl GeometryWitness {
    pub(crate) fn bound(&self, directory: &Path, raw_name: &str, gib: u64) -> bool {
        self.directory == directory
            && self.raw_name == raw_name
            && (1..=64).contains(&gib)
            && self.bytes == gib * GIB
    }

    pub(crate) fn reopen_after(
        &self,
        wanted_gib: u64,
        budget: &ReadBudget,
    ) -> Result<DiskGeometry> {
        if wanted_gib < self.gib() || !self.bytes.is_multiple_of(GIB) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let disk =
            DiskGeometry::capture_with_budget(&self.directory, &self.raw_name, wanted_gib, budget)?;
        let current = disk.witness();
        if current.directory_identity != self.directory_identity
            || current.stamp != self.stamp
            || current.layout != self.layout
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(disk)
    }

    pub(crate) fn reopen(&self, raw_name: &str) -> Result<DiskGeometry> {
        if self.raw_name != raw_name || self.bytes & (GIB - 1) != 0 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let disk = DiskGeometry::capture(&self.directory, raw_name, self.bytes / GIB)?;
        if disk.witness() != *self {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(disk)
    }

    pub(crate) fn directory(&self) -> &Path {
        &self.directory
    }

    pub(crate) fn gib(&self) -> u64 {
        self.bytes / GIB
    }
}

pub(crate) struct DiskGeometry {
    path: PathBuf,
    directory: PathBuf,
    raw_name: String,
    directory_handle: File,
    directory_identity: (u64, u64),
    file: File,
    stamp: Stamp,
    layout: Layout,
    bytes: u64,
    format: DiskFormat,
}

impl DiskGeometry {
    pub(crate) fn witness(&self) -> GeometryWitness {
        GeometryWitness {
            directory: self.directory.clone(),
            raw_name: self.raw_name.clone(),
            directory_identity: self.directory_identity,
            stamp: self.stamp,
            layout: self.layout.clone(),
            bytes: self.bytes,
        }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn capture(directory: &Path, raw_name: &str, expected_gib: u64) -> Result<Self> {
        let budget = ReadBudget::new(std::time::Duration::from_secs(30), Cancellation::new())?;
        Self::capture_with_budget(directory, raw_name, expected_gib, &budget)
    }

    pub(crate) fn capture_with_budget(
        directory: &Path,
        raw_name: &str,
        expected_gib: u64,
        budget: &ReadBudget,
    ) -> Result<Self> {
        budget.check()?;
        let expected = capacity(expected_gib)?;
        unredirected(directory)?;
        let directory_handle = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_DIRECTORY)
            .open(directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let dm = directory_handle
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if dm.uid() != unsafe { libc::geteuid() } || dm.mode() & 0o022 != 0 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let (path, format) = smolvm::agent::resolve_disk_image(directory, raw_name);
        let file = open(&path)?;
        let stamp = Stamp::of(&file)?;
        let (bytes, layout) = layout(&file, format, &path, budget)?;
        if bytes != expected {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(Self {
            path,
            directory: directory.into(),
            raw_name: raw_name.into(),
            directory_handle,
            directory_identity: (dm.dev(), dm.ino()),
            file,
            stamp,
            layout,
            bytes,
            format,
        })
    }

    pub(crate) fn verify_after(&self, wanted_gib: u64) -> Result<()> {
        let budget = ReadBudget::new(std::time::Duration::from_secs(30), Cancellation::new())?;
        self.verify_after_with_budget(wanted_gib, &budget)
    }

    pub(crate) fn verify_after_with_budget(
        &self,
        wanted_gib: u64,
        budget: &ReadBudget,
    ) -> Result<()> {
        self.after(wanted_gib, budget)
            .map_err(|e| Error::uncertain(e.code))
    }

    fn after(&self, wanted_gib: u64, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        let wanted = capacity(wanted_gib)?;
        if wanted < self.bytes {
            return Err(Error::before(ErrorCode::Validation));
        }
        unredirected(&self.directory)?;
        let path_metadata = std::fs::symlink_metadata(&self.directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let dm = self
            .directory_handle
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if (dm.dev(), dm.ino()) != self.directory_identity
            || (path_metadata.dev(), path_metadata.ino()) != self.directory_identity
            || dm.uid() != unsafe { libc::geteuid() }
            || dm.mode() & 0o022 != 0
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let (path, format) = smolvm::agent::resolve_disk_image(&self.directory, &self.raw_name);
        if path != self.path || format != self.format || Stamp::of(&self.file)? != self.stamp {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let current = open(&path)?;
        if Stamp::of(&current)? != self.stamp {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let (bytes, current_layout) = layout(&current, format, &path, budget)?;
        // The pinned SDK enlarges raw backing or the QCOW virtual-size field.
        // It does not grow ext4 until normal boot. Its existing filesystem and
        // QCOW metadata/backing references must be preserved, not fabricated.
        if bytes != wanted || current_layout != self.layout {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

fn capacity(gib: u64) -> Result<u64> {
    if !(1..=64).contains(&gib) {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(gib * GIB)
}

fn open(path: &Path) -> Result<File> {
    unredirected(path)?;
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Ownership))
}

fn read<const N: usize>(file: &File, offset: u64) -> Result<[u8; N]> {
    let mut bytes = [0; N];
    file.read_exact_at(&mut bytes, offset)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    Ok(bytes)
}

fn layout(
    file: &File,
    format: DiskFormat,
    path: &Path,
    budget: &ReadBudget,
) -> Result<(u64, Layout)> {
    let origin = FileVersion::of(file)?;
    let mut remaining = crate::qcow_geometry::IO_BYTES;
    let (bytes, mut layout) = single_layout(file, format, budget, &mut remaining)?;
    if format == DiskFormat::Raw {
        if FileVersion::of(file)? != origin {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()?;
        return Ok((bytes, layout));
    }
    let mut sb = [0; 1024];
    let mut resolved = [false; 1024];
    crate::qcow_geometry::superblock(file, budget, &mut sb, &mut resolved)?;
    let mut next = backing_path(file, path, budget)?;
    let mut seen = vec![(origin.stamp.device, origin.stamp.inode)];
    let mut backings = Vec::new();
    while let Some((path, declared)) = next {
        budget.check()?;
        if backings.len() >= MAX_BACKINGS {
            return Err(Error::before(ErrorCode::Admission));
        }
        let parent = backing_parent(&path)?;
        let backing = open(&path)?;
        let version = FileVersion::of(&backing)?;
        let identity = (version.stamp.device, version.stamp.inode);
        if seen.contains(&identity) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        seen.push(identity);
        let format = if read::<4>(&backing, 0)? == *b"QFI\xfb" {
            DiskFormat::Qcow2
        } else {
            DiskFormat::Raw
        };
        if declared.is_some_and(|value| value != format) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let (virtual_bytes, shape) = single_layout(&backing, format, budget, &mut remaining)?;
        if format == DiskFormat::Raw {
            let data = read::<1024>(&backing, 1024)?;
            for index in 0..sb.len() {
                if !resolved[index] {
                    sb[index] = data[index];
                    resolved[index] = true;
                }
            }
            next = None;
        } else {
            crate::qcow_geometry::superblock(&backing, budget, &mut sb, &mut resolved)?;
            next = backing_path(&backing, &path, budget)?;
        }
        if FileVersion::of(&backing)? != version || backing_parent(&path)? != parent {
            return Err(Error::before(ErrorCode::Ownership));
        }
        drop(backing);
        if FileVersion::of(&open(&path)?)? != version {
            return Err(Error::before(ErrorCode::Ownership));
        }
        backings.push(BackingWitness {
            path,
            parent,
            version,
            virtual_bytes,
            layout: shape,
        });
        // No chain-length-dependent FD retention: each iteration closes its file.
    }
    for backing in &backings {
        budget.check()?;
        if backing_parent(&backing.path)? != backing.parent
            || FileVersion::of(&open(&backing.path)?)? != backing.version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    let filesystem_bytes = filesystem_size(&sb, bytes)?;
    if FileVersion::of(file)? != origin {
        return Err(Error::before(ErrorCode::Ownership));
    }
    if let Layout::Qcow {
        filesystem_bytes: size,
        superblock_sha256,
        backings: saved,
        ..
    } = &mut layout
    {
        *size = filesystem_bytes;
        *superblock_sha256 = Sha256::digest(sb).into();
        *saved = backings;
    }
    budget.check()?;
    Ok((bytes, layout))
}

fn backing_parent(path: &Path) -> Result<(u64, u64, u32, u32)> {
    let parent = path.parent().ok_or(Error::before(ErrorCode::Ownership))?;
    unredirected(parent)?;
    let metadata = std::fs::symlink_metadata(parent).map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o022 != 0
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok((
        metadata.dev(),
        metadata.ino(),
        metadata.uid(),
        metadata.mode(),
    ))
}

fn backing_path(
    file: &File,
    path: &Path,
    budget: &ReadBudget,
) -> Result<Option<(PathBuf, Option<DiskFormat>)>> {
    let header = read::<72>(file, 0)?;
    let offset = u64::from_be_bytes(header[8..16].try_into().unwrap());
    let size = u32::from_be_bytes(header[16..20].try_into().unwrap()) as usize;
    if size == 0 {
        return Ok(None);
    }
    if size as u64 > MAX_BACKING_NAME {
        return Err(Error::before(ErrorCode::Validation));
    }
    let declared = backing_format(file, &header, offset, budget)?;
    let mut name = vec![0; size];
    file.read_exact_at(&mut name, offset)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    let name = std::str::from_utf8(&name).map_err(|_| Error::before(ErrorCode::Validation))?;
    if name.contains('\0') || name.contains("://") {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    let joined = path
        .parent()
        .ok_or(Error::before(ErrorCode::Ownership))?
        .join(name);
    let mut normalized = PathBuf::new();
    for component in joined.components() {
        budget.check()?;
        use std::path::Component;
        match component {
            Component::RootDir => normalized.push("/"),
            Component::CurDir => {}
            Component::ParentDir => {
                // Check traversed directories before lexical normalization; a
                // symlink in a/../base must not disappear from validation.
                unredirected(&normalized)?;
                if !normalized.is_dir() || !normalized.pop() {
                    return Err(Error::before(ErrorCode::Ownership));
                }
            }
            Component::Normal(name) => {
                normalized.push(name);
                unredirected(&normalized)?;
            }
            Component::Prefix(_) => return Err(Error::before(ErrorCode::Unsupported)),
        }
    }
    Ok(Some((normalized, declared)))
}

fn backing_format(
    file: &File,
    header: &[u8; 72],
    limit: u64,
    budget: &ReadBudget,
) -> Result<Option<DiskFormat>> {
    let version = u32::from_be_bytes(header[4..8].try_into().unwrap());
    let mut offset = if version == 2 { 72 } else { 104 };
    let mut format = None;
    let mut extensions = 0;
    while offset < limit {
        budget.check()?;
        if extensions >= 1024 || limit - offset < 8 {
            return Err(Error::before(ErrorCode::Validation));
        }
        extensions += 1;
        let extension = read::<8>(file, offset)?;
        let kind = u32::from_be_bytes(extension[..4].try_into().unwrap());
        let size = u32::from_be_bytes(extension[4..].try_into().unwrap()) as u64;
        if kind == 0 {
            if size != 0 {
                return Err(Error::before(ErrorCode::Validation));
            }
            break;
        }
        let end = offset
            .checked_add(8)
            .and_then(|n| n.checked_add(size.div_ceil(8) * 8))
            .filter(|n| *n <= limit)
            .ok_or(Error::before(ErrorCode::Validation))?;
        if kind == 0xe2792aca {
            if format.is_some() || !matches!(size, 3 | 5) {
                return Err(Error::before(ErrorCode::Unsupported));
            }
            let value = read::<8>(file, offset + 8)?;
            format = Some(match &value[..size as usize] {
                b"raw" => DiskFormat::Raw,
                b"qcow2" => DiskFormat::Qcow2,
                _ => return Err(Error::before(ErrorCode::Unsupported)),
            });
        }
        offset = end;
    }
    Ok(format)
}

fn filesystem_size(sb: &[u8; 1024], capacity: u64) -> Result<u64> {
    if u16::from_le_bytes(sb[56..58].try_into().unwrap()) != 0xef53 {
        return Err(Error::before(ErrorCode::Validation));
    }
    let low = u32::from_le_bytes(sb[4..8].try_into().unwrap()) as u64;
    let incompat = u32::from_le_bytes(sb[96..100].try_into().unwrap());
    let high = u32::from_le_bytes(sb[336..340].try_into().unwrap()) as u64;
    let log = u32::from_le_bytes(sb[24..28].try_into().unwrap());
    if log > 6 || (incompat & 0x80 == 0 && high != 0) {
        return Err(Error::before(ErrorCode::Validation));
    }
    let blocks = low | (if incompat & 0x80 != 0 { high } else { 0 } << 32);
    blocks
        .checked_mul(1024u64 << log)
        .filter(|n| *n > 0 && *n <= capacity)
        .ok_or(Error::before(ErrorCode::Validation))
}

fn single_layout(
    file: &File,
    format: DiskFormat,
    budget: &ReadBudget,
    remaining: &mut u64,
) -> Result<(u64, Layout)> {
    budget.check()?;
    let len = file
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?
        .len();
    if len < 2048 {
        return Err(Error::before(ErrorCode::Validation));
    }
    match format {
        DiskFormat::Raw => {
            if len > MAX_BYTES {
                return Err(Error::before(ErrorCode::Validation));
            }
            if read::<4>(file, 0)? == *b"QFI\xfb" {
                return Err(Error::before(ErrorCode::Validation));
            }
            let sb = read::<1024>(file, 1024)?;
            let filesystem_bytes = filesystem_size(&sb, len)?;
            Ok((
                len,
                Layout::Raw {
                    filesystem_bytes,
                    superblock_sha256: Sha256::digest(sb).into(),
                },
            ))
        }
        DiskFormat::Qcow2 => {
            let prefix = read::<72>(file, 0)?;
            let version = u32::from_be_bytes(prefix[4..8].try_into().unwrap());
            if prefix[..4] != *b"QFI\xfb" || !matches!(version, 2 | 3) {
                return Err(Error::before(ErrorCode::Validation));
            }
            let cluster_bits = u32::from_be_bytes(prefix[20..24].try_into().unwrap());
            let bytes = u64::from_be_bytes(prefix[24..32].try_into().unwrap());
            let backing_offset = u64::from_be_bytes(prefix[8..16].try_into().unwrap());
            let backing_bytes = u32::from_be_bytes(prefix[16..20].try_into().unwrap()) as u64;
            let crypt = u32::from_be_bytes(prefix[32..36].try_into().unwrap());
            let snapshots = u32::from_be_bytes(prefix[60..64].try_into().unwrap());
            if !(9..=21).contains(&cluster_bits)
                || !(GIB..=MAX_BYTES).contains(&bytes)
                || bytes % GIB != 0
                || crypt != 0
                || snapshots != 0
                || backing_bytes > MAX_BACKING_NAME
                || (backing_offset == 0) != (backing_bytes == 0)
            {
                return Err(Error::before(ErrorCode::Validation));
            }
            let mut header = if version == 3 {
                read::<104>(file, 0)?.to_vec()
            } else {
                prefix.to_vec()
            };
            if version == 3 {
                let incompat = u64::from_be_bytes(header[72..80].try_into().unwrap());
                let refcount_order = u32::from_be_bytes(header[96..100].try_into().unwrap());
                let header_bytes = u32::from_be_bytes(header[100..104].try_into().unwrap());
                if incompat & !1 != 0 || refcount_order != 4 || header_bytes != 104 {
                    return Err(Error::before(ErrorCode::Unsupported));
                }
            }
            let mut backing = vec![0; backing_bytes as usize];
            if backing_bytes != 0 {
                if backing_offset < header.len() as u64
                    || backing_offset
                        .checked_add(backing_bytes)
                        .is_none_or(|end| end > len || end > 1u64 << cluster_bits)
                {
                    return Err(Error::before(ErrorCode::Validation));
                }
                file.read_exact_at(&mut backing, backing_offset)
                    .map_err(|_| Error::before(ErrorCode::Validation))?;
                if backing.contains(&0) {
                    return Err(Error::before(ErrorCode::Validation));
                }
            }
            header[24..32].fill(0);
            let tables_sha256 = crate::qcow_geometry::snapshot(file, &header, budget, remaining)?;
            Ok((
                bytes,
                Layout::Qcow {
                    version,
                    host_bytes: len,
                    header_sha256: Sha256::digest(header).into(),
                    backing_sha256: Sha256::digest(backing).into(),
                    tables_sha256,
                    filesystem_bytes: 0,
                    superblock_sha256: [0; 32],
                    backings: Vec::new(),
                },
            ))
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::Write;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn directory() -> (tempfile::TempDir, PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        (temp, root)
    }
    pub(crate) fn raw(root: &Path) -> PathBuf {
        let path = root.join("storage.raw");
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        file.set_len(GIB).unwrap();
        file.write_all_at(&superblock(), 1024).unwrap();
        path
    }

    fn superblock() -> [u8; 1024] {
        let mut sb = [0; 1024];
        sb[4..8].copy_from_slice(&((GIB / 4096) as u32).to_le_bytes());
        sb[24..28].copy_from_slice(&2u32.to_le_bytes());
        sb[56..58].copy_from_slice(&0xef53u16.to_le_bytes());
        sb[104..120].fill(7);
        sb
    }
    pub(crate) fn qcow(root: &Path, version: u32) -> PathBuf {
        let path = root.join("storage.qcow2");
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        let mut h = [0; 104];
        h[..4].copy_from_slice(b"QFI\xfb");
        h[4..8].copy_from_slice(&version.to_be_bytes());
        h[20..24].copy_from_slice(&16u32.to_be_bytes());
        h[24..32].copy_from_slice(&GIB.to_be_bytes());
        let cluster = 1u64 << 16;
        h[36..40].copy_from_slice(&2u32.to_be_bytes());
        h[40..48].copy_from_slice(&cluster.to_be_bytes());
        h[48..56].copy_from_slice(&(3 * cluster).to_be_bytes());
        h[56..60].copy_from_slice(&1u32.to_be_bytes());
        if version == 3 {
            h[96..100].copy_from_slice(&4u32.to_be_bytes());
            h[100..104].copy_from_slice(&104u32.to_be_bytes());
        }
        file.write_all(&h).unwrap();
        file.set_len(6 * cluster).unwrap();
        let copied = 1u64 << 63;
        file.write_all_at(&(copied | (2 * cluster)).to_be_bytes(), cluster)
            .unwrap();
        file.write_all_at(&(copied | (5 * cluster)).to_be_bytes(), 2 * cluster)
            .unwrap();
        file.write_all_at(&(4 * cluster).to_be_bytes(), 3 * cluster)
            .unwrap();
        for index in 0..6 {
            file.write_all_at(&1u16.to_be_bytes(), 4 * cluster + index * 2)
                .unwrap();
        }
        file.write_all_at(&superblock(), 5 * cluster + 1024)
            .unwrap();
        path
    }

    fn link_backing(path: &Path, name: &str, declared: Option<DiskFormat>, unallocated: bool) {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .unwrap();
        file.write_all_at(&256u64.to_be_bytes(), 8).unwrap();
        file.write_all_at(&(name.len() as u32).to_be_bytes(), 16)
            .unwrap();
        file.write_all_at(name.as_bytes(), 256).unwrap();
        if let Some(format) = declared {
            let start = if read::<4>(&file, 4).unwrap() == 2u32.to_be_bytes() {
                72
            } else {
                104
            };
            let value: &[u8] = if format == DiskFormat::Raw {
                b"raw"
            } else {
                b"qcow2"
            };
            file.write_all_at(&0xe2792acau32.to_be_bytes(), start)
                .unwrap();
            file.write_all_at(&(value.len() as u32).to_be_bytes(), start + 4)
                .unwrap();
            file.write_all_at(value, start + 8).unwrap();
        }
        if unallocated {
            let cluster = 1u64 << 16;
            file.write_all_at(&0u64.to_be_bytes(), 2 * cluster).unwrap();
            file.write_all_at(&0u16.to_be_bytes(), 4 * cluster + 5 * 2)
                .unwrap();
            file.set_len(5 * cluster).unwrap();
        }
    }

    pub(crate) fn backed_qcow(root: &Path, version: u32) -> PathBuf {
        let raw_path = raw(root);
        let name = format!("base-{version}.ext4");
        let base = root.join(&name);
        std::fs::rename(raw_path, &base).unwrap();
        std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o444)).unwrap();
        let path = qcow(root, version);
        link_backing(&path, &name, Some(DiskFormat::Raw), true);
        path
    }

    #[test]
    fn qcow_backing_depth_and_parent_authority_are_bounded_before_dispatch() {
        let (_temp, root) = directory();
        let raw_path = raw(&root);
        std::fs::rename(raw_path, root.join("base.ext4")).unwrap();
        for index in 0..10 {
            let path = qcow(&root, 3);
            std::fs::rename(path, root.join(format!("layer-{index}.qcow2"))).unwrap();
        }
        for index in 0..9 {
            link_backing(
                &root.join(format!("layer-{index}.qcow2")),
                &format!("layer-{}.qcow2", index + 1),
                None,
                true,
            );
        }
        link_backing(&root.join("layer-9.qcow2"), "base.ext4", None, true);
        let path = root.join("storage.qcow2");
        std::fs::rename(root.join("layer-0.qcow2"), &path).unwrap();
        let error = DiskGeometry::capture(&root, "storage.raw", 1)
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Admission);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        link_backing(&root.join("layer-7.qcow2"), "base.ext4", None, true);
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_ok());

        let untrusted = root.join("untrusted");
        std::fs::create_dir(&untrusted).unwrap();
        let file = raw(&untrusted);
        std::fs::set_permissions(&untrusted, std::fs::Permissions::from_mode(0o777)).unwrap();
        link_backing(&path, file.to_str().unwrap(), None, true);
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
    }

    #[test]
    fn qcow_backing_fallback_preserves_ext4_and_shared_base_identity_after_sdk_growth() {
        let (_temp, root) = directory();
        let raw_path = raw(&root);
        let base = root.join("base.ext4");
        std::fs::rename(raw_path, &base).unwrap();
        std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o444)).unwrap();
        let path = qcow(&root, 3);
        link_backing(&path, "base.ext4", Some(DiskFormat::Raw), true);
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        let Layout::Qcow {
            filesystem_bytes,
            backings,
            ..
        } = &geometry.layout
        else {
            unreachable!()
        };
        assert_eq!(*filesystem_bytes, GIB);
        assert_eq!(backings.len(), 1);
        assert_eq!(backings[0].path, base);
        assert!(
            serde_json::to_vec(&geometry.witness()).unwrap().len()
                < crate::growth::METADATA_BYTES as usize / 2
        );
        assert!(geometry.witness().reopen("storage.raw").is_ok());
        smolvm::storage::expand_disk::<smolvm::storage::Storage>(&path, 2).unwrap();
        assert!(geometry.verify_after(2).is_ok());

        std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o600)).unwrap();
        OpenOptions::new()
            .write(true)
            .open(&base)
            .unwrap()
            .write_all_at(&[9], 4096)
            .unwrap();
        std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o444)).unwrap();
        assert_eq!(
            geometry.verify_after(2).err().unwrap().dispatch,
            crate::Dispatch::MayHaveDispatched
        );
    }

    #[test]
    fn qcow_chain_rejects_cycles_missing_redirected_and_replaced_backing_files() {
        for name in ["storage.qcow2", "missing", "alias"] {
            let (_temp, root) = directory();
            let path = qcow(&root, 3);
            symlink(&path, root.join("alias")).unwrap();
            link_backing(&path, name, None, false);
            assert_eq!(
                DiskGeometry::capture(&root, "storage.raw", 1)
                    .err()
                    .unwrap()
                    .dispatch,
                crate::Dispatch::NotDispatched
            );
        }
        let (_temp, root) = directory();
        let raw_path = raw(&root);
        let base = root.join("base.ext4");
        std::fs::rename(raw_path, &base).unwrap();
        let path = qcow(&root, 3);
        link_backing(&path, "base.ext4", None, true);
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        std::fs::rename(&base, root.join("retained-base")).unwrap();
        let replacement = raw(&root);
        std::fs::rename(replacement, &base).unwrap();
        assert!(geometry.witness().reopen("storage.raw").is_err());
        assert!(geometry.verify_after(1).is_err());
    }

    #[test]
    fn qcow_nested_relative_chain_binds_declared_formats_and_cannot_hide_a_symlink() {
        let (_temp, root) = directory();
        let raw_path = raw(&root);
        std::fs::rename(raw_path, root.join("base.ext4")).unwrap();
        let middle = qcow(&root, 2);
        link_backing(&middle, "base.ext4", Some(DiskFormat::Raw), true);
        let middle_path = root.join("middle.qcow2");
        std::fs::rename(middle, &middle_path).unwrap();
        std::fs::create_dir(root.join("sub")).unwrap();
        let path = qcow(&root, 3);
        link_backing(&path, "sub/../middle.qcow2", Some(DiskFormat::Qcow2), true);
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        let Layout::Qcow { backings, .. } = &geometry.layout else {
            unreachable!()
        };
        assert_eq!(backings.len(), 2);
        assert_eq!(backings[0].path, middle_path);

        link_backing(&path, "middle.qcow2", Some(DiskFormat::Raw), true);
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
        symlink(root.join("sub"), root.join("link")).unwrap();
        link_backing(&path, "link/../middle.qcow2", Some(DiskFormat::Qcow2), true);
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
    }

    #[test]
    fn qcow_virtual_ext4_geometry_rejects_over_capacity_and_explicit_zero_does_not_fall_back() {
        let (_temp, root) = directory();
        let path = qcow(&root, 3);
        let file = OpenOptions::new().write(true).open(&path).unwrap();
        file.write_all_at(
            &((2 * GIB / 4096) as u32).to_le_bytes(),
            5 * (1 << 16) + 1024 + 4,
        )
        .unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
        let raw_path = raw(&root);
        std::fs::rename(raw_path, root.join("base.ext4")).unwrap();
        link_backing(&path, "base.ext4", Some(DiskFormat::Raw), true);
        file.write_all_at(&1u64.to_be_bytes(), 2 * (1 << 16))
            .unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
    }

    #[test]
    fn raw_sdk_growth_preserves_filesystem_and_requires_exact_backing_capacity() {
        let (_temp, root) = directory();
        let path = raw(&root);
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        assert!(geometry.verify_after(2).is_err());
        smolvm::storage::expand_disk::<smolvm::storage::Storage>(&path, 2).unwrap();
        assert!(geometry.verify_after(2).is_ok());
        assert!(geometry.verify_after(3).is_err());
        assert!(geometry.verify_after(0).is_err());
        let Layout::Raw {
            filesystem_bytes, ..
        } = geometry.layout
        else {
            unreachable!()
        };
        assert_eq!(filesystem_bytes, GIB); // Stopped resize is not filesystem growth.
    }

    #[test]
    fn serialized_worker_witness_requires_original_inode_layout_parent_and_role() {
        let (_temp, root) = directory();
        let path = raw(&root);
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        let witness: GeometryWitness =
            serde_json::from_slice(&serde_json::to_vec(&geometry.witness()).unwrap()).unwrap();
        assert!(witness.reopen("storage.raw").is_ok());
        assert!(witness.reopen("overlay.raw").is_err());
        let file = OpenOptions::new().write(true).open(&path).unwrap();
        file.write_all_at(&[9; 16], 1024 + 104).unwrap();
        assert!(witness.reopen("storage.raw").is_err());
        file.write_all_at(&[7; 16], 1024 + 104).unwrap();
        std::fs::rename(&path, root.join("retained.raw")).unwrap();
        raw(&root);
        assert!(witness.reopen("storage.raw").is_err());
    }

    #[test]
    fn raw_changed_filesystem_and_record_size_mismatch_never_authorize_growth() {
        let (_temp, root) = directory();
        let path = raw(&root);
        assert!(DiskGeometry::capture(&root, "storage.raw", 2).is_err());
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        let file = OpenOptions::new().write(true).open(&path).unwrap();
        file.set_len(2 * GIB).unwrap();
        file.write_all_at(&[8; 16], 1024 + 104).unwrap();
        let error = geometry.verify_after(2).err().unwrap();
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
    }

    #[test]
    fn geometry_rejects_redirected_replaced_and_shared_inodes() {
        let (_temp, root) = directory();
        let path = raw(&root);
        symlink(&path, root.join("storage.qcow2")).unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
        std::fs::remove_file(root.join("storage.qcow2")).unwrap();
        std::fs::hard_link(&path, root.join("alias.raw")).unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
        std::fs::remove_file(root.join("alias.raw")).unwrap();
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        std::fs::rename(&path, root.join("retained.raw")).unwrap();
        raw(&root);
        assert!(geometry.verify_after(1).is_err());
    }

    #[test]
    fn qcow_sdk_growth_checks_virtual_size_instead_of_physical_file_length() {
        for version in [2, 3] {
            let (_temp, root) = directory();
            let path = qcow(&root, version);
            let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
            assert_eq!(std::fs::metadata(&path).unwrap().len(), 6 * (1 << 16));
            let file = OpenOptions::new().write(true).open(&path).unwrap();
            file.set_len(2 * GIB).unwrap();
            assert!(geometry.verify_after(2).is_err()); // Padding is not QCOW growth.
                                                        // Bind the padded image independently before legitimate SDK growth.
            let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
            smolvm::storage::expand_disk::<smolvm::storage::Storage>(&path, 2).unwrap();
            assert!(geometry.verify_after(2).is_ok());
            file.write_all_at(&17u32.to_be_bytes(), 20).unwrap();
            assert!(geometry.verify_after(2).is_err());
        }
    }

    #[test]
    fn malformed_ext4_geometry_and_unsupported_qcow_headers_reject_before_dispatch() {
        let (_temp, root) = directory();
        let path = raw(&root);
        let file = OpenOptions::new().write(true).open(&path).unwrap();
        file.write_all_at(b"QFI\xfb", 0).unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
        file.write_all_at(&[0; 4], 0).unwrap();
        file.write_all_at(&u32::MAX.to_le_bytes(), 1024 + 4)
            .unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
        std::fs::remove_file(path).unwrap();
        let path = qcow(&root, 3);
        let file = OpenOptions::new().write(true).open(path).unwrap();
        file.write_all_at(&4u64.to_be_bytes(), 72).unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
    }

    #[test]
    fn backing_reference_and_parent_directory_remain_bound_to_the_original_snapshot() {
        let (temp, root) = directory();
        let base = raw(&root);
        std::fs::rename(base, root.join("base")).unwrap();
        let path = qcow(&root, 3);
        let file = OpenOptions::new().write(true).open(path).unwrap();
        file.write_all_at(&128u64.to_be_bytes(), 8).unwrap();
        file.write_all_at(&4u32.to_be_bytes(), 16).unwrap();
        file.write_all_at(b"base", 128).unwrap();
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        file.write_all_at(b"evil", 128).unwrap();
        assert!(geometry.verify_after(1).is_err());
        let renamed = root.with_extension("saved");
        std::fs::rename(&root, &renamed).unwrap();
        std::fs::create_dir(&root).unwrap();
        qcow(&root, 3);
        assert!(geometry.verify_after(1).is_err());
        std::fs::remove_dir_all(renamed).unwrap();
        drop(temp);
    }

    #[test]
    fn qcow_tables_reject_reserved_offsets_truncation_and_metadata_aliases_before_dispatch() {
        let cluster = 1u64 << 16;
        let copied = 1u64 << 63;
        for (offset, bytes) in [
            (40, (cluster + 512).to_be_bytes().to_vec()),
            (48, u64::MAX.to_be_bytes().to_vec()),
            (56, u32::MAX.to_be_bytes().to_vec()),
            (cluster, (copied | (2 * cluster) | 1).to_be_bytes().to_vec()),
            (cluster + 8, (copied | (2 * cluster)).to_be_bytes().to_vec()),
            (2 * cluster, (copied | (3 * cluster)).to_be_bytes().to_vec()),
            (2 * cluster, (copied | (7 * cluster)).to_be_bytes().to_vec()),
            (3 * cluster, (4 * cluster + 512).to_be_bytes().to_vec()),
        ] {
            let (_temp, root) = directory();
            let path = qcow(&root, 3);
            OpenOptions::new()
                .write(true)
                .open(path)
                .unwrap()
                .write_all_at(&bytes, offset)
                .unwrap();
            let error = DiskGeometry::capture(&root, "storage.raw", 1)
                .err()
                .unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        }
    }

    #[test]
    fn qcow_growth_cannot_preserve_authority_after_table_or_physical_extent_changes() {
        let cluster = 1u64 << 16;
        for offset in [
            cluster + 8,
            2 * cluster + 8,
            3 * cluster + 8,
            4 * cluster + 2,
        ] {
            let (_temp, root) = directory();
            let path = qcow(&root, 3);
            let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
            smolvm::storage::expand_disk::<smolvm::storage::Storage>(&path, 2).unwrap();
            OpenOptions::new()
                .write(true)
                .open(path)
                .unwrap()
                .write_all_at(&1u64.to_be_bytes(), offset)
                .unwrap();
            let error = geometry.verify_after(2).err().unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        }
        let (_temp, root) = directory();
        let path = qcow(&root, 3);
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        smolvm::storage::expand_disk::<smolvm::storage::Storage>(&path, 2).unwrap();
        OpenOptions::new()
            .write(true)
            .open(path)
            .unwrap()
            .set_len(7 * cluster)
            .unwrap();
        assert!(geometry.verify_after(2).is_err());
    }

    #[test]
    fn qcow_scan_honors_cancellation_and_aggregate_table_io_limit() {
        let (_temp, root) = directory();
        let path = qcow(&root, 3);
        let cancel = Cancellation::new();
        cancel.cancel();
        let budget = ReadBudget::new(std::time::Duration::from_secs(1), cancel).unwrap();
        assert!(DiskGeometry::capture_with_budget(&root, "storage.raw", 1, &budget).is_err());

        let cluster = 1u64 << 16;
        let file = OpenOptions::new().write(true).open(path).unwrap();
        file.set_len(1106 * cluster).unwrap();
        file.write_all_at(&1100u32.to_be_bytes(), 36).unwrap();
        for index in 0..1100 {
            file.write_all_at(&((index + 6) * cluster).to_be_bytes(), cluster + index * 8)
                .unwrap();
        }
        let error = DiskGeometry::capture(&root, "storage.raw", 1)
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Admission);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
    }

    #[test]
    fn qcow_compressed_entries_and_oversized_backing_names_are_explicit_rejections() {
        let (_temp, root) = directory();
        let path = qcow(&root, 3);
        let file = OpenOptions::new().write(true).open(&path).unwrap();
        file.write_all_at(&(1u64 << 62).to_be_bytes(), 2 * (1 << 16))
            .unwrap();
        let error = DiskGeometry::capture(&root, "storage.raw", 1)
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Unsupported);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);

        std::fs::remove_file(path).unwrap();
        let path = qcow(&root, 3);
        let file = OpenOptions::new().write(true).open(path).unwrap();
        file.write_all_at(&128u64.to_be_bytes(), 8).unwrap();
        file.write_all_at(&1024u32.to_be_bytes(), 16).unwrap();
        file.write_all_at(&[b'x'; 1024], 128).unwrap();
        let error = DiskGeometry::capture(&root, "storage.raw", 1)
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Validation);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
    }

    #[test]
    fn qcow_refcounts_reject_missing_undercounted_overcounted_and_leaked_allocations() {
        let cluster = 1u64 << 16;
        for (index, count) in [(0, 0u16), (2, 0), (4, 0), (5, 0), (3, 2), (5, 2), (6, 1)] {
            let (_temp, root) = directory();
            let path = qcow(&root, 3);
            OpenOptions::new()
                .write(true)
                .open(path)
                .unwrap()
                .write_all_at(&count.to_be_bytes(), 4 * cluster + index * 2)
                .unwrap();
            let error = DiskGeometry::capture(&root, "storage.raw", 1)
                .err()
                .unwrap();
            assert_eq!(error.code, ErrorCode::Validation);
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        }
        let (_temp, root) = directory();
        let path = qcow(&root, 3);
        OpenOptions::new()
            .write(true)
            .open(path)
            .unwrap()
            .write_all_at(&0u64.to_be_bytes(), 3 * cluster)
            .unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
    }

    #[test]
    fn qcow_shared_data_requires_exact_counts_and_cannot_claim_copied_exclusivity() {
        let (_temp, root) = directory();
        let path = qcow(&root, 3);
        let file = OpenOptions::new().write(true).open(&path).unwrap();
        let cluster = 1u64 << 16;
        file.write_all_at(&(5 * cluster).to_be_bytes(), 2 * cluster)
            .unwrap();
        file.write_all_at(&(5 * cluster).to_be_bytes(), 2 * cluster + 8)
            .unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 1).is_err());
        file.write_all_at(&2u16.to_be_bytes(), 4 * cluster + 5 * 2)
            .unwrap();
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        smolvm::storage::expand_disk::<smolvm::storage::Storage>(&path, 2).unwrap();
        assert!(geometry.verify_after(2).is_ok());
        file.write_all_at(&((1u64 << 63) | (5 * cluster)).to_be_bytes(), 2 * cluster)
            .unwrap();
        assert!(DiskGeometry::capture(&root, "storage.raw", 2).is_err());
    }

    #[test]
    fn qcow_reference_map_allocation_is_bounded_before_sdk_entry() {
        let (_temp, root) = directory();
        let path = qcow(&root, 3);
        OpenOptions::new()
            .write(true)
            .open(path)
            .unwrap()
            .set_len(((8 * 1024 * 1024 / 2) + 1) * (1u64 << 16))
            .unwrap();
        let error = DiskGeometry::capture(&root, "storage.raw", 1)
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Admission);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
    }

    #[test]
    fn qcow_refcount_table_indexes_cover_sparse_high_host_clusters() {
        let (_temp, root) = directory();
        let path = qcow(&root, 3);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let cluster = 1u64 << 16;
        let high = (cluster / 2) * cluster;
        let sb = read::<1024>(&file, 5 * cluster + 1024).unwrap();
        file.set_len(high + cluster).unwrap();
        file.write_all_at(&((1u64 << 63) | high).to_be_bytes(), 2 * cluster)
            .unwrap();
        file.write_all_at(&(5 * cluster).to_be_bytes(), 3 * cluster + 8)
            .unwrap();
        file.write_all_at(&vec![0; cluster as usize], 5 * cluster)
            .unwrap();
        file.write_all_at(&1u16.to_be_bytes(), 5 * cluster).unwrap();
        file.write_all_at(&sb, high + 1024).unwrap();
        let geometry = DiskGeometry::capture(&root, "storage.raw", 1).unwrap();
        smolvm::storage::expand_disk::<smolvm::storage::Storage>(&path, 2).unwrap();
        assert!(geometry.verify_after(2).is_ok());
        file.write_all_at(&0u16.to_be_bytes(), 5 * cluster).unwrap();
        assert!(geometry.verify_after(2).is_err());
    }
}
