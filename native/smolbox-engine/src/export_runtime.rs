//! Bounded post-collection file custody. Inventory cannot enroll a child or
//! supply these snapshots without the original manager's collection authority.
use crate::{Error, ErrorCode, ReadBudget, Result};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const FILES: usize = 16;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Anchor(u64, u64, u32, u32);
impl Anchor {
    fn metadata(m: &std::fs::Metadata) -> Result<Self> {
        if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o022 != 0 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(Self(m.dev(), m.ino(), m.uid(), m.mode()))
    }
    fn verify(&self, file: &File, path: &Path) -> Result<()> {
        crate::host::unredirected(path)?;
        let held = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        let current = std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Io))?;
        if Self::metadata(&held)? != *self || Self::metadata(&current)? != *self {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    name: String,
    mode: u32,
    version: (u64, u64, u64, i64, i64, i64, i64),
}
#[allow(clippy::unnecessary_cast)] // libc mode_t is u16 on macOS and u32 on Linux.
impl Entry {
    fn capture(path: &Path, name: &str, socket: bool) -> Result<Self> {
        let m =
            std::fs::symlink_metadata(path.join(name)).map_err(|_| Error::before(ErrorCode::Io))?;
        let kind = m.mode() & (libc::S_IFMT as u32);
        if kind
            != if socket {
                libc::S_IFSOCK as u32
            } else {
                libc::S_IFREG as u32
            }
            || m.uid() != unsafe { libc::geteuid() }
            || m.nlink() != 1
            || (!socket && m.mode() & 0o022 != 0)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(Self {
            name: name.into(),
            mode: m.mode(),
            version: (
                m.dev(),
                m.ino(),
                m.len(),
                m.mtime(),
                m.mtime_nsec(),
                m.ctime(),
                m.ctime_nsec(),
            ),
        })
    }
    fn socket(&self) -> bool {
        self.mode & (libc::S_IFMT as u32) == libc::S_IFSOCK as u32
    }
    fn verify(&self, path: &Path, removing: bool) -> Result<bool> {
        if removing && absent(&path.join(&self.name)) {
            return Ok(false);
        }
        if Self::capture(path, &self.name, self.socket())? != *self {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(true)
    }
    fn validate(&self, maximum: u64, socket: bool) -> Result<()> {
        let kind = self.mode & (libc::S_IFMT as u32);
        if kind
            != if socket {
                libc::S_IFSOCK as u32
            } else {
                libc::S_IFREG as u32
            }
            || (!socket && self.mode & 0o022 != 0)
            || self.version.0 == 0
            || self.version.1 == 0
            || self.version.2 > maximum
            || !(0..1_000_000_000).contains(&self.version.4)
            || !(0..1_000_000_000).contains(&self.version.6)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Snapshot {
    root: Anchor,
    files: Vec<Entry>,
    rootfs_path: PathBuf,
    rootfs: Anchor,
    marker_name: String,
    marker: Option<Entry>,
}
fn limit(name: &str, plan: &crate::ExportConversionBudget) -> Result<(u64, bool)> {
    Ok(match name {
        "name" | "agent.pid" => (128, false),
        "storage.formatted" | "overlay.formatted" => (1, false),
        "storage.raw" => (plan.storage_gib * (1 << 30), false),
        "overlay.raw" => (plan.overlay_gib * (1 << 30), false),
        "export-source.qcow2" => (plan.source_storage_bytes * 2, false),
        "agent.config.json" | "boot-config.json" => (8 << 20, false),
        "agent-console.log" | "agent-startup-error.log" | "boot-debug.log" => (64 << 20, false),
        "vm.lock" => (0, false),
        // The SDK can leave the libkrun control endpoint in the original
        // helper directory after collection, alongside its agent sockets.
        "agent.sock" | "agent.ready" | "control.sock" => (4096, true),
        _ => return Err(Error::before(ErrorCode::Ownership)),
    })
}
fn marker_name(helper: &str) -> String {
    format!(
        "{}.{}",
        smolvm_protocol::AGENT_READY_MARKER,
        smolvm::agent::vm_dir_hash(helper)
    )
}
fn absent(path: &Path) -> bool {
    matches!(std::fs::symlink_metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound)
}
impl Snapshot {
    pub(crate) fn capture(
        root: &File,
        path: &Path,
        rootfs: &crate::export_source::Root,
        helper: &str,
        plan: &crate::ExportConversionBudget,
        budget: &ReadBudget,
    ) -> Result<Self> {
        budget.check()?;
        rootfs.verify()?;
        let anchor = Anchor::metadata(&root.metadata().map_err(|_| Error::before(ErrorCode::Io))?)?;
        anchor.verify(root, path)?;
        let marker_name = marker_name(helper);
        let marker = if absent(&rootfs.path().join(&marker_name)) {
            None
        } else {
            Some(Entry::capture(rootfs.path(), &marker_name, false)?)
        };
        let mut files = Vec::new();
        for entry in std::fs::read_dir(path).map_err(|_| Error::before(ErrorCode::Io))? {
            budget.check()?;
            if files.len() == FILES {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let name = entry
                .map_err(|_| Error::before(ErrorCode::Io))?
                .file_name()
                .into_string()
                .map_err(|_| Error::before(ErrorCode::Ownership))?;
            let (_, socket) = limit(&name, plan)?;
            files.push(Entry::capture(path, &name, socket)?);
        }
        files.sort_by(|a, b| a.name.cmp(&b.name));
        let snapshot = Self {
            root: anchor,
            files,
            rootfs_path: rootfs.path().into(),
            rootfs: Anchor::metadata(
                &rootfs
                    .descriptor()
                    .metadata()
                    .map_err(|_| Error::before(ErrorCode::Io))?,
            )?,
            marker_name,
            marker,
        };
        snapshot.validate(helper, plan)?;
        snapshot.verify(root, path, false, budget)?;
        Ok(snapshot)
    }
    pub(crate) fn validate(
        &self,
        helper: &str,
        plan: &crate::ExportConversionBudget,
    ) -> Result<()> {
        if self.files.len() > FILES
            || self.marker_name != marker_name(helper)
            || !self.rootfs_path.is_absolute()
            || self
                .rootfs_path
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
            || self.root.0 == 0
            || self.root.1 == 0
            || self.root.2 != unsafe { libc::geteuid() }
            || self.root.3 & 0o777 != 0o700
            || self.rootfs.0 == 0
            || self.rootfs.1 == 0
            || self.rootfs.2 != unsafe { libc::geteuid() }
            || self.rootfs.3 & 0o022 != 0
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut names = std::collections::BTreeSet::new();
        let mut bytes = 0u64;
        for entry in &self.files {
            let (maximum, socket) = limit(&entry.name, plan)?;
            entry.validate(maximum, socket)?;
            if match entry.name.as_str() {
                "name" => entry.version.2 != helper.len() as u64,
                // Post-collection custody is cleanup authority, not successful
                // launch/geometry evidence. A failed SDK formatting attempt can
                // leave a shorter raw file; the per-role maximum still applies.
                "export-source.qcow2" => entry.version.2 == 0,
                _ => false,
            } {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if !names.insert(&entry.name) || entry.version.0 != self.root.0 {
                return Err(Error::before(ErrorCode::Ownership));
            }
            bytes = bytes
                .checked_add(entry.version.2)
                .ok_or(Error::before(ErrorCode::Ownership))?;
        }
        if let Some(marker) = &self.marker {
            marker.validate(4096, false)?;
            if marker.name != self.marker_name || marker.version.0 != self.rootfs.0 {
                return Err(Error::before(ErrorCode::Ownership));
            }
            bytes = bytes
                .checked_add(marker.version.2)
                .ok_or(Error::before(ErrorCode::Ownership))?;
        }
        if ["name", "storage.raw", "overlay.raw", "export-source.qcow2"]
            .iter()
            .any(|name| !names.contains(&name.to_string()))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if bytes > plan.private_disk_bytes {
            return Err(Error::before(ErrorCode::Admission));
        }
        Ok(())
    }
    pub(crate) fn verify(
        &self,
        root: &File,
        path: &Path,
        removing: bool,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.root.verify(root, path)?;
        let mut count = 0;
        for entry in std::fs::read_dir(path).map_err(|_| Error::before(ErrorCode::Io))? {
            budget.check()?;
            count += 1;
            if count > FILES {
                return Err(Error::before(ErrorCode::Ownership));
            }
            let name = entry
                .map_err(|_| Error::before(ErrorCode::Io))?
                .file_name()
                .into_string()
                .map_err(|_| Error::before(ErrorCode::Ownership))?;
            let expected = self
                .files
                .iter()
                .find(|e| e.name == name)
                .ok_or(Error::before(ErrorCode::Ownership))?;
            expected.verify(path, false)?;
        }
        if !removing && count != self.files.len() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if !removing {
            let name = self
                .files
                .iter()
                .find(|e| e.name == "name")
                .ok_or(Error::before(ErrorCode::Ownership))?;
            name.verify(path, false)?;
            let mut bytes = Vec::new();
            std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
                .open(path.join("name"))
                .map_err(|_| Error::before(ErrorCode::Io))?
                .take(129)
                .read_to_end(&mut bytes)
                .map_err(|_| Error::before(ErrorCode::Io))?;
            // The marker encodes the exact helper hash; the retained name file
            // must still name that same helper before retirement is enrolled.
            let text =
                std::str::from_utf8(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
            if marker_name(text) != self.marker_name {
                return Err(Error::before(ErrorCode::Ownership));
            }
            name.verify(path, false)?;
        }
        self.verify_marker(removing)?;
        self.root.verify(root, path)?;
        budget.check()
    }
    fn verify_marker(&self, removing: bool) -> Result<crate::export_source::Root> {
        let rootfs = crate::export_source::Root::open(&self.rootfs_path)?;
        self.rootfs.verify(rootfs.descriptor(), rootfs.path())?;
        if let Some(marker) = &self.marker {
            marker.verify(rootfs.path(), removing)?;
        } else if !absent(&rootfs.path().join(&self.marker_name)) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(rootfs)
    }
    pub(crate) fn remove_files(&self, root: &File, path: &Path, budget: &ReadBudget) -> Result<()> {
        self.verify(root, path, true, budget)?;
        let rootfs = self.verify_marker(true)?;
        if let Some(marker) = &self.marker {
            budget.check()?;
            if marker.verify(rootfs.path(), true)? {
                unlink(rootfs.descriptor(), &marker.name)?;
            }
        }
        rootfs
            .descriptor()
            .sync_all()
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        for entry in &self.files {
            budget.check()?;
            self.root.verify(root, path)?;
            if entry.verify(path, true)? {
                unlink(root, &entry.name)?;
            }
        }
        root.sync_all()
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        self.verify_removed_marker()?;
        Ok(())
    }
    pub(crate) fn verify_removed_marker(&self) -> Result<()> {
        self.verify_marker(true)?;
        if !absent(&self.rootfs_path.join(&self.marker_name)) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn bound_rootfs(&self, rootfs: &crate::export_source::Root) -> Result<()> {
        if self.rootfs_path != rootfs.path() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.rootfs.verify(rootfs.descriptor(), rootfs.path())
    }
}
fn unlink(root: &File, name: &str) -> Result<()> {
    let name = std::ffi::CString::new(name).map_err(|_| Error::before(ErrorCode::Ownership))?;
    if unsafe { libc::unlinkat(root.as_raw_fd(), name.as_ptr(), 0) } != 0 {
        return Err(Error::uncertain(ErrorCode::Io));
    }
    Ok(())
}
