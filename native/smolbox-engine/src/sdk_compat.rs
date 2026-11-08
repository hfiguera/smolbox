//! Revision-specific SDK path/schema knowledge lives here, never in a bridge.
//! Source compatibility: 9f446ae00219148ca4a703914f44a8e2fab11655.
use crate::host::unredirected;
use crate::{Error, ErrorCode, Result};
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

pub const OBSERVATION_SCHEMA: u32 = 1;

/// The pinned SDK transports launch failures as text. Keep the same narrow
/// virtio bind-conflict classification as its public HTTP path, without
/// publishing diagnostics or treating an unrelated conflict as a port error.
pub(crate) fn launch_error(error: &smolvm::Error) -> ErrorCode {
    let text = error.to_string().to_ascii_lowercase();
    if text.contains("virtio") && text.contains("address already in use") {
        ErrorCode::PortConflict
    } else {
        ErrorCode::Native
    }
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Schema {
    schema: u32,
    revision: String,
    user_version: i64,
    objects: Vec<SchemaObject>,
}
#[derive(serde::Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct SchemaObject {
    kind: String,
    name: String,
    table: String,
    sql: String,
}

/// Observational snapshot, never a reservation API or SDK writer connection.
/// The caller holds account/domain ownership and its per-name gate, quiesces
/// old actors and verifies host material while this consistent read is open.
pub(crate) fn observe_absence(
    database: &Path,
    identity: (u64, u64),
    name: &str,
    verify_material: impl FnOnce() -> Result<bool>,
) -> Result<bool> {
    let budget = crate::ReadBudget::new(
        std::time::Duration::from_secs(30),
        crate::Cancellation::new(),
    )?;
    observe_absence_budget(database, identity, name, &budget, verify_material)
}

pub(crate) fn observe_absence_budget(
    database: &Path,
    identity: (u64, u64),
    name: &str,
    budget: &crate::ReadBudget,
    verify_material: impl FnOnce() -> Result<bool>,
) -> Result<bool> {
    if !crate::domain::valid_id(name) {
        return Err(Error::before(ErrorCode::Validation));
    }
    with_observation_budget(database, identity, budget, |transaction| {
        let present: bool = transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM vms WHERE name = ?1)
                OR EXISTS(SELECT 1 FROM vm_create_reservations WHERE name = ?1)",
                [name],
                |row| row.get(0),
            )
            .map_err(|_| Error::before(ErrorCode::Database))?;
        Ok(!present && verify_material()?)
    })
}

pub(crate) fn validate_database(database: &Path, identity: (u64, u64)) -> Result<()> {
    with_observation(database, identity, |_| Ok(()))
}
pub(crate) fn validate_database_budget(
    database: &Path,
    identity: (u64, u64),
    budget: &crate::ReadBudget,
) -> Result<()> {
    with_observation_budget(database, identity, budget, |_| Ok(()))
}

/// Pinned fork preparation can copy a shared-pack lease into an empty private
/// `pack` directory, link the source cache or leave this path absent. The SDK's
/// detach path skips links and cannot find a layers mount or lease in an empty
/// directory. Reject nonempty/unsafe private caches before SDK deletion. This
/// predicate supplies no ownership, collection or child-absence authority.
pub(crate) fn branch_deletion_cache(directory: &Path) -> Result<()> {
    unredirected(directory)?;
    let pack = directory.join("pack");
    match std::fs::symlink_metadata(&pack) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Ok(metadata) if metadata.file_type().is_symlink() => Ok(()),
        Ok(metadata) if metadata.is_dir() => {
            let root = crate::export_source::Root::open(&pack)?;
            let empty = std::fs::read_dir(root.path())
                .map_err(|_| Error::before(ErrorCode::Io))?
                .next()
                .is_none();
            root.verify()?;
            if empty {
                Ok(())
            } else {
                Err(Error::before(ErrorCode::Ownership))
            }
        }
        _ => Err(Error::before(ErrorCode::Ownership)),
    }
}

/// A completed bare child can cold-start by extracting its approved pack into
/// a private cache. Only the pinned bare layout is allowed here. In particular,
/// SDK force_detach_layers_volume must find neither a mount nor lease state.
/// Callers still require original collection and a canonical stopped row;
/// unbooted/partial callers retain the stricter absent/link/empty predicate.
pub(crate) fn stopped_branch_deletion_cache(directory: &Path) -> Result<()> {
    unredirected(directory)?;
    let pack = directory.join("pack");
    let metadata = match std::fs::symlink_metadata(&pack) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(Error::before(ErrorCode::Io)),
        Ok(metadata) if metadata.file_type().is_symlink() => return Ok(()),
        Ok(metadata) => metadata,
    };
    if !metadata.is_dir() {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let root = crate::export_source::Root::open(&pack)?;
    for (count, entry) in std::fs::read_dir(root.path())
        .map_err(|_| Error::before(ErrorCode::Io))?
        .enumerate()
    {
        let entry = entry.map_err(|_| Error::before(ErrorCode::Io))?;
        if count >= 6 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let path = entry.path();
        let metadata =
            std::fs::symlink_metadata(&path).map_err(|_| Error::before(ErrorCode::Io))?;
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o022 != 0 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match entry.file_name().to_str() {
            Some("agent-rootfs") if metadata.is_dir() => {
                crate::export_source::Root::open(&path)?.verify()?;
            }
            Some("layers") if metadata.is_dir() => {
                let layers = crate::export_source::Root::open(&path)?;
                if std::fs::read_dir(layers.path())
                    .map_err(|_| Error::before(ErrorCode::Io))?
                    .next()
                    .is_some()
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                layers.verify()?;
            }
            Some("agent-rootfs.tar" | "overlay.raw" | "storage.ext4") if metadata.is_file() => {}
            Some(".smolvm-extracted") if metadata.is_file() && metadata.len() == 0 => {}
            _ => return Err(Error::before(ErrorCode::Ownership)),
        }
    }
    root.verify()
}

