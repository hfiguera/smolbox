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
                let mounts = if value.mounts.is_empty() {
                    None
                } else {
                    Some(
                        value
                            .mounts
                            .into_iter()
                            .map(|mount| wire::ObservedMount {
                                source: mount.source,
                                target: mount.target,
                                readonly: mount.readonly,
                                staged: mount.staged,
                            })
                            .collect(),
                    )
                };
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
                    mounts,
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
    emit: impl FnMut(wire::Stream, &[u8]) -> Result<(), ()>,
) -> wire::Outcome {
    run_with_policy(engine, operation, None, remaining, cancel, upload, emit)
}

pub fn run_with_policy(
    engine: &engine::Engine,
    operation: wire::Operation,
    policy: Option<engine::LocalVolumePolicy>,
    remaining: Duration,
    cancel: engine::Cancellation,
    upload: Option<File>,
    mut emit: impl FnMut(wire::Stream, &[u8]) -> Result<(), ()>,
) -> wire::Outcome {
    let entered = Instant::now();
    let operation_deadline = entered.checked_add(remaining);
    let stop_deadline = capped_stop_deadline(entered, remaining);
    let mounts = match mount_selection(operation.creation_mounts(), policy.as_ref()) {
        Ok(mounts) => mounts,
        Err(failure) => return error(failure),
    };
    let observation_budget =
        || engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel.clone());
    let result = match operation {
        wire::Operation::InspectUnbootedBranchDisposal { .. } | wire::Operation::DisposeUnbootedBranch { .. } | wire::Operation::ResolveUnbootedBranchDisposal { .. } | wire::Operation::ReleaseUnbootedBranchBacking { .. } | wire::Operation::RetirePreparedBranch { .. } | wire::Operation::ContinueHeldBranchDeletion { .. } | wire::Operation::CleanupHeldBranchDeletion { .. }
        | wire::Operation::ContinueReleasedBranchDeletion { .. }
        | wire::Operation::CollectBranchDeletion { .. }
        | wire::Operation::CleanupReleasedBranchDeletion { .. }
        | wire::Operation::ResolveReleasedBranchDeletion { .. }
        | wire::Operation::ResolveHeldBranchDeletion { .. }
        | wire::Operation::ReleaseBranchBacking { .. }
        | wire::Operation::QualifyUnbootedBranchChildAbsence { .. }
        | wire::Operation::QualifyBranchChildAbsence { .. }
        | wire::Operation::ReleaseHeldBranch { .. } | wire::Operation::QualifyHeldBranchRelease { .. }
        | wire::Operation::CreateBranch { .. } | wire::Operation::InspectBranchCompletion { .. }
        | wire::Operation::ResolveReadyBranchCompletion { .. } =>
            return error(engine::Error {code:engine::ErrorCode::Unsupported, dispatch:engine::Dispatch::NotDispatched}),
        wire::Operation::BranchPreflight { receipt: supplied } => observation_budget()
            .and_then(|budget| engine.branch_preflight(&receipt(&supplied), &budget))
            .map(observation),
        wire::Operation::QualifyCheckpointCreation { .. }
        | wire::Operation::CreateCheckpoint { .. }
        | wire::Operation::InspectCheckpointCreation { .. } => return wire::Outcome::Error {
            code: wire::SafeCode::Unsupported,
            dispatch: wire::Dispatch::NotDispatched,
        },
        wire::Operation::Volume { .. } => return wire::Outcome::Error {code:wire::SafeCode::Unsupported,dispatch:wire::Dispatch::NotDispatched},
        wire::Operation::QualifyRegistryCreation {source,resources:requested,user,features,..}=>observation_budget().and_then(|budget| {
            let source=source.request();engine.qualify_registry_intent(&engine::RegistryArtifactSource {reference:source.reference,platform:source.platform,content_sha256:source.content_sha256},resources(&requested),user.as_deref(),&effective_features(features),&budget)
        }).map(|()|wire::Outcome::Qualified),
        wire::Operation::CreateRegistryPrepared {..}=>return wire::Outcome::Error {code:wire::SafeCode::Unsupported,dispatch:wire::Dispatch::NotDispatched},
        wire::Operation::InspectRegistryCreation {create}=> observation_budget().and_then(|budget|engine.inspect_registry_creation(&registry_intent(create),&budget)).map(|presence|wire::Outcome::CreationPresence {presence:match presence {engine::CreationPresence::Absent=>wire::CreationPresence::Absent,engine::CreationPresence::Unverified=>wire::CreationPresence::Unverified}}),
        wire::Operation::PrepareArtifact {..}=>return wire::Outcome::Error {code:wire::SafeCode::Unsupported,dispatch:wire::Dispatch::NotDispatched},
        wire::Operation::StartOci { receipt: supplied, source } => {
            operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation,
                dispatch: engine::Dispatch::NotDispatched }).and_then(|deadline| {
                let source = source.request();
                let source = engine::ImagePullRequest { reference: source.reference, platform: source.platform };
                match &policy {
                    Some(policy) => engine.start_oci_source_with_volume_policy(&receipt(&supplied), &source, policy, deadline, cancel.clone()),
                    None => engine.start_oci_source_owned(&receipt(&supplied), &source, deadline, cancel.clone()),
                }
            }).map(observation)
        }
        wire::Operation::CreateOci { create } => {
            operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation,
                dispatch: engine::Dispatch::NotDispatched })
                .and_then(|deadline| match mounts {
                    Some(mounts) => engine.create_oci_intent_with_mount_selection(oci_intent(create), mounts, deadline, &cancel),
                    None => engine.create_oci_intent(oci_intent(create), deadline, &cancel),
                })
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
        wire::Operation::InspectExport {receipt: supplied, operation_id, request_sha256} => {
            observation_budget().and_then(|budget| {
                let publication = engine.inspect_export_publication(&receipt(&supplied), &operation_id, &request_sha256, &budget)?;
                let converted = publication.map(|proof| {
                    let proof: wire::ExportPublication = serde_json::from_value(serde_json::to_value(proof).map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::NotDispatched})?).map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::NotDispatched})?;
                    proof.matches(&supplied, &operation_id, &request_sha256).map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::NotDispatched})?;
                    Ok(Box::new(proof))
                }).transpose()?;
                Ok(wire::Outcome::ExportPresence {publication: converted})
            })
        },
        wire::Operation::CleanupExportStaging {receipt: supplied, operation_id, request_sha256, quiesced} => {
            observation_budget().and_then(|budget| {
                let cleanup = engine.cleanup_export_staging(&receipt(&supplied), &operation_id, &request_sha256, quiesced, &budget)?;
                let cleanup: wire::ExportStageCleanup = serde_json::from_value(serde_json::to_value(cleanup).map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?).map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                cleanup.matches(&supplied, &operation_id, &request_sha256).map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                Ok(wire::Outcome::ExportStagingCleaned {cleanup: Box::new(cleanup)})
            })
        },
        wire::Operation::QualifyExport {..} | wire::Operation::AdmitExport {..} | wire::Operation::ExportMachine {..} => Err(engine::Error {code: engine::ErrorCode::Unsupported, dispatch: engine::Dispatch::NotDispatched}),
        wire::Operation::CaptureCheckpoint { receipt: supplied, operation_id, request, chunk_bytes } => {
            engine::ReadBudget::for_checkpoint_work(remaining, cancel.clone()).and_then(|budget| {
                let mut captured = engine.capture_checkpoint(&receipt(&supplied), &operation_id,
                    engine::CaptureRequest {max_bytes: request.max_bytes, idle: request.idle}, budget.clone())?;
                let transition: wire::CaptureTransition = serde_json::to_value(captured.transition()).ok()
                    .and_then(|value| serde_json::from_value(value).ok())
                    .ok_or(engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                transition.matches(&supplied, &operation_id, &request).map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                captured.stream(&budget, |chunk| {
                    for part in chunk.chunks(chunk_bytes.unwrap_or(wire::MAX_CHUNK_BYTES as u64) as usize) {
                        emit(wire::Stream::Checkpoint, part).map_err(|_| engine::Error {code: engine::ErrorCode::Io, dispatch: engine::Dispatch::MayHaveDispatched})?;
                    }
                    Ok(())
                })
                    .map_err(|error| engine::Error {code: error.code, dispatch: engine::Dispatch::MayHaveDispatched})?;
                if cancel.is_cancelled() || operation_deadline.is_none_or(|deadline| Instant::now() >= deadline) {
                    return Err(engine::Error {code: engine::ErrorCode::State, dispatch: engine::Dispatch::MayHaveDispatched});
                }
                Ok(wire::Outcome::Captured {transition: Box::new(transition)})
            })
        },
        wire::Operation::QualifyAbortedCaptureSource { receipt: supplied, operation_id, request, quiesced } => {
            observation_budget().and_then(|budget| {
                let qualification = engine.qualify_aborted_capture_source(&receipt(&supplied), &operation_id,
                    &engine::CaptureRequest {max_bytes: request.max_bytes, idle: request.idle}, quiesced, &budget)?;
                let converted: wire::CaptureAbortSourceQualification = serde_json::to_value(qualification).ok()
                    .and_then(|value| serde_json::from_value(value).ok())
                    .ok_or(engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                converted.matches(&supplied, &operation_id, &request)
                    .map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                Ok(wire::Outcome::AbortedCaptureSourceQualified {qualification: Box::new(converted)})
            })
        },
        wire::Operation::AbortCaptureStaging { receipt: supplied, operation_id, request, quiesced } => {
            observation_budget().and_then(|budget| {
                let cleanup = engine.abort_capture_staging(&receipt(&supplied), &operation_id,
                    &engine::CaptureRequest {max_bytes: request.max_bytes, idle: request.idle}, quiesced, &budget)?;
                let converted: wire::CaptureStagingCleanupReceipt = serde_json::to_value(cleanup).ok()
                    .and_then(|value| serde_json::from_value(value).ok())
                    .ok_or(engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                converted.matches(&supplied, &operation_id, &request)
                    .map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                Ok(wire::Outcome::CaptureStagingAborted {cleanup: Box::new(converted)})
            })
        },
        wire::Operation::CleanupCaptureStaging { receipt: supplied, operation_id, request, quiesced } => {
            observation_budget().and_then(|budget| {
                let cleanup = engine.cleanup_capture_staging(&receipt(&supplied), &operation_id,
                    &engine::CaptureRequest {max_bytes: request.max_bytes, idle: request.idle}, quiesced, &budget)?;
                let converted: wire::CaptureStagingCleanupReceipt = serde_json::to_value(cleanup).ok()
                    .and_then(|value| serde_json::from_value(value).ok())
                    .ok_or(engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                converted.matches(&supplied, &operation_id, &request)
                    .map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                Ok(wire::Outcome::CaptureStagingCleaned {cleanup: Box::new(converted)})
            })
        },
        wire::Operation::ResolveCapture { receipt: supplied, operation_id, request, quiesced: true } => {
            observation_budget().and_then(|budget| {
                let transition = engine.resolve_entered_capture(&receipt(&supplied), &operation_id,
                    &engine::CaptureRequest {max_bytes: request.max_bytes, idle: request.idle}, &budget)?;
                let converted: wire::CaptureResolutionTransition = serde_json::to_value(transition).ok()
                    .and_then(|value| serde_json::from_value(value).ok())
                    .ok_or(engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                converted.matches(&supplied, &operation_id, &request)
                    .map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::MayHaveDispatched})?;
                Ok(wire::Outcome::CaptureResolved {transition: Box::new(converted)})
            })
        },
        wire::Operation::ResolveCapture { quiesced: false, .. } => {
            Err(engine::Error {code: engine::ErrorCode::Validation, dispatch: engine::Dispatch::NotDispatched})
        },
        wire::Operation::InspectCaptureResolution { receipt: supplied, operation_id, request } => {
            observation_budget().and_then(|budget| {
                let transition = engine.resolved_capture_with_budget(&receipt(&supplied), &operation_id,
                    &engine::CaptureRequest {max_bytes: request.max_bytes, idle: request.idle}, &budget)?;
                let converted = transition.map(|transition| {
                    let converted: wire::CaptureResolutionTransition = serde_json::to_value(transition).ok()
                        .and_then(|value| serde_json::from_value(value).ok())
                        .ok_or(engine::Error {code: engine::ErrorCode::Native, dispatch: engine::Dispatch::NotDispatched})?;
                    converted.matches(&supplied, &operation_id, &request)
                        .map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::NotDispatched})?;
                    Ok(converted)
                }).transpose()?;
                Ok(wire::Outcome::CaptureResolutionPresence {transition: converted.map(Box::new)})
            })
        },
        wire::Operation::InspectCapture { receipt: supplied, operation_id, request } => {
            observation_budget().and_then(|budget| {
                let transition = engine.completed_capture_with_budget(&receipt(&supplied), &operation_id,
                    &engine::CaptureRequest {max_bytes: request.max_bytes, idle: request.idle}, &budget)?;
                let converted = transition.map(|transition| {
                    let converted: wire::CaptureTransition = serde_json::to_value(transition).ok()
                        .and_then(|value| serde_json::from_value(value).ok())
                        .ok_or(engine::Error {code: engine::ErrorCode::Native, dispatch: engine::Dispatch::NotDispatched})?;
                    converted.matches(&supplied, &operation_id, &request)
                        .map_err(|_| engine::Error {code: engine::ErrorCode::Ownership, dispatch: engine::Dispatch::NotDispatched})?;
                    Ok(converted)
                }).transpose()?;
                Ok(wire::Outcome::CapturePresence {transition: converted.map(Box::new)})
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
            checkpointable,
        } => {
            let approved = engine::ApprovedArtifact {
                    path: artifact.path.into(),
                    sha256: artifact.sha256,
                    max_bytes: artifact.max_bytes,
                    guest_platform: artifact.guest_platform,
                };
            let result = if checkpointable == Some(true) {
                engine.qualify_checkpointable_creation(&approved, resources(&admitted), user.as_deref())
            } else {
                engine.qualify_creation_with_features(&approved, resources(&admitted), user.as_deref(), requested.map(|value| features(*value)).as_ref())
            };
            result.map(|()| wire::Outcome::Qualified)
        },
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
            let result = match mounts {
                Some(mounts) => operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation, dispatch: engine::Dispatch::NotDispatched })
                    .and_then(|deadline| {
                        let budget = engine::ReadBudget::new(deadline.saturating_duration_since(Instant::now()).min(Duration::from_secs(30)), cancel.clone())?;
                        let qualified = engine.qualify_volume_mounts(&mounts.policy, &mounts.requests, &budget)?;
                        engine.create_with_volume_mounts(request, requested.unwrap_or_else(|| effective_features(None)), qualified, deadline, &cancel)
                    }),
                None if create.checkpointable == Some(true) => operation_deadline
                    .ok_or(engine::Error { code: engine::ErrorCode::Validation, dispatch: engine::Dispatch::NotDispatched })
                    .and_then(|deadline| engine.create_checkpointable(request, deadline, &cancel)),
                None => match requested {
                    Some(features) => engine.create_with_features(request, features),
                    None => engine.create_versioned(request),
                },
            };
            result
            .map(|r| wire::Outcome::Created {
                receipt: receipt_wire(r),
            })
        },
        wire::Operation::Inspect { receipt: r } => engine.inspect(&receipt(&r)).map(observation),
        wire::Operation::StartCheckpointable { receipt: r } => operation_deadline
            .ok_or(engine::Error { code: engine::ErrorCode::Validation, dispatch: engine::Dispatch::NotDispatched })
            .and_then(|deadline| engine.start_checkpointable(&receipt(&r), deadline, &cancel)).map(observation),
        wire::Operation::CheckpointPreflight { receipt: r } => observation_budget()
            .and_then(|budget| engine.checkpoint_preflight(&receipt(&r), &budget)).map(observation),
        wire::Operation::Start { receipt: r } => match policy {
            Some(policy) => operation_deadline.ok_or(engine::Error { code: engine::ErrorCode::Validation, dispatch: engine::Dispatch::NotDispatched })
                .and_then(|deadline| engine.start_with_volume_policy(&receipt(&r), &policy, deadline, &cancel)),
            None => engine.start(&receipt(&r)),
        }.map(observation),
        wire::Operation::Stop { receipt: r } => stop_operation(stop_deadline, cancel.clone(),
            |budget| engine.stop_with_budget(&receipt(&r), budget)),
        wire::Operation::Delete { receipt: r } => observation_budget()
            .and_then(|budget| engine.delete_with_budget(&receipt(&r), &budget)).map(observation),
        wire::Operation::ExecBackground {receipt:r,command} => match &policy { Some(policy) => engine.exec_background_with_volume_policy(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel
        ,policy), None => engine.exec_background(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel
        ) }.map(|value| {
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
        wire::Operation::ExecStream {receipt:r,command} => match &policy { Some(policy) => engine.exec_stream_owned_with_volume_policy(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel,
            |output|emit(match output.stream {engine::Stream::Stdout=>wire::Stream::Stdout,engine::Stream::Stderr=>wire::Stream::Stderr},&output.bytes)
        ,policy), None => engine.exec_stream_owned(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel,
            |output|emit(match output.stream {engine::Stream::Stdout=>wire::Stream::Stdout,engine::Stream::Stderr=>wire::Stream::Stderr},&output.bytes)
        ) }.map(command_outcome),
        wire::Operation::ExecBuffered {receipt:r,command} => match &policy { Some(policy) => engine.exec_buffered_with_volume_policy(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel,
            |output|emit(match output.stream {engine::Stream::Stdout=>wire::Stream::Stdout,engine::Stream::Stderr=>wire::Stream::Stderr},&output.bytes)
        ,policy), None => engine.exec_buffered(&receipt(&r),
            engine::BufferedCommand {argv:command.argv,env:command.env.into_iter().collect(),workdir:command.workdir,
                user:command.user,stdin:command.stdin,timeout:remaining,max_output_bytes:command.max_output_bytes},cancel,
            |output|emit(match output.stream {engine::Stream::Stdout=>wire::Stream::Stdout,engine::Stream::Stderr=>wire::Stream::Stderr},&output.bytes)
        ) }.map(command_outcome),
        wire::Operation::Exec { receipt: r, command } => {
            let command = engine::Command { argv: command.argv, env: command.env.into_iter().collect(),
                workdir: command.workdir, user: command.user, timeout: remaining, max_output_bytes: command.max_output_bytes };
            let consumer = |output: engine::Output| emit(match output.stream { engine::Stream::Stdout => wire::Stream::Stdout, engine::Stream::Stderr => wire::Stream::Stderr }, &output.bytes);
            match &policy {
                Some(policy) => engine.exec_with_volume_policy(&receipt(&r), command, cancel, consumer, policy),
                None => engine.exec(&receipt(&r), command, cancel, consumer),
            }.map(command_outcome)
        },
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

pub fn volume(
    native: &engine::Engine,
    policy: engine::LocalVolumePolicy,
    request: wire::VolumeRequest,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    let execute = || -> engine::Result<wire::VolumeResult> {
        if policy.id != request.policy_id {
            return Err(engine::Error {
                code: engine::ErrorCode::Unsupported,
                dispatch: engine::Dispatch::NotDispatched,
            });
        }
        let budget = if request.is_observation() {
            engine::ReadBudget::new(remaining, cancel)
        } else {
            engine::ReadBudget::for_volume_work(remaining, cancel)
        }?;
        let intent = engine::LocalVolumeIntent {
            worker_volume_id: request.intent.worker_volume_id,
            size_gb: request.intent.size_gb,
        };
        Ok(match request.action {
            wire::VolumeAction::Provision => wire::VolumeResult::Provisioned {
                proof: Box::new(volume_dto(
                    &native.provision_volume(&policy, &intent, &budget)?,
                )?),
            },
            wire::VolumeAction::Delete => wire::VolumeResult::Deleted {
                proof: Box::new(volume_dto(
                    &native.delete_volume(&policy, &intent, &budget)?,
                )?),
            },
            wire::VolumeAction::ResolveDeletion { quiesced } => wire::VolumeResult::Deleted {
                proof: Box::new(volume_dto(
                    &native.resolve_volume_deletion(&policy, &intent, quiesced, &budget)?,
                )?),
            },
            wire::VolumeAction::AbortStaging { quiesced } => wire::VolumeResult::Aborted {
                proof: Box::new(volume_dto(
                    &native.abort_volume_staging(&policy, &intent, quiesced, &budget)?,
                )?),
            },
            wire::VolumeAction::InspectProvision => {
                match native.inspect_volume_provision(&policy, &intent, &budget)? {
                    engine::VolumeProvisionPresence::Absent => wire::VolumeResult::Absent,
                    engine::VolumeProvisionPresence::Unverified => wire::VolumeResult::Unverified,
                    engine::VolumeProvisionPresence::Provisioned(proof) => {
                        wire::VolumeResult::Provisioned {
                            proof: Box::new(volume_dto(&*proof)?),
                        }
                    }
                }
            }
            wire::VolumeAction::InspectDeletion => {
                match native.inspect_volume_deletion(&policy, &intent, &budget)? {
                    engine::VolumeDeletionPresence::Unverified => wire::VolumeResult::Unverified,
                    engine::VolumeDeletionPresence::Deleted(proof) => wire::VolumeResult::Deleted {
                        proof: Box::new(volume_dto(&*proof)?),
                    },
                }
            }
            wire::VolumeAction::InspectAbort => match native
                .inspect_volume_staging_abort(&policy, &intent, &budget)?
            {
                engine::VolumeStagingAbortPresence::Unverified => wire::VolumeResult::Unverified,
                engine::VolumeStagingAbortPresence::Aborted(proof) => wire::VolumeResult::Aborted {
                    proof: Box::new(volume_dto(&*proof)?),
                },
            },
            wire::VolumeAction::QualifyDeletion => wire::VolumeResult::Qualified {
                proof: Box::new(volume_dto(
                    native
                        .qualify_volume_deletion(&policy, &intent, &budget)?
                        .receipt(),
                )?),
            },
        })
    };
    match execute() {
        Ok(volume) => wire::Outcome::Volume { volume },
        Err(failure) => error(failure),
    }
}

fn volume_dto<T: serde::Serialize, U: serde::de::DeserializeOwned>(value: &T) -> engine::Result<U> {
    serde_json::to_value(value)
        .and_then(serde_json::from_value)
        .map_err(|_| engine::Error {
            code: engine::ErrorCode::Native,
            dispatch: engine::Dispatch::MayHaveDispatched,
        })
}

fn mount_selection(
    mounts: Option<&[wire::VolumeMount]>,
    policy: Option<&engine::LocalVolumePolicy>,
) -> engine::Result<Option<engine::VolumeMountSelection>> {
    let Some(mounts) = mounts else {
        return Ok(None);
    };
    let reject = || engine::Error {
        code: engine::ErrorCode::Ownership,
        dispatch: engine::Dispatch::NotDispatched,
    };
    let policy = policy.ok_or_else(reject)?;
    wire::VolumeMount::validate_set(mounts).map_err(|_| reject())?;
    let requests: Vec<engine::VolumeMountRequest> = serde_json::to_value(mounts)
        .and_then(serde_json::from_value)
        .map_err(|_| reject())?;
    if requests
        .iter()
        .any(|request| request.proof.backing.policy != *policy)
    {
        return Err(reject());
    }
    Ok(Some(engine::VolumeMountSelection {
        policy: policy.clone(),
        requests,
    }))
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
pub fn checkpoint(
    engine: &engine::Engine,
    operation: wire::Operation,
    approval: crate::package::CheckpointApproval,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    let Some((source, requested)) = operation.checkpoint_source() else {
        return wire::Outcome::Error {
            code: wire::SafeCode::Unsupported,
            dispatch: wire::Dispatch::NotDispatched,
        };
    };
    if !approval.matches(source, requested)
        || operation.validate(remaining.as_millis() as u64).is_err()
    {
        return wire::Outcome::Error {
            code: wire::SafeCode::Validation,
            dispatch: wire::Dispatch::NotDispatched,
        };
    }
    let approved = match approval.engine() {
        Ok(approved) => approved,
        Err(code) => {
            return wire::Outcome::Error {
                code,
                dispatch: wire::Dispatch::NotDispatched,
            }
        }
    };
    let result = (|| {
        let budget = engine::ReadBudget::for_checkpoint_work(remaining, cancel)?;
        match operation {
            wire::Operation::QualifyCheckpointCreation { .. } => {
                engine.inspect_checkpoint_artifact(approved, budget)?;
                Ok(wire::Outcome::Qualified)
            }
            wire::Operation::CreateCheckpoint { create } => {
                let receipt = engine.create_checkpoint_approved(
                    approved,
                    engine::CheckpointCreationIntent {
                        name: create.name,
                        owner_token: create.owner_token,
                        incarnation: create.incarnation,
                        source_sha256: create.source.sha256,
                        resources: resources(&create.resources),
                        labels: create.labels,
                    },
                    budget,
                )?;
                Ok(wire::Outcome::Created {
                    receipt: receipt_wire(receipt),
                })
            }
            wire::Operation::InspectCheckpointCreation { create } => {
                let presence = engine.inspect_checkpoint_creation(
                    &engine::CheckpointCreationIntent {
                        name: create.name,
                        owner_token: create.owner_token,
                        incarnation: create.incarnation,
                        source_sha256: create.source.sha256,
                        resources: resources(&create.resources),
                        labels: create.labels,
                    },
                    &budget,
                )?;
                Ok(wire::Outcome::CreationPresence {
                    presence: match presence {
                        engine::CreationPresence::Absent => wire::CreationPresence::Absent,
                        engine::CreationPresence::Unverified => wire::CreationPresence::Unverified,
                    },
                })
            }
            _ => Err(engine::Error {
                code: engine::ErrorCode::Unsupported,
                dispatch: engine::Dispatch::NotDispatched,
            }),
        }
    })();
    match result {
        Ok(outcome) => outcome,
        Err(failure) => error(failure),
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
    create_registry_with_policy(engine, create, size, approval, None, remaining, cancel)
}

pub fn create_registry_with_policy(
    engine: &engine::Engine,
    create: wire::RegistryCreate,
    size: u64,
    approval: crate::package::RegistryApproval,
    policy: Option<engine::LocalVolumePolicy>,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    let mounts = match mount_selection(create.volume_mounts.as_deref(), policy.as_ref()) {
        Ok(mounts) => mounts,
        Err(failure) => return error(failure),
    };
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
    let checkpointable = create.checkpointable == Some(true);
    let result = match mounts {
        Some(mounts) => engine.create_registry_cached_with_mount_selection(
            registry_intent(create),
            (size, approval.cache_policy),
            mounts,
            deadline,
            &cancel,
        ),
        None if checkpointable => engine.create_registry_checkpointable_cached(
            registry_intent(create),
            size,
            approval.cache_policy,
            deadline,
            &cancel,
        ),
        None => engine.create_registry_cached(
            registry_intent(create),
            size,
            approval.cache_policy,
            deadline,
            &cancel,
        ),
    };
    match result {
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
    policy: Option<engine::LocalVolumePolicy>,
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
    let request = engine::TerminalRequest {
        options,
        deadline: Instant::now() + remaining,
        cancel,
    };
    let controls = || bridge.borrow_mut().control();
    let output = |event| match event {
        engine::TerminalEvent::Opened => bridge.borrow_mut().opened(),
        engine::TerminalEvent::Output(output) => {
            let n = output.bytes.len() as u64;
            bridge.borrow_mut().output(output)?;
            bytes.set(bytes.get() + n);
            Ok(())
        }
    };
    let result = match policy {
        Some(policy) => engine.terminal_owned_with_volume_policy(
            &receipt(&proof),
            request,
            controls,
            output,
            &policy,
        ),
        None => engine.terminal_owned(&receipt(&proof), request, controls, output),
    };
    match result {
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

pub fn branch(
    engine: &engine::Engine,
    operation: wire::Operation,
    approval: wire::BranchApproval,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    let collection_deadline = Instant::now().checked_add(remaining.min(Duration::from_secs(30)));
    if matches!(
        operation,
        wire::Operation::InspectUnbootedBranchDisposal { .. }
    ) || operation.unbooted_disposal_request().is_some()
        || matches!(
            operation,
            wire::Operation::ReleaseUnbootedBranchBacking { .. }
        )
    {
        return unbooted_branch(engine, operation, approval, remaining, cancel);
    }
    if let wire::Operation::RetirePreparedBranch { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let before = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            let uncertain = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::MayHaveDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| before())?;
            if request.creation.approval != approval {
                return Err(before());
            }
            let native: engine::PreparedBranchRetirementRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| before())?)
                    .map_err(|_| before())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            let proof = engine.retire_prepared_branch_checked(&native, &budget)?;
            let proof: wire::PreparedBranchRetirement =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| uncertain())?)
                    .map_err(|_| uncertain())?;
            request.matches(&proof).map_err(|_| uncertain())?;
            Ok(wire::Outcome::PreparedBranchRetired {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if let Some(request) = operation.held_deletion_action_request() {
        let run = || -> engine::Result<wire::Outcome> {
            let before = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            let uncertain = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::MayHaveDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| before())?;
            if *request.approval() != approval {
                return Err(before());
            }
            let native: engine::HeldBranchDeletionActionRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| before())?)
                    .map_err(|_| before())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            match request.action {
                wire::HeldBranchDeletionAction::Continue => {
                    let proof = engine.continue_held_branch_deletion_checked(&native, &budget)?;
                    let proof: wire::BranchDeletionContinuation = serde_json::from_value(
                        serde_json::to_value(proof).map_err(|_| uncertain())?,
                    )
                    .map_err(|_| uncertain())?;
                    request
                        .matches_continuation(&proof)
                        .map_err(|_| uncertain())?;
                    Ok(wire::Outcome::HeldBranchDeletionContinued {
                        proof: Box::new(proof),
                    })
                }
                wire::HeldBranchDeletionAction::Cleanup => {
                    let proof = engine.cleanup_held_branch_deletion_checked(&native, &budget)?;
                    let proof: wire::BranchDeletionResolution = serde_json::from_value(
                        serde_json::to_value(proof).map_err(|_| uncertain())?,
                    )
                    .map_err(|_| uncertain())?;
                    request.matches_cleanup(&proof).map_err(|_| uncertain())?;
                    Ok(wire::Outcome::HeldBranchDeletionCleaned {
                        proof: Box::new(proof),
                    })
                }
            }
        };
        return run().unwrap_or_else(error);
    }
    if let wire::Operation::ContinueReleasedBranchDeletion { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let failure = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| failure())?;
            if *request.approval() != approval {
                return Err(failure());
            }
            let native: engine::ReleasedBranchDeletionContinuationRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            let proof = engine.continue_released_branch_deletion_checked(&native, &budget)?;
            let uncertain = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::MayHaveDispatched,
            };
            let proof: wire::ReleasedBranchDeletionContinuation =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| uncertain())?)
                    .map_err(|_| uncertain())?;
            request.matches(&proof).map_err(|_| uncertain())?;
            Ok(wire::Outcome::ReleasedBranchDeletionContinued {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if let wire::Operation::CleanupReleasedBranchDeletion { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let failure = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| failure())?;
            if *request.approval() != approval {
                return Err(failure());
            }
            let native: engine::ReleasedBranchDeletionCleanupRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            let proof = engine.cleanup_released_branch_deletion_checked(&native, &budget)?;
            let uncertain = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::MayHaveDispatched,
            };
            let proof: wire::ReleasedBranchDeletionResolution =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| uncertain())?)
                    .map_err(|_| uncertain())?;
            request.matches(&proof).map_err(|_| uncertain())?;
            Ok(wire::Outcome::ReleasedBranchDeletionCleaned {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if let wire::Operation::CollectBranchDeletion { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let failure = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| failure())?;
            if *request.approval() != approval {
                return Err(failure());
            }
            let native: engine::BranchDeletionCollectionRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            let budget =
                engine::ReadBudget::until(collection_deadline.ok_or_else(failure)?, cancel)?;
            let proof = engine.collect_branch_deletion_checked(&native, &budget)?;
            let uncertain = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::MayHaveDispatched,
            };
            let proof: wire::BranchDeletionCollection =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| uncertain())?)
                    .map_err(|_| uncertain())?;
            request.matches(&proof).map_err(|_| uncertain())?;
            Ok(wire::Outcome::BranchDeletionCollected {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if let wire::Operation::ResolveReleasedBranchDeletion { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let failure = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| failure())?;
            if *request.approval() != approval {
                return Err(failure());
            }
            let native: engine::ReleasedBranchDeletionRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            let proof = engine.resolve_released_branch_deletion_checked(&native, &budget)?;
            let uncertain = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::MayHaveDispatched,
            };
            let proof: wire::ReleasedBranchDeletionResolution =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| uncertain())?)
                    .map_err(|_| uncertain())?;
            request.matches(&proof).map_err(|_| uncertain())?;
            Ok(wire::Outcome::ReleasedBranchDeletionResolved {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if let wire::Operation::ResolveHeldBranchDeletion { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let failure = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| failure())?;
            if *request.approval() != approval {
                return Err(failure());
            }
            let native: engine::HeldBranchDeletionRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            let proof = engine.resolve_held_branch_deletion_checked(&native, &budget)?;
            let uncertain = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::MayHaveDispatched,
            };
            let proof: wire::BranchDeletionResolution =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| uncertain())?)
                    .map_err(|_| uncertain())?;
            request.matches(&proof).map_err(|_| uncertain())?;
            Ok(wire::Outcome::HeldBranchDeletionResolved {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if let wire::Operation::ReleaseBranchBacking { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let failure = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| failure())?;
            if *request.approval() != approval {
                return Err(failure());
            }
            let native: engine::BranchBackingReleaseRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            let proof = engine.release_branch_backing_checked(&native, &budget)?;
            let uncertain = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::MayHaveDispatched,
            };
            let proof: wire::BranchBackingRelease =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| uncertain())?)
                    .map_err(|_| uncertain())?;
            request.matches(&proof).map_err(|_| uncertain())?;
            Ok(wire::Outcome::BranchBackingReleased {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if let wire::Operation::QualifyUnbootedBranchChildAbsence { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let failure = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| failure())?;
            if *request.approval() != approval {
                return Err(failure());
            }
            let native: engine::UnbootedBranchChildAbsenceRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            let proof = engine.qualify_unbooted_branch_child_absence(&native, &budget)?;
            let proof: wire::UnbootedBranchChildAbsence =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            request.matches(&proof).map_err(|_| failure())?;
            Ok(wire::Outcome::UnbootedBranchChildAbsent {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if let wire::Operation::QualifyBranchChildAbsence { request } = &operation {
        let run = || -> engine::Result<wire::Outcome> {
            let failure = || engine::Error {
                code: engine::ErrorCode::Ownership,
                dispatch: engine::Dispatch::NotDispatched,
            };
            operation
                .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
                .map_err(|_| failure())?;
            if *request.approval() != approval {
                return Err(failure());
            }
            let native: engine::BranchChildAbsenceRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
            let proof = engine.qualify_branch_child_absence(&native, &budget)?;
            let proof: wire::BranchChildAbsence =
                serde_json::from_value(serde_json::to_value(proof).map_err(|_| failure())?)
                    .map_err(|_| failure())?;
            request.matches(&proof).map_err(|_| failure())?;
            Ok(wire::Outcome::BranchChildAbsent {
                proof: Box::new(proof),
            })
        };
        return run().unwrap_or_else(error);
    }
    if operation
        .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
        .is_err()
    {
        return error(engine::Error {
            code: engine::ErrorCode::Validation,
            dispatch: engine::Dispatch::NotDispatched,
        });
    }
    if operation.held_branch_request().is_some() {
        return held_branch_release(engine, operation, approval, remaining, cancel);
    }
    let (request, lookup, resolving) = match operation {
        wire::Operation::CreateBranch { request } => (request, false, false),
        wire::Operation::InspectBranchCompletion { request } => (request, true, false),
        wire::Operation::ResolveReadyBranchCompletion {
            request,
            quiesced: true,
        } => (request, true, true),
        _ => {
            return error(engine::Error {
                code: engine::ErrorCode::Unsupported,
                dispatch: engine::Dispatch::NotDispatched,
            })
        }
    };
    let convert_error = || engine::Error {
        code: engine::ErrorCode::Ownership,
        dispatch: engine::Dispatch::NotDispatched,
    };
    let run = || -> engine::Result<wire::Outcome> {
        request.validate().map_err(|_| convert_error())?;
        if request.approval != approval {
            return Err(convert_error());
        }
        let native: engine::BranchCreateRequest =
            serde_json::from_value(serde_json::to_value(&request).map_err(|_| convert_error())?)
                .map_err(|_| convert_error())?;
        let budget = if lookup {
            engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)
        } else {
            engine::ReadBudget::for_checkpoint_work(remaining, cancel)
        }?;
        let completion = if resolving {
            engine.resolve_ready_branch_completion(&native, true, &budget)?
        } else if lookup {
            engine.inspect_branch_completion(&native, &budget)?
        } else {
            Some(engine.create_branch(&native, &budget)?)
        };
        let completion = completion
            .map(|value| {
                let value: wire::BranchCompletion =
                    serde_json::from_value(serde_json::to_value(value).map_err(|_| {
                        engine::Error {
                            code: engine::ErrorCode::Native,
                            dispatch: engine::Dispatch::MayHaveDispatched,
                        }
                    })?)
                    .map_err(|_| engine::Error {
                        code: engine::ErrorCode::Native,
                        dispatch: engine::Dispatch::MayHaveDispatched,
                    })?;
                value.matches(&request).map_err(|_| engine::Error {
                    code: engine::ErrorCode::Native,
                    dispatch: engine::Dispatch::MayHaveDispatched,
                })?;
                Ok(Box::new(value))
            })
            .transpose()?;
        if lookup {
            Ok(wire::Outcome::BranchCompletionPresence { completion })
        } else {
            Ok(wire::Outcome::BranchCreated {
                completion: completion.ok_or(engine::Error {
                    code: engine::ErrorCode::Native,
                    dispatch: engine::Dispatch::MayHaveDispatched,
                })?,
            })
        }
    };
    run().unwrap_or_else(error)
}

fn held_branch_release(
    engine: &engine::Engine,
    operation: wire::Operation,
    approval: wire::BranchApproval,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    let (request, qualify) = match operation {
        wire::Operation::ReleaseHeldBranch { request } => (request, false),
        wire::Operation::QualifyHeldBranchRelease { request } => (request, true),
        _ => unreachable!(),
    };
    let convert_error = || engine::Error {
        code: engine::ErrorCode::Ownership,
        dispatch: engine::Dispatch::NotDispatched,
    };
    let run = || -> engine::Result<wire::Outcome> {
        request.validate().map_err(|_| convert_error())?;
        if *request.approval() != approval {
            return Err(convert_error());
        }
        let completion: engine::BranchCompletion = serde_json::from_value(
            serde_json::to_value(&request.completion).map_err(|_| convert_error())?,
        )
        .map_err(|_| convert_error())?;
        let native_request: engine::BranchReleaseRequest = serde_json::from_value(
            serde_json::to_value(&request.request).map_err(|_| convert_error())?,
        )
        .map_err(|_| convert_error())?;
        let budget = if qualify {
            engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)
        } else {
            engine::ReadBudget::for_checkpoint_work(remaining, cancel)
        }?;
        let proof = if qualify {
            engine.qualify_held_branch_release(
                &completion,
                &receipt(&request.source),
                &native_request,
                &budget,
            )?
        } else {
            Some(engine.release_held_branch_checked(
                &completion,
                &receipt(&request.source),
                &native_request,
                &budget,
            )?)
        };
        let transition = proof
            .map(|proof| {
                let failure = || engine::Error {
                    code: engine::ErrorCode::Native,
                    dispatch: engine::Dispatch::MayHaveDispatched,
                };
                let proof: wire::BranchReleaseTransition =
                    serde_json::from_value(serde_json::to_value(proof).map_err(|_| failure())?)
                        .map_err(|_| failure())?;
                request.matches(&proof).map_err(|_| failure())?;
                Ok(Box::new(proof))
            })
            .transpose()?;
        if qualify {
            Ok(wire::Outcome::HeldBranchReleasePresence { transition })
        } else {
            Ok(wire::Outcome::HeldBranchReleased {
                transition: transition.ok_or_else(convert_error)?,
            })
        }
    };
    run().unwrap_or_else(error)
}

#[cfg(test)]
mod growth_tests {
    use super::*;

    #[test]
    fn engine_capture_evidence_matches_wire_without_rewriting_proofs() {
        let bytes = include_bytes!("../../smolbox-protocol/fixtures/capture-transitions-v1.json");
        let engine: Vec<engine::CaptureTransition> = serde_json::from_slice(bytes).unwrap();
        for transition in engine {
            transition.validate().unwrap();
            let serialized = serde_json::to_value(&transition).unwrap();
            let wire: wire::CaptureTransition = serde_json::from_value(serialized.clone()).unwrap();
            wire.validate().unwrap();
            assert_eq!(serde_json::to_value(wire).unwrap(), serialized);
        }
    }

    #[test]
    fn synthetic_branch_creation_evidence_matches_both_engine_and_wire_without_rewriting() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-creation-v1.json"
        ))
        .unwrap();
        for row in rows {
            let request: wire::BranchCreateRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            request.validate().unwrap();
            let native: engine::BranchCreateRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            assert!(serde_json::to_value(native).unwrap() == row["request"]);
            let native: engine::BranchCompletion =
                serde_json::from_value(row["completion"].clone()).unwrap();
            native.validate().unwrap();
            let wire: wire::BranchCompletion =
                serde_json::from_value(row["completion"].clone()).unwrap();
            wire.matches(&request).unwrap();
            assert!(serde_json::to_value(native).unwrap() == serde_json::to_value(wire).unwrap());
        }
    }

    #[test]
    fn mixed_material_fixture_preserves_individually_valid_engine_and_wire_proofs() {
        let values: Vec<serde_json::Value> = serde_json::from_slice(include_bytes!(
            "../../smolbox-protocol/fixtures/material-history-v1.json"
        ))
        .unwrap();
        for value in values {
            if value["change"].get("intent").is_some() {
                let proof: engine::CaptureTransition =
                    serde_json::from_value(value.clone()).unwrap();
                proof.validate().unwrap();
                let wire: wire::CaptureTransition = serde_json::from_value(value).unwrap();
                wire.validate().unwrap();
            } else {
                let proof: engine::GrowthTransition =
                    serde_json::from_value(value.clone()).unwrap();
                proof.validate().unwrap();
                let wire: wire::GrowthTransition = serde_json::from_value(value).unwrap();
                wire.validate().unwrap();
            }
        }
    }

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

