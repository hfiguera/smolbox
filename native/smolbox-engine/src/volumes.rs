//! Linux volume root qualification. A qualified root is neither ownership of a
//! child directory nor guest-write qualification. Provision/delete must obtain
//! separate durable operation evidence; directory inventory cannot supply it.
use crate::{Engine, Error, ErrorCode, ReadBudget, Result};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

pub const VOLUME_WORK_MS: u64 = 86_400_000;
pub const VOLUME_OBSERVATION_MS: u64 = 30_000;
pub const VOLUME_RECORD_BYTES: usize = 16 * 1024;
pub const VOLUME_DELETE_ENTRIES: usize = 1_000_000;
pub const VOLUME_ANCESTOR_BYTES: usize = 4096;
pub const VOLUME_OBSERVATION_METADATA_BYTES: u64 = 128 * 1024;

#[path = "volume_staging.rs"]
mod staging;
pub(crate) use staging::remove_tree as remove_owned_tree;
#[cfg(test)]
pub(crate) use staging::{foreign_handle, owned_handle};
pub use staging::{
    QualifiedVolumeMounts, VolumeAccount, VolumeDeletionPermit, VolumeDeletionPresence,
    VolumeDeletionReceipt, VolumeMountRequest, VolumeMountSelection, VolumeProvisionPresence,
    VolumeProvisionReceipt, VolumeStagingAbortPresence, VolumeStagingAbortReceipt,
    VolumeStagingPresence, VolumeStagingReceipt, VOLUME_MOUNTS,
};

/// The exact operator-approved root, not an arbitrary managed host mount.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LocalVolumePolicy {
    pub id: String,
    pub root: PathBuf,
}
impl std::fmt::Debug for LocalVolumePolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocalVolumePolicy")
            .field("id", &self.id)
            .finish_non_exhaustive()
    }
}
impl LocalVolumePolicy {
    pub fn validate(&self) -> Result<()> {
        let path = self
            .root
            .to_str()
            .ok_or(Error::before(ErrorCode::Validation))?;
        if !crate::domain::valid_id(&self.id)
            || !self.root.is_absolute()
            || path.len() > 4059
            || path.contains('\0')
            || path.contains('\\')
            || path.contains("//")
            || path.ends_with('/')
            || path.split('/').any(|part| matches!(part, "." | ".."))
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }

    /// Canonical SDK 1.22.0 node-local volume root. This read never creates a
    /// directory and rejects the SDK handler's relative-path fallback.
    pub fn canonical_sdk_root() -> Result<PathBuf> {
        let base = dirs::data_local_dir().ok_or(Error::before(ErrorCode::Unsupported))?;
        if !base.is_absolute() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        std::fs::canonicalize(base.join("smolvm").join("volumes"))
            .map_err(|_| Error::before(ErrorCode::Ownership))
    }
}

