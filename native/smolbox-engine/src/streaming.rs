//! Supervised streaming commands using existing receipt-bound SDK agents.
use crate::transfer_supervisor::RunResult;
use crate::transfer_worker::{Blob, Event, Request};
use crate::{
    BufferedCommand, Cancellation, CommandOutcome, Completion, CreationReceipt, Dispatch, Engine,
    Error, ErrorCode, FileCompletion, Output, Result, Stream,
};
use std::io::Write;
use std::time::Instant;

impl Engine {
    pub fn exec_stream_owned(
        &self,
        receipt: &CreationReceipt,
        command: BufferedCommand,
        cancel: Cancellation,
        consumer: impl FnMut(Output) -> std::result::Result<(), ()>,
    ) -> Result<CommandOutcome> {
        self.exec_stream_owned_mode(receipt, command, cancel, consumer, None)
    }

    pub fn exec_stream_owned_with_volume_policy(
        &self,
        receipt: &CreationReceipt,
        command: BufferedCommand,
        cancel: Cancellation,
        consumer: impl FnMut(Output) -> std::result::Result<(), ()>,
        policy: &crate::LocalVolumePolicy,
    ) -> Result<CommandOutcome> {
        self.exec_stream_owned_mode(receipt, command, cancel, consumer, Some(policy))
    }

    fn exec_stream_owned_mode(
        &self,
        receipt: &CreationReceipt,
        command: BufferedCommand,
        cancel: Cancellation,
        mut consumer: impl FnMut(Output) -> std::result::Result<(), ()>,
        policy: Option<&crate::LocalVolumePolicy>,
    ) -> Result<CommandOutcome> {
        let expires = Instant::now()
            .checked_add(command.timeout)
            .ok_or(Error::before(ErrorCode::Validation))?;
        let record = self.record(receipt)?;
        command.validate(record.image.is_some())?;
        if command.stdin.is_some() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let metadata = crate::buffered::Metadata::new(&record, command, expires)?;
        metadata.validate()?;
        let mount_budget = crate::ReadBudget::new(
            expires
                .saturating_duration_since(Instant::now())
                .min(std::time::Duration::from_secs(30))
                .max(std::time::Duration::from_nanos(1)),
            cancel.clone(),
        )?;
        let mounts = self.worker_mounts(receipt, &record, policy, &mount_budget)?;
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source = self.source_lease(receipt)?;
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let bytes =
            serde_json::to_vec(&metadata).map_err(|_| Error::before(ErrorCode::Validation))?;
        let (permit, mount_authority) = self.reserve_mounted_worker(
            receipt,
            mounts,
            crate::jobs::Demand::command(metadata.command.max_output_bytes, bytes.len() as u64)?,
            &mount_budget,
        )?;
        let prepared = supervisor
            .prepare_job_reserved(
                permit,
                &self.transfer_directory()?,
                self.vm_directory(&receipt.name).join("agent.sock"),
                &bytes,
                metadata.command.max_output_bytes,
                false,
            )?
            .into_streaming()?;
        if self.inspect(receipt)?.state != crate::ObservedState::Running {
            return Err(Error::before(ErrorCode::State));
        }
        if cancel.is_cancelled() || Instant::now() >= expires {
            return Ok(CommandOutcome {
                completion: if cancel.is_cancelled() {
                    Completion::Cancelled
                } else {
                    Completion::Deadline
                },
                dispatch: Dispatch::NotDispatched,
                observed_exit: None,
                running_observed: true,
                output_bytes: 0,
            });
        }
        let mut observed = 0;
        let result = supervisor.run_streaming(
            prepared,
            Box::new((machine, source, self.domain.clone(), mount_authority)),
            expires,
            &cancel,
            &mut |output| {
                let size = output.bytes.len() as u64;
                consumer(output)?;
                observed += size;
                Ok(())
            },
        )?;
        let (transfer, proof) = match result {
            RunResult::Retained(transfer) => (transfer, None),
            RunResult::Collected(collected) => {
                (collected.outcome.clone(), collected.stream.clone())
            }
        };
        let mut outcome = proof.unwrap_or(CommandOutcome {
            completion: Completion::NativeError,
            dispatch: transfer.dispatch,
            observed_exit: None,
            running_observed: observed > 0,
            output_bytes: observed,
        });
        if transfer.completion != FileCompletion::Completed {
            outcome.completion = match transfer.completion {
                FileCompletion::Cancelled => Completion::Cancelled,
                FileCompletion::Deadline => Completion::Deadline,
                FileCompletion::ConsumerLost => Completion::ConsumerLost,
                FileCompletion::OutputLimit => Completion::OutputLimit,
                _ => Completion::NativeError,
            };
        }
        outcome.dispatch = transfer.dispatch;
        outcome.output_bytes = observed;
        if cancel.is_cancelled() || Instant::now() >= expires {
            outcome.completion = if cancel.is_cancelled() {
                Completion::Cancelled
            } else {
                Completion::Deadline
            };
        }
        Ok(outcome)
    }
}

pub(crate) fn run(
    request: &Request,
    reference: &Blob,
    mut spool: std::fs::File,
    mut emit: impl FnMut(Event) -> Result<()>,
) -> Result<()> {
    let metadata: crate::buffered::Metadata =
        reference.read(request.owner, crate::COMMAND_METADATA_BYTES)?;
    metadata.validate()?;
    if metadata.command.stdin.is_some() || metadata.command.max_output_bytes != request.max_bytes {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut connection =
        crate::agent_io::BoundedAgent::connect(&request.socket, request.max_bytes)?;
    let stopper = connection.stopper();
    let cancel = Cancellation::new();
    let mut collector = crate::exec::Collector::new(request.max_bytes);
    let mut cursor = 0;
    let native = metadata.execute_streaming(&mut connection.client, |event| {
        collector.event(event, &cancel, &mut |output| {
            let size = output.bytes.len() as u64;
            spool
                .write_all(&output.bytes)
                .and_then(|()| spool.flush())
                .map_err(|_| ())?;
            emit(Event::StreamOutput {
                stderr: output.stream == Stream::Stderr,
                offset: cursor,
                bytes: size,
            })
            .map_err(|_| ())?;
            cursor += size;
            Ok(())
        });
        if cancel.is_cancelled() {
            stopper.stop();
        }
    });
    let mut outcome = collector.finish(native.is_ok(), cancel.is_cancelled(), false);
    if connection.limited() {
        outcome.completion = Completion::OutputLimit;
    }
    if outcome.completion == Completion::Unknown {
        outcome.completion = Completion::NativeError;
    }
    emit(Event::StreamCompleted {
        completion: outcome.completion,
        exit_code: outcome.observed_exit,
        bytes: cursor,
        running: outcome.running_observed,
    })
}