#[cfg(test)]
mod mount_tests {
    use super::*;

    #[test]
    fn mount_selection_preserves_full_proof_and_requires_exact_operator_policy() {
        let value: serde_json::Value = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/mounted-creation-request.json"
        ))
        .unwrap();
        let mounts: Vec<wire::VolumeMount> =
            serde_json::from_value(value["operation"]["create"]["volume_mounts"].clone()).unwrap();
        let policy = engine::LocalVolumePolicy {
            id: mounts[0].proof.backing.policy.id.clone(),
            root: mounts[0].proof.backing.policy.root.clone().into(),
        };
        let selected = mount_selection(Some(&mounts), Some(&policy))
            .unwrap()
            .unwrap();
        assert_eq!(
            serde_json::to_value(selected.requests).unwrap(),
            serde_json::to_value(&mounts).unwrap()
        );
        assert!(selected.policy == policy);
        assert!(mount_selection(Some(&mounts), None).is_err());
        let other = engine::LocalVolumePolicy {
            root: "/foreign".into(),
            ..policy
        };
        assert!(mount_selection(Some(&mounts), Some(&other)).is_err());
        assert!(mount_selection(Some(&[]), Some(&other)).is_err());
        assert!(mount_selection(None, None).unwrap().is_none());
    }
}

