//! Receipt-bound console diagnostics. No SDK manager, boot or lifecycle lock.
use crate::{Cancellation, CreationReceipt, Engine, Error, ErrorCode, FileCompletion, Result};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const LOG_LINES: u64 = 10_000;
pub const LOG_LINE_BYTES: usize = 131_064;
pub const LOG_OUTPUT_BYTES: u64 = 8 * 1024 * 1024;
pub const LOG_RAW_LINE_BYTES: usize = 1024 * 1024;
pub const LOG_MEMORY_BYTES: u64 = 6 * 1024 * 1024;
pub const LOG_POLL_MS: u64 = 100;
const CHUNK: usize = 65536;

pub struct LogOptions {
    pub tail: u64,
    pub follow: bool,
    pub timeout: Duration,
    pub max_bytes: u64,
}
impl LogOptions {
    pub fn validate(&self) -> Result<()> {
        if self.tail > LOG_LINES
            || self.timeout.is_zero()
            || self.timeout > Duration::from_secs(300)
            || self.max_bytes == 0
            || self.max_bytes > LOG_OUTPUT_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
pub struct LogOutcome {
    pub completion: FileCompletion,
    pub lines: u64,
    pub bytes: u64,
}
struct Control<'a> {
    expires: Instant,
    cancel: &'a Cancellation,
}
impl Control<'_> {
    fn completion(&self) -> Option<FileCompletion> {
        if self.cancel.is_cancelled() {
            Some(FileCompletion::Cancelled)
        } else if Instant::now() >= self.expires {
            Some(FileCompletion::Deadline)
        } else {
            None
        }
    }
}
struct LogFile {
    path: PathBuf,
    file: File,
    parent: File,
    identity: (u64, u64),
    parent_identity: (u64, u64),
}
fn owned_directory(path: &Path) -> Result<()> {
    crate::host::unredirected(path)?;
    let meta = std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o022 != 0 {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}
impl LogFile {
    fn open(path: &Path) -> Result<Self> {
        let directory = path.parent().ok_or(Error::before(ErrorCode::Ownership))?;
        owned_directory(directory)?;
        let parent = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)
            .map_err(|e| {
                Error::before(if e.kind() == std::io::ErrorKind::NotFound {
                    ErrorCode::NotFound
                } else {
                    ErrorCode::Ownership
                })
            })?;
        let meta = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        let parent_meta = parent
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let value = Self {
            path: path.into(),
            file,
            parent,
            identity: (meta.dev(), meta.ino()),
            parent_identity: (parent_meta.dev(), parent_meta.ino()),
        };
        value.verify()?;
        Ok(value)
    }
    fn verify(&self) -> Result<u64> {
        crate::host::unredirected(&self.path)?;
        let directory = self
            .path
            .parent()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        owned_directory(directory)?;
        let meta = self
            .file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let current = std::fs::symlink_metadata(&self.path)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let parent = self
            .parent
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let current_parent = std::fs::symlink_metadata(directory)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if !meta.is_file()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.mode() & 0o022 != 0
            || meta.nlink() != 1
            || (meta.dev(), meta.ino()) != self.identity
            || (current.dev(), current.ino()) != self.identity
            || (parent.dev(), parent.ino()) != self.parent_identity
            || (current_parent.dev(), current_parent.ino()) != self.parent_identity
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(meta.len())
    }
    fn read_at(&mut self, position: u64, end: u64) -> Result<Vec<u8>> {
        let size = (end.saturating_sub(position)).min(CHUNK as u64) as usize;
        self.file
            .seek(SeekFrom::Start(position))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let mut bytes = vec![0; size];
        self.file
            .read_exact(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        Ok(bytes)
    }
    fn tail_start(
        &mut self,
        options: &LogOptions,
        end: u64,
        check: &mut impl FnMut() -> Result<()>,
    ) -> Result<u64> {
        if options.tail == 0 {
            return Ok(end);
        }
        let mut cursor = end;
        let mut lines = 0;
        let mut scanned = 0;
        let cap = options.max_bytes + 2 * options.tail + CHUNK as u64;
        while cursor > 0 {
            check()?;
            let start = cursor.saturating_sub(CHUNK as u64);
            let bytes = self.read_at(start, cursor)?;
            scanned += bytes.len() as u64;
            for (index, byte) in bytes.iter().enumerate().rev() {
                let absolute = start + index as u64;
                if *byte == b'\n' && absolute + 1 != end {
                    lines += 1;
                    if lines == options.tail {
                        return Ok(absolute + 1);
                    }
                }
            }
            if scanned > cap {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            cursor = start;
        }
        Ok(0)
    }
}

impl Engine {
    pub fn logs(
        &self,
        receipt: &CreationReceipt,
        options: LogOptions,
        cancel: Cancellation,
        consumer: impl FnMut(&str) -> std::result::Result<(), ()>,
    ) -> Result<LogOutcome> {
        options.validate()?;
        let expires = Instant::now() + options.timeout;
        self.record(receipt)?;
        let _job = self.jobs.acquire(crate::jobs::Demand::logs())?;
        let path = self.vm_directory(&receipt.name).join("agent-console.log");
        read(
            &path,
            &options,
            expires,
            &cancel,
            || self.record(receipt).map(|_| ()),
            consumer,
        )
    }
}

fn read(
    path: &Path,
    options: &LogOptions,
    expires: Instant,
    cancel: &Cancellation,
    mut authority: impl FnMut() -> Result<()>,
    mut consumer: impl FnMut(&str) -> std::result::Result<(), ()>,
) -> Result<LogOutcome> {
    let control = Control { expires, cancel };
    let mut outcome = LogOutcome {
        completion: FileCompletion::Completed,
        lines: 0,
        bytes: 0,
    };
    if let Some(reason) = control.completion() {
        outcome.completion = reason;
        return Ok(outcome);
    }
    let mut file = LogFile::open(path)?;
    let end = file.verify()?;
    let mut check = || {
        if cancel.is_cancelled() || Instant::now() >= expires {
            return Err(Error::before(ErrorCode::State));
        }
        authority()
    };
    let mut position = match file.tail_start(options, end, &mut check) {
        Ok(position) => position,
        Err(error) => {
            if let Some(reason) = control.completion() {
                outcome.completion = reason;
                return Ok(outcome);
            }
            if error.code == ErrorCode::OutputLimit {
                outcome.completion = FileCompletion::OutputLimit;
                return Ok(outcome);
            }
            return Err(error);
        }
    };
    let mut pending = Vec::new();
    // The initial tail includes its unfinished final line, as the HTTP tail does.
    let mut initial = true;
    loop {
        if cancel.is_cancelled() || Instant::now() >= expires {
            outcome.completion = if cancel.is_cancelled() {
                FileCompletion::Cancelled
            } else {
                FileCompletion::Deadline
            };
            return Ok(outcome);
        }
        let size = match authority().and_then(|()| file.verify()) {
            Ok(size) if size >= position => {
                if initial {
                    end.min(size)
                } else {
                    size
                }
            }
            _ => {
                outcome.completion = FileCompletion::NativeError;
                return Ok(outcome);
            }
        };
        if position < size {
            let data = match file.read_at(position, size) {
                Ok(data) => data,
                Err(_) => {
                    outcome.completion = FileCompletion::NativeError;
                    return Ok(outcome);
                }
            };
            position += data.len() as u64;
            for byte in data {
                if byte == b'\n' {
                    if !emit_line(
                        &mut pending,
                        if initial { Some(2) } else { None },
                        options,
                        &mut outcome,
                        &mut consumer,
                        &control,
                    ) {
                        return Ok(outcome);
                    }
                } else {
                    pending.push(byte);
                    if pending.len() > LOG_RAW_LINE_BYTES {
                        outcome.completion = FileCompletion::OutputLimit;
                        return Ok(outcome);
                    }
                }
            }
            continue;
        }
        if initial {
            if !pending.is_empty()
                && !emit_line(
                    &mut pending,
                    Some(1),
                    options,
                    &mut outcome,
                    &mut consumer,
                    &control,
                )
            {
                return Ok(outcome);
            }
            initial = false;
            if !options.follow {
                return Ok(outcome);
            }
        }
        std::thread::sleep(
            Duration::from_millis(LOG_POLL_MS)
                .min(expires.saturating_duration_since(Instant::now())),
        );
    }
}
fn emit_line(
    pending: &mut Vec<u8>,
    carriage_returns: Option<usize>,
    options: &LogOptions,
    outcome: &mut LogOutcome,
    consumer: &mut impl FnMut(&str) -> std::result::Result<(), ()>,
    control: &Control<'_>,
) -> bool {
    if let Some(reason) = control.completion() {
        outcome.completion = reason;
        return false;
    }
    let mut removed = 0;
    while pending.last() == Some(&b'\r') && carriage_returns.is_none_or(|max| removed < max) {
        pending.pop();
        removed += 1;
    }
    let line = String::from_utf8_lossy(pending);
    if line.len() > LOG_LINE_BYTES
        || outcome.lines >= LOG_LINES
        || outcome.bytes + line.len() as u64 + 1 > options.max_bytes
    {
        outcome.completion = FileCompletion::OutputLimit;
        return false;
    }
    if consumer(&line).is_err() {
        outcome.completion = FileCompletion::ConsumerLost;
        return false;
    }
    outcome.lines += 1;
    outcome.bytes += line.len() as u64 + 1;
    pending.clear();
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::unix::fs::{symlink, PermissionsExt};
    fn fixture(bytes: &[u8]) -> (tempfile::TempDir, PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory
            .path()
            .canonicalize()
            .unwrap()
            .join("agent-console.log");
        std::fs::write(&path, bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        (directory, path)
    }
    fn options(tail: u64, max_bytes: u64) -> LogOptions {
        LogOptions {
            tail,
            follow: false,
            timeout: Duration::from_secs(1),
            max_bytes,
        }
    }
    fn snapshot(path: &Path, options: &LogOptions) -> (LogOutcome, Vec<String>) {
        let mut lines = Vec::new();
        let result = read(
            path,
            options,
            Instant::now() + options.timeout,
            &Cancellation::new(),
            || Ok(()),
            |line| {
                lines.push(line.to_owned());
                Ok(())
            },
        )
        .unwrap();
        (result, lines)
    }
    #[test]
    fn tail_keeps_empty_crlf_partial_lossy_lines_and_skips_an_irrelevant_large_prefix() {
        let mut data = vec![b'x'; 2 * 1024 * 1024];
        data.extend(b"\nfirst\r\n\nlast\xff");
        let (_directory, path) = fixture(&data);
        let (result, lines) = snapshot(&path, &options(3, 128));
        assert_eq!(lines, ["first", "", "last\u{fffd}"]);
        assert_eq!(result.completion, FileCompletion::Completed);
        assert_eq!(result.lines, 3);
        let (result, lines) = snapshot(&path, &options(0, 1));
        assert!(lines.is_empty());
        assert_eq!(result.bytes, 0);
        assert_eq!(result.completion, FileCompletion::Completed);
        assert_eq!(
            snapshot(&path, &options(100, 128)).0.completion,
            FileCompletion::OutputLimit
        );
    }
    #[test]
    fn raw_cr_follow_lines_and_utf8_chunk_boundaries_are_bounded_without_losing_characters() {
        let mut text = vec![b'a'; CHUNK - 1];
        text.extend("é\n".as_bytes());
        let (_directory, path) = fixture(&text);
        let (result, lines) = snapshot(&path, &options(1, LOG_OUTPUT_BYTES));
        assert!(lines[0].ends_with('é'));
        assert_eq!(result.completion, FileCompletion::Completed);
        let (_directory, path) = fixture(b"\n");
        assert_eq!(snapshot(&path, &options(1, 1)).1, [""]);
    }
    #[test]
    fn missing_redirected_or_replaced_console_never_supplies_ownership_or_reopens() {
        let (_directory, path) = fixture(b"old\n");
        let opened = LogFile::open(&path).unwrap();
        std::fs::set_permissions(
            path.parent().unwrap(),
            std::fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        assert!(opened.verify().is_ok());
        std::fs::rename(&path, path.with_extension("old")).unwrap();
        std::fs::write(&path, b"replacement").unwrap();
        assert!(opened.verify().is_err());
        std::fs::remove_file(&path).unwrap();
        symlink(path.with_extension("old"), &path).unwrap();
        assert!(LogFile::open(&path).is_err());
        std::fs::remove_file(&path).unwrap();
        assert_eq!(
            LogFile::open(&path).err().unwrap().code,
            ErrorCode::NotFound
        );
    }
    #[test]
    fn explicit_follow_cancellation_keeps_observed_lines_and_has_no_exit_or_reconnect() {
        let (_directory, path) = fixture(b"old\n");
        let mut options = options(0, 128);
        options.follow = true;
        let cancel = Cancellation::new();
        let token = cancel.clone();
        let mut lines = Vec::new();
        let mut appended = false;
        let result = read(
            &path,
            &options,
            Instant::now() + options.timeout,
            &cancel,
            || {
                if !appended {
                    OpenOptions::new()
                        .append(true)
                        .open(&path)
                        .unwrap()
                        .write_all(b"new\r\r\n")
                        .unwrap();
                    appended = true;
                }
                Ok(())
            },
            |line| {
                lines.push(line.to_owned());
                token.cancel();
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(result.completion, FileCompletion::Cancelled);
        assert_eq!(result.lines, 1);
        assert_eq!(lines[0], "new");
    }
    #[test]
    fn deadlines_and_consumer_failure_never_become_completed_snapshots() {
        let (_directory, path) = fixture(b"one\ntwo\n");
        let opts = options(2, 128);
        let result = read(
            &path,
            &opts,
            Instant::now(),
            &Cancellation::new(),
            || panic!("expired authority read"),
            |_| panic!("expired output"),
        )
        .unwrap();
        assert_eq!(result.completion, FileCompletion::Deadline);
        let mut calls = 0;
        let result = read(
            &path,
            &opts,
            Instant::now() + opts.timeout,
            &Cancellation::new(),
            || Ok(()),
            |_| {
                calls += 1;
                if calls == 2 {
                    Err(())
                } else {
                    Ok(())
                }
            },
        )
        .unwrap();
        assert_eq!(result.completion, FileCompletion::ConsumerLost);
        assert_eq!(result.lines, 1);
    }
}
