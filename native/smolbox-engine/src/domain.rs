use crate::{Error, ErrorCode, Result};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DomainBinding {
    pub target_id: String,
    /// Operator-selected generation; never regenerated on helper restart.
    pub generation: String,
    pub database: PathBuf,
    pub vm_root: PathBuf,
}

impl std::fmt::Debug for DomainBinding {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DomainBinding")
            .field("target_id", &self.target_id)
            .finish_non_exhaustive()
    }
}

impl DomainBinding {
    pub fn default_paths(target_id: String, generation: String) -> Result<Self> {
        Ok(Self {
            target_id,
            generation,
            database: smolvm::db::SmolvmDb::default_path()
                .map_err(|_| Error::before(ErrorCode::Database))?,
            vm_root: smolvm::agent::vm_cache_root(),
        })
    }

    pub(crate) fn validate(&self) -> Result<()> {
        if !valid_id(&self.target_id)
            || !valid_hex(&self.generation, 32)
            || !self.database.is_absolute()
            || !self.vm_root.is_absolute()
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        // A DB override does not isolate lower runtime/cache lookups.
        let defaults = Self::default_paths(self.target_id.clone(), self.generation.clone())?;
        if self.database != defaults.database || self.vm_root != defaults.vm_root {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        Ok(())
    }
}

pub(crate) fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

pub(crate) fn valid_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(crate) struct DomainGuard {
    // The open file holds the OS lock until the engine's handles have shut down.
    _lock: File,
    _account_lock: Option<File>,
    pub directory: PathBuf,
    directory_identity: (u64, u64),
    binding_identity: (u64, u64),
    descriptor: String,
}

impl DomainGuard {
    pub fn acquire(binding: &DomainBinding, allow_initialize: bool) -> Result<Self> {
        binding.validate()?;
        // Default lookups can depend on XDG variables. A lock only under that
        // path would allow two helpers with different environments for one OS
        // account. The account lock is independent of those path overrides.
        let account_path = PathBuf::from(format!("/tmp/smolbox-native-{}.lock", unsafe {
            libc::geteuid()
        }));
        let account_lock = private_open(&account_path, true)?;
        if unsafe { libc::flock(account_lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let directory = binding
            .database
            .parent()
            .ok_or(Error::before(ErrorCode::Validation))?
            .join("smolbox");
        let mut guard = Self::acquire_at(binding, directory, allow_initialize)?;
        guard._account_lock = Some(account_lock);
        Ok(guard)
    }

    pub(crate) fn acquire_at(
        binding: &DomainBinding,
        directory: PathBuf,
        allow_initialize: bool,
    ) -> Result<Self> {
        if !directory.is_absolute()
            || directory.components().any(|component| {
                matches!(
                    component,
                    std::path::Component::ParentDir | std::path::Component::CurDir
                )
            })
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        for ancestor in directory.ancestors().collect::<Vec<_>>().into_iter().rev() {
            match std::fs::symlink_metadata(ancestor) {
                Ok(metadata) if metadata.is_dir() => {}
                Ok(_) => return Err(Error::before(ErrorCode::Ownership)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
                Err(_) => return Err(Error::before(ErrorCode::Io)),
            }
        }
        if !directory.exists() && !allow_initialize {
            return Err(Error::before(ErrorCode::Ownership));
        }
        std::fs::create_dir_all(&directory).map_err(|_| Error::before(ErrorCode::Io))?;
        let metadata =
            std::fs::symlink_metadata(&directory).map_err(|_| Error::before(ErrorCode::Io))?;
        if !metadata.is_dir()
            || metadata.file_type().is_symlink()
            || metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let lock = private_open(&directory.join("domain.lock"), true)?;
        // Nonblocking: a second bridge must fail instead of becoming a second
        // reservation authority. flock applies across separate helper processes.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let descriptor = format!(
            "smolbox-native-domain-v1\n{}\n{}\n{}\n{}\n",
            binding.target_id,
            binding.generation,
            binding
                .database
                .to_str()
                .ok_or(Error::before(ErrorCode::Validation))?,
            binding
                .vm_root
                .to_str()
                .ok_or(Error::before(ErrorCode::Validation))?
        );
        if descriptor.len() > 4096 || descriptor.lines().count() != 5 {
            return Err(Error::before(ErrorCode::Validation));
        }
        let path = directory.join("domain.binding");
        match private_open(&path, false) {
            Ok(mut file) => {
                let mut actual = String::new();
                Read::by_ref(&mut file)
                    .take(4097)
                    .read_to_string(&mut actual)
                    .map_err(|_| Error::before(ErrorCode::Io))?;
                if actual != descriptor {
                    return Err(Error::before(ErrorCode::Ownership));
                }
            }
            Err(_) if allow_initialize && !path.exists() => {
                // Atomic publication: no partial generation is accepted after a
                // crash, and initialization never overwrites an existing binding.
                let mut staged = tempfile::NamedTempFile::new_in(&directory)
                    .map_err(|_| Error::before(ErrorCode::Io))?;
                staged
                    .write_all(descriptor.as_bytes())
                    .map_err(|_| Error::before(ErrorCode::Io))?;
                staged
                    .as_file()
                    .sync_all()
                    .map_err(|_| Error::before(ErrorCode::Io))?;
                staged
                    .persist_noclobber(&path)
                    .map_err(|_| Error::before(ErrorCode::Conflict))?;
                File::open(&directory)
                    .and_then(|f| f.sync_all())
                    .map_err(|_| Error::before(ErrorCode::Io))?;
            }
            Err(error) => return Err(error),
        }
        Ok(Self {
            _lock: lock,
            _account_lock: None,
            directory,
            directory_identity: (metadata.dev(), metadata.ino()),
            binding_identity: {
                let metadata =
                    std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Io))?;
                (metadata.dev(), metadata.ino())
            },
            descriptor,
        })
    }