pub fn export(
    engine: &engine::Engine,
    operation: wire::Operation,
    approval: crate::package::ExportApproval,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    let result = (|| -> engine::Result<wire::Outcome> {
        operation
            .validate(remaining.as_millis().try_into().unwrap_or(u64::MAX))
            .map_err(|_| engine::Error {
                code: engine::ErrorCode::Validation,
                dispatch: engine::Dispatch::NotDispatched,
            })?;
        let request = match &operation {
            wire::Operation::QualifyExport { request, .. }
            | wire::Operation::AdmitExport { request, .. }
            | wire::Operation::ExportMachine { request, .. } => request,
            _ => {
                return Err(engine::Error {
                    code: engine::ErrorCode::Validation,
                    dispatch: engine::Dispatch::NotDispatched,
                })
            }
        };
        if !approval.matches(request) {
            return Err(engine::Error {
                code: engine::ErrorCode::Unsupported,
                dispatch: engine::Dispatch::NotDispatched,
            });
        }
        let destination = approval.resolved.as_ref().ok_or(engine::Error {
            code: engine::ErrorCode::Unsupported,
            dispatch: engine::Dispatch::NotDispatched,
        })?;
        let budget = engine::ReadBudget::for_export_work(remaining, cancel)?;
        match operation {
            wire::Operation::AdmitExport {
                receipt: supplied,
                operation_id,
                request,
            } => {
                engine.admit_export_intent(
                    &receipt(&supplied),
                    &operation_id,
                    &request.request_sha256,
                    request.max_staging_bytes,
                    &request.identity_sha256().map_err(|_| engine::Error {
                        code: engine::ErrorCode::Validation,
                        dispatch: engine::Dispatch::NotDispatched,
                    })?,
                    &budget,
                )?;
                Ok(wire::Outcome::Qualified)
            }
            wire::Operation::QualifyExport {
                receipt: supplied,
                request,
            } => {
                engine.qualify_export(
                    &receipt(&supplied),
                    request.max_artifact_bytes,
                    request.max_staging_bytes,
                    approval.conversion_resources.as_ref(),
                    &budget,
                )?;
                Ok(wire::Outcome::Qualified)
            }
            wire::Operation::ExportMachine {
                receipt: supplied,
                operation_id,
                request,
                push_token,
            } => {
                let credential = engine::RegistryPublishCredential::new(push_token.into_secret())?;
                engine.check_export_intent(
                    &receipt(&supplied),
                    &operation_id,
                    &request.request_sha256,
                    request.max_staging_bytes,
                    &request.identity_sha256().map_err(|_| engine::Error {
                        code: engine::ErrorCode::Validation,
                        dispatch: engine::Dispatch::NotDispatched,
                    })?,
                    &budget,
                )?;
                // Preflight capacity/assets before any scratch registration; source
                // identity is independently requalified for the actual attempt.
                engine.qualify_export(
                    &receipt(&supplied),
                    request.max_artifact_bytes,
                    request.max_staging_bytes,
                    approval.conversion_resources.as_ref(),
                    &budget,
                )?;
                let intent = engine::ContainerExportIntent {
                    operation_id: operation_id.clone(),
                    request_sha256: request.request_sha256.clone(),
                    request_identity_sha256: request.identity_sha256().map_err(|_| {
                        engine::Error {
                            code: engine::ErrorCode::Validation,
                            dispatch: engine::Dispatch::NotDispatched,
                        }
                    })?,
                    max_artifact_bytes: request.max_artifact_bytes,
                    max_staging_bytes: request.max_staging_bytes,
                };
                let packed = engine.pack_export(
                    &receipt(&supplied),
                    &intent,
                    approval.conversion_resources.as_ref(),
                    &budget,
                )?;
                let published = packed
                    .publish(engine, destination, &request.tag, credential)
                    .map_err(|e| engine::Error {
                        code: e.code,
                        dispatch: engine::Dispatch::MayHaveDispatched,
                    })?;
                let proof: wire::ExportPublication = serde_json::from_value(
                    serde_json::to_value(published.publication()).map_err(|_| engine::Error {
                        code: engine::ErrorCode::Ownership,
                        dispatch: engine::Dispatch::MayHaveDispatched,
                    })?,
                )
                .map_err(|_| engine::Error {
                    code: engine::ErrorCode::Ownership,
                    dispatch: engine::Dispatch::MayHaveDispatched,
                })?;
                proof
                    .matches_request(&supplied, &operation_id, &request)
                    .map_err(|_| engine::Error {
                        code: engine::ErrorCode::Ownership,
                        dispatch: engine::Dispatch::MayHaveDispatched,
                    })?;
                // Retiring the collected handle retains registered scratch; no
                // cleanup/quiescence assertion accompanies publication success.
                drop(published);
                Ok(wire::Outcome::Exported {
                    publication: Box::new(proof),
                })
            }
            _ => unreachable!(),
        }
    })();
    result.unwrap_or_else(error)
}

