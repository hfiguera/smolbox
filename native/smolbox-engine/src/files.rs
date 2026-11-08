use crate::exec::Deadline;
use crate::transfer_supervisor::{Collected, RunResult};
use crate::transfer_worker::Kind;
use crate::{Cancellation, CreationReceipt, Dispatch, Engine, Error, ErrorCode, Result};
use std::io::{Read, Seek, SeekFrom};
use std::path::Component;
use std::time::{Duration, Instant};

#[derive(Clone)]
pub struct FileOptions {
    pub guest_path: String,
    pub max_bytes: u64,
    pub timeout: Duration,
    pub mode: Option<u32>,
}

impl FileOptions {
    pub(crate) fn validate(&self, write: bool) -> Result<()> {
        let path = std::path::Path::new(&self.guest_path);
        if !path.is_absolute()
            || self.guest_path.len() > 4096
            || self.guest_path.contains('\0')
            || self.guest_path.ends_with('/')
            || path.components().any(|c| matches!(c, Component::ParentDir))
            || self.max_bytes == 0
            || self.max_bytes > 16 * 1024 * 1024
            || self.timeout.is_zero()
            || self.timeout > Duration::from_secs(600)
            || self.mode.is_some_and(|mode| mode > 0o777)
            || (!write && self.mode.is_some())
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileCompletion {
    Completed,
    Cancelled,
    Deadline,
    NativeError,
    ConsumerLost,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileOutcome {
    pub completion: FileCompletion,
    pub dispatch: Dispatch,
    pub observed_bytes: u64,
    pub native_acknowledged: bool,
}

impl FileOutcome {
    pub fn success(&self) -> bool {
        self.completion == FileCompletion::Completed
    }
}

impl Engine {
    /// Upload bounded caller data using the guest agent's atomic write protocol.
    /// File acknowledgment proves transfer completion, not command termination.
    pub fn write_file(
        &self,
        receipt: &CreationReceipt,
        options: FileOptions,
        data: &[u8],
        cancel: Cancellation,
    ) -> Result<FileOutcome> {
        self.write_file_from_reader(
            receipt,
            options,
            std::io::Cursor::new(data),
            data.len() as u64,
            cancel,
        )
    }

    /// Stage and validate an exact bounded source before any guest dispatch.
    pub fn write_file_from_reader(
        &self,
        receipt: &CreationReceipt,
        options: FileOptions,
        reader: impl Read,
        total_bytes: u64,
        cancel: Cancellation,
    ) -> Result<FileOutcome> {
        options.validate(true)?;
        if total_bytes > options.max_bytes {
            return Err(Error::before(ErrorCode::Validation));
        }
        let expires = Instant::now() + options.timeout;
        if let Some(outcome) = before_budget(expires, &cancel) {
            return Ok(outcome);
        }
        self.record(receipt)?;
        let transfers = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let mut prepared = transfers.prepare(
            &self.transfer_directory()?,
            self.vm_directory(&receipt.name).join("agent.sock"),
            &options,
            Kind::Write {
                total: total_bytes,
                mode: options.mode,
            },
        )?;
        if let Err(error) = prepared.upload(reader, expires, &cancel) {
            if let Some(outcome) = before_budget(expires, &cancel) {
                return Ok(outcome);
            }
            return Err(error);
        }
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source = self.source_lease(receipt)?;
        if let Some(outcome) = before_budget(expires, &cancel) {
            return Ok(outcome);
        }
        let deadline = Deadline::start(
            expires.saturating_duration_since(Instant::now()),
            cancel.clone(),
        );
        if !self.activate_files(
            receipt,
            expires.saturating_duration_since(Instant::now()),
            &cancel,
        )? {
            return Ok(finish(
                false,
                cancel.is_cancelled(),
                deadline.finish(),
                0,
                false,
            ));
        }
        let collected = transfers.run(
            prepared,
            Box::new((machine, source, self.domain.clone())),
            expires,
            &cancel,
        )?;
        let mut outcome = match collected {
            RunResult::Collected(collected) => collected.outcome,
            RunResult::Retained(outcome) => outcome,
        };
        if deadline.finish() {
            outcome.completion = FileCompletion::Deadline;
        }
        Ok(outcome)
    }

    /// A capped spool reserves finite bytes before guest dispatch. Forward only
    /// a completely acknowledged read in public 64-KiB credit-controlled chunks.
    pub fn read_file(
        &self,
        receipt: &CreationReceipt,
        options: FileOptions,
        cancel: Cancellation,
        mut consumer: impl FnMut(Vec<u8>) -> std::result::Result<(), ()>,
    ) -> Result<FileOutcome> {
        options.validate(false)?;
        let expires = Instant::now() + options.timeout;
        if let Some(outcome) = before_budget(expires, &cancel) {
            return Ok(outcome);
        }
        self.record(receipt)?;
        let transfers = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let prepared = transfers.prepare(
            &self.transfer_directory()?,
            self.vm_directory(&receipt.name).join("agent.sock"),
            &options,
            Kind::Read,
        )?;
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source = self.source_lease(receipt)?;
        if let Some(outcome) = before_budget(expires, &cancel) {
            return Ok(outcome);
        }
        let deadline = Deadline::start(
            expires.saturating_duration_since(Instant::now()),
            cancel.clone(),
        );
        if !self.activate_files(
            receipt,
            expires.saturating_duration_since(Instant::now()),
            &cancel,
        )? {
            return Ok(finish(
                false,
                cancel.is_cancelled(),
                deadline.finish(),
                0,
                false,
            ));
        }
        let result = transfers.run(
            prepared,
            Box::new((machine, source, self.domain.clone())),
            expires,
            &cancel,
        )?;
        let mut outcome = match result {
            RunResult::Retained(outcome) => outcome,
            RunResult::Collected(mut collected) => {
                if collected.outcome.success() {
                    forward(&mut collected, expires, &cancel, &mut consumer)?;
                }
                collected.outcome.clone()
            }
        };
        if deadline.finish() {
            outcome.completion = FileCompletion::Deadline;
        }
        Ok(outcome)
    }
}

fn before_budget(expires: Instant, cancel: &Cancellation) -> Option<FileOutcome> {
    let expired = Instant::now() >= expires;
    (expired || cancel.is_cancelled()).then_some(FileOutcome {
        completion: if expired {
            FileCompletion::Deadline
        } else {
            FileCompletion::Cancelled
        },
        dispatch: Dispatch::NotDispatched,
        observed_bytes: 0,
        native_acknowledged: false,
    })
}

fn forward(
    collected: &mut Collected,
    expires: Instant,
    cancel: &Cancellation,
    consumer: &mut impl FnMut(Vec<u8>) -> std::result::Result<(), ()>,
) -> Result<()> {
    collected.prepared.spool.verify()?;
    let file = &mut collected.prepared.spool.file;
    if file
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?
        .len()
        != collected.outcome.observed_bytes
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let mut forwarded = 0;
    let mut buffer = [0; 64 * 1024];
    while forwarded < collected.outcome.observed_bytes {
        if let Some(outcome) = before_budget(expires, cancel) {
            collected.outcome.completion = outcome.completion;
            return Ok(());
        }
        let count = ((collected.outcome.observed_bytes - forwarded) as usize).min(buffer.len());
        file.read_exact(&mut buffer[..count])
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        if consumer(buffer[..count].to_vec()).is_err() {
            collected.outcome.completion = FileCompletion::ConsumerLost;
            return Ok(());
        }
        forwarded += count as u64;
    }
    Ok(())
}

fn finish(
    ok: bool,
    cancelled: bool,
    expired: bool,
    observed_bytes: u64,
    native_acknowledged: bool,
) -> FileOutcome {
    FileOutcome {
        completion: if expired {
            FileCompletion::Deadline
        } else if cancelled {
            FileCompletion::Cancelled
        } else if ok {
            FileCompletion::Completed
        } else {
            FileCompletion::NativeError
        },
        dispatch: Dispatch::MayHaveDispatched,
        observed_bytes,
        native_acknowledged,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paths_modes_and_caps_are_validated_before_native_dispatch() {
        let mut options = FileOptions {
            guest_path: "/workspace/a".into(),
            max_bytes: 1024,
            timeout: Duration::from_secs(1),
            mode: Some(0o600),
        };
        assert!(options.validate(true).is_ok());
        assert!(options.validate(false).is_err());
        for path in [
            "relative",
            "/workspace/../etc/a",
            "/",
            "/workspace/",
            "/a\0b",
        ] {
            options.guest_path = path.into();
            assert!(options.validate(true).is_err());
        }
        options.guest_path = "/workspace/a".into();
        options.mode = Some(0o4600);
        assert!(options.validate(true).is_err());
        options.mode = None;
        options.max_bytes = 0;
        assert!(options.validate(true).is_err());
    }
}