    pub(crate) fn verify(&self) -> Result<()> {
        crate::host::unredirected(&self.directory)?;
        let metadata =
            std::fs::metadata(&self.directory).map_err(|_| Error::before(ErrorCode::Ownership))?;
        if !metadata.is_dir()
            || (metadata.dev(), metadata.ino()) != self.directory_identity
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o700
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        verify_lock(&self._lock, &self.directory.join("domain.lock"))?;
        if let Some(lock) = &self._account_lock {
            verify_lock(
                lock,
                &PathBuf::from(format!("/tmp/smolbox-native-{}.lock", unsafe {
                    libc::geteuid()
                })),
            )?;
        }
        let mut file = private_open(&self.directory.join("domain.binding"), false)?;
        let metadata = file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let mut actual = String::new();
        Read::by_ref(&mut file)
            .take(4097)
            .read_to_string(&mut actual)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if (metadata.dev(), metadata.ino()) != self.binding_identity || actual != self.descriptor {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

fn verify_lock(file: &File, path: &Path) -> Result<()> {
    let pinned = file
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    let named = std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !named.is_file()
        || (named.dev(), named.ino()) != (pinned.dev(), pinned.ino())
        || named.uid() != unsafe { libc::geteuid() }
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

fn private_open(path: &Path, create: bool) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(create)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_cannot_alias_storage_roots() {
        for invalid in [".", "..", "../owned", "owned/other"] {
            assert!(!valid_id(invalid));
        }
        for valid in ["owned", "owned-1", ".owned", "owned.test"] {
            assert!(valid_id(valid));
        }
    }

    #[test]
    fn lock_and_generation_prevent_duplicate_or_rebound_domains() {
        let temp = tempfile::tempdir().unwrap();
        let directory = temp.path().canonicalize().unwrap().join("owned");
        let mut binding = DomainBinding {
            target_id: "local".into(),
            generation: "a".repeat(32),
            database: temp.path().join("db"),
            vm_root: temp.path().join("vms"),
        };
        assert!(DomainGuard::acquire_at(&binding, directory.clone(), false).is_err());
        let guard = DomainGuard::acquire_at(&binding, directory.clone(), true).unwrap();
        assert!(matches!(
            DomainGuard::acquire_at(&binding, directory.clone(), true),
            Err(Error {
                code: ErrorCode::Conflict,
                ..
            })
        ));
        drop(guard);
        binding.generation = "b".repeat(32);
        assert!(matches!(
            DomainGuard::acquire_at(&binding, directory.clone(), true),
            Err(Error {
                code: ErrorCode::Ownership,
                ..
            })
        ));
        binding.generation = "a".repeat(32);
        let _guard = DomainGuard::acquire_at(&binding, directory, false).unwrap();
    }

    #[test]
    fn arbitrary_database_override_is_not_domain_isolation() {
        let mut binding = DomainBinding::default_paths("local".into(), "a".repeat(32)).unwrap();
        binding.database = PathBuf::from("/different/database");
        assert_eq!(binding.validate().unwrap_err().code, ErrorCode::Unsupported);
    }

    #[test]
    fn changed_domain_descriptor_or_lock_cannot_release_observed_capacity() {
        for replace_lock in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let root = temp.path().canonicalize().unwrap();
            let binding = DomainBinding {
                target_id: "owned".into(),
                generation: "a".repeat(32),
                database: root.join("db"),
                vm_root: root.join("vms"),
            };
            let directory = root.join("owned");
            let guard = DomainGuard::acquire_at(&binding, directory.clone(), true).unwrap();
            guard.verify().unwrap();
            let path = directory.join(if replace_lock {
                "domain.lock"
            } else {
                "domain.binding"
            });
            std::fs::rename(&path, path.with_extension("saved")).unwrap();
            std::fs::write(&path, b"replacement").unwrap();
            assert_eq!(guard.verify().unwrap_err().code, ErrorCode::Ownership);
        }
    }
}
