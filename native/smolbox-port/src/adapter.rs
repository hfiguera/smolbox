//! Explicit conversion at the bridge boundary; engine types stay wire-neutral.
use smolbox_engine as engine;
use smolbox_protocol as wire;
use std::fs::File;
use std::time::{Duration, Instant};

pub fn receipt(receipt: &wire::Receipt) -> engine::CreationReceipt {
    engine::CreationReceipt {
        target_id: receipt.target_id.clone(),
        domain_generation: receipt.domain_generation.clone(),
        name: receipt.name.clone(),
        owner_token: receipt.owner_token.clone(),
        incarnation: receipt.incarnation.clone(),
        material_sha256: receipt.material_sha256.clone(),
        material: receipt
            .material
            .as_ref()
            .map(|proof| engine::MaterialProof {
                schema: proof.schema,
                revision: proof.revision,
                record_sha256: proof.record_sha256.clone(),
                chain_sha256: proof.chain_sha256.clone(),
                operation_id: proof.operation_id.clone(),
                request_sha256: proof.request_sha256.clone(),
            }),
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
        material: receipt.material.map(|proof| {
            Box::new(wire::MaterialProof {
                schema: proof.schema,
                revision: proof.revision,
                record_sha256: proof.record_sha256,
                chain_sha256: proof.chain_sha256,
                operation_id: proof.operation_id,
                request_sha256: proof.request_sha256,
            })
        }),
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
            configuration: observation.configuration.map(|value| {
                Box::new(wire::MachineConfiguration {
                    network: wire::NetworkPolicy {
                        enabled: value.network.enabled,
                        hosts: value.network.hosts,
                        cidrs: value.network.cidrs,
                    },
                    ports: value
                        .ports
                        .into_iter()
                        .map(|p| wire::PortMapping {
                            host: p.host,
                            guest: p.guest,
                        })
                        .collect(),
                    backend: value.backend,
                })
            }),
        },
    }
}
fn dispatch(dispatch: engine::Dispatch) -> wire::Dispatch {
    match dispatch {
        engine::Dispatch::NotDispatched => wire::Dispatch::NotDispatched,
        engine::Dispatch::MayHaveDispatched => wire::Dispatch::MayHaveDispatched,
    }
}
fn file_completion(value: engine::FileCompletion) -> wire::Completion {
    match value {
        engine::FileCompletion::Completed => wire::Completion::Completed,
        engine::FileCompletion::Cancelled => wire::Completion::Cancelled,
        engine::FileCompletion::Deadline => wire::Completion::Deadline,
        engine::FileCompletion::NativeError => wire::Completion::NativeError,
        engine::FileCompletion::ConsumerLost => wire::Completion::ConsumerLost,
        engine::FileCompletion::OutputLimit => wire::Completion::OutputLimit,
    }
}
pub fn error(error: engine::Error) -> wire::Outcome {
    wire::Outcome::Error {
        code: match error.code {
            engine::ErrorCode::NotFound => wire::SafeCode::NotFound,
            engine::ErrorCode::Validation => wire::SafeCode::Validation,
            engine::ErrorCode::Unsupported => wire::SafeCode::Unsupported,
            engine::ErrorCode::Conflict => wire::SafeCode::Conflict,
            engine::ErrorCode::Ownership => wire::SafeCode::Ownership,
            engine::ErrorCode::Database => wire::SafeCode::Database,
            engine::ErrorCode::State => wire::SafeCode::State,
            engine::ErrorCode::Native => wire::SafeCode::Native,
            engine::ErrorCode::Io => wire::SafeCode::Io,
            engine::ErrorCode::OutputLimit => wire::SafeCode::OutputLimit,
            engine::ErrorCode::PortConflict => wire::SafeCode::PortConflict,
            engine::ErrorCode::Admission => wire::SafeCode::Overload,
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
            engine::FileCompletion::OutputLimit => wire::Completion::OutputLimit,
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
    let observation_budget =
        || engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel.clone());
    let result = match operation {
        // Interactive controls require the dedicated runtime TerminalBridge;
        // the ordinary one-way adapter cannot dispatch a terminal session.
        wire::Operation::TerminalOpen { .. } => Err(engine::Error { code: engine::ErrorCode::Unsupported, dispatch: engine::Dispatch::NotDispatched }),
        wire::Operation::Logs {receipt: r, tail, follow, max_bytes} => {
            let mut wire_bytes = 0;
            engine.logs(&receipt(&r), engine::LogOptions {tail, follow, timeout: remaining, max_bytes}, cancel,
                |line| {
                    let mut frame = (line.len() as u32).to_be_bytes().to_vec();
                    frame.extend_from_slice(line.as_bytes());
                    for chunk in frame.chunks(wire::MAX_CHUNK_BYTES) {
                        emit(wire::Stream::Log, chunk)?;
                        wire_bytes += chunk.len() as u64;
                    }
                    Ok(())
                }
            ).map(|value| wire::Outcome::Logs {completion: file_completion(value.completion), lines: value.lines,
                bytes: value.bytes, wire_bytes})
        },
        wire::Operation::Health => observation_budget().and_then(|budget| engine.node_health(&budget)).map(|value| wire::Outcome::Health {
            snapshot: wire::HealthSnapshot { total: value.total, running: value.running, uptime_seconds: value.uptime_seconds }
        }),
        wire::Operation::Readiness => observation_budget().and_then(|budget| {
            if !engine.available() { return Err(engine::Error { code: engine::ErrorCode::State, dispatch: engine::Dispatch::NotDispatched }); }
            engine.node_health(&budget).map(|_| wire::Outcome::Ready)
        }),
        wire::Operation::Capacity => observation_budget().and_then(|budget| engine.node_capacity(&budget)).map(capacity),
        wire::Operation::Metrics => observation_budget().and_then(|budget| {
            let health = engine.node_health(&budget)?;
            let node = engine.node_capacity(&budget)?;
            Ok(wire::Outcome::Metrics { text: format!("# TYPE smolbox_native_machines gauge\nsmolbox_native_machines {}\n# TYPE smolbox_native_running_machines gauge\nsmolbox_native_running_machines {}\n# TYPE smolbox_native_allocated_cpus gauge\nsmolbox_native_allocated_cpus {}\n# TYPE smolbox_native_allocated_memory_mb gauge\nsmolbox_native_allocated_memory_mb {}\n# TYPE smolbox_native_used_cpus gauge\nsmolbox_native_used_cpus {}\n# TYPE smolbox_native_used_memory_mb gauge\nsmolbox_native_used_memory_mb {}\n# TYPE smolbox_native_used_disk_gb gauge\nsmolbox_native_used_disk_gb {}\n", health.total, health.running, node.allocated_cpus, node.allocated_memory_mb, node.used_cpu_millis as f64 / 1000.0, node.used_memory_mb, node.used_disk_gb) })
        }),
        wire::Operation::List => observation_budget().and_then(|budget| {
            let value = engine.inventory(&budget)?;
            for chunk in value.bytes.chunks(wire::MAX_CHUNK_BYTES) {
                if cancel.is_cancelled() || emit(wire::Stream::File, chunk).is_err() { return Err(engine::Error {code: engine::ErrorCode::Io, dispatch: engine::Dispatch::MayHaveDispatched}); }
            }
            Ok(wire::Outcome::Inventory { count: value.count, bytes: value.bytes.len() as u64 })
        }),
        wire::Operation::Measurements { receipt: proof } => observation_budget().and_then(|budget| engine.machine_counters(&receipt(&proof), &budget)).map(|(value, counters)| {
            let wire::Outcome::Observed { observation } = observation(value) else { unreachable!() };
            wire::Outcome::Measurements { observation, counters: Box::new(wire::MachineCounters {
                cpu_seconds: counters.cpu_seconds, cpu_millis: counters.cpu_millis, rss_mb: counters.rss_mb,
                pss_mb: counters.pss_mb, private_memory_mb: counters.private_memory_mb,
                shared_memory_mapped_mb: counters.shared_memory_mapped_mb, disk_used_mb: counters.disk_used_mb, egress_bytes: counters.egress_bytes
            }) }
        }),
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
            features: requested,
        } => engine
            .qualify_creation_with_features(
                &engine::ApprovedArtifact {
                    path: artifact.path.into(),
                    sha256: artifact.sha256,
                    max_bytes: artifact.max_bytes,
                    guest_platform: artifact.guest_platform,
                },
                resources(&admitted),
                user.as_deref(),
                requested.map(|value| features(*value)).as_ref(),
            )
            .map(|()| wire::Outcome::Qualified),
        wire::Operation::Create { create } => {
            let requested = create.features.map(|value| features(*value));
            let request = engine::CreateRequest {
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
            };
            let result = match requested {
                Some(features) => engine.create_with_features(request, features),
                None => engine.create_versioned(request),
            };
            result
            .map(|r| wire::Outcome::Created {
                receipt: receipt_wire(r),
            })
        },
        wire::Operation::Inspect { receipt: r } => engine.inspect(&receipt(&r)).map(observation),
        wire::Operation::Start { receipt: r } => engine.start(&receipt(&r)).map(observation),
        wire::Operation::Stop { receipt: r } => engine.stop(&receipt(&r)).map(observation),
        wire::Operation::Delete { receipt: r } => engine.delete(&receipt(&r)).map(observation),
        wire::Operation::ExecBackground {receipt:r,command} => engine.exec_background(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel
        ).map(|value| {
            if value.transfer.success() {
                if let Some(pid) = value.pid { return wire::Outcome::Launched { pid }; }
            }
            wire::Outcome::Error {
                code: match value.transfer.completion {
                    engine::FileCompletion::Cancelled => wire::SafeCode::Cancelled,
                    engine::FileCompletion::Deadline => wire::SafeCode::Deadline,
                    engine::FileCompletion::OutputLimit => wire::SafeCode::OutputLimit,
                    _ => wire::SafeCode::Native,
                },
                dispatch: dispatch(value.transfer.dispatch),
            }
        }),
        wire::Operation::ExecStream {receipt:r,command} => engine.exec_stream_owned(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel,
            |output|emit(match output.stream {engine::Stream::Stdout=>wire::Stream::Stdout,engine::Stream::Stderr=>wire::Stream::Stderr},&output.bytes)
        ).map(command_outcome),
        wire::Operation::ExecBuffered {receipt:r,command} => engine.exec_buffered(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel,
            |output|emit(match output.stream {engine::Stream::Stdout=>wire::Stream::Stdout,engine::Stream::Stderr=>wire::Stream::Stderr},&output.bytes)
        ).map(command_outcome),
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
            .map(command_outcome),
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

fn capacity(value: engine::CapacitySnapshot) -> wire::Outcome {
    wire::Outcome::Capacity {
        snapshot: Box::new(wire::CapacitySnapshot {
            allocated_cpus: value.allocated_cpus,
            allocated_memory_mb: value.allocated_memory_mb,
            used_cpu_millis: value.used_cpu_millis,
            used_memory_mb: value.used_memory_mb,
            used_memory_pss_mb: value.used_memory_pss_mb,
            used_memory_private_mb: value.used_memory_private_mb,
            used_memory_shared_mapped_mb: value.used_memory_shared_mapped_mb,
            host_memory_total_mb: value.host_memory_total_mb,
            host_memory_available_mb: value.host_memory_available_mb,
            used_disk_gb: value.used_disk_gb,
            boot_id: value.boot_id,
        }),
    }
}

fn features(value: wire::CreationFeatures) -> engine::CreationFeatures {
    engine::CreationFeatures {
        network: engine::NetworkPolicy {
            enabled: value.network.enabled,
            hosts: value.network.hosts,
            cidrs: value.network.cidrs,
        },
        ports: value
            .ports
            .into_iter()
            .map(|p| engine::PortMapping {
                host: p.host,
                guest: p.guest,
            })
            .collect(),
        workload: value.workload.map(|workload| engine::StartupWorkload {
            entrypoint: workload.entrypoint,
            cmd: workload.cmd,
            env: workload.env,
            workdir: workload.workdir,
        }),
    }
}

fn command_outcome(outcome: engine::CommandOutcome) -> wire::Outcome {
    wire::Outcome::Command {
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
    }
}

pub fn terminal(
    engine: &engine::Engine,
    proof: wire::Receipt,
    spec: wire::TerminalSpec,
    remaining: Duration,
    cancel: engine::Cancellation,
    bridge: &mut dyn crate::runtime::TerminalBridge,
) -> wire::Outcome {
    let options = engine::TerminalOptions {
        program: spec.program,
        cols: spec.cols,
        rows: spec.rows,
        session: Duration::from_millis(spec.session_ms),
        idle: Duration::from_millis(spec.idle_ms),
        attach: Duration::from_millis(spec.attach_ms),
        close: Duration::from_millis(spec.close_ms),
        max_buffer_bytes: spec.max_buffer_bytes,
        max_input_bytes: spec.max_input_bytes,
        total_input_bytes: spec.total_input_bytes,
    };
    let bridge = std::cell::RefCell::new(bridge);
    let bytes = std::cell::Cell::new(0u64);
    match engine.terminal_owned(
        &receipt(&proof),
        engine::TerminalRequest {
            options,
            deadline: Instant::now() + remaining,
            cancel,
        },
        || bridge.borrow_mut().control(),
        |event| match event {
            engine::TerminalEvent::Opened => bridge.borrow_mut().opened(),
            engine::TerminalEvent::Output(output) => {
                let n = output.bytes.len() as u64;
                bridge.borrow_mut().output(output)?;
                bytes.set(bytes.get() + n);
                Ok(())
            }
        },
    ) {
        Ok(result) => wire::Outcome::Terminal {
            completion: match result.outcome.failure {
                None if result.collected => wire::Completion::Exited,
                Some(engine::TerminalFailure::Cancelled) => wire::Completion::Cancelled,
                Some(
                    engine::TerminalFailure::InputLimit | engine::TerminalFailure::OutputLimit,
                ) => wire::Completion::OutputLimit,
                Some(engine::TerminalFailure::ConsumerLost) => wire::Completion::ConsumerLost,
                Some(
                    engine::TerminalFailure::SessionDeadline
                    | engine::TerminalFailure::IdleDeadline
                    | engine::TerminalFailure::AttachDeadline
                    | engine::TerminalFailure::CloseDeadline,
                ) => wire::Completion::Deadline,
                _ => wire::Completion::NativeError,
            },
            dispatch: dispatch(result.dispatch),
            observed_exit: result.outcome.observed_exit,
            worker_collected: result.collected,
            output_bytes: bytes.get(),
        },
        Err(value) => error(value),
    }
}
