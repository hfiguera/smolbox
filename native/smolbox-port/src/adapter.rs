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
fn growth_wire(transition: engine::GrowthTransition) -> engine::Result<wire::GrowthTransition> {
    let converted = serde_json::to_value(transition)
        .ok()
        .and_then(|value| serde_json::from_value::<wire::GrowthTransition>(value).ok())
        .ok_or(engine::Error {
            code: engine::ErrorCode::Native,
            dispatch: engine::Dispatch::NotDispatched,
        })?;
    converted.validate().map_err(|_| engine::Error {
        code: engine::ErrorCode::Ownership,
        dispatch: engine::Dispatch::NotDispatched,
    })?;
    Ok(converted)
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
    let operation_deadline = Instant::now().checked_add(remaining);
    let observation_budget =
        || engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel.clone());
    let result = match operation {
        wire::Operation::QualifyRegistryCreation {source,resources:requested,user,features}=>observation_budget().and_then(|budget| {
            let source=source.request();engine.qualify_registry_intent(&engine::RegistryArtifactSource {reference:source.reference,platform:source.platform,content_sha256:source.content_sha256},resources(&requested),user.as_deref(),&effective_features(features),&budget)
        }).map(|()|wire::Outcome::Qualified),
        wire::Operation::CreateRegistryPrepared {..}=>return wire::Outcome::Error {code:wire::SafeCode::Unsupported,dispatch:wire::Dispatch::NotDispatched},
        wire::Operation::InspectRegistryCreation {create}=> observation_budget().and_then(|budget|engine.inspect_registry_creation(&registry_intent(create),&budget)).map(|presence|wire::Outcome::CreationPresence {presence:match presence {engine::CreationPresence::Absent=>wire::CreationPresence::Absent,engine::CreationPresence::Unverified=>wire::CreationPresence::Unverified}}),
        wire::Operation::PrepareArtifact {..}=>return wire::Outcome::Error {code:wire::SafeCode::Unsupported,dispatch:wire::Dispatch::NotDispatched},
        wire::Operation::StartOci { receipt: supplied, source } => {
            operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation,
                dispatch: engine::Dispatch::NotDispatched }).and_then(|deadline| {
                let source = source.request();
                engine.start_oci_source_owned(&receipt(&supplied), &engine::ImagePullRequest {
                    reference: source.reference, platform: source.platform,
                }, deadline, cancel.clone())
            }).map(observation)
        }
        wire::Operation::CreateOci { create } => {
            operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation,
                dispatch: engine::Dispatch::NotDispatched })
                .and_then(|deadline| engine.create_oci_intent(oci_intent(create), deadline, &cancel))
                .map(|receipt| wire::Outcome::Created { receipt: receipt_wire(receipt) })
        }
        wire::Operation::InspectOciCreation { create } => {
            observation_budget().and_then(|budget| engine.inspect_oci_creation(&oci_intent(create), &budget))
                .map(|presence| wire::Outcome::CreationPresence { presence: match presence {
                    engine::CreationPresence::Absent => wire::CreationPresence::Absent,
                    engine::CreationPresence::Unverified => wire::CreationPresence::Unverified,
                } })
        }
        wire::Operation::QualifyOciCreation { source, resources: requested, user, features: requested_features } => {
            operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation,
                dispatch: engine::Dispatch::NotDispatched }).and_then(|deadline| {
                let source = source.request();
                engine.qualify_oci_creation(engine::ImagePullRequest { reference: source.reference, platform: source.platform },
                    resources(&requested), user.as_deref(), effective_features(requested_features), deadline, &cancel)
            }).map(|()| wire::Outcome::Qualified)
        }
        wire::Operation::ExpandDisks { receipt: supplied, operation_id, request, previous } => {
            let owned = receipt(&supplied);
            engine.inspect(&owned).and_then(|observed| {
                let deadline = operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation, dispatch: engine::Dispatch::NotDispatched })?;
                let sizes = observed.resources.ok_or(engine::Error { code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::NotDispatched })?;
                if observed.state != engine::ObservedState::Stopped || sizes.storage_gib != previous.storage_gib || sizes.overlay_gib != previous.overlay_gib {
                    return Err(engine::Error { code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::NotDispatched });
                }
                let transition = engine.expand_disks_transition_owned(&owned, &operation_id, engine::GrowDisks {
                    storage_gib: request.storage_gib, overlay_gib: request.overlay_gib,
                }, deadline, &cancel)?;
                let observed = engine.inspect(&transition.receipt).map_err(|error| engine::Error { code: error.code, dispatch: engine::Dispatch::MayHaveDispatched })?;
                if observed.state != engine::ObservedState::Stopped {
                    return Err(engine::Error { code: engine::ErrorCode::State, dispatch: engine::Dispatch::MayHaveDispatched });
                }
                let transition = growth_wire(transition).map_err(|error| engine::Error { code: error.code, dispatch: engine::Dispatch::MayHaveDispatched })?;
                let wire::Outcome::Observed { observation } = observation(observed) else { unreachable!() };
                Ok(wire::Outcome::Grown { transition: Box::new(transition), observation })
            })
        },
        wire::Operation::QualifyGrowth { receipt: supplied, operation_id, request, previous, quiesced } => {
            observation_budget().and_then(|budget| {
                let transition = engine.qualify_growth(&receipt(&supplied), &operation_id, engine::GrowDisks {
                    storage_gib: request.storage_gib, overlay_gib: request.overlay_gib,
                }, (previous.storage_gib, previous.overlay_gib), quiesced, &budget)?;
                let transition = growth_wire(transition).map_err(|error| engine::Error { code: error.code, dispatch: engine::Dispatch::MayHaveDispatched })?;
                transition.matches(&supplied, &operation_id, request, previous).map_err(|_| engine::Error { code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched })?;
                if operation_deadline.is_none_or(|deadline| Instant::now() >= deadline) || cancel.is_cancelled() {
                    return Err(engine::Error { code: engine::ErrorCode::State, dispatch: engine::Dispatch::MayHaveDispatched });
                }
                let observed = engine.inspect(&receipt(&transition.receipt)).map_err(|error| engine::Error { code: error.code, dispatch: engine::Dispatch::MayHaveDispatched })?;
                if observed.state != engine::ObservedState::Stopped || operation_deadline.is_none_or(|deadline| Instant::now() >= deadline) || cancel.is_cancelled() {
                    return Err(engine::Error { code: engine::ErrorCode::State, dispatch: engine::Dispatch::MayHaveDispatched });
                }
                let wire::Outcome::Observed { observation } = observation(observed) else { unreachable!() };
                Ok(wire::Outcome::GrowthQualified { transition: Box::new(transition), observation })
            })
        },
        wire::Operation::InspectGrowth { receipt: supplied, operation_id, request, previous } => {
            observation_budget().and_then(|budget| engine.inspect_growth_transition_with_budget(&receipt(&supplied), &operation_id, engine::GrowDisks {
                storage_gib: request.storage_gib, overlay_gib: request.overlay_gib,
            }, &budget)).and_then(|transition| {
                let transition = transition.map(growth_wire).transpose()?;
                if let Some(transition) = &transition {
                    transition.matches(&supplied, &operation_id, request, previous).map_err(|_| engine::Error { code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::NotDispatched })?;
                }
                Ok(wire::Outcome::GrowthPresence { transition: transition.map(Box::new) })
            })
        },
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
        wire::Operation::PullImage { receipt: proof, source } => {
            let request = engine::ImagePullRequest { reference: source.reference, platform: source.platform };
            operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation, dispatch: engine::Dispatch::NotDispatched })
                .and_then(|deadline| engine.pull_image_owned(&receipt(&proof), request, deadline, cancel.clone()))
                .map(|image| wire::Outcome::Pulled { image: wire::ImageObservation { reference: image.reference,
                    digest: image.digest, size: image.size, architecture: image.architecture, os: image.os, layer_count: image.layer_count } })
        },
        wire::Operation::ListImages { receipt: proof } => observation_budget().and_then(|budget| {
            engine.list_images_stream(&receipt(&proof), &budget,
                |chunk| emit(wire::Stream::File, chunk))
                .map(|(count, bytes)| wire::Outcome::Images { count, bytes })
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

pub fn prepare_artifact(
    engine: &engine::Engine,
    approval: crate::package::RegistryApproval,
    token: Option<wire::RegistryToken>,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    if approval.credential_ref.is_some() != token.is_some() {
        return wire::Outcome::Error {
            code: wire::SafeCode::Unsupported,
            dispatch: wire::Dispatch::NotDispatched,
        };
    }
    let Some(deadline) = Instant::now().checked_add(remaining) else {
        return wire::Outcome::Error {
            code: wire::SafeCode::Validation,
            dispatch: wire::Dispatch::NotDispatched,
        };
    };
    let source = wire::RegistrySource {
        reference: approval.source.reference.clone(),
        platform: approval.source.platform.clone(),
        content_sha256: approval.source.content_sha256.clone(),
    };
    let credential = match token {
        Some(token) => match approval.token_realm.as_deref().and_then(|realm| {
            engine::RegistryIdentityCredential::new(token.into_secret(), realm).ok()
        }) {
            Some(credential) => Some(credential),
            None => {
                return wire::Outcome::Error {
                    code: wire::SafeCode::Validation,
                    dispatch: wire::Dispatch::NotDispatched,
                }
            }
        },
        None => None,
    };
    match engine.prepare_registry_blob_with_credential(
        approval.source,
        approval.max_bytes,
        approval.cache_policy,
        deadline,
        cancel,
        credential,
    ) {
        Ok(blob) => wire::Outcome::PreparedArtifact {
            source,
            size_bytes: blob.size(),
            already_cached: blob.already_cached(),
        },
        Err(failure) => error(failure),
    }
}

fn registry_intent(create: wire::RegistryCreate) -> engine::RegistryCreationIntent {
    let source = create.source.request();
    engine::RegistryCreationIntent {
        name: create.name,
        owner_token: create.owner_token,
        incarnation: create.incarnation,
        source: engine::RegistryArtifactSource {
            reference: source.reference,
            platform: source.platform,
            content_sha256: source.content_sha256,
        },
        resources: resources(&create.resources),
        labels: create.labels,
        features: effective_features(create.features),
    }
}
pub fn create_registry_prepared(
    engine: &engine::Engine,
    create: wire::RegistryCreate,
    size: u64,
    approval: crate::package::RegistryApproval,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    let Some(deadline) = Instant::now().checked_add(remaining) else {
        return wire::Outcome::Error {
            code: wire::SafeCode::Validation,
            dispatch: wire::Dispatch::NotDispatched,
        };
    };
    if size > approval.max_bytes {
        return wire::Outcome::Error {
            code: wire::SafeCode::Unsupported,
            dispatch: wire::Dispatch::NotDispatched,
        };
    }
    match engine.create_registry_cached(
        registry_intent(create),
        size,
        approval.cache_policy,
        deadline,
        &cancel,
    ) {
        Ok(receipt) => wire::Outcome::Created {
            receipt: receipt_wire(receipt),
        },
        Err(failure) => error(failure),
    }
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

fn effective_features(value: Option<Box<wire::CreationFeatures>>) -> engine::CreationFeatures {
    value
        .map(|value| features(*value))
        .unwrap_or_else(|| engine::CreationFeatures {
            network: engine::NetworkPolicy {
                enabled: false,
                hosts: vec![],
                cidrs: vec![],
            },
            ports: vec![],
            workload: None,
        })
}
fn oci_intent(create: wire::OciCreate) -> engine::OciCreationIntent {
    let source = create.source.request();
    engine::OciCreationIntent {
        name: create.name,
        owner_token: create.owner_token,
        incarnation: create.incarnation,
        source: engine::ImagePullRequest {
            reference: source.reference,
            platform: source.platform,
        },
        resources: resources(&create.resources),
        labels: create.labels,
        features: effective_features(create.features),
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

#[cfg(test)]
mod growth_tests {
    use super::*;

    #[test]
    fn completed_engine_transition_converts_without_changing_canonical_evidence() {
        let proofs: Vec<engine::GrowthTransition> = serde_json::from_slice(include_bytes!(
            "../../smolbox-protocol/fixtures/growth-transitions-v1.json"
        ))
        .unwrap();
        for proof in proofs {
            let expected = serde_json::to_value(&proof).unwrap();
            let converted = growth_wire(proof).unwrap();
            converted.validate().unwrap();
            assert_eq!(serde_json::to_value(converted).unwrap(), expected);
        }
    }
}
