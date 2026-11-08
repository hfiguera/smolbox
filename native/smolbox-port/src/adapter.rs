//! Explicit conversion at the bridge boundary; engine types stay wire-neutral.
use smolbox_engine as engine;
use smolbox_protocol as wire;
use std::fs::File;
use std::time::Duration;

pub fn receipt(receipt: &wire::Receipt) -> engine::CreationReceipt {
    engine::CreationReceipt {
        target_id: receipt.target_id.clone(),
        domain_generation: receipt.domain_generation.clone(),
        name: receipt.name.clone(),
        owner_token: receipt.owner_token.clone(),
        incarnation: receipt.incarnation.clone(),
        material_sha256: receipt.material_sha256.clone(),
    }
}
fn receipt_wire(receipt: engine::CreationReceipt) -> wire::Receipt {
    wire::Receipt {
        target_id: receipt.target_id,
        domain_generation: receipt.domain_generation,
        name: receipt.name,
        owner_token: receipt.owner_token,
        incarnation: receipt.incarnation,
        material_sha256: receipt.material_sha256,
    }
}
fn resources(resources: &wire::Resources) -> engine::Resources {
    engine::Resources {
        cpus: resources.cpus,
        memory_mib: resources.memory_mib,
        storage_gib: resources.storage_gib,
        overlay_gib: resources.overlay_gib,
    }
}
fn observation(observation: engine::Observation) -> wire::Outcome {
    wire::Outcome::Observed {
        observation: wire::Observation {
            state: match observation.state {
                engine::ObservedState::Missing => wire::ObservedState::Missing,
                engine::ObservedState::Stopped => wire::ObservedState::Stopped,
                engine::ObservedState::Running => wire::ObservedState::Running,
                engine::ObservedState::Paused => wire::ObservedState::Paused,
                engine::ObservedState::Pausing => wire::ObservedState::Pausing,
                engine::ObservedState::Frozen => wire::ObservedState::Frozen,
                engine::ObservedState::Failed => wire::ObservedState::Failed,
                engine::ObservedState::Unreachable => wire::ObservedState::Unreachable,
                engine::ObservedState::IdentityUnknown => wire::ObservedState::IdentityUnknown,
            },
            resources: observation.resources.map(|r| wire::Resources {
                cpus: r.cpus,
                memory_mib: r.memory_mib,
                storage_gib: r.storage_gib,
                overlay_gib: r.overlay_gib,
            }),
            pid_identity: observation.pid_identity,
        },
    }
}
fn dispatch(dispatch: engine::Dispatch) -> wire::Dispatch {
    match dispatch {
        engine::Dispatch::NotDispatched => wire::Dispatch::NotDispatched,
        engine::Dispatch::MayHaveDispatched => wire::Dispatch::MayHaveDispatched,
    }
}
pub fn error(error: engine::Error) -> wire::Outcome {
    wire::Outcome::Error {
        code: match error.code {
            engine::ErrorCode::Validation => wire::SafeCode::Validation,
            engine::ErrorCode::Unsupported => wire::SafeCode::Unsupported,
            engine::ErrorCode::Conflict => wire::SafeCode::Conflict,
            engine::ErrorCode::Ownership => wire::SafeCode::Ownership,
            engine::ErrorCode::Database => wire::SafeCode::Database,
            engine::ErrorCode::State => wire::SafeCode::State,
            engine::ErrorCode::Native => wire::SafeCode::Native,
            engine::ErrorCode::Io => wire::SafeCode::Io,
        },
        dispatch: dispatch(error.dispatch),
    }
}
fn file_options(options: &wire::FileOptions, remaining: Duration) -> engine::FileOptions {
    engine::FileOptions {
        guest_path: options.guest_path.clone(),
        max_bytes: options.max_bytes,
        timeout: remaining,
        mode: options.mode,
    }
}
fn file(outcome: engine::FileOutcome) -> wire::Outcome {
    wire::Outcome::File {
        completion: match outcome.completion {
            engine::FileCompletion::Completed => wire::Completion::Completed,
            engine::FileCompletion::Cancelled => wire::Completion::Cancelled,
            engine::FileCompletion::Deadline => wire::Completion::Deadline,
            engine::FileCompletion::NativeError => wire::Completion::NativeError,
            engine::FileCompletion::ConsumerLost => wire::Completion::ConsumerLost,
        },
        dispatch: dispatch(outcome.dispatch),
        observed_bytes: outcome.observed_bytes,
        native_acknowledged: outcome.native_acknowledged,
    }
}