/// Exclude every retained SDK mount, including stopped and read-only records.
/// Single-row bounded projection avoids a complete VM inventory allocation and
/// never initializes/repairs SDK state. Caller must serialize volume attachments
/// through its volume gate and durable attachment authority before deletion.
pub(crate) fn volume_unattached(
    database: &Path,
    identity: (u64, u64),
    source: &Path,
    budget: &crate::ReadBudget,
) -> Result<bool> {
    let source = source
        .to_str()
        .ok_or(Error::before(ErrorCode::Validation))?;
    if !mount_path(source) {
        return Err(Error::before(ErrorCode::Validation));
    }
    with_observation_budget(database, identity, budget, |connection| {
        let mut query = connection.prepare(
            "SELECT name,length(CAST(data AS BLOB)),substr(CAST(data AS BLOB),1,?1) FROM vms ORDER BY name LIMIT 1025")
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let mut rows = query
            .query([crate::observations::MAX_RECORD_BYTES + 1])
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let mut count = 0;
        let mut total = 0;
        while let Some(row) = rows
            .next()
            .map_err(|_| Error::before(ErrorCode::Database))?
        {
            budget.check()?;
            count += 1;
            let length: usize = row.get(1).map_err(|_| Error::before(ErrorCode::Database))?;
            if count > crate::observations::MAX_RECORDS
                || length > crate::observations::MAX_RECORD_BYTES
                || length > crate::observations::MAX_SNAPSHOT_BYTES - total
            {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            total += length;
            let name = row
                .get_ref(0)
                .map_err(|_| Error::before(ErrorCode::Database))?
                .as_str()
                .map_err(|_| Error::before(ErrorCode::Database))?;
            let data = row
                .get_ref(2)
                .map_err(|_| Error::before(ErrorCode::Database))?;
            let record: VolumeMountProjection = serde_json::from_slice(
                data.as_blob()
                    .map_err(|_| Error::before(ErrorCode::Database))?,
            )
            .map_err(|_| Error::before(ErrorCode::Database))?;
            if record.name != name
                || !crate::domain::valid_id(name)
                || record
                    .mounts
                    .iter()
                    .any(|(host, guest, _)| !mount_path(host) || !mount_path(guest))
                || record
                    .staged_mounts
                    .iter()
                    .any(|(_, host, guest)| !mount_path(host) || !mount_path(guest))
            {
                return Err(Error::before(ErrorCode::Database));
            }
            if record.mounts.iter().any(|(host, _, _)| host == source)
                || record
                    .staged_mounts
                    .iter()
                    .any(|(_, host, _)| host == source)
            {
                return Ok(false);
            }
        }
        budget.check()?;
        Ok(true)
    })
}

fn mount_path(path: &str) -> bool {
    path.starts_with('/')
        && path.len() <= 4096
        && !path.contains('\0')
        && !path.contains('\\')
        && !path.contains("//")
        && (path == "/" || !path.ends_with('/'))
        && !path.split('/').any(|part| matches!(part, "." | ".."))
}

#[derive(serde::Deserialize)]
struct VolumeMountProjection {
    name: String,
    #[serde(default, deserialize_with = "bounded_mounts")]
    mounts: Vec<(String, String, bool)>,
    #[serde(default, deserialize_with = "bounded_mounts")]
    staged_mounts: Vec<(usize, String, String)>,
}

fn bounded_mounts<'de, D, T>(deserializer: D) -> std::result::Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    struct Visitor<T>(std::marker::PhantomData<T>);
    impl<'de, T: serde::Deserialize<'de>> serde::de::Visitor<'de> for Visitor<T> {
        type Value = Vec<T>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("bounded SDK mount list")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut sequence: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut values = Vec::new();
            for _ in 0..1024 {
                let Some(value) = sequence.next_element()? else {
                    return Ok(values);
                };
                values.push(value);
            }
            if sequence.next_element::<serde::de::IgnoredAny>()?.is_some() {
                return Err(serde::de::Error::custom("SDK mount count bound"));
            }
            Ok(values)
        }
    }
    deserializer.deserialize_seq(Visitor(std::marker::PhantomData))
}

fn with_observation<T>(
    database: &Path,
    identity: (u64, u64),
    action: impl FnOnce(&rusqlite::Connection) -> Result<T>,
) -> Result<T> {
    let budget = crate::ReadBudget::new(
        std::time::Duration::from_secs(30),
        crate::Cancellation::new(),
    )?;
    with_observation_budget(database, identity, &budget, action)
}

