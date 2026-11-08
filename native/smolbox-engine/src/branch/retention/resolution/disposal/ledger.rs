//! Private no-follow, bounded, synchronized single-entry disposal history.
use super::*;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;
type Version = crate::checkpoint_materialize::FileVersion;
const MAX_BYTES: u64 = 64 * 1024;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Intent {
    pub creation: BranchCreateRequest,
    pub request: UnbootedBranchDisposalRequest,
    pub publication: crate::BranchPublication,
    pub metadata_sha256: String,
    pub source: Directory,
    pub child: Directory,
    pub snapshot: Directory,
}
impl Intent {
    fn validate(&self) -> Result<()> {
        self.request.validate(&self.creation)?;
        self.publication.validate()?;
        self.publication
            .change
            .child_origin
            .intent
            .matches_creation(&self.creation)?;
        if !crate::domain::valid_hex(&self.metadata_sha256, 64)
            || self.source.path.file_name()
                != Some(smolvm::agent::vm_dir_hash(&self.creation.source.name).as_ref())
            || self.child.path
                != self
                    .source
                    .path
                    .parent()
                    .ok_or(Error::before(ErrorCode::Ownership))?
                    .join(smolvm::agent::vm_dir_hash(&self.creation.child.name))
            || self.snapshot.path
                != self
                    .source
                    .path
                    .join("s")
                    .join(&self.publication.change.child_origin.generation)
            || [&self.source, &self.child, &self.snapshot]
                .into_iter()
                .any(|root| {
                    !root.path.is_absolute()
                        || root.path.as_os_str().len() > 4096
                        || root.inode == 0
                })
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Stage {
    Entered,
    Deleted,
    ResolvedAbsent,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Record {
    pub schema: u8,
    pub intent: Intent,
    pub stage: Stage,
    pub proof: Option<UnbootedBranchDisposal>,
}
impl Record {
    fn validate(&self) -> Result<()> {
        self.intent.validate()?;
        if self.schema != 1 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match (&self.stage, &self.proof) {
            (Stage::Entered, None) => Ok(()),
            (stage @ (Stage::Deleted | Stage::ResolvedAbsent), Some(proof)) => {
                proof.validate()?;
                let completion = if *stage == Stage::Deleted {
                    UnbootedBranchDisposalCompletion::Deleted
                } else {
                    UnbootedBranchDisposalCompletion::ResolvedAbsent
                };
                if *proof != UnbootedBranchDisposal::issue(&self.intent, completion)? {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                Ok(())
            }
            _ => Err(Error::before(ErrorCode::Ownership)),
        }
    }
}
pub(super) struct Ledger {
    domain: Arc<crate::domain::DomainGuard>,
    path: PathBuf,
}
impl Ledger {
    #[cfg(test)]
    pub(super) fn path(&self) -> &std::path::Path {
        &self.path
    }
    pub(super) fn new(
        domain: Arc<crate::domain::DomainGuard>,
        creation: &BranchCreateRequest,
    ) -> Result<Self> {
        let key = crate::material::hash(&("smolbox-unbooted-branch-disposal-v1", creation))?;
        Ok(Self {
            path: domain
                .directory
                .join(format!("branch-unbooted-disposal-{key}.json")),
            domain,
        })
    }
    pub(super) fn read(&self) -> Result<Option<(Record, Version)>> {
        self.domain.verify()?;
        match std::fs::symlink_metadata(&self.path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(Error::before(ErrorCode::Ownership)),
            _ => {}
        }
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&self.path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let info = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if !info.is_file()
            || info.nlink() != 1
            || info.uid() != unsafe { libc::geteuid() }
            || info.mode() & 0o777 != 0o600
            || info.len() > MAX_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let version = Version::of(&info);
        let mut bytes = Vec::new();
        std::io::Read::by_ref(&mut file)
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        let record: Record =
            serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
        record.validate()?;
        if Self::new(self.domain.clone(), &record.intent.creation)?.path != self.path {
            return Err(Error::before(ErrorCode::Ownership));
        }
        for metadata in [file.metadata(), std::fs::symlink_metadata(&self.path)] {
            if Version::of(&metadata.map_err(|_| Error::before(ErrorCode::Ownership))?) != version {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        self.domain.verify()?;
        Ok(Some((record, version)))
    }
    pub(super) fn write(&self, record: &Record, previous: Option<Version>) -> Result<()> {
        record.validate()?;
        self.domain.verify()?;
        if Self::new(self.domain.clone(), &record.intent.creation)?.path != self.path {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let bytes = serde_json::to_vec(record).map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        let mut file = tempfile::NamedTempFile::new_in(&self.domain.directory)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        file.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))
            .and_then(|()| file.write_all(&bytes))
            .and_then(|()| file.as_file().sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        self.domain.verify()?;
        if let Some(version) = previous {
            if self.read()?.ok_or(Error::before(ErrorCode::Ownership))?.1 != version {
                return Err(Error::before(ErrorCode::Ownership));
            }
            file.persist(&self.path)
                .map_err(|_| Error::before(ErrorCode::Io))?;
        } else {
            file.persist_noclobber(&self.path)
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
        }
        File::open(&self.domain.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))
    }
    /// A visible completion may follow a failed earlier directory sync. Exact
    /// acknowledgement recovery must synchronize again before retiring work.
    pub(super) fn synchronize(&self, version: &Version) -> Result<()> {
        self.domain.verify()?;
        if self.read()?.ok_or(Error::before(ErrorCode::Ownership))?.1 != *version {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&self.path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if Version::of(&file.metadata().map_err(|_| Error::before(ErrorCode::Io))?) != *version {
            return Err(Error::before(ErrorCode::Ownership));
        }
        file.sync_all().map_err(|_| Error::before(ErrorCode::Io))?;
        OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&self.domain.directory)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        self.domain.verify()?;
        if Version::of(&file.metadata().map_err(|_| Error::before(ErrorCode::Io))?) != *version
            || self.read()?.ok_or(Error::before(ErrorCode::Ownership))?.1 != *version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