pub fn run(
    engine: &engine::Engine,
    operation: wire::Operation,
    remaining: Duration,
    cancel: engine::Cancellation,
    upload: Option<File>,
    mut emit: impl FnMut(wire::Stream, &[u8]) -> Result<(), ()>,
) -> wire::Outcome {
    let result = match operation {
        wire::Operation::InspectCreation { create } => engine
            .inspect_creation(&engine::CreateRequest {
                name: create.name,
                owner_token: create.owner_token,
                incarnation: create.incarnation,
                artifact: engine::ApprovedArtifact {
                    path: create.artifact.path.into(),
                    sha256: create.artifact.sha256,
                    max_bytes: create.artifact.max_bytes,
                    guest_platform: create.artifact.guest_platform,
                },
                resources: resources(&create.resources),
                labels: create.labels,
            })
            .map(|presence| wire::Outcome::CreationPresence {
                presence: match presence {
                    engine::CreationPresence::Absent => wire::CreationPresence::Absent,
                    engine::CreationPresence::Unverified => wire::CreationPresence::Unverified,
                },
            }),
        wire::Operation::QualifyCreation {
            artifact,
            resources: admitted,
            user,
        } => engine
            .qualify_creation(
                &engine::ApprovedArtifact {
                    path: artifact.path.into(),
                    sha256: artifact.sha256,
                    max_bytes: artifact.max_bytes,
                    guest_platform: artifact.guest_platform,
                },
                resources(&admitted),
                user.as_deref(),
            )
            .map(|()| wire::Outcome::Qualified),
        wire::Operation::Create { create } => engine
            .create(engine::CreateRequest {
                name: create.name,
                owner_token: create.owner_token,
                incarnation: create.incarnation,
                artifact: engine::ApprovedArtifact {
                    path: create.artifact.path.into(),
                    sha256: create.artifact.sha256,
                    max_bytes: create.artifact.max_bytes,
                    guest_platform: create.artifact.guest_platform,
                },
                resources: resources(&create.resources),
                labels: create.labels,
            })
            .map(|r| wire::Outcome::Created {
                receipt: receipt_wire(r),
            }),
        wire::Operation::Inspect { receipt: r } => engine.inspect(&receipt(&r)).map(observation),
        wire::Operation::Start { receipt: r } => engine.start(&receipt(&r)).map(observation),
        wire::Operation::Stop { receipt: r } => engine.stop(&receipt(&r)).map(observation),
        wire::Operation::Delete { receipt: r } => engine.delete(&receipt(&r)).map(observation),
        wire::Operation::Exec {
            receipt: r,
            command,
        } => engine
            .exec(
                &receipt(&r),
                engine::Command {
                    argv: command.argv,
                    env: command.env.into_iter().collect(),
                    workdir: command.workdir,
                    user: command.user,
                    timeout: remaining,
                    max_output_bytes: command.max_output_bytes,
                },
                cancel,
                |output| {
                    emit(
                        match output.stream {
                            engine::Stream::Stdout => wire::Stream::Stdout,
                            engine::Stream::Stderr => wire::Stream::Stderr,
                        },
                        &output.bytes,
                    )
                },
            )
            .map(|outcome| wire::Outcome::Command {
                completion: match outcome.completion {
                    engine::Completion::Exited => wire::Completion::Exited,
                    engine::Completion::Cancelled => wire::Completion::Cancelled,
                    engine::Completion::Deadline => wire::Completion::Deadline,
                    engine::Completion::OutputLimit => wire::Completion::OutputLimit,
                    engine::Completion::ConsumerLost => wire::Completion::ConsumerLost,
                    engine::Completion::NativeError => wire::Completion::NativeError,
                    engine::Completion::Unknown => wire::Completion::Unknown,
                },
                dispatch: dispatch(outcome.dispatch),
                observed_exit: outcome.observed_exit,
                running_observed: outcome.running_observed,
                output_bytes: outcome.output_bytes,
            }),
        wire::Operation::ReadFile {
            receipt: r,
            options,
        } => engine
            .read_file(
                &receipt(&r),
                file_options(&options, remaining),
                cancel,
                |bytes| emit(wire::Stream::File, &bytes),
            )
            .map(file),
        wire::Operation::WriteFile {
            receipt: r,
            options,
            total_bytes,
        } => {
            let Some(upload) = upload else {
                return wire::Outcome::Error {
                    code: wire::SafeCode::Io,
                    dispatch: wire::Dispatch::NotDispatched,
                };
            };
            engine
                .write_file_from_reader(
                    &receipt(&r),
                    file_options(&options, remaining),
                    upload,
                    total_bytes,
                    cancel,
                )
                .map(file)
        }
    };
    result.unwrap_or_else(error)
}