fn unbooted_branch(
    engine: &engine::Engine,
    operation: wire::Operation,
    approval: wire::BranchApproval,
    remaining: Duration,
    cancel: engine::Cancellation,
) -> wire::Outcome {
    let run = || -> engine::Result<wire::Outcome> {
        let before = || engine::Error {
            code: engine::ErrorCode::Ownership,
            dispatch: engine::Dispatch::NotDispatched,
        };
        let uncertain = || engine::Error {
            code: engine::ErrorCode::Ownership,
            dispatch: engine::Dispatch::MayHaveDispatched,
        };
        operation
            .validate(remaining.as_millis().min(u64::MAX as u128) as u64)
            .map_err(|_| before())?;
        if operation.branch_approval() != Some(&approval) {
            return Err(before());
        }
        let check_cancel = cancel.clone();
        let deadline = std::time::Instant::now() + remaining.min(Duration::from_secs(30));
        let budget = engine::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel)?;
        if let wire::Operation::InspectUnbootedBranchDisposal { request, quiesced } = &operation {
            let creation: engine::BranchCreateRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| before())?)
                    .map_err(|_| before())?;
            let original = engine
                .retain_branch_resolution(&creation, *quiesced, &budget)?
                .ok_or_else(before)?;
            let candidate = original.inspect_disposal_candidate(engine)?;
            let candidate: wire::UnbootedBranchDisposalCandidate =
                serde_json::from_value(serde_json::to_value(candidate).map_err(|_| before())?)
                    .map_err(|_| before())?;
            candidate.matches(request).map_err(|_| before())?;
            if check_cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(before());
            }
            return Ok(wire::Outcome::UnbootedBranchDisposalCandidate {
                candidate: Box::new(candidate),
            });
        }
        if let wire::Operation::ReleaseUnbootedBranchBacking { request } = &operation {
            let native: engine::UnbootedBranchBackingReleaseRequest =
                serde_json::from_value(serde_json::to_value(request).map_err(|_| before())?)
                    .map_err(|_| before())?;
            let result = engine.release_unbooted_branch_backing_checked(&native, &budget)?;
            let proof: wire::BranchBackingRelease =
                serde_json::from_value(serde_json::to_value(result).map_err(|_| uncertain())?)
                    .map_err(|_| uncertain())?;
            request.matches(&proof).map_err(|_| uncertain())?;
            if check_cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(engine::Error {
                    code: engine::ErrorCode::State,
                    dispatch: engine::Dispatch::MayHaveDispatched,
                });
            }
            return Ok(wire::Outcome::BranchBackingReleased {
                proof: Box::new(proof),
            });
        }
        let request = operation.unbooted_disposal_request().ok_or_else(before)?;
        let creation: engine::BranchCreateRequest =
            serde_json::from_value(serde_json::to_value(&request.creation).map_err(|_| before())?)
                .map_err(|_| before())?;
        let native: engine::UnbootedBranchDisposalRequest =
            serde_json::from_value(serde_json::to_value(&request.request).map_err(|_| before())?)
                .map_err(|_| before())?;
        let proof = if let Some(saved) =
            engine.inspect_unbooted_branch_disposal(&creation, &native, &budget)?
        {
            saved
        } else {
            let original = engine
                .retain_branch_resolution(&creation, native.quiesced, &budget)?
                .ok_or_else(before)?;
            let proof = if matches!(operation, wire::Operation::DisposeUnbootedBranch { .. }) {
                original.dispose_unbooted_child(engine, &native)?
            } else {
                original.resolve_unbooted_disposal(engine, &native)?
            };
            original
                .finish_unbooted_disposal(engine, &proof)
                .map_err(|e| engine::Error {
                    code: e.code,
                    dispatch: engine::Dispatch::MayHaveDispatched,
                })?
        };
        let proof: wire::UnbootedBranchDisposal =
            serde_json::from_value(serde_json::to_value(proof).map_err(|_| uncertain())?)
                .map_err(|_| uncertain())?;
        request.matches(&proof).map_err(|_| uncertain())?;
        if check_cancel.is_cancelled() || std::time::Instant::now() >= deadline {
            return Err(engine::Error {
                code: engine::ErrorCode::State,
                dispatch: engine::Dispatch::MayHaveDispatched,
            });
        }
        Ok(wire::Outcome::UnbootedBranchDisposed {
            proof: Box::new(proof),
        })
    };
    run().unwrap_or_else(error)
}