/// Receipt-free provision intent. Size is an admission declaration, not a
/// filesystem quota. Generated IDs cannot address unrelated SDK directories.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LocalVolumeIntent {
    pub worker_volume_id: String,
    pub size_gb: u64,
}
impl std::fmt::Debug for LocalVolumeIntent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocalVolumeIntent")
            .field("size_gb", &self.size_gb)
            .finish_non_exhaustive()
    }
}
impl LocalVolumeIntent {
    pub fn validate(&self) -> Result<()> {
        if !self
            .worker_volume_id
            .strip_prefix("sbv-")
            .is_some_and(|id| crate::domain::valid_hex(id, 32))
            || !(1..=1024).contains(&self.size_gb)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}

/// Open descriptor bound to the selected root. No child inventory, path or
/// directory bits grant ownership. Recheck before future descriptor-relative IO.
pub struct QualifiedVolumeRoot {
    policy: LocalVolumePolicy,
    directory: File,
    identity: (u64, u64),
    // Descriptor admission lasts as long as the qualified handle, not just the
    // request that opened it. Fixtures use no engine pool.
    _lease: Option<crate::jobs::JobLease>,
}
impl std::fmt::Debug for QualifiedVolumeRoot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QualifiedVolumeRoot")
            .finish_non_exhaustive()
    }
}
impl QualifiedVolumeRoot {
    fn open(policy: &LocalVolumePolicy, expected: &Path, budget: &ReadBudget) -> Result<Self> {
        budget.check()?;
        policy.validate()?;
        if policy.root != expected {
            return Err(Error::before(ErrorCode::Ownership));
        }
        crate::host::unredirected(&policy.root)?;
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&policy.root)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let metadata = directory
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let root = Self {
            policy: policy.clone(),
            directory,
            identity: (metadata.dev(), metadata.ino()),
            _lease: None,
        };
        root.verify(budget)?;
        Ok(root)
    }

    /// Read-only identity check; substitution or unsafe root permissions cannot
    /// authorize repair, adoption or removal of the replacement path.
    pub fn verify(&self, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        crate::host::unredirected(&self.policy.root)?;
        let descriptor = self
            .directory
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let path = std::fs::symlink_metadata(&self.policy.root)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let uid = unsafe { libc::geteuid() };
        for metadata in [descriptor, path] {
            if !metadata.is_dir()
                || (metadata.dev(), metadata.ino()) != self.identity
                || metadata.uid() != uid
                || metadata.mode() & 0o7022 != 0
                || metadata.mode() & 0o700 != 0o700
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        budget.check()
    }
}

impl Engine {
    /// Pre-dispatch Linux root feasibility only. Does not provision a volume or
    /// prove that isolated guest UIDs can write after normal helper replacement.
    pub fn qualify_volume_root(
        &self,
        policy: &LocalVolumePolicy,
        budget: &ReadBudget,
    ) -> Result<QualifiedVolumeRoot> {
        budget.check()?;
        policy.validate()?;
        if !cfg!(target_os = "linux") {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let job = self.jobs.acquire(crate::jobs::Demand::volume_root())?;
        self.domain.verify()?;
        let expected = LocalVolumePolicy::canonical_sdk_root()?;
        let mut root = QualifiedVolumeRoot::open(policy, &expected, budget)?;
        root._lease = Some(job);
        Ok(root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Cancellation;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::time::Duration;

    pub(super) fn budget() -> ReadBudget {
        ReadBudget::new(Duration::from_secs(2), Cancellation::default()).unwrap()
    }
    pub(super) fn fixture() -> (tempfile::TempDir, LocalVolumePolicy) {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap().join("volumes");
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
        (
            dir,
            LocalVolumePolicy {
                id: "local".into(),
                root,
            },
        )
    }

    #[test]
    fn volume_intent_accepts_only_generated_ids_and_shared_admission_bounds() {
        let mut intent = LocalVolumeIntent {
            worker_volume_id: format!("sbv-{}", "a".repeat(32)),
            size_gb: 1024,
        };
        intent.validate().unwrap();
        for id in ["vol-abc", "../sbv-a", "sbv-ABC", "sbv-", "sbv-000/../x"] {
            intent.worker_volume_id = id.into();
            assert_eq!(intent.validate().unwrap_err().code, ErrorCode::Validation);
        }
        intent.worker_volume_id = format!("sbv-{}", "0".repeat(32));
        for size in [0, 1025, u64::MAX] {
            intent.size_gb = size;
            assert!(intent.validate().is_err());
        }
        assert!(serde_json::from_str::<LocalVolumeIntent>(r#"{"worker_volume_id":"sbv-00000000000000000000000000000000","size_gb":1,"receipt":{}}"#).is_err());
    }

    #[test]
    fn volume_policy_rejects_ambiguous_or_unbounded_paths() {
        let (_, mut policy) = fixture();
        policy.validate().unwrap();
        for path in [
            "relative", "/", "/a/", "/a//b", "/a/../b", "/a/./b", "/a\\b", "/a\0b",
        ] {
            policy.root = path.into();
            assert!(policy.validate().is_err(), "{path:?}");
        }
        policy.root = format!("/{}", "a".repeat(4059)).into();
        assert!(policy.validate().is_err());
    }

    #[test]
    fn root_qualification_is_read_only_and_rejects_other_policy_roots() {
        let (_dir, policy) = fixture();
        let root = QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).unwrap();
        root.verify(&budget()).unwrap();
        assert_eq!(std::fs::read_dir(&policy.root).unwrap().count(), 0);
        assert!(QualifiedVolumeRoot::open(&policy, Path::new("/different"), &budget()).is_err());
        assert!(!format!("{root:?}").contains(policy.root.to_str().unwrap()));
    }

    #[test]
    fn root_qualification_rejects_links_files_and_missing_paths_without_repair() {
        let (_dir, policy) = fixture();
        std::fs::remove_dir(&policy.root).unwrap();
        assert!(QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).is_err());
        assert!(!policy.root.exists());
        std::fs::write(&policy.root, b"foreign").unwrap();
        assert!(QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).is_err());
        std::fs::remove_file(&policy.root).unwrap();
        symlink(policy.root.parent().unwrap(), &policy.root).unwrap();
        assert!(QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).is_err());
    }

    #[test]
    fn root_descriptor_detects_substitution_and_keeps_foreign_content() {
        let (_dir, policy) = fixture();
        let root = QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).unwrap();
        std::fs::rename(&policy.root, policy.root.with_extension("original")).unwrap();
        std::fs::create_dir(&policy.root).unwrap();
        std::fs::write(policy.root.join("foreign"), b"preserve").unwrap();
        assert_eq!(
            root.verify(&budget()).unwrap_err().code,
            ErrorCode::Ownership
        );
        assert_eq!(
            std::fs::read(policy.root.join("foreign")).unwrap(),
            b"preserve"
        );
    }

