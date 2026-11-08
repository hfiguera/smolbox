//! Approved assets for the clean SDK's home/executable template resolver.
//! Installation never relocates HOME, overwrites conflicts or removes references.
use crate::domain::valid_hex;
use crate::host::{private_directory, unredirected};
use crate::{DomainBinding, Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

const MAX_BYTES: u64 = 32 * 1024 * 1024 * 1024;
const BLOCK: usize = 64 * 1024;
const NAMES: [&str; 2] = ["storage-template.ext4", "overlay-template.ext4"];

/// The clean SDK copies template permissions to a new backing disk. Keep
/// approved account templates immutable, but make only newly created owned
/// backing files writable before publishing a receipt or attempting boot.
pub(crate) fn prepare_created_disk(path: &Path) -> Result<()> {
    unredirected(path)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let before = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !before.is_file()
        || before.uid() != unsafe { libc::geteuid() }
        || before.nlink() != 1
        || !matches!(before.mode() & 0o777, 0o400 | 0o444 | 0o600 | 0o644)
        || before.len() == 0
        || before.len() > 1024 * 1024 * 1024 * 1024
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    file.set_permissions(std::fs::Permissions::from_mode(0o600))
        .and_then(|()| file.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    unredirected(path)?;
    let after = std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Io))?;
    if after.dev() != before.dev() || after.ino() != before.ino() || after.mode() & 0o777 != 0o600 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TemplateFile {
    pub path: PathBuf,
    pub sha256: String,
    pub bytes: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovedTemplate {
    pub plain: TemplateFile,
    pub compressed: TemplateFile,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovedTemplates {
    pub storage: ApprovedTemplate,
    pub overlay: ApprovedTemplate,
}

#[derive(PartialEq, Eq)]
struct Stamp {
    device: u64,
    inode: u64,
    length: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
    mode: u32,
    uid: u32,
}
fn stamp(metadata: &std::fs::Metadata) -> Result<Stamp> {
    if !metadata.is_file() || metadata.mode() & 0o022 != 0 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(Stamp {
        device: metadata.dev(),
        inode: metadata.ino(),
        length: metadata.len(),
        mtime: (metadata.mtime(), metadata.mtime_nsec()),
        ctime: (metadata.ctime(), metadata.ctime_nsec()),
        mode: metadata.mode(),
        uid: metadata.uid(),
    })
}

struct Candidate {
    path: PathBuf,
    stamp: Option<Stamp>,
}
/// Verified candidates plus authenticated account references. Cheap rechecks
/// reject changes before SDK dispatch; hashes are established during preparation.
pub(crate) struct PreparedTemplates {
    candidates: Vec<Candidate>,
    roots: Vec<PathBuf>,
}
impl PreparedTemplates {
    pub(crate) fn verify(&self) -> Result<()> {
        for root in &self.roots {
            directory(root)?;
        }
        for candidate in &self.candidates {
            let actual = optional_stamp(&candidate.path)?;
            if actual != candidate.stamp {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
}

#[derive(Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct References {
    schema: u32,
    source_revision: String,
    package_sha256: String,
    domain: DomainBinding,
    account_directory: PathBuf,
    templates: ApprovedTemplates,
}

impl ApprovedTemplates {
    pub(crate) fn prepare(
        &self,
        domain: &DomainBinding,
        owned_directory: &Path,
        package_sha256: &str,
    ) -> Result<PreparedTemplates> {
        let account = dirs::home_dir()
            .ok_or(Error::before(ErrorCode::Unsupported))?
            .join(".smolvm");
        let executable = std::env::current_exe().map_err(|_| Error::before(ErrorCode::Io))?;
        let mut roots = vec![account.clone(), parent(&executable)?];
        // The future immutable launcher can also invoke SDK resolution. Verify
        // its directory, while keeping the account's plain file first.
        let boot =
            std::env::var_os("SMOLVM_BOOT_BINARY").ok_or(Error::before(ErrorCode::Unsupported))?;
        let boot_root = parent(Path::new(&boot))?;
        if !roots.contains(&boot_root) {
            roots.push(boot_root);
        }
        self.prepare_at(domain, owned_directory, package_sha256, account, roots)
    }

    fn prepare_at(
        &self,
        domain: &DomainBinding,
        owned_directory: &Path,
        package_sha256: &str,
        account: PathBuf,
        roots: Vec<PathBuf>,
    ) -> Result<PreparedTemplates> {
        if !valid_hex(package_sha256, 64) || roots.first() != Some(&account) {
            return Err(Error::before(ErrorCode::Validation));
        }
        private_directory(owned_directory)?;
        for (name, approved) in self.entries() {
            approved.validate(name)?;
        }
        unredirected(&parent(&account)?)?;
        if std::fs::symlink_metadata(&account)
            .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
        {
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&account)
                .map_err(|_| Error::before(ErrorCode::Io))?;
        }
        directory(&account)?;
        if std::fs::metadata(&account)
            .map_err(|_| Error::before(ErrorCode::Io))?
            .uid()
            != unsafe { libc::geteuid() }
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // Validate every possible plain/compressed selection before publishing
        // either account file. Existence never authorizes adopting a conflict.
        for root in &roots {
            directory(root)?;
            for (name, approved) in self.entries() {
                for (filename, evidence) in [
                    (name.to_string(), &approved.plain),
                    (format!("{name}.zst"), &approved.compressed),
                ] {
                    let path = root.join(filename);
                    if optional_stamp(&path)?.is_some() {
                        verify_file(&path, evidence)?;
                    }
                }
            }
        }
        for (name, approved) in self.entries() {
            let destination = account.join(name);
            if optional_stamp(&destination)?.is_none() {
                install_sparse(&approved.plain, &destination)?;
            }
            verify_file(&destination, &approved.plain)?;
        }
        let references = References {
            schema: 1,
            source_revision: crate::SMOLVM_REVISION.into(),
            package_sha256: package_sha256.into(),
            domain: domain.clone(),
            account_directory: account,
            templates: self.clone(),
        };
        record_references(owned_directory, &references)?;
        let mut candidates = Vec::new();
        for root in &roots {
            for name in NAMES {
                for filename in [name.to_string(), format!("{name}.zst")] {
                    let path = root.join(filename);
                    candidates.push(Candidate {
                        stamp: optional_stamp(&path)?,
                        path,
                    });
                }
            }
        }
        // Pin source assets too. Preparation cannot turn mutable package bytes
        // into authority for later SDK activation.
        for (_, approved) in self.entries() {
            for asset in [&approved.plain, &approved.compressed] {
                candidates.push(Candidate {
                    stamp: Some(verify_file(&asset.path, asset)?),
                    path: asset.path.clone(),
                });
            }
        }
        let result = PreparedTemplates { candidates, roots };
        result.verify()?;
        Ok(result)
    }

    fn entries(&self) -> [(&'static str, &ApprovedTemplate); 2] {
        [(NAMES[0], &self.storage), (NAMES[1], &self.overlay)]
    }
}

impl ApprovedTemplate {
    fn validate(&self, name: &str) -> Result<()> {
        if self.plain.path.file_name() != Some(name.as_ref())
            || self.compressed.path.file_name() != Some(format!("{name}.zst").as_ref())
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        verify_file(&self.plain.path, &self.plain)?;
        crate::archive::validate_disk(
            &mut open_regular(&self.plain.path)?,
            self.plain.bytes,
            self.plain.bytes,
        )
        .map_err(|_| Error::before(ErrorCode::Validation))?;
        verify_file(&self.compressed.path, &self.compressed)?;
        // A compressed candidate must expand into exactly the approved plain
        // bytes and geometry, even though ordinary SDK work will use plain home.
        let file = open_regular(&self.compressed.path)?;
        let mut decoder =
            zstd::Decoder::new(file).map_err(|_| Error::before(ErrorCode::Validation))?;
        decoder
            .window_log_max(23)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        let (digest, bytes) = digest_stream(&mut decoder, self.plain.bytes)?;
        if digest != self.plain.sha256 || bytes != self.plain.bytes {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}

fn parent(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(path
        .parent()
        .ok_or(Error::before(ErrorCode::Validation))?
        .into())
}
fn directory(path: &Path) -> Result<()> {
    unredirected(path)?;
    let metadata = std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_dir() || metadata.mode() & 0o022 != 0 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
fn open_regular(path: &Path) -> Result<File> {
    unredirected(path)?;
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))
}
fn optional_stamp(path: &Path) -> Result<Option<Stamp>> {
    unredirected(&parent(path)?)?;
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(stamp(&metadata)?)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(Error::before(ErrorCode::Io)),
    }
}
fn verify_file(path: &Path, evidence: &TemplateFile) -> Result<Stamp> {
    if !path.is_absolute()
        || evidence.bytes == 0
        || evidence.bytes > MAX_BYTES
        || !valid_hex(&evidence.sha256, 64)
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut file = open_regular(path)?;
    let before = stamp(&file.metadata().map_err(|_| Error::before(ErrorCode::Io))?)?;
    if before.length != evidence.bytes {
        return Err(Error::before(ErrorCode::Validation));
    }
    let (digest, bytes) = digest_stream(&mut file, evidence.bytes)?;
    if digest != evidence.sha256 || bytes != evidence.bytes || optional_stamp(path)? != Some(before)
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    stamp(&file.metadata().map_err(|_| Error::before(ErrorCode::Io))?)
}
fn digest_stream(reader: &mut impl Read, cap: u64) -> Result<(String, u64)> {
    let mut digest = Sha256::new();
    let mut total = 0;
    let mut buffer = [0; BLOCK];
    loop {
        let count = reader
            .read(&mut buffer)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > cap {
            return Err(Error::before(ErrorCode::Validation));
        }
        digest.update(&buffer[..count]);
    }
    Ok((hex::encode(digest.finalize()), total))
}
fn install_sparse(source: &TemplateFile, destination: &Path) -> Result<()> {
    let root = destination
        .parent()
        .ok_or(Error::before(ErrorCode::Validation))?;
    let mut input = open_regular(&source.path)?;
    let mut staged =
        tempfile::NamedTempFile::new_in(root).map_err(|_| Error::before(ErrorCode::Io))?;
    let mut offset = 0;
    let mut digest = Sha256::new();
    let mut buffer = [0; BLOCK];
    loop {
        let mut count = 0;
        while count < BLOCK {
            let read = input
                .read(&mut buffer[count..])
                .map_err(|_| Error::before(ErrorCode::Io))?;
            if read == 0 {
                break;
            }
            count += read;
        }
        if count == 0 {
            break;
        }
        if offset + count as u64 > source.bytes {
            return Err(Error::before(ErrorCode::Validation));
        }
        digest.update(&buffer[..count]);
        if buffer[..count].iter().any(|byte| *byte != 0) {
            staged
                .seek(SeekFrom::Start(offset))
                .and_then(|_| staged.write_all(&buffer[..count]))
                .map_err(|_| Error::before(ErrorCode::Io))?;
        } else {
            extend_hole(staged.as_file(), offset, count as u64)?;
        }
        offset += count as u64;
    }
    if offset != source.bytes || hex::encode(digest.finalize()) != source.sha256 {
        return Err(Error::before(ErrorCode::Validation));
    }
    staged
        .as_file()
        .set_len(offset)
        .and_then(|_| {
            staged
                .as_file()
                .set_permissions(std::fs::Permissions::from_mode(0o400))
        })
        .and_then(|_| staged.as_file().sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    staged
        .persist_noclobber(destination)
        .map_err(|_| Error::before(ErrorCode::Conflict))?;
    File::open(root)
        .and_then(|file| file.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    Ok(())
}
#[cfg(target_os = "macos")]
fn extend_hole(file: &File, offset: u64, bytes: u64) -> Result<()> {
    use std::os::fd::AsRawFd;
    // APFS may allocate gaps on seek/ftruncate. Punch only verified zero blocks
    // in this private staging inode, keeping temporary allocation to one block.
    file.set_len(offset + bytes)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let length = bytes / 4096 * 4096;
    if length != 0 {
        let hole = libc::fpunchhole_t {
            fp_flags: 0,
            reserved: 0,
            fp_offset: offset as i64,
            fp_length: length as i64,
        };
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_PUNCHHOLE, &hole) } != 0 {
            return Err(Error::before(ErrorCode::Unsupported));
        }
    }
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn extend_hole(_: &File, _: u64, _: u64) -> Result<()> {
    Ok(())
}
fn record_references(owned: &Path, references: &References) -> Result<()> {
    let bytes = serde_json::to_vec(references).map_err(|_| Error::before(ErrorCode::Validation))?;
    if bytes.len() > 16384 {
        return Err(Error::before(ErrorCode::Validation));
    }
    let path = owned.join(format!("templates-{}.json", references.package_sha256));
    if optional_stamp(&path)?.is_some() {
        let mut actual = Vec::new();
        open_regular(&path)?
            .take(16385)
            .read_to_end(&mut actual)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let actual: References =
            serde_json::from_slice(&actual).map_err(|_| Error::before(ErrorCode::Ownership))?;
        if &actual != references {
            return Err(Error::before(ErrorCode::Ownership));
        }
    } else {
        let mut staged =
            tempfile::NamedTempFile::new_in(owned).map_err(|_| Error::before(ErrorCode::Io))?;
        staged
            .write_all(&bytes)
            .and_then(|_| staged.as_file().sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        staged
            .persist_noclobber(path)
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        File::open(owned)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn created_backing_is_private_writable_without_changing_immutable_template() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let template = root.join("template");
        let backing = root.join("storage.raw");
        std::fs::write(&template, b"approved-template").unwrap();
        std::fs::set_permissions(&template, std::fs::Permissions::from_mode(0o400)).unwrap();
        std::fs::copy(&template, &backing).unwrap();
        assert_eq!(std::fs::metadata(&backing).unwrap().mode() & 0o777, 0o400);
        prepare_created_disk(&backing).unwrap();
        assert_eq!(std::fs::metadata(&backing).unwrap().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(&template).unwrap().mode() & 0o777, 0o400);
        assert_eq!(std::fs::read(&backing).unwrap(), b"approved-template");
        prepare_created_disk(&backing).unwrap();
    }

    #[test]
    fn created_backing_refuses_redirects_shared_inodes_and_unsafe_modes() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let template = root.join("template");
        std::fs::write(&template, b"approved-template").unwrap();
        std::fs::set_permissions(&template, std::fs::Permissions::from_mode(0o400)).unwrap();
        let alias = root.join("alias");
        std::os::unix::fs::symlink(&template, &alias).unwrap();
        assert!(prepare_created_disk(&alias).is_err());
        std::fs::remove_file(&alias).unwrap();
        std::fs::hard_link(&template, &alias).unwrap();
        assert!(prepare_created_disk(&alias).is_err());
        assert_eq!(std::fs::metadata(&template).unwrap().mode() & 0o777, 0o400);
        std::fs::remove_file(&alias).unwrap();
        std::fs::set_permissions(&template, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert!(prepare_created_disk(&template).is_err());
        let empty = root.join("empty");
        std::fs::write(&empty, b"").unwrap();
        assert!(prepare_created_disk(&empty).is_err());
    }
    struct Fixture {
        _temporary: tempfile::TempDir,
        approved: ApprovedTemplates,
        account: PathBuf,
        executable: PathBuf,
        owned: PathBuf,
        domain: DomainBinding,
    }
    impl Fixture {
        fn new() -> Self {
            let temporary = tempfile::tempdir().unwrap();
            let root = temporary.path().canonicalize().unwrap();
            let package = root.join("package");
            let executable = root.join("executable");
            let owned = root.join("owned");
            for path in [&package, &executable, &owned] {
                std::fs::DirBuilder::new().mode(0o700).create(path).unwrap();
            }
            let template = |name: &str| {
                let mut contents = vec![0; 2 * 1024 * 1024];
                contents[..name.len()].copy_from_slice(name.as_bytes());
                let blocks = contents.len() as u32 / 4096;
                let sb = &mut contents[1024..];
                sb[4..8].copy_from_slice(&blocks.to_le_bytes());
                sb[24..28].copy_from_slice(&2u32.to_le_bytes());
                sb[56..58].copy_from_slice(&0xef53u16.to_le_bytes());
                let compressed = zstd::stream::encode_all(contents.as_slice(), 1).unwrap();
                let evidence = |filename: String, bytes: &[u8]| {
                    let path = package.join(filename);
                    std::fs::write(&path, bytes).unwrap();
                    TemplateFile {
                        path,
                        bytes: bytes.len() as u64,
                        sha256: hex::encode(Sha256::digest(bytes)),
                    }
                };
                ApprovedTemplate {
                    plain: evidence(name.into(), &contents),
                    compressed: evidence(format!("{name}.zst"), &compressed),
                }
            };
            Self {
                approved: ApprovedTemplates {
                    storage: template(NAMES[0]),
                    overlay: template(NAMES[1]),
                },
                account: root.join("account"),
                executable,
                owned,
                domain: DomainBinding {
                    target_id: "owned".into(),
                    generation: "a".repeat(32),
                    database: root.join("db"),
                    vm_root: root.join("vms"),
                },
                _temporary: temporary,
            }
        }
        fn prepare(&self) -> Result<PreparedTemplates> {
            self.approved.prepare_at(
                &self.domain,
                &self.owned,
                &"b".repeat(64),
                self.account.clone(),
                vec![self.account.clone(), self.executable.clone()],
            )
        }
    }
    #[test]
    fn installation_is_sparse_noclobber_and_restart_preserves_account_references() {
        let fixture = Fixture::new();
        let prepared = fixture.prepare().unwrap();
        prepared.verify().unwrap();
        let path = fixture.account.join(NAMES[0]);
        let first = std::fs::metadata(&path).unwrap();
        assert_eq!(first.len(), fixture.approved.storage.plain.bytes);
        assert_eq!(first.mode() & 0o777, 0o400);
        assert!(first.blocks() * 512 < first.len() / 2);
        fixture.prepare().unwrap().verify().unwrap();
        assert_eq!(first.ino(), std::fs::metadata(path).unwrap().ino());
        assert!(fixture
            .owned
            .join(format!("templates-{}.json", "b".repeat(64)))
            .is_file());
    }
    #[test]
    fn conflicting_home_or_executable_plain_and_compressed_assets_are_preserved() {
        for home in [true, false] {
            for compressed in [true, false] {
                let fixture = Fixture::new();
                std::fs::create_dir(&fixture.account).unwrap();
                let root = if home {
                    &fixture.account
                } else {
                    &fixture.executable
                };
                let name = if compressed {
                    format!("{}.zst", NAMES[0])
                } else {
                    NAMES[0].into()
                };
                let path = root.join(name);
                std::fs::write(&path, b"unrelated bytes").unwrap();
                assert!(fixture.prepare().is_err());
                assert_eq!(std::fs::read(&path).unwrap(), b"unrelated bytes");
                assert!(!fixture.account.join(NAMES[1]).exists());
            }
        }
    }
    #[test]
    fn redirected_missing_changed_and_overlong_geometry_never_reach_sdk_resolution() {
        let fixture = Fixture::new();
        let prepared = fixture.prepare().unwrap();
        let path = fixture.account.join(NAMES[0]);
        std::fs::remove_file(&path).unwrap();
        assert!(prepared.verify().is_err());
        std::os::unix::fs::symlink(&fixture.approved.storage.plain.path, &path).unwrap();
        assert!(fixture.prepare().is_err());
        std::fs::remove_file(&path).unwrap();
        std::fs::copy(&fixture.approved.storage.plain.path, &path).unwrap();
        assert!(prepared.verify().is_err());
        let compressed = &fixture.approved.storage.compressed.path;
        std::fs::write(
            compressed,
            zstd::stream::encode_all(&b"different geometry"[..], 1).unwrap(),
        )
        .unwrap();
        assert!(fixture.prepare().is_err());
        std::fs::remove_file(&fixture.approved.overlay.plain.path).unwrap();
        assert!(fixture.prepare().is_err());
    }
    #[test]
    fn approved_compression_and_filesystem_geometry_must_match_plain_backing() {
        let mut fixture = Fixture::new();
        let bytes = zstd::stream::encode_all(&b"wrong expanded size"[..], 1).unwrap();
        let compressed = &mut fixture.approved.storage.compressed;
        std::fs::write(&compressed.path, &bytes).unwrap();
        compressed.sha256 = hex::encode(Sha256::digest(&bytes));
        compressed.bytes = bytes.len() as u64;
        assert!(fixture.prepare().is_err());
        assert!(!fixture.account.exists());

        let mut fixture = Fixture::new();
        let plain = &mut fixture.approved.storage.plain;
        let mut bytes = std::fs::read(&plain.path).unwrap();
        bytes[1028..1032].copy_from_slice(&u32::MAX.to_le_bytes());
        std::fs::write(&plain.path, &bytes).unwrap();
        plain.sha256 = hex::encode(Sha256::digest(&bytes));
        assert!(fixture.prepare().is_err());
        assert!(!fixture.account.exists());
    }
    #[test]
    fn later_candidate_and_changed_reference_cannot_be_silently_adopted() {
        let fixture = Fixture::new();
        let prepared = fixture.prepare().unwrap();
        let candidate = fixture.executable.join(format!("{}.zst", NAMES[0]));
        std::fs::copy(&fixture.approved.storage.compressed.path, &candidate).unwrap();
        assert!(prepared.verify().is_err());
        // A fresh preparation can approve matching bytes, but old references
        // cannot be rebound to another domain with the same package hash.
        fixture.prepare().unwrap();
        let mut other = fixture.domain.clone();
        other.generation = "c".repeat(32);
        assert!(fixture
            .approved
            .prepare_at(
                &other,
                &fixture.owned,
                &"b".repeat(64),
                fixture.account.clone(),
                vec![fixture.account.clone(), fixture.executable.clone()]
            )
            .is_err());
    }
}