pub(crate) fn observe_records(
    database: &Path,
    identity: (u64, u64),
    budget: &crate::ReadBudget,
) -> Result<Vec<smolvm::config::VmRecord>> {
    with_observation_budget(database, identity, budget, |connection| {
        let mut query = connection
            .prepare("SELECT name,length(CAST(data AS BLOB)),substr(CAST(data AS BLOB),1,?1) FROM vms ORDER BY name LIMIT 1025")
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let mut rows = query
            .query([crate::observations::MAX_RECORD_BYTES + 1])
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let mut records = Vec::new();
        let mut bytes = 0;
        while let Some(row) = rows
            .next()
            .map_err(|_| Error::before(ErrorCode::Database))?
        {
            budget.check()?;
            if records.len() >= crate::observations::MAX_RECORDS {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            let length: usize = row.get(1).map_err(|_| Error::before(ErrorCode::Database))?;
            bytes += length;
            if length > crate::observations::MAX_RECORD_BYTES
                || bytes > crate::observations::MAX_SNAPSHOT_BYTES
            {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            let name = row
                .get_ref(0)
                .map_err(|_| Error::before(ErrorCode::Database))?
                .as_str()
                .map_err(|_| Error::before(ErrorCode::Database))?;
            if !crate::domain::valid_id(name) {
                return Err(Error::before(ErrorCode::Unsupported));
            }
            let value = row
                .get_ref(2)
                .map_err(|_| Error::before(ErrorCode::Database))?;
            let record: smolvm::config::VmRecord = serde_json::from_slice(
                value
                    .as_blob()
                    .map_err(|_| Error::before(ErrorCode::Database))?,
            )
            .map_err(|_| Error::before(ErrorCode::Database))?;
            if record.name != name {
                return Err(Error::before(ErrorCode::Database));
            }
            records.push(record);
        }
        Ok(records)
    })
}

/// A receipt-bound operation needs one row, not adoption of an inventory snapshot.
/// Limit SQLite's returned blob before allocation and preserve read-only budget/
/// schema/inode checks used by the node observers.
/// Bounded dependency projection: inventory can block source work, never mint
/// child ownership. Do not retain every decoded VM alongside the source record.
pub(crate) fn has_source_dependents(
    database: &Path,
    identity: (u64, u64),
    source: &str,
    budget: &crate::ReadBudget,
) -> Result<bool> {
    Ok(!source_dependents(database, identity, source, budget)?.is_empty())
}

pub(crate) fn source_dependents(
    database: &Path,
    identity: (u64, u64),
    source: &str,
    budget: &crate::ReadBudget,
) -> Result<Vec<String>> {
    #[derive(serde::Deserialize)]
    struct Dependency {
        name: String,
        #[serde(default)]
        golden: Option<String>,
    }
    if !crate::domain::valid_id(source) {
        return Err(Error::before(ErrorCode::Validation));
    }
    with_observation_budget(database, identity, budget, |connection| {
        let mut query = connection.prepare("SELECT name,length(CAST(data AS BLOB)),substr(CAST(data AS BLOB),1,?1) FROM vms ORDER BY name LIMIT 1025")
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let mut rows = query
            .query([crate::observations::MAX_RECORD_BYTES + 1])
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let mut bytes = 0usize;
        let mut count = 0usize;
        let mut found = Vec::new();
        while let Some(row) = rows
            .next()
            .map_err(|_| Error::before(ErrorCode::Database))?
        {
            budget.check()?;
            count += 1;
            let length: usize = row.get(1).map_err(|_| Error::before(ErrorCode::Database))?;
            bytes = bytes
                .checked_add(length)
                .ok_or(Error::before(ErrorCode::OutputLimit))?;
            if count > crate::observations::MAX_RECORDS
                || length > crate::observations::MAX_RECORD_BYTES
                || bytes > crate::observations::MAX_SNAPSHOT_BYTES
            {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            let name: String = row.get(0).map_err(|_| Error::before(ErrorCode::Database))?;
            let blob = row
                .get_ref(2)
                .map_err(|_| Error::before(ErrorCode::Database))?;
            let dependency: Dependency = serde_json::from_slice(
                blob.as_blob()
                    .map_err(|_| Error::before(ErrorCode::Database))?,
            )
            .map_err(|_| Error::before(ErrorCode::Database))?;
            if dependency.name != name
                || !crate::domain::valid_id(&name)
                || dependency
                    .golden
                    .as_ref()
                    .is_some_and(|parent| !crate::domain::valid_id(parent))
            {
                return Err(Error::before(ErrorCode::Database));
            }
            if dependency.golden.as_deref() == Some(source) {
                found.push(name);
            }
        }
        budget.check()?;
        Ok(found)
    })
}

pub(crate) fn observe_record(
    database: &Path,
    identity: (u64, u64),
    name: &str,
    budget: &crate::ReadBudget,
) -> Result<Option<smolvm::config::VmRecord>> {
    if !crate::domain::valid_id(name) {
        return Err(Error::before(ErrorCode::Validation));
    }
    with_observation_budget(database, identity, budget, |connection| {
        let mut query = connection.prepare(
            "SELECT length(CAST(data AS BLOB)),substr(CAST(data AS BLOB),1,?2) FROM vms WHERE name=?1 LIMIT 1")
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let mut rows = query
            .query(rusqlite::params![
                name,
                crate::observations::MAX_RECORD_BYTES + 1
            ])
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let Some(row) = rows
            .next()
            .map_err(|_| Error::before(ErrorCode::Database))?
        else {
            return Ok(None);
        };
        budget.check()?;
        let length: usize = row.get(0).map_err(|_| Error::before(ErrorCode::Database))?;
        if length > crate::observations::MAX_RECORD_BYTES {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        let blob = row
            .get_ref(1)
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let record: smolvm::config::VmRecord = serde_json::from_slice(
            blob.as_blob()
                .map_err(|_| Error::before(ErrorCode::Database))?,
        )
        .map_err(|_| Error::before(ErrorCode::Database))?;
        if record.name != name {
            return Err(Error::before(ErrorCode::Database));
        }
        Ok(Some(record))
    })
}

fn with_observation_budget<T>(
    database: &Path,
    identity: (u64, u64),
    budget: &crate::ReadBudget,
    action: impl FnOnce(&rusqlite::Connection) -> Result<T>,
) -> Result<T> {
    budget.check()?;
    verify_database_path(database, identity)?;
    check_sidecars(database)?;
    let mut connection = rusqlite::Connection::open_with_flags(
        database,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
            | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
            | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )
    .map_err(|_| Error::before(ErrorCode::Database))?;
    // SQLite owns the inode pin. Closing an independently opened descriptor
    // would cancel this process's POSIX locks, including the SDK's cached ones.
    verify_database_connection(&connection, database, identity)?;
    let interrupted = budget.clone();
    connection.progress_handler(1000, Some(move || interrupted.check().is_err()));
    connection
        .busy_timeout(std::time::Duration::ZERO)
        .map_err(|_| Error::before(ErrorCode::Database))?;
    connection
        .execute_batch("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;")
        .map_err(|_| Error::before(ErrorCode::Database))?;
    let transaction = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Deferred)
        .map_err(|_| Error::before(ErrorCode::Database))?;
    verify_schema(&transaction)?;
    let integrity: String = transaction
        .query_row("PRAGMA quick_check(1)", [], |row| row.get(0))
        .map_err(|_| Error::before(ErrorCode::Database))?;
    if integrity != "ok" {
        return Err(Error::before(ErrorCode::Database));
    }
    let observation = action(&transaction)?;
    verify_database_connection(&transaction, database, identity)?;
    check_sidecars(database)?;
    transaction
        .rollback()
        .map_err(|_| Error::before(ErrorCode::Database))?;
    verify_database_connection(&connection, database, identity)?;
    drop(connection);
    budget.check()?;
    Ok(observation)
}

fn verify_schema(connection: &rusqlite::Connection) -> Result<()> {
    let schema: Schema = serde_json::from_str(include_str!("sdk_schema.json"))
        .map_err(|_| Error::before(ErrorCode::Unsupported))?;
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|_| Error::before(ErrorCode::Database))?;
    if schema.schema != OBSERVATION_SCHEMA
        || schema.revision != crate::SMOLVM_REVISION
        || version != schema.user_version
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    let mut statement = connection
        .prepare(
            "SELECT substr(type,1,17),substr(name,1,129),substr(tbl_name,1,129),substr(sql,1,16385)
            FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY type,name LIMIT 65",
        )
        .map_err(|_| Error::before(ErrorCode::Database))?;
    let objects = statement
        .query_map([], |row| {
            let sql: String = row.get(3)?;
            Ok(SchemaObject {
                kind: row.get(0)?,
                name: row.get(1)?,
                table: row.get(2)?,
                sql: sql.split_whitespace().collect::<Vec<_>>().join(" "),
            })
        })
        .map_err(|_| Error::before(ErrorCode::Database))?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| Error::before(ErrorCode::Database))?;
    if objects != schema.objects {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(())
}

fn verify_database_path(database: &Path, identity: (u64, u64)) -> Result<()> {
    // A missing DB is an error, never an empty SQLite database.
    let metadata =
        std::fs::symlink_metadata(database).map_err(|_| Error::before(ErrorCode::Database))?;
    if !metadata.is_file()
        || (metadata.dev(), metadata.ino()) != identity
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o022 != 0
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    unredirected(database)?;
    Ok(())
}

fn verify_database_connection(
    connection: &rusqlite::Connection,
    database: &Path,
    identity: (u64, u64),
) -> Result<()> {
    verify_database_path(database, identity)?;
    if connection
        .path()
        .is_none_or(|path| Path::new(path) != database)
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut moved: libc::c_int = 1;
    // SAFETY: this thread exclusively borrows the live connection. The public
    // SQLite opcode only observes its main-file identity and writes one c_int.
    // No SQLite/VFS private structs or borrowed file descriptors are inspected.
    let result = unsafe {
        rusqlite::ffi::sqlite3_file_control(
            connection.handle(),
            c"main".as_ptr(),
            rusqlite::ffi::SQLITE_FCNTL_HAS_MOVED,
            (&mut moved as *mut libc::c_int).cast(),
        )
    };
    if result != rusqlite::ffi::SQLITE_OK || moved != 0 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    verify_database_path(database, identity)
}
fn check_sidecars(database: &Path) -> Result<()> {
    for suffix in ["-wal", "-shm", "-journal"] {
        let path = database.with_file_name(format!(
            "{}{suffix}",
            database
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or(Error::before(ErrorCode::Validation))?
        ));
        match std::fs::symlink_metadata(path) {
            Ok(metadata)
                if !metadata.is_file()
                    || metadata.uid() != unsafe { libc::geteuid() }
                    || metadata.mode() & 0o022 != 0 =>
            {
                return Err(Error::before(ErrorCode::Ownership))
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Error::before(ErrorCode::Database)),
        }
    }
    Ok(())
}

pub(crate) struct SourceLease {
    _file: File,
}
impl Drop for SourceLease {
    fn drop(&mut self) {
        // O_CLOEXEC closes an unrelated spawned child's inherited descriptor
        // only at exec. Release this owned lease explicitly so that temporary
        // copy cannot prolong the source flock after exact worker collection.
        // Retained jobs keep this guard alive; timeout alone never reaches Drop.
        unsafe {
            libc::flock(self._file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
pub(crate) fn source_lease(vm_root: &Path, name: &str) -> Result<SourceLease> {
    if !crate::domain::valid_id(name) {
        return Err(Error::before(ErrorCode::Validation));
    }
    // Clean SDK agent/fork.rs uses the VM directory's parent and exact logical
    // name. Both hash-based VM directories and these sibling locks share vm_root.
    unredirected(vm_root)?;
    let path = vm_root.join(format!(".{name}.fork-operation.lock"));
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o022 != 0
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(Error::before(ErrorCode::Conflict));
    }
    Ok(SourceLease { _file: file })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_deletion_accepts_only_absent_shared_or_owned_empty_cache() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let pack = root.join("pack");
        assert!(branch_deletion_cache(&root).is_ok());
        assert!(stopped_branch_deletion_cache(&root).is_ok());
        std::fs::create_dir(&pack).unwrap();
        std::fs::set_permissions(&pack, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(branch_deletion_cache(&root).is_ok());
        assert!(stopped_branch_deletion_cache(&root).is_ok());
        let marker = pack.join("private-volume-or-lease");
        std::fs::write(&marker, b"retain").unwrap();
        assert!(branch_deletion_cache(&root).is_err());
        assert!(stopped_branch_deletion_cache(&root).is_err());
        assert_eq!(std::fs::read(&marker).unwrap(), b"retain");
        std::fs::remove_file(&marker).unwrap();
        std::fs::set_permissions(&pack, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(branch_deletion_cache(&root).is_err());
        assert!(stopped_branch_deletion_cache(&root).is_err());
        std::fs::set_permissions(&pack, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::remove_dir(&pack).unwrap();
        std::fs::write(&pack, b"not a directory").unwrap();
        assert!(branch_deletion_cache(&root).is_err());
        assert!(stopped_branch_deletion_cache(&root).is_err());
        std::fs::remove_file(&pack).unwrap();
        let source = tempfile::tempdir().unwrap();
        let marker = source.path().join("source-marker");
        std::fs::write(&marker, b"source remains").unwrap();
        symlink(source.path(), &pack).unwrap();
        assert!(branch_deletion_cache(&root).is_ok());
        assert!(stopped_branch_deletion_cache(&root).is_ok());
        assert_eq!(std::fs::read(&marker).unwrap(), b"source remains");
    }

    #[test]
    fn stopped_bare_cache_accepts_only_the_pinned_layout_without_mounts_or_leases() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let pack = root.join("pack");
        std::fs::create_dir(&pack).unwrap();
        std::fs::set_permissions(&pack, std::fs::Permissions::from_mode(0o755)).unwrap();
        for name in ["agent-rootfs", "layers"] {
            std::fs::create_dir(pack.join(name)).unwrap();
        }
        for name in [
            "agent-rootfs.tar",
            "overlay.raw",
            "storage.ext4",
            ".smolvm-extracted",
        ] {
            std::fs::write(pack.join(name), b"").unwrap();
        }
        std::fs::write(pack.join("agent-rootfs/owned"), b"derived cache").unwrap();
        assert!(stopped_branch_deletion_cache(&root).is_ok());
        assert!(branch_deletion_cache(&root).is_err());
        for name in ["leases", "layers-cs", "layers-cs.sparseimage", "unknown"] {
            std::fs::write(pack.join(name), b"retain").unwrap();
            assert!(stopped_branch_deletion_cache(&root).is_err(), "{name}");
            assert_eq!(std::fs::read(pack.join(name)).unwrap(), b"retain");
            std::fs::remove_file(pack.join(name)).unwrap();
        }
        std::fs::write(pack.join("layers/private-layer"), b"retain").unwrap();
        assert!(stopped_branch_deletion_cache(&root).is_err());
        std::fs::remove_file(pack.join("layers/private-layer")).unwrap();
        let overlay = pack.join("overlay.raw");
        std::fs::remove_file(&overlay).unwrap();
        symlink(root.join("unowned"), &overlay).unwrap();
        assert!(stopped_branch_deletion_cache(&root).is_err());
        std::fs::remove_file(&overlay).unwrap();
        std::fs::write(&overlay, b"retain").unwrap();
        std::fs::set_permissions(&overlay, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert!(stopped_branch_deletion_cache(&root).is_err());
        std::fs::set_permissions(&overlay, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(pack.join(".smolvm-extracted"), b"not an empty marker").unwrap();
        assert!(stopped_branch_deletion_cache(&root).is_err());
        std::fs::write(pack.join(".smolvm-extracted"), b"").unwrap();
        assert!(stopped_branch_deletion_cache(&root).is_ok());
        assert_eq!(
            std::fs::read(pack.join("agent-rootfs/owned")).unwrap(),
            b"derived cache"
        );
    }

    #[test]
    fn owned_source_release_is_not_prolonged_by_a_duplicate_descriptor() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let lease = source_lease(&root, "owned").unwrap();
        let copied = lease._file.try_clone().unwrap();
        assert!(source_lease(&root, "owned").is_err());
        drop(lease);
        let next = source_lease(&root, "owned").unwrap();
        drop(copied);
        assert!(source_lease(&root, "owned").is_err());
        drop(next);
        assert!(source_lease(&root, "owned").is_ok());
    }
    #[test]
    fn only_a_virtio_bind_conflict_has_the_public_port_conflict_category() {
        assert_eq!(
            launch_error(&smolvm::Error::VmCreation(
                "virtio-net: Address already in use (private details)".into()
            )),
            ErrorCode::PortConflict
        );
        for message in [
            "address already in use: database",
            "virtio startup failed",
            "private unrelated error",
        ] {
            assert_eq!(
                launch_error(&smolvm::Error::VmCreation(message.into())),
                ErrorCode::Native
            );
        }
    }
    fn database() -> (
        tempfile::TempDir,
        smolvm::db::SmolvmDb,
        std::path::PathBuf,
        (u64, u64),
    ) {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().canonicalize().unwrap().join("db");
        let db = smolvm::db::SmolvmDb::open_at(&path).unwrap();
        let metadata = std::fs::metadata(&path).unwrap();
        (temporary, db, path, (metadata.dev(), metadata.ino()))
    }

    fn volume_budget() -> crate::ReadBudget {
        crate::ReadBudget::new(
            std::time::Duration::from_secs(2),
            crate::Cancellation::default(),
        )
        .unwrap()
    }

    #[test]
    fn sqlite_observation_preserves_cached_sdk_writer_across_an_external_writer() {
        const CHILD: &str = "SMOLBOX_SQLITE_MODEL_CHILD";
        const MODEL: &str = "private sqlite observation model; no SDK runtime or VM";
        if let Some(path) = std::env::var_os(CHILD) {
            let path = std::path::PathBuf::from(path);
            let root = path.parent().unwrap();
            assert_eq!(path.file_name().unwrap(), "model.db");
            assert!(root
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with("sbx-sqlite-fd-"));
            assert_eq!(
                std::fs::read_to_string(root.join("model-kind")).unwrap(),
                MODEL
            );
            let metadata = std::fs::symlink_metadata(root).unwrap();
            assert!(metadata.is_dir() && metadata.uid() == unsafe { libc::geteuid() });
            let db = smolvm::db::SmolvmDb::open_at(&path).unwrap();
            let record =
                smolvm::config::VmRecord::new("worker".into(), 1, 128, vec![], vec![], false);
            db.insert_vm("worker", &record).unwrap();
            return;
        }
        let root = tempfile::Builder::new()
            .prefix("sbx-sqlite-fd-")
            .tempdir()
            .unwrap();
        std::fs::write(root.path().join("model-kind"), MODEL).unwrap();
        let path = root.path().canonicalize().unwrap().join("model.db");
        let db = smolvm::db::SmolvmDb::open_at(&path).unwrap();
        let parent = smolvm::config::VmRecord::new("parent".into(), 1, 128, vec![], vec![], false);
        db.insert_vm("parent", &parent).unwrap();
        assert!(db.get_vm("parent").unwrap().is_some());
        let metadata = std::fs::metadata(&path).unwrap();
        let identity = (metadata.dev(), metadata.ino());
        validate_database(&path, identity).unwrap();
        // A normal child writes only this private model DB, then exits. No
        // production SDK namespace, lifecycle, process loss or fault campaign.
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "sdk_compat::tests::sqlite_observation_preserves_cached_sdk_writer_across_an_external_writer",
                "--test-threads=1",
            ])
            .env(CHILD, &path)
            .output()
            .unwrap();
        assert!(child.status.success(), "private writer child failed");
        assert!(observe_record(&path, identity, "worker", &volume_budget())
            .unwrap()
            .is_some());
        let updated = db
            .update_vm("worker", |row| {
                row.labels.insert("model".into(), "original-writer".into());
            })
            .unwrap()
            .unwrap();
        assert_eq!(
            updated.labels.get("model").map(String::as_str),
            Some("original-writer")
        );
        assert_eq!(
            observe_record(&path, identity, "worker", &volume_budget())
                .unwrap()
                .unwrap()
                .labels,
            updated.labels
        );
    }

    #[test]
    fn sqlite_identity_uses_the_opened_file_and_rejects_a_substituted_or_unrelated_connection() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let first = root.join("first.db");
        let second = root.join("second.db");
        for path in [&first, &second] {
            drop(smolvm::db::SmolvmDb::open_at(path).unwrap());
        }
        let metadata = std::fs::metadata(&first).unwrap();
        let identity = (metadata.dev(), metadata.ino());
        let connection = rusqlite::Connection::open_with_flags(
            &first,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap();
        verify_database_connection(&connection, &first, identity).unwrap();
        let unrelated = rusqlite::Connection::open_with_flags(
            &second,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap();
        assert!(verify_database_connection(&unrelated, &first, identity).is_err());
        let original = root.join("original.db");
        std::fs::rename(&first, &original).unwrap();
        std::fs::rename(&second, &first).unwrap();
        let substituted = rusqlite::Connection::open_with_flags(
            &first,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap();
        std::fs::rename(&first, &second).unwrap();
        std::fs::rename(&original, &first).unwrap();
        // The pathname once again has the expected identity, but this SQLite
        // connection still pins the replacement file opened during the swap.
        verify_database_path(&first, identity).unwrap();
        assert!(verify_database_connection(&substituted, &first, identity).is_err());
        let memory = rusqlite::Connection::open_in_memory().unwrap();
        assert!(verify_database_connection(&memory, &first, identity).is_err());
    }

    #[test]
    fn volume_mount_guard_includes_stopped_readonly_and_staged_sdk_records() {
        use smolvm::config::{RecordState, VmRecord};
        let source = Path::new("/srv/smolvm/volumes/sbv-00000000000000000000000000000000");
        for state in [
            RecordState::Created,
            RecordState::Stopped,
            RecordState::Running,
            RecordState::Failed,
        ] {
            for read_only in [false, true] {
                let (_temporary, db, path, identity) = database();
                let mut record = VmRecord::new(
                    "machine".into(),
                    1,
                    128,
                    vec![(
                        source.to_str().unwrap().into(),
                        "/mnt/volumes/data".into(),
                        read_only,
                    )],
                    vec![],
                    false,
                );
                record.state = state.clone();
                db.insert_vm("machine", &record).unwrap();
                let before = serde_json::to_vec(&db.get_vm("machine").unwrap()).unwrap();
                assert!(!volume_unattached(&path, identity, source, &volume_budget()).unwrap());
                assert_eq!(
                    serde_json::to_vec(&db.get_vm("machine").unwrap()).unwrap(),
                    before
                );
            }
        }
        let (_temporary, db, path, identity) = database();
        let mut record = VmRecord::new("staged".into(), 1, 128, vec![], vec![], false);
        record.staged_mounts = vec![(
            0,
            source.to_str().unwrap().into(),
            "/mnt/volumes/data".into(),
        )];
        db.insert_vm("staged", &record).unwrap();
        assert!(!volume_unattached(&path, identity, source, &volume_budget()).unwrap());
    }

    #[test]
    fn volume_mount_guard_distinguishes_exact_sources_without_adopting_other_rows() {
        let (_temporary, db, path, identity) = database();
        let source = Path::new("/srv/volumes/owned");
        assert!(volume_unattached(&path, identity, source, &volume_budget()).unwrap());
        let record = smolvm::config::VmRecord::new(
            "foreign".into(),
            1,
            128,
            vec![("/srv/volumes/owned-other".into(), "/mnt/data".into(), false)],
            vec![],
            false,
        );
        db.insert_vm("foreign", &record).unwrap();
        assert!(volume_unattached(&path, identity, source, &volume_budget()).unwrap());
        assert_eq!(db.list_vms().unwrap().len(), 1);
        assert!(
            volume_unattached(&path, identity, Path::new("relative"), &volume_budget()).is_err()
        );
    }

    #[test]
    fn volume_mount_guard_fails_closed_on_malformed_ambiguous_or_unbounded_inventory() {
        let (_temporary, _db, path, identity) = database();
        let writer = rusqlite::Connection::open(&path).unwrap();
        for data in [
            serde_json::json!({"name":"other","mounts":[]}),
            serde_json::json!({"name":"machine","mounts":[["/host/../other","/guest",false]]}),
            serde_json::json!({"name":"machine","mounts":[["/host","/guest","wrong"]]}),
            serde_json::json!({"name":"machine","mounts":vec![("/host","/guest",false); 1025]}),
        ] {
            writer
                .execute(
                    "INSERT OR REPLACE INTO vms VALUES ('machine', ?1)",
                    [serde_json::to_string(&data).unwrap()],
                )
                .unwrap();
            assert_eq!(
                volume_unattached(
                    &path,
                    identity,
                    Path::new("/srv/volumes/owned"),
                    &volume_budget()
                )
                .unwrap_err()
                .code,
                ErrorCode::Database
            );
        }
        writer
            .execute(
                "UPDATE vms SET data=zeroblob(?1)",
                [crate::observations::MAX_RECORD_BYTES + 1],
            )
            .unwrap();
        assert_eq!(
            volume_unattached(
                &path,
                identity,
                Path::new("/srv/volumes/owned"),
                &volume_budget()
            )
            .unwrap_err()
            .code,
            ErrorCode::OutputLimit
        );
    }

    #[test]
    fn volume_mount_guard_cancellation_is_readonly_and_not_dispatched() {
        let (_temporary, db, path, identity) = database();
        let cancel = crate::Cancellation::default();
        cancel.cancel();
        let budget = crate::ReadBudget::new(std::time::Duration::from_secs(2), cancel).unwrap();
        let error = volume_unattached(&path, identity, Path::new("/srv/volumes/owned"), &budget)
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::State);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(db.list_vms().unwrap().is_empty());
    }
    #[test]
    fn clean_schema_and_readonly_policy_preserve_rows_and_consistent_wal_snapshot() {
        let (_temporary, _db, path, identity) = database();
        let writer = rusqlite::Connection::open(&path).unwrap();
        with_observation(&path, identity, |reader| {
            assert!(reader.is_readonly(rusqlite::DatabaseName::Main).unwrap());
            assert!(reader
                .execute("INSERT INTO config VALUES ('reader', 'forbidden')", [])
                .is_err());
            let count: i64 = reader
                .query_row("SELECT count(*) FROM config", [], |row| row.get(0))
                .unwrap();
            assert_eq!(count, 0);
            // A deterministic temporary-DB writer illustrates WAL consistency.
            // Read-only observation does not promise an independent-writer lock.
            writer
                .execute("INSERT INTO config VALUES ('writer', 'ordinary')", [])
                .unwrap();
            let count: i64 = reader
                .query_row("SELECT count(*) FROM config", [], |row| row.get(0))
                .unwrap();
            assert_eq!(count, 0);
            Ok(())
        })
        .unwrap();
        assert_eq!(
            writer
                .query_row("SELECT value FROM config WHERE key='writer'", [], |row| row
                    .get::<_, String>(0))
                .unwrap(),
            "ordinary"
        );
        validate_database(&path, identity).unwrap();
        assert!(observe_absence(&path, identity, "absent", || Ok(true)).unwrap());
    }
    #[test]
    fn stale_reservation_and_corrupt_record_presence_are_never_reaped_or_adopted() {
        let (_temporary, _db, path, identity) = database();
        let writer = rusqlite::Connection::open(&path).unwrap();
        writer
            .execute(
                "INSERT INTO vm_create_reservations VALUES ('stale', 'foreign', -1, 0)",
                [],
            )
            .unwrap();
        writer
            .execute("INSERT INTO vms VALUES ('broken', X'00')", [])
            .unwrap();
        for name in ["stale", "broken"] {
            assert!(!observe_absence(&path, identity, name, || panic!(
                "present name reached host absence probe"
            ))
            .unwrap());
        }
        assert_eq!(
            writer
                .query_row(
                    "SELECT owner_token FROM vm_create_reservations",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .unwrap(),
            "foreign"
        );
        assert_eq!(
            writer
                .query_row("SELECT data FROM vms", [], |row| row.get::<_, Vec<u8>>(0))
                .unwrap(),
            [0]
        );
    }
    #[test]
    fn absence_uses_the_callers_original_budget_before_and_after_the_host_probe() {
        let (_temporary, db, path, identity) = database();
        let budget = crate::ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap();
        budget.cancel.cancel();
        let error = observe_absence_budget(&path, identity, "absent", &budget, || {
            panic!("cancelled observation reached the material probe")
        })
        .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        let budget = crate::ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap();
        assert!(
            observe_absence_budget(&path, identity, "absent", &budget, || {
                budget.cancel.cancel();
                Ok(true)
            })
            .is_err()
        );
        assert!(db.list_vms().unwrap().is_empty());
        assert!(observe_absence(&path, identity, "absent", || Ok(true)).unwrap());
    }
    #[test]
    fn database_validation_keeps_the_original_cancelled_control_budget() {
        let (_temporary, db, path, identity) = database();
        let budget = crate::ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap();
        validate_database_budget(&path, identity, &budget).unwrap();
        budget.cancel.cancel();
        let error = validate_database_budget(&path, identity, &budget).unwrap_err();
        assert_eq!(error.code, ErrorCode::State);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(db.list_vms().unwrap().is_empty());
    }
    #[test]
    fn unsupported_schema_version_table_or_trigger_is_rejected_without_repair() {
        for change in [
            "PRAGMA user_version=1",
            "DROP TABLE vm_create_reservations",
            "CREATE TABLE future_data (data BLOB)",
            "CREATE TRIGGER future_trigger AFTER INSERT ON config BEGIN SELECT 1; END",
        ] {
            let (_temporary, _db, path, identity) = database();
            let writer = rusqlite::Connection::open(&path).unwrap();
            writer.execute_batch(change).unwrap();
            assert_eq!(
                validate_database(&path, identity).unwrap_err().code,
                ErrorCode::Unsupported
            );
            assert_eq!(
                observe_absence(&path, identity, "absent", || panic!(
                    "unsupported schema reached material check"
                ))
                .unwrap_err()
                .code,
                ErrorCode::Unsupported
            );
            let version: i64 = writer
                .query_row("PRAGMA user_version", [], |row| row.get(0))
                .unwrap();
            assert_eq!(version, i64::from(change == "PRAGMA user_version=1"));
            if change.starts_with("DROP") {
                assert!(writer
                    .prepare("SELECT * FROM vm_create_reservations")
                    .is_err());
            }
        }
    }
    #[test]
    fn corrupt_missing_replaced_or_redirected_database_never_becomes_absence() {
        let (_temporary, db, path, identity) = database();
        drop(db);
        let saved = path.with_extension("saved");
        std::fs::rename(&path, &saved).unwrap();
        assert_eq!(
            observe_absence(&path, identity, "absent", || Ok(true))
                .unwrap_err()
                .code,
            ErrorCode::Database
        );
        assert!(!path.exists());
        std::fs::write(&path, b"foreign replacement").unwrap();
        assert_eq!(
            observe_absence(&path, identity, "absent", || Ok(true))
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&saved, &path).unwrap();
        assert_eq!(
            observe_absence(&path, identity, "absent", || Ok(true))
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        std::fs::remove_file(&path).unwrap();
        std::fs::rename(saved, &path).unwrap();
        std::fs::write(&path, b"invalid database").unwrap();
        assert_eq!(
            observe_absence(&path, identity, "absent", || Ok(true))
                .unwrap_err()
                .code,
            ErrorCode::Database
        );
    }
    #[test]
    fn exclusive_sqlite_contention_is_an_error_and_never_an_absence_result() {
        let (_temporary, db, path, identity) = database();
        drop(db);
        let writer = rusqlite::Connection::open(&path).unwrap();
        writer
            .execute_batch("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;")
            .unwrap();
        assert_eq!(
            observe_absence(&path, identity, "absent", || panic!(
                "busy DB reached material check"
            ))
            .unwrap_err()
            .code,
            ErrorCode::Database
        );
        writer.execute_batch("ROLLBACK;").unwrap();
        assert!(observe_absence(&path, identity, "absent", || Ok(true)).unwrap());
    }
    #[test]
    fn source_contention_rejects_without_waiting_or_replacing_sdk_lock() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let first = source_lease(&root, "owned").unwrap();
        let path = root.join(".owned.fork-operation.lock");
        let original = std::fs::metadata(&path).unwrap().ino();
        assert_eq!(
            source_lease(&root, "owned").err().unwrap().code,
            ErrorCode::Conflict
        );
        source_lease(&root, "sibling").unwrap();
        drop(first);
        source_lease(&root, "owned").unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().ino(), original);
    }
}