fn capped_stop_deadline(entered: Instant, remaining: Duration) -> Option<Instant> {
    entered
        .checked_add(remaining)
        .map(|deadline| deadline.min(entered + Duration::from_secs(30)))
}
fn stop_budget_outcome(
    deadline: Instant,
    cancel: &engine::Cancellation,
    dispatch: wire::Dispatch,
) -> Option<wire::Outcome> {
    let code = if cancel.is_cancelled() {
        wire::SafeCode::Cancelled
    } else if Instant::now() >= deadline {
        wire::SafeCode::Deadline
    } else {
        return None;
    };
    Some(wire::Outcome::Error { code, dispatch })
}
fn stop_operation(
    deadline: Option<Instant>,
    cancel: engine::Cancellation,
    invoke: impl FnOnce(&engine::ReadBudget) -> engine::Result<engine::Observation>,
) -> engine::Result<wire::Outcome> {
    let deadline = deadline.ok_or(engine::Error {
        code: engine::ErrorCode::Validation,
        dispatch: engine::Dispatch::NotDispatched,
    })?;
    if let Some(outcome) = stop_budget_outcome(deadline, &cancel, wire::Dispatch::NotDispatched) {
        return Ok(outcome);
    }
    let budget = match engine::ReadBudget::until(deadline, cancel.clone()) {
        Ok(budget) => budget,
        Err(error) => {
            return match stop_budget_outcome(deadline, &cancel, wire::Dispatch::NotDispatched) {
                Some(outcome) => Ok(outcome),
                None => Err(error),
            }
        }
    };
    let result = invoke(&budget);
    let evidence = result.as_ref().map_or_else(
        |error| dispatch(error.dispatch),
        |_| wire::Dispatch::MayHaveDispatched,
    );
    if let Some(outcome) = stop_budget_outcome(deadline, &cancel, evidence) {
        return Ok(outcome);
    }
    result.map(observation)
}
#[cfg(test)]
mod stop_tests;