    #[test]
    fn root_permissions_are_checked_on_open_and_reverification_without_chmod() {
        let (_dir, policy) = fixture();
        let root = QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).unwrap();
        for mode in [0o777, 0o775, 0o757, 0o4755, 0o2755, 0o1755, 0o500] {
            std::fs::set_permissions(&policy.root, std::fs::Permissions::from_mode(mode)).unwrap();
            assert!(root.verify(&budget()).is_err());
            assert!(QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).is_err());
            assert_eq!(
                std::fs::metadata(&policy.root).unwrap().mode() & 0o7777,
                mode
            );
        }
    }

    #[test]
    fn root_qualification_honors_pre_dispatch_cancellation() {
        let (_dir, policy) = fixture();
        let cancel = Cancellation::default();
        cancel.cancel();
        let budget = ReadBudget::new(Duration::from_secs(2), cancel).unwrap();
        assert_eq!(
            QualifiedVolumeRoot::open(&policy, &policy.root, &budget)
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        assert_eq!(std::fs::read_dir(&policy.root).unwrap().count(), 0);
    }

    #[test]
    fn qualified_root_retains_descriptor_admission_without_using_control_slots() {
        let (_dir, policy) = fixture();
        let pool = crate::jobs::JobPool::default();
        let mut root = QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).unwrap();
        root._lease = Some(pool.acquire(crate::jobs::Demand::volume_root()).unwrap());
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().descriptors, 4);
        let control = [
            pool.acquire(crate::jobs::Demand::observation()).unwrap(),
            pool.acquire(crate::jobs::Demand::observation()).unwrap(),
        ];
        assert_eq!(pool.counts().control, 2);
        root.verify(&budget()).unwrap();
        drop(root);
        assert_eq!(pool.counts().work, 0);
        assert_eq!(pool.counts().descriptors, 8);
        drop(control);
        assert_eq!(pool.counts().descriptors, 0);
    }
}
