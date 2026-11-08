//! Immutable operator-selected pack inputs. These grants are never guest paths.
use crate::{Error, ErrorCode, ReadBudget, Result};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::PathBuf;

pub const EXPORT_ASSET_FILE_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const FILE_BYTES: u64 = EXPORT_ASSET_FILE_BYTES;
pub const EXPORT_ASSET_TOTAL_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const TOTAL_BYTES: u64 = EXPORT_ASSET_TOTAL_BYTES;
#[derive(Clone, PartialEq, Eq)]
pub struct ApprovedExportAsset {
    pub name: String,
    pub path: PathBuf,
    pub sha256: String,
    pub max_bytes: u64,
}
#[derive(Clone, PartialEq, Eq)]
pub struct ApprovedExportAssets {
    pub files: Vec<ApprovedExportAsset>,
}
impl std::fmt::Debug for ApprovedExportAssets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApprovedExportAssets")
            .field("files", &self.files.len())
            .finish_non_exhaustive()
    }
}
impl std::fmt::Debug for ApprovedExportAsset {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApprovedExportAsset")
            .field("name", &self.name)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
struct Version(u64, u64, u64, u32, i64, i64, i64, i64);
impl Version {
    fn of(file: &File) -> Result<Self> {
        let m = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if !m.is_file()
            || m.uid() != unsafe { libc::geteuid() }
            || m.nlink() != 1
            || m.mode() & 0o022 != 0
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
struct Asset {
    approval: ApprovedExportAsset,
    file: File,
    version: Version,
}
pub(crate) struct QualifiedExportAssets {
    files: Vec<Asset>,
    budget: ReadBudget,
}
impl std::fmt::Debug for QualifiedExportAssets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QualifiedExportAssets")
            .field("files", &self.files.len())
            .finish_non_exhaustive()
    }
}
impl ApprovedExportAssets {
    pub(crate) fn validate(&self) -> Result<()> {
        let required = if cfg!(target_os = "macos") {
            vec![
                "agent-rootfs.tar",
                "lib/libkrun.dylib",
                "lib/libkrunfw.5.dylib",
            ]
        } else {
            vec!["agent-rootfs.tar", "lib/libkrun.so", "lib/libkrunfw.so.5"]
        };
        if self.files.len() != required.len()
            || required
                .iter()
                .any(|name| self.files.iter().filter(|file| file.name == *name).count() != 1)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        for file in &self.files {
            if !crate::domain::valid_hex(&file.sha256, 64)
                || file.max_bytes == 0
                || file.max_bytes > FILE_BYTES
                || !file.path.is_absolute()
                || file.path.as_os_str().len() > 4096
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        Ok(())
    }
    pub(crate) fn qualify(&self, budget: &ReadBudget) -> Result<QualifiedExportAssets> {
        budget.check()?;
        self.validate()?;
        let mut files = Vec::new();
        let mut total = 0u64;
        for approval in &self.files {
            budget.check()?;
            let file = open(&approval.path)?;
            let version = Version::of(&file)?;
            total = total
                .checked_add(version.2)
                .ok_or(Error::before(ErrorCode::Admission))?;
            if version.2 == 0 || version.2 > approval.max_bytes || total > TOTAL_BYTES {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            let asset = Asset {
                approval: approval.clone(),
                file,
                version,
            };
            asset.rehash(budget, budget)?;
            files.push(asset);
        }
        let qualified = QualifiedExportAssets {
            files,
            budget: budget.clone(),
        };
        qualified.verify()?;
        Ok(qualified)
    }
}
fn open(path: &std::path::Path) -> Result<File> {
    crate::host::unredirected(path)?;
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))
}
impl Asset {
    fn verify(&self) -> Result<()> {
        if Version::of(&self.file)? != self.version
            || Version::of(&open(&self.approval.path)?)? != self.version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn rehash(&self, budget: &ReadBudget, approval_budget: &ReadBudget) -> Result<()> {
        use std::os::unix::fs::FileExt;
        self.verify()?;
        let mut hash = Sha256::new();
        let mut buffer = [0; 64 * 1024];
        let mut offset = 0;
        while offset < self.version.2 {
            budget.check()?;
            approval_budget.check()?;
            let take = (self.version.2 - offset).min(buffer.len() as u64) as usize;
            self.file
                .read_exact_at(&mut buffer[..take], offset)
                .map_err(|_| Error::before(ErrorCode::Io))?;
            hash.update(&buffer[..take]);
            offset += take as u64;
        }
        self.verify()?;
        budget.check()?;
        approval_budget.check()?;
        if format!("{:x}", hash.finalize()) != self.approval.sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl QualifiedExportAssets {
    pub(crate) fn verify(&self) -> Result<()> {
        self.budget.check()?;
        for file in &self.files {
            file.verify()?;
        }
        self.budget.check()
    }
    pub(crate) fn rehash(&self, budget: &ReadBudget) -> Result<()> {
        self.budget.check()?;
        for file in &self.files {
            file.rehash(budget, &self.budget)?;
        }
        self.budget.check()
    }
    pub(crate) fn entries(&self) -> Vec<(String, u64)> {
        self.files
            .iter()
            .map(|file| (file.approval.name.clone(), file.version.2))
            .collect()
    }
    pub(crate) fn reader<'a>(&'a self, name: &str, budget: &ReadBudget) -> Result<AssetReader<'a>> {
        self.verify()?;
        let asset = self
            .files
            .iter()
            .find(|file| file.approval.name == name)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        Ok(AssetReader {
            asset,
            budget: budget.clone(),
            approval_budget: self.budget.clone(),
            position: 0,
        })
    }
}
pub(crate) struct AssetReader<'a> {
    asset: &'a Asset,
    budget: ReadBudget,
    approval_budget: ReadBudget,
    position: u64,
}
impl Read for AssetReader<'_> {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        use std::os::unix::fs::FileExt;
        self.budget
            .check()
            .and_then(|_| self.approval_budget.check())
            .and_then(|_| self.asset.verify())
            .map_err(|_| std::io::Error::other("export asset authority"))?;
        let take = self
            .asset
            .version
            .2
            .saturating_sub(self.position)
            .min(bytes.len() as u64)
            .min(64 * 1024) as usize;
        if take > 0 {
            self.asset
                .file
                .read_exact_at(&mut bytes[..take], self.position)?;
            self.position += take as u64;
        }
        self.asset
            .verify()
            .and_then(|_| self.budget.check())
            .and_then(|_| self.approval_budget.check())
            .map_err(|_| std::io::Error::other("export asset changed or budget expired"))?;
        Ok(take)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::Cancellation;
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;
    pub(crate) fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(300), Cancellation::default()).unwrap()
    }
    pub(crate) fn fixture(root: &std::path::Path) -> ApprovedExportAssets {
        std::fs::create_dir_all(root).unwrap();
        let root = std::fs::canonicalize(root).unwrap();
        let names = if cfg!(target_os = "macos") {
            [
                "agent-rootfs.tar",
                "lib/libkrun.dylib",
                "lib/libkrunfw.5.dylib",
            ]
        } else {
            ["agent-rootfs.tar", "lib/libkrun.so", "lib/libkrunfw.so.5"]
        };
        let mut files = vec![];
        for name in names {
            let path = root.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            // Synthetic bytes exercise asset authority, not runtime bootability.
            let bytes = format!("synthetic {name}");
            std::fs::write(&path, &bytes).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
            files.push(ApprovedExportAsset {
                name: name.into(),
                path,
                sha256: format!("{:x}", Sha256::digest(bytes.as_bytes())),
                max_bytes: 1024,
            });
        }
        ApprovedExportAssets { files }
    }
    #[test]
    fn exact_catalog_digest_and_file_limits_precede_qualification() {
        let temp = tempfile::tempdir().unwrap();
        let approved = fixture(temp.path());
        let qualified = approved.qualify(&budget()).unwrap();
        let mut bytes = vec![];
        qualified
            .reader("agent-rootfs.tar", &budget())
            .unwrap()
            .read_to_end(&mut bytes)
            .unwrap();
        assert_eq!(bytes, b"synthetic agent-rootfs.tar");
        for change in 0..6 {
            let mut invalid = approved.clone();
            match change {
                0 => {
                    invalid.files.pop();
                }
                1 => invalid.files[1].name = invalid.files[0].name.clone(),
                2 => invalid.files[0].name = "../outside".into(),
                3 => invalid.files[0].sha256 = "0".repeat(64),
                4 => invalid.files[0].max_bytes = 1,
                _ => invalid.files[0].max_bytes = FILE_BYTES + 1,
            }
            assert!(invalid.qualify(&budget()).is_err());
        }
        let cancel = Cancellation::default();
        let original =
            ReadBudget::for_export_work(Duration::from_secs(30), cancel.clone()).unwrap();
        let qualified = approved.qualify(&original).unwrap();
        let mut reader = qualified.reader("agent-rootfs.tar", &budget()).unwrap();
        cancel.cancel();
        assert!(reader.read(&mut [0; 1]).is_err());
        assert!(qualified.verify().is_err());
        assert!(qualified.rehash(&budget()).is_err());
        assert!(qualified.reader("agent-rootfs.tar", &budget()).is_err());
        assert!(approved.qualify(&original).is_err());
    }
    #[test]
    fn replaced_changed_linked_or_writable_assets_never_retain_authority() {
        for change in 0..5 {
            let temp = tempfile::tempdir().unwrap();
            let approved = fixture(temp.path());
            let qualified = approved.qualify(&budget()).unwrap();
            let path = &approved.files[0].path;
            match change {
                0 => {
                    std::fs::rename(path, path.with_extension("retained")).unwrap();
                    std::fs::write(path, b"foreign").unwrap();
                }
                1 => {
                    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
                    std::fs::write(path, b"changed bytes").unwrap();
                    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o400)).unwrap();
                }
                2 => std::fs::hard_link(path, path.with_extension("link")).unwrap(),
                3 => {
                    std::fs::rename(path, path.with_extension("retained")).unwrap();
                    std::os::unix::fs::symlink(path.with_extension("retained"), path).unwrap();
                }
                _ => {
                    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o666)).unwrap()
                }
            }
            assert!(qualified.verify().is_err());
            assert!(qualified.reader("agent-rootfs.tar", &budget()).is_err());
            assert!(approved.qualify(&budget()).is_err());
        }
    }
    #[test]
    fn reader_retains_cancellation_and_checks_original_version_each_chunk() {
        let temp = tempfile::tempdir().unwrap();
        let approved = fixture(temp.path());
        let qualified = approved.qualify(&budget()).unwrap();
        let cancel = Cancellation::default();
        let work = ReadBudget::for_export_work(Duration::from_secs(30), cancel.clone()).unwrap();
        let mut reader = qualified.reader("agent-rootfs.tar", &work).unwrap();
        assert_eq!(reader.read(&mut [0; 1]).unwrap(), 1);
        cancel.cancel();
        assert!(reader.read(&mut [0; 1]).is_err());
        let mut reader = qualified.reader("agent-rootfs.tar", &budget()).unwrap();
        std::fs::set_permissions(
            &approved.files[0].path,
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        std::fs::write(&approved.files[0].path, b"replacement").unwrap();
        assert!(reader.read(&mut [0; 1]).is_err());
        assert!(!format!("{approved:?} {qualified:?}").contains(temp.path().to_str().unwrap()));
    }
}
