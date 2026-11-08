use serde_json::{json, Value};
use smolbox_protocol::*;

fn hello() -> Hello {
    Hello {
        major: PROTOCOL_MAJOR,
        minor: PROTOCOL_MINOR,
        epoch: "ab".repeat(16),
        domain: DomainIdentity {
            target_id: "embedded-local".into(),
            generation: "cd".repeat(16),
        },
        package: PackageIdentity {
            engine_version: "0.1.0".into(),
            smolvm_revision: "ef".repeat(20),
            source_sha256: "01".repeat(32),
            build_sha256: "23".repeat(32),
            assets_sha256: "45".repeat(32),
            platform: "macos".into(),
            architecture: "aarch64".into(),
        },
        capabilities: vec![
            Capability::Create,
            Capability::Inspect,
            Capability::Start,
            Capability::Stop,
            Capability::Delete,
            Capability::Exec,
            Capability::ReadFile,
            Capability::WriteFile,
            Capability::QualifyCreation,
            Capability::InspectCreation,
        ],
        limits: Limits::default(),
        preflight: Preflight::Ready,
        sdk: None,
    }
}

#[test]
fn linux_image_descriptor_preserves_the_previous_platform_contract() {
    let current: ServerMessage =
        serde_json::from_str(include_str!("../fixtures/hello-v2-linux-images.json")).unwrap();
    let previous: ServerMessage = serde_json::from_str(include_str!(
        "../fixtures/hello-v2-linux-terminal-preflight.json"
    ))
    .unwrap();
    let ServerMessage::Hello { hello: current } = current else {
        unreachable!()
    };
    let ServerMessage::Hello { hello: previous } = previous else {
        unreachable!()
    };
    current.validate().unwrap();
    previous.validate().unwrap();
    assert!(current.capabilities == current.sdk.as_ref().unwrap().capabilities());
    assert!(current.capabilities.contains(&Capability::PrepareArtifact));
    assert!(current.capabilities.contains(&Capability::ListImages));
    assert!(current.capabilities.contains(&Capability::PullImage));
    assert!(!previous.capabilities.contains(&Capability::PrepareArtifact));
    assert!(current.limits == previous.limits);
    let mut sdk = current.sdk.as_ref().unwrap().as_ref().clone();
    sdk.feature_versions.remove("remote_sources");
    sdk.feature_versions.remove("images");
    assert!(&sdk == previous.sdk.as_deref().unwrap());
}
fn receipt() -> Receipt {
    Receipt {
        target_id: "embedded-local".into(),
        domain_generation: "cd".repeat(16),
        name: "owned".into(),
        owner_token: "67".repeat(32),
        incarnation: "89".repeat(16),
        material_sha256: "ab".repeat(32),
        material: None,
    }
}
fn command() -> Operation {
    Operation::Exec {
        receipt: receipt(),
        command: Command {
            argv: vec!["/bin/sh".into(), "-c".into(), "printf witness".into()],
            env: [("KEY".into(), "".into())].into(),
            workdir: Some("/workspace".into()),
            user: Some("65534:65534".into()),
            max_output_bytes: 1024,
        },
    }
}
fn request(id: u64, operation: Operation) -> ClientMessage {
    ClientMessage::Request {
        epoch: hello().epoch,
        id,
        budget_ms: 1000,
        initial_credit: INITIAL_CREDIT_BYTES,
        initial_event_credit: INITIAL_CREDIT_EVENTS,
        operation,
    }
}
fn session() -> Session {
    let h = hello();
    let mut s = Session::new(h.clone()).unwrap();
    s.approve(&h).unwrap();
    s
}

fn parity_hello() -> Hello {
    let value: Value = serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap();
    let ServerMessage::Hello { hello } = ServerMessage::decode(value).unwrap() else {
        unreachable!()
    };
    *hello
}

fn oci_create() -> OciCreate {
    let r = parity_receipt();
    OciCreate {
        name: r.name,
        owner_token: r.owner_token,
        incarnation: r.incarnation,
        source: OciIdentity {
            kind: "oci".into(),
            id: "approved-source".into(),
            sha256: "a".repeat(64),
            architecture: "aarch64".into(),
            reference: format!("registry.example/app@sha256:{}", "a".repeat(64)),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 256,
            storage_gib: 1,
            overlay_gib: 1,
        },
        labels: Default::default(),
        volume_mounts: None,
        features: None,
    }
}

#[test]
fn source_wire_rejects_mixed_authority_bad_identity_and_unapproved_feature_without_new_capabilities(
) {
    let operation = Operation::CreateOci {
        create: oci_create(),
    };
    assert!(operation.capability() == Capability::Create);
    operation.validate(1000).unwrap();
    for (field, value) in [
        ("sha256", json!("b".repeat(64))),
        ("kind", json!("registry")),
        ("architecture", json!("unknown")),
        ("reference", json!("registry.example/app:tag")),
    ] {
        let mut changed = serde_json::to_value(&operation).unwrap();
        changed["create"]["source"][field] = value;
        let decoded: Operation = serde_json::from_value(changed).unwrap();
        assert!(decoded.validate(1000).is_err());
    }
    for (field, value) in [("artifact", json!({})), ("metadata", json!({}))] {
        let mut changed = serde_json::to_value(&operation).unwrap();
        changed["create"][field] = value;
        assert!(serde_json::from_value::<Operation>(changed).is_err());
    }
    for h in [hello(), parity_hello()] {
        let mut session = Session::new(h.clone()).unwrap();
        session.approve(&h).unwrap();
        let message = ClientMessage::Request {
            epoch: h.epoch.clone(),
            id: 1,
            budget_ms: 1000,
            initial_credit: INITIAL_CREDIT_BYTES,
            initial_event_credit: INITIAL_CREDIT_EVENTS,
            operation: operation.clone(),
        };
        assert!(matches!(
            session.admit(message).unwrap(),
            ServerMessage::Terminal {
                outcome: Outcome::Error {
                    code: SafeCode::Unsupported,
                    dispatch: Dispatch::NotDispatched
                },
                ..
            }
        ));
    }
}

#[test]
fn approved_source_creation_requires_correlated_versioned_completion_and_never_adopts_inventory() {
    let mut h = growth_hello();
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("remote_sources".into(), 1);
    h.capabilities = h.sdk.as_ref().unwrap().capabilities();
    let mut create = oci_create();
    let mut r = parity_receipt();
    r.target_id = h.domain.target_id.clone();
    r.domain_generation = h.domain.generation.clone();
    create.name = r.name.clone();
    create.owner_token = r.owner_token.clone();
    create.incarnation = r.incarnation.clone();
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    session
        .admit(ClientMessage::Request {
            epoch: h.epoch.clone(),
            id: 1,
            budget_ms: 1000,
            initial_credit: INITIAL_CREDIT_BYTES,
            initial_event_credit: INITIAL_CREDIT_EVENTS,
            operation: Operation::CreateOci { create },
        })
        .unwrap();
    let mut crossed = r.clone();
    crossed.incarnation = "0".repeat(32);
    assert!(session.event(1, Stream::Stdout, b"unexpected").is_err());
    assert!(session
        .terminal(1, Outcome::Created { receipt: crossed })
        .is_err());
    assert!(session
        .terminal(
            1,
            Outcome::CreationPresence {
                presence: CreationPresence::Absent
            }
        )
        .is_err());
    session
        .terminal(1, Outcome::Created { receipt: r })
        .unwrap();
}

#[test]
fn source_features_require_the_existing_bounded_job_buffer_and_compact_contracts() {
    let mut sdk = growth_hello().sdk.unwrap();
    sdk.feature_versions.insert("remote_sources".into(), 1);
    sdk.validate().unwrap();
    for required in ["job_resources", "buffered_exec", "compact_creation"] {
        let mut missing = sdk.clone();
        missing.feature_versions.remove(required);
        assert!(missing.validate().is_err());
    }
}

#[test]
fn source_compact_payload_preserves_full_workload_and_start_rejects_legacy_receipts() {
    let mut value: Value =
        serde_json::from_slice(include_bytes!("../fixtures/compact-creation-request.json"))
            .unwrap();
    let payload = value["operation"]["features_payload"].clone();
    let mut create = serde_json::to_value(oci_create()).unwrap();
    create["features_payload"] = payload;
    value["operation"] = json!({"operation": "create_oci", "create": create});
    let decoded = ClientMessage::decode(value).unwrap();
    let ClientMessage::Request {
        operation: Operation::CreateOci { create },
        ..
    } = decoded
    else {
        panic!()
    };
    let features = create.features.unwrap();
    assert!(features.compact);
    assert_eq!(
        features.workload.unwrap().cmd,
        vec!["literal; $(text)", "é\u{1}"]
    );
    let valid = Operation::StartOci {
        source: oci_create().source,
        receipt: parity_receipt(),
    };
    valid.validate(1000).unwrap();
    let mut old = parity_receipt();
    old.material = None;
    assert!(Operation::StartOci {
        source: oci_create().source,
        receipt: old
    }
    .validate(1000)
    .is_err());
}

fn growth_fixture() -> GrowthTransition {
    serde_json::from_slice::<Vec<GrowthTransition>>(include_bytes!(
        "../fixtures/growth-transitions-v1.json"
    ))
    .unwrap()
    .remove(0)
}
fn growth_hello() -> Hello {
    let value: Value =
        serde_json::from_slice(include_bytes!("../fixtures/hello-v2-current.json")).unwrap();
    let ServerMessage::Hello { hello } = ServerMessage::decode(value).unwrap() else {
        unreachable!()
    };
    let mut hello = *hello;
    let proof = growth_fixture();
    hello.domain = DomainIdentity {
        target_id: proof.previous.target_id.clone(),
        generation: proof.previous.domain_generation.clone(),
    };
    let sdk = hello.sdk.as_mut().unwrap();
    sdk.feature_versions.insert("disk_growth".into(), 1);
    hello.capabilities = sdk.capabilities();
    hello
}

#[test]
fn volume_sessions_require_protocol_feature_and_exact_nonstreaming_correlated_proof() {
    let mut h = growth_hello();
    let sdk = h.sdk.as_mut().unwrap();
    sdk.feature_versions.insert("volumes".into(), 1);
    h.capabilities = sdk.capabilities();
    h.limits = Limits::for_sdk(sdk);
    h.package.platform = "linux".into();
    h.package.architecture = "x86_64".into();
    let request_body = VolumeRequest {
        policy_id: "local".into(),
        intent: VolumeIntent {
            worker_volume_id: format!("sbv-{}", "a".repeat(32)),
            size_gb: 4,
        },
        action: VolumeAction::InspectProvision,
    };
    assert!(matches!(
        session()
            .admit(request(
                1,
                Operation::Volume {
                    request: request_body.clone()
                }
            ))
            .unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                ..
            },
            ..
        }
    ));
    let mut s = Session::new(h.clone()).unwrap();
    s.approve(&h).unwrap();
    assert!(matches!(
        s.admit(request(
            1,
            Operation::Volume {
                request: request_body.clone()
            }
        ))
        .unwrap(),
        ServerMessage::Accepted { .. }
    ));
    assert!(s
        .terminal(
            1,
            Outcome::Volume {
                volume: VolumeResult::Unverified
            }
        )
        .is_ok());
    let mut wrong = request_body.clone();
    wrong.action = VolumeAction::Provision;
    s.admit(request(2, Operation::Volume { request: wrong }))
        .unwrap();
    assert!(s
        .terminal(
            2,
            Outcome::Volume {
                volume: VolumeResult::Unverified
            }
        )
        .is_err());
    assert!(Outcome::Volume {
        volume: VolumeResult::Absent
    }
    .validate_for(1)
    .is_err());
    let mut value = serde_json::to_value(request(
        3,
        Operation::Volume {
            request: request_body,
        },
    ))
    .unwrap();
    value["request"]["root"] = json!("/caller/path");
    assert!(ClientMessage::decode(value).is_err());
}

#[test]
fn volume_hello_declares_exact_limits_platform_and_dependencies_without_changing_legacy() {
    let value: Value =
        serde_json::from_slice(include_bytes!("../fixtures/hello-v2-volumes.json")).unwrap();
    let ServerMessage::Hello { hello: h } = ServerMessage::decode(value.clone()).unwrap() else {
        unreachable!()
    };
    assert!(h.limits == Limits::for_sdk(h.sdk.as_ref().unwrap()));
    assert!(h.limits.volumes.is_some());
    let limits = h.limits.volumes.as_ref().unwrap();
    assert_eq!(limits.control_metadata_bytes, 262_144);
    for key in [
        "work_ms",
        "observation_ms",
        "record_bytes",
        "delete_entries",
        "ancestor_bytes",
        "control_metadata_bytes",
        "observation_metadata_bytes",
    ] {
        let mut changed = value.clone();
        changed["hello"]["limits"]["volumes"][key] = json!(0);
        assert!(ServerMessage::decode(changed).is_err());
    }
    let mut changed = value.clone();
    changed["hello"]["limits"]
        .as_object_mut()
        .unwrap()
        .remove("volumes");
    assert!(ServerMessage::decode(changed).is_err());
    let mut changed = value.clone();
    changed["hello"]["package"]["platform"] = json!("macos");
    assert!(ServerMessage::decode(changed).is_err());
    for feature in ["job_resources", "buffered_exec", "compact_creation"] {
        let mut changed = value.clone();
        changed["hello"]["sdk"]["feature_versions"]
            .as_object_mut()
            .unwrap()
            .remove(feature);
        assert!(ServerMessage::decode(changed).is_err());
    }
    assert!(hello().limits.volumes.is_none());
    let baseline = parity_hello();
    assert!(baseline.limits.volumes.is_none());
}

#[test]
fn linux_storage_hello_adds_growth_without_changing_volume_only_approval() {
    let current: ServerMessage =
        serde_json::from_str(include_str!("../fixtures/hello-v2-linux-current.json")).unwrap();
    let older: ServerMessage =
        serde_json::from_str(include_str!("../fixtures/hello-v2-volumes.json")).unwrap();
    let ServerMessage::Hello { hello: current } = current else {
        unreachable!()
    };
    let ServerMessage::Hello { hello: older } = older else {
        unreachable!()
    };
    current.validate().unwrap();
    older.validate().unwrap();
    assert!(current.capabilities == current.sdk.as_ref().unwrap().capabilities());
    assert!(current.limits == older.limits);
    assert!(current.capabilities.contains(&Capability::ExpandDisks));
    assert!(current.capabilities.contains(&Capability::InspectGrowth));
    assert!(current.capabilities.contains(&Capability::QualifyGrowth));
    assert!(!older.capabilities.contains(&Capability::ExpandDisks));
    let mut sdk = current.sdk.as_ref().unwrap().as_ref().clone();
    sdk.feature_versions.remove("disk_growth");
    assert!(&sdk == older.sdk.as_deref().unwrap());
}
fn growth_operation(inspect: bool) -> Operation {
    let proof = growth_fixture();
    let receipt = proof.previous;
    let operation_id = proof.change.operation_id;
    let request = proof.change.request;
    let previous = DiskSizes {
        storage_gib: 1,
        overlay_gib: 1,
    };
    if inspect {
        Operation::InspectGrowth {
            receipt,
            operation_id,
            request,
            previous,
        }
    } else {
        Operation::ExpandDisks {
            receipt,
            operation_id,
            request,
            previous,
        }
    }
}
fn grown() -> Outcome {
    Outcome::Grown {
        transition: Box::new(growth_fixture()),
        observation: Observation {
            state: ObservedState::Stopped,
            resources: Some(Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 2,
                overlay_gib: 1,
            }),
            pid_identity: None,
            configuration: None,
        },
    }
}

#[test]
fn growth_wire_preserves_crypto_fixture_and_binds_completion_to_exact_durable_intent() {
    let hello = growth_hello();
    hello.validate().unwrap();
    let mut session = Session::new(hello.clone()).unwrap();
    session.approve(&hello).unwrap();
    assert!(matches!(
        session.admit(request(1, growth_operation(false))).unwrap(),
        ServerMessage::Accepted { .. }
    ));
    assert!(session.event(1, Stream::Stdout, b"unexpected").is_err());
    let mut foreign = grown();
    if let Outcome::Grown { transition, .. } = &mut foreign {
        transition.change.operation_id = "foreign".into();
    }
    assert!(session.terminal(1, foreign).is_err());
    let mut mismatch = grown();
    if let Outcome::Grown { observation, .. } = &mut mismatch {
        observation.resources.as_mut().unwrap().storage_gib = 3;
    }
    assert!(session.terminal(1, mismatch).is_err());
    assert!(session
        .terminal(
            1,
            Outcome::Observed {
                observation: Observation {
                    state: ObservedState::Stopped,
                    resources: None,
                    pid_identity: None,
                    configuration: None
                }
            }
        )
        .is_err());
    session.terminal(1, grown()).unwrap();
    assert!(session.terminal(1, grown()).is_err());
    assert!(grown().validate_for(1).is_err());
    assert!(grown().validate_for(2).is_ok());
}

#[test]
fn growth_lookup_is_distinct_bounded_nonmutating_evidence_and_requires_feature_approval() {
    let hello = growth_hello();
    let mut session = Session::new(hello.clone()).unwrap();
    session.approve(&hello).unwrap();
    session.admit(request(1, growth_operation(true))).unwrap();
    assert!(session.terminal(1, grown()).is_err());
    session
        .terminal(
            1,
            Outcome::GrowthPresence {
                transition: Some(Box::new(growth_fixture())),
            },
        )
        .unwrap();
    session.admit(request(2, growth_operation(true))).unwrap();
    session
        .terminal(2, Outcome::GrowthPresence { transition: None })
        .unwrap();
    let mut denied = hello;
    denied
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("disk_growth");
    denied.capabilities = denied.sdk.as_ref().unwrap().capabilities();
    let mut session = Session::new(denied.clone()).unwrap();
    session.approve(&denied).unwrap();
    assert!(matches!(
        session.admit(request(1, growth_operation(false))).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    assert!(growth_operation(true).validate(30001).is_err());
    assert!(growth_operation(false).validate(600001).is_err());
}

#[test]
fn growth_nullable_targets_strict_shapes_and_bounds_do_not_normalize_missing_fields() {
    let operation = growth_operation(false);
    let encoded = serde_json::to_value(operation).unwrap();
    for key in ["storage_gib", "overlay_gib"] {
        let mut bad = encoded.clone();
        bad["request"].as_object_mut().unwrap().remove(key);
        assert!(serde_json::from_value::<Operation>(bad).is_err());
    }
    let mut unknown = encoded.clone();
    unknown["request"]["extra"] = json!(1);
    assert!(serde_json::from_value::<Operation>(unknown).is_err());
    for size in [0, 1, 65, u64::MAX] {
        let mut invalid = encoded.clone();
        invalid["request"]["storage_gib"] = json!(size);
        match serde_json::from_value::<Operation>(invalid) {
            Err(_) => {}
            Ok(operation) => assert!(operation.validate(1000).is_err()),
        }
    }
    let mut proof = growth_fixture();
    proof.receipt.material.as_mut().unwrap().chain_sha256 = "9".repeat(64);
    assert!(proof.validate().is_err());
}

#[test]
fn explicit_growth_qualification_has_distinct_capability_quiescence_budget_and_completion() {
    let hello = growth_hello();
    let Operation::ExpandDisks {
        receipt,
        operation_id,
        request: targets,
        previous,
    } = growth_operation(false)
    else {
        unreachable!()
    };
    let operation = Operation::QualifyGrowth {
        receipt,
        operation_id,
        request: targets,
        previous,
        quiesced: true,
    };
    operation.validate(30000).unwrap();
    assert!(operation.validate(30001).is_err());
    let mut unsafe_operation = operation.clone();
    if let Operation::QualifyGrowth { quiesced, .. } = &mut unsafe_operation {
        *quiesced = false;
    }
    assert!(unsafe_operation.validate(1000).is_err());
    let mut value = serde_json::to_value(&operation).unwrap();
    value.as_object_mut().unwrap().remove("quiesced");
    assert!(serde_json::from_value::<Operation>(value).is_err());
    assert!(operation.capability() == Capability::QualifyGrowth);
    let mut session = Session::new(hello.clone()).unwrap();
    session.approve(&hello).unwrap();
    session.admit(request(1, operation)).unwrap();
    assert!(session.terminal(1, grown()).is_err());
    let Outcome::Grown {
        transition,
        observation,
    } = grown()
    else {
        unreachable!()
    };
    let qualified = Outcome::GrowthQualified {
        transition,
        observation,
    };
    assert!(qualified.validate_for(1).is_err());
    roundtrip_server(session.terminal(1, qualified.clone()).unwrap());
    assert!(session.terminal(1, qualified.clone()).is_err());
    session.admit(request(2, growth_operation(false))).unwrap();
    assert!(session.terminal(2, qualified).is_err());
}

#[test]
fn terminal_wire_binds_open_controls_whole_credit_and_collected_exit_without_lifetime_output_cap() {
    Outcome::Terminal {
        completion: Completion::NativeError,
        dispatch: Dispatch::NotDispatched,
        observed_exit: None,
        worker_collected: true,
        output_bytes: 0,
    }
    .validate_for(2)
    .unwrap();
    let message = ClientMessage::decode(
        serde_json::from_str(include_str!("../fixtures/terminal-open-request.json")).unwrap(),
    )
    .unwrap();
    let mut h = parity_hello();
    let mut old = Session::new(h.clone()).unwrap();
    old.approve(&h).unwrap();
    assert!(matches!(
        old.admit(message.clone()).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    h.sdk.as_mut().unwrap().feature_versions.extend([
        ("terminals".into(), 1),
        ("buffered_exec".into(), 1),
        ("job_resources".into(), 1),
    ]);
    h.limits = Limits::for_sdk(h.sdk.as_ref().unwrap());
    h.capabilities.push(Capability::TerminalOpen);
    h.validate().unwrap();
    assert!(h.limits.terminals.is_some());
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    session.admit(message).unwrap();
    assert!(session
        .terminal_control(&h.epoch, 1, 1, &TerminalAction::Attach)
        .is_err());
    assert!(session.event(1, Stream::Terminal, b"early").is_err());
    session.terminal_opened(1).unwrap();
    assert!(session.terminal_opened(1).is_err());
    assert!(session
        .terminal_control(
            &h.epoch,
            1,
            1,
            &TerminalAction::Input {
                data_base64: encode_chunk(b"input").unwrap()
            }
        )
        .is_err());
    assert!(session
        .terminal_control(&h.epoch, 1, 1, &TerminalAction::Attach)
        .unwrap());
    assert!(session
        .terminal_control(&h.epoch, 1, 1, &TerminalAction::Attach)
        .is_err());
    session
        .terminal_control(
            &h.epoch,
            1,
            2,
            &TerminalAction::Input {
                data_base64: encode_chunk(b"\0\xff").unwrap(),
            },
        )
        .unwrap();
    // More than the historical 65,536-event cap, with bounded outstanding credit.
    for _ in 0..65_540 {
        session.event(1, Stream::Terminal, b"\0\xff").unwrap();
        assert!(session.credit(&h.epoch, 1, 1, 0).is_err());
        session.credit(&h.epoch, 1, 2, 1).unwrap();
    }
    session
        .terminal_control(
            &h.epoch,
            1,
            3,
            &TerminalAction::Resize {
                cols: 120,
                rows: 43,
            },
        )
        .unwrap();
    session
        .terminal_control(&h.epoch, 1, 4, &TerminalAction::Close)
        .unwrap();
    assert!(session
        .terminal_control(
            &h.epoch,
            1,
            5,
            &TerminalAction::Resize { cols: 80, rows: 24 }
        )
        .is_err());
    for (code, collected) in [(Some(7), false), (Some(124), true), (None, true)] {
        assert!(session
            .terminal(
                1,
                Outcome::Terminal {
                    completion: Completion::Exited,
                    dispatch: Dispatch::MayHaveDispatched,
                    observed_exit: code,
                    worker_collected: collected,
                    output_bytes: 131080
                }
            )
            .is_err());
    }
    assert!(session.terminal(1, unknown()).is_err());
    session
        .terminal(
            1,
            Outcome::Terminal {
                completion: Completion::Exited,
                dispatch: Dispatch::MayHaveDispatched,
                observed_exit: Some(7),
                worker_collected: true,
                output_bytes: 131080,
            },
        )
        .unwrap();
    assert!(!session
        .terminal_control(&h.epoch, 1, 5, &TerminalAction::Close)
        .unwrap());
    assert!(session
        .terminal_control(&"ef".repeat(16), 1, 5, &TerminalAction::Close)
        .is_err());
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("buffered_exec");
    assert!(h.validate().is_err());
}

fn parity_receipt() -> Receipt {
    let value: Value = serde_json::from_str(include_str!("../fixtures/created-v2.json")).unwrap();
    let ServerMessage::Terminal {
        outcome: Outcome::Created { receipt },
        ..
    } = ServerMessage::decode(value).unwrap()
    else {
        unreachable!()
    };
    receipt
}

fn observation_hello() -> Hello {
    let mut approved = parity_hello();
    let sdk = approved.sdk.as_mut().unwrap();
    sdk.feature_versions.insert("observability".into(), 1);
    approved.limits = Limits::for_sdk(sdk);
    approved.capabilities.extend([
        Capability::Health,
        Capability::Capacity,
        Capability::Metrics,
        Capability::Readiness,
        Capability::List,
        Capability::Measurements,
    ]);
    approved
}

fn creation_features() -> CreationFeatures {
    CreationFeatures {
        compact: false,
        network: NetworkPolicy {
            enabled: false,
            hosts: vec![],
            cidrs: vec![],
        },
        ports: vec![PortMapping {
            host: 8080,
            guest: 80,
        }],
        workload: Some(StartupWorkload {
            entrypoint: vec![],
            cmd: vec!["/bin/app".into()],
            env: Default::default(),
            workdir: None,
        }),
    }
}

fn compact_fixture() -> Value {
    serde_json::from_str(include_str!("../fixtures/compact-creation-request.json")).unwrap()
}

#[test]
fn buffered_command_codec_requires_capability_and_preserves_nul_stdin_and_credit() {
    let value: Value =
        serde_json::from_str(include_str!("../fixtures/buffered-command-request.json")).unwrap();
    let message = ClientMessage::decode(value.clone()).ok().unwrap();
    let ClientMessage::Request {
        operation: Operation::ExecBuffered { command, .. },
        ..
    } = &message
    else {
        unreachable!()
    };
    assert_eq!(command.stdin.as_deref(), Some("hé\0stdin"));
    let mut h = observation_hello();
    let mut s = Session::new(h.clone()).ok().unwrap();
    s.approve(&h).unwrap();
    assert!(matches!(
        s.admit(message.clone()).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                ..
            },
            ..
        }
    ));
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .extend([("buffered_exec".into(), 1), ("job_resources".into(), 1)]);
    h.capabilities.push(Capability::ExecBuffered);
    h.limits = Limits::for_sdk(h.sdk.as_ref().unwrap());
    let mut s = Session::new(h.clone()).ok().unwrap();
    s.approve(&h).unwrap();
    s.admit(message).unwrap();
    s.event(1, Stream::Stdout, b"out\0\xff").unwrap();
    assert!(s
        .terminal(
            1,
            Outcome::Command {
                completion: Completion::Exited,
                dispatch: Dispatch::MayHaveDispatched,
                observed_exit: Some(7),
                running_observed: true,
                output_bytes: 5
            }
        )
        .is_ok());
    let mut broken = value.clone();
    broken["operation"]["command"] = json!({});
    assert!(ClientMessage::decode(broken).is_err());
    let mut broken = value;
    broken["operation"]["command_payload"]["schema"] = json!(2);
    assert!(ClientMessage::decode(broken).is_err());
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("job_resources");
    assert!(h.validate().is_err());
}

#[test]
fn background_ack_requires_its_own_capability_and_never_accepts_exit_output_or_stdin() {
    let value: Value =
        serde_json::from_str(include_str!("../fixtures/background-command-request.json")).unwrap();
    let message = ClientMessage::decode(value.clone()).ok().unwrap();
    let mut h = observation_hello();
    h.sdk.as_mut().unwrap().feature_versions.extend([
        ("job_resources".into(), 1),
        ("buffered_exec".into(), 1),
        ("background_exec".into(), 1),
    ]);
    h.limits = Limits::for_sdk(h.sdk.as_ref().unwrap());
    let mut unapproved = Session::new(h.clone()).ok().unwrap();
    unapproved.approve(&h).unwrap();
    assert!(matches!(
        unapproved.admit(message.clone()).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    h.capabilities.push(Capability::ExecBackground);
    let mut s = Session::new(h.clone()).ok().unwrap();
    s.approve(&h).unwrap();
    s.admit(message.clone()).unwrap();
    assert!(s.event(1, Stream::Stdout, b"pid=4242\n").is_err());
    assert!(s.terminal(1, unknown()).is_err());
    assert!(s.terminal(1, Outcome::Launched { pid: 0 }).is_err());
    s.terminal(1, Outcome::Launched { pid: 4242 }).unwrap();
    assert!(s.terminal(1, Outcome::Launched { pid: 4242 }).is_err());
    assert!(Outcome::Launched { pid: 4242 }.validate_for(1).is_err());
    let mut invalid = value;
    invalid["operation"]["operation"] = json!("exec_buffered");
    let mut stdin = ClientMessage::decode(invalid).ok().unwrap();
    if let ClientMessage::Request { operation, .. } = &mut stdin {
        let Operation::ExecBuffered { receipt, command } = operation else {
            unreachable!()
        };
        command.stdin = Some("forbidden".into());
        *operation = Operation::ExecBackground {
            receipt: receipt.clone(),
            command: command.clone(),
        };
    }
    assert!(stdin.validate().is_err());
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("buffered_exec");
    assert!(h.validate().is_err());
}

#[test]
fn streaming_commands_require_explicit_capability_nil_stdin_and_actual_exit_evidence() {
    let value: Value =
        serde_json::from_str(include_str!("../fixtures/streaming-command-request.json")).unwrap();
    let message = ClientMessage::decode(value).unwrap();
    let mut h = observation_hello();
    h.sdk.as_mut().unwrap().feature_versions.extend([
        ("job_resources".into(), 1),
        ("buffered_exec".into(), 1),
        ("streaming_exec".into(), 1),
    ]);
    h.limits = Limits::for_sdk(h.sdk.as_ref().unwrap());
    let mut unapproved = Session::new(h.clone()).unwrap();
    unapproved.approve(&h).unwrap();
    assert!(matches!(
        unapproved.admit(message.clone()).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    h.capabilities.push(Capability::ExecStream);
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    session.admit(message.clone()).unwrap();
    session.event(1, Stream::Stdout, b"out\0\xff").unwrap();
    session.event(1, Stream::Stderr, b"err\0\xfe").unwrap();
    assert!(session
        .terminal(1, Outcome::Launched { pid: 4242 })
        .is_err());
    assert!(session
        .terminal(
            1,
            Outcome::Command {
                completion: Completion::Exited,
                dispatch: Dispatch::MayHaveDispatched,
                observed_exit: None,
                running_observed: true,
                output_bytes: 10
            }
        )
        .is_err());
    session
        .terminal(
            1,
            Outcome::Command {
                completion: Completion::Exited,
                dispatch: Dispatch::MayHaveDispatched,
                observed_exit: Some(7),
                running_observed: true,
                output_bytes: 10,
            },
        )
        .unwrap();
    let mut invalid = message;
    if let ClientMessage::Request {
        operation: Operation::ExecStream { command, .. },
        ..
    } = &mut invalid
    {
        command.stdin = Some("forbidden".into());
    } else {
        unreachable!()
    }
    assert!(invalid.validate().is_err());
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("buffered_exec");
    assert!(h.validate().is_err());
}

#[test]
fn console_stream_has_distinct_credit_completion_and_version_authority() {
    let mut h = observation_hello();
    h.sdk.as_mut().unwrap().feature_versions.extend([
        ("logs".into(), 1),
        ("buffered_exec".into(), 1),
        ("job_resources".into(), 1),
    ]);
    h.limits = Limits::for_sdk(h.sdk.as_ref().unwrap());
    let operation = Operation::Logs {
        receipt: parity_receipt(),
        tail: 2,
        follow: false,
        max_bytes: 128,
    };
    let mut unavailable = Session::new(h.clone()).ok().unwrap();
    unavailable.approve(&h).unwrap();
    assert!(matches!(
        unavailable.admit(request(1, operation.clone())).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                ..
            },
            ..
        }
    ));
    h.capabilities.push(Capability::Logs);
    let mut s = Session::new(h.clone()).ok().unwrap();
    s.approve(&h).unwrap();
    s.admit(request(1, operation)).unwrap();
    assert!(s.event(1, Stream::Stdout, b"not command output").is_err());
    let mut frame = vec![0; 4];
    frame.extend_from_slice(&8u32.to_be_bytes());
    frame.extend_from_slice("hé\0line".as_bytes());
    s.event(1, Stream::Log, &frame).unwrap();
    assert!(s.terminal(1, unknown()).is_err());
    assert!(s
        .terminal(
            1,
            Outcome::Logs {
                completion: Completion::Completed,
                lines: 2,
                bytes: 10,
                wire_bytes: 15
            }
        )
        .is_err());
    s.terminal(
        1,
        Outcome::Logs {
            completion: Completion::Completed,
            lines: 2,
            bytes: 10,
            wire_bytes: 16,
        },
    )
    .unwrap();
    s.admit(request(
        2,
        Operation::Logs {
            receipt: parity_receipt(),
            tail: 0,
            follow: true,
            max_bytes: 128,
        },
    ))
    .unwrap();
    assert!(s
        .terminal(
            2,
            Outcome::Logs {
                completion: Completion::Completed,
                lines: 0,
                bytes: 0,
                wire_bytes: 0
            }
        )
        .is_err());
    s.terminal(
        2,
        Outcome::Logs {
            completion: Completion::Deadline,
            lines: 0,
            bytes: 0,
            wire_bytes: 0,
        },
    )
    .unwrap();
    assert!(Outcome::Error {
        code: SafeCode::NotFound,
        dispatch: Dispatch::NotDispatched
    }
    .validate_for(1)
    .is_err());
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("buffered_exec");
    assert!(h.validate().is_err());
}

#[test]
fn compact_creation_preserves_utf8_and_requires_the_explicit_transport_gate() {
    let message = ClientMessage::decode(compact_fixture()).ok().unwrap();
    let ClientMessage::Request { operation, .. } = &message else {
        unreachable!()
    };
    let features = operation.creation_features().unwrap();
    assert!(features.compact);
    assert_eq!(
        features.workload.as_ref().unwrap().cmd,
        vec!["literal; $(text)", "é\u{1}"]
    );
    assert_eq!(
        features.workload.as_ref().unwrap().env["PRIVATE"],
        "opaque\u{1}value"
    );
    let mut approved = observation_hello();
    approved
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .extend([("ports".into(), 1), ("workloads".into(), 1)]);
    let mut s = Session::new(approved.clone()).ok().unwrap();
    s.approve(&approved).unwrap();
    assert!(matches!(
        s.admit(message.clone()).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    approved
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("compact_creation".into(), 1);
    approved.limits = Limits::for_sdk(approved.sdk.as_ref().unwrap());
    assert_eq!(approved.limits.frame_bytes, MAX_FRAME_BYTES as u64);
    assert_eq!(
        approved.limits.creation.as_ref().unwrap().payload_bytes,
        MAX_CREATION_PAYLOAD as u64
    );
    let mut s = Session::new(approved.clone()).ok().unwrap();
    s.approve(&approved).unwrap();
    assert!(matches!(
        s.admit(message).unwrap(),
        ServerMessage::Accepted { .. }
    ));
}

#[test]
fn large_compact_workload_roundtrips_with_the_original_frame_cap() {
    fn string(bytes: &mut Vec<u8>, value: &str) {
        bytes.extend((value.len() as u32).to_be_bytes());
        bytes.extend(value.as_bytes());
    }
    let mut bytes = b"SBCF\x01\x00\x00\x00\x00\x00\x00\x00\x01".to_vec();
    bytes.extend(1u16.to_be_bytes());
    string(&mut bytes, "/bin/app");
    bytes.extend(0u16.to_be_bytes());
    bytes.extend(64u16.to_be_bytes());
    for n in 0..64 {
        string(&mut bytes, &format!("KEY_{n:02}"));
        string(&mut bytes, &"\u{1}".repeat(8192));
    }
    bytes.push(0);
    let chunks: Vec<_> = bytes
        .chunks(MAX_CHUNK_BYTES)
        .map(|chunk| encode_chunk(chunk).unwrap())
        .collect();
    let mut value = compact_fixture();
    value["operation"]["features_payload"]["chunks"] = json!(chunks);
    let mut frame = Vec::new();
    write_frame(&mut frame, &value).unwrap();
    assert!(frame.len() < MAX_FRAME_BYTES);
    let parsed = read_frame(&mut frame.as_slice()).unwrap().unwrap();
    let ClientMessage::Request { operation, .. } = ClientMessage::decode(parsed).ok().unwrap()
    else {
        unreachable!()
    };
    let features = operation.creation_features().unwrap();
    assert!(features.compact);
    let env = &features.workload.as_ref().unwrap().env;
    assert_eq!(env.len(), 64);
    assert!(env
        .values()
        .all(|value| value.len() == 8192 && value.bytes().all(|byte| byte == 1)));
    let original = serde_json::to_value(features).unwrap();
    assert!(write_frame(&mut Vec::new(), &original).is_err());
}

#[test]
fn compact_payload_rejects_truncation_trailing_data_large_counts_and_duplicate_encodings() {
    let value = compact_fixture();
    let encoded = value["operation"]["features_payload"]["chunks"][0]
        .as_str()
        .unwrap()
        .to_owned();
    let bytes = decode_chunk(&encoded).unwrap();
    for size in 0..bytes.len() {
        let mut broken = value.clone();
        // Empty is intentionally invalid too.
        use base64::Engine;
        broken["operation"]["features_payload"]["chunks"][0] =
            json!(base64::engine::general_purpose::STANDARD.encode(&bytes[..size]));
        assert!(ClientMessage::decode(broken).is_err(), "prefix {size}");
    }
    for broken_bytes in [
        [bytes.as_slice(), &[0]].concat(),
        {
            let mut b = bytes.clone();
            b[5] = 2;
            b
        },
        {
            let mut b = bytes.clone();
            b[6] = 255;
            b[7] = 255;
            b
        },
    ] {
        let mut broken = value.clone();
        broken["operation"]["features_payload"]["chunks"][0] =
            json!(encode_chunk(&broken_bytes).unwrap());
        assert!(ClientMessage::decode(broken).is_err());
    }
    let mut broken = value.clone();
    broken["operation"]["features"] = json!({});
    assert!(ClientMessage::decode(broken).is_err());
    let mut broken = value.clone();
    broken["operation"]["features_payload"]["extra"] = json!(true);
    assert!(ClientMessage::decode(broken).is_err());
    let mut broken = value;
    broken["operation"]["features_payload"]["chunks"] = json!([encoded, encoded]);
    assert!(ClientMessage::decode(broken).is_err());
    let mut features = serde_json::to_value(creation_features()).unwrap();
    features["compact"] = json!(true);
    assert!(serde_json::from_value::<CreationFeatures>(features).is_err());
}

#[test]
fn creation_features_require_each_explicit_sdk_gate_before_dispatch() {
    let query = Operation::QualifyCreation {
        checkpointable: None,
        artifact: Artifact {
            path: "/approved.smolmachine".into(),
            sha256: "ef".repeat(32),
            max_bytes: 1024,
            guest_platform: "linux/arm64".into(),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        user: None,
        features: Some(Box::new(creation_features())),
    };
    for mut approved in [hello(), parity_hello()] {
        let mut s = Session::new(approved.clone()).unwrap();
        s.approve(&approved).unwrap();
        assert!(matches!(
            s.admit(request(1, query.clone())).unwrap(),
            ServerMessage::Terminal {
                outcome: Outcome::Error {
                    code: SafeCode::Unsupported,
                    dispatch: Dispatch::NotDispatched
                },
                ..
            }
        ));
        if approved.major == 2 {
            let sdk = approved.sdk.as_mut().unwrap();
            sdk.feature_versions.insert("ports".into(), 1);
            assert!(!creation_features().approved(&approved));
            approved
                .sdk
                .as_mut()
                .unwrap()
                .feature_versions
                .insert("workloads".into(), 1);
            let mut s = Session::new(approved.clone()).unwrap();
            s.approve(&approved).unwrap();
            assert!(matches!(
                s.admit(request(1, query.clone())).unwrap(),
                ServerMessage::Accepted { .. }
            ));
            let mut enabled = creation_features();
            enabled.network = NetworkPolicy {
                enabled: true,
                hosts: vec!["api.example.com".into()],
                cidrs: vec![],
            };
            assert!(!enabled.approved(&approved));
            approved
                .sdk
                .as_mut()
                .unwrap()
                .feature_versions
                .insert("networking".into(), 1);
            assert!(enabled.approved(&approved));
        }
    }
    let mut empty = creation_features();
    empty.ports.clear();
    empty.workload = None;
    assert!(!empty.approved(&parity_hello()));
}

#[test]
fn creation_workload_bounds_match_public_requests_and_reject_unknown_fields() {
    let original = creation_features();
    assert!(original.validate().is_ok());
    let mut invalid = original.clone();
    invalid
        .workload
        .as_mut()
        .unwrap()
        .env
        .insert("1INVALID".into(), "value".into());
    assert!(invalid.validate().is_err());
    let mut invalid = original.clone();
    invalid.workload.as_mut().unwrap().cmd = vec!["x".repeat(16384); 4];
    assert!(invalid.validate().is_err());
    let mut invalid = original.clone();
    invalid.ports.push(invalid.ports[0]);
    assert!(invalid.validate().is_err());
    let mut wire = serde_json::to_value(&original).unwrap();
    wire["workload"]["restart"] = json!("always");
    assert!(serde_json::from_value::<CreationFeatures>(wire).is_err());
}

#[test]
fn network_observation_and_port_conflict_cannot_be_mislabelled_legacy() {
    let observed = Outcome::Observed {
        observation: Observation {
            state: ObservedState::Stopped,
            resources: None,
            pid_identity: None,
            configuration: Some(Box::new(MachineConfiguration {
                network: creation_features().network,
                ports: creation_features().ports,
                backend: Some("virtio-net".into()),
                mounts: None,
            })),
        },
    };
    assert!(observed.validate_for(2).is_ok());
    assert!(observed.validate_for(1).is_err());
    let error = Outcome::Error {
        code: SafeCode::PortConflict,
        dispatch: Dispatch::MayHaveDispatched,
    };
    assert!(error.validate_for(2).is_ok());
    assert!(error.validate_for(1).is_err());
    let mut invalid = serde_json::to_value(&observed).unwrap();
    invalid["observation"]["configuration"] = Value::Null;
    assert!(serde_json::from_value::<Outcome>(invalid).is_err());
    let query = Operation::QualifyCreation {
        checkpointable: None,
        artifact: Artifact {
            path: "/approved.smolmachine".into(),
            sha256: "ef".repeat(32),
            max_bytes: 1024,
            guest_platform: "linux/arm64".into(),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        user: None,
        features: None,
    };
    let mut wire = serde_json::to_value(&query).unwrap();
    assert!(wire.get("features").is_none());
    wire["features"] = Value::Null;
    assert!(serde_json::from_value::<Operation>(wire).is_err());
}

#[test]
fn observations_require_the_explicit_sdk_feature_and_versioned_limits() {
    let approved = observation_hello();
    assert!(approved.validate().is_ok());
    let mut legacy = hello();
    legacy.capabilities = vec![Capability::Health];
    assert!(legacy.validate().is_err());
    let mut missing_feature = parity_hello();
    missing_feature.capabilities.push(Capability::Health);
    assert!(missing_feature.validate().is_err());
    let mut wrong_limits = approved.clone();
    wrong_limits.limits = Limits::default();
    assert!(wrong_limits.validate().is_err());
    let ready = Outcome::Ready;
    assert!(ready.validate_for(2).is_ok());
    assert!(ready.validate_for(1).is_err());
    let full = Outcome::Health {
        snapshot: HealthSnapshot {
            total: 1,
            running: 2,
            uptime_seconds: 0,
        },
    };
    assert!(full.validate().is_err());
}

#[test]
fn job_limits_require_the_explicit_feature_and_exact_pool_contract() {
    let mut approved = observation_hello();
    approved
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("job_resources".into(), 1);
    approved.limits = Limits::for_sdk(approved.sdk.as_ref().unwrap());
    assert!(approved.validate().is_ok());
    assert_eq!(approved.limits.jobs.as_ref().unwrap().work_slots, 4);
    let mut wrong = approved.clone();
    wrong.limits.jobs.as_mut().unwrap().work_slots = 5;
    assert!(wrong.validate().is_err());
    let mut wrong = approved.clone();
    wrong.limits.jobs = None;
    assert!(wrong.validate().is_err());
    let mut wrong = observation_hello();
    wrong.limits.jobs = approved.limits.jobs;
    assert!(wrong.validate().is_err());
    assert!(Limits::default().jobs.is_none());
}

#[test]
fn inventory_uses_credited_chunks_and_cannot_complete_with_unaccounted_bytes() {
    let approved = observation_hello();
    let mut session = Session::new(approved.clone()).unwrap();
    session.approve(&approved).unwrap();
    let req = ClientMessage::Request {
        epoch: approved.epoch.clone(),
        id: 1,
        budget_ms: 1000,
        initial_credit: INITIAL_CREDIT_BYTES,
        initial_event_credit: INITIAL_CREDIT_EVENTS,
        operation: Operation::List,
    };
    assert!(matches!(
        session.admit(req).unwrap(),
        ServerMessage::Accepted { .. }
    ));
    assert!(session.event(1, Stream::Stdout, b"[]").is_err());
    assert!(session.event(1, Stream::File, b"[]").is_ok());
    assert!(session
        .terminal(1, Outcome::Inventory { count: 0, bytes: 1 })
        .is_err());
    assert!(session
        .terminal(
            1,
            Outcome::Health {
                snapshot: HealthSnapshot {
                    total: 0,
                    running: 0,
                    uptime_seconds: 0
                }
            }
        )
        .is_err());
    assert!(session
        .terminal(1, Outcome::Inventory { count: 0, bytes: 2 })
        .is_ok());
    assert!(Outcome::Inventory {
        count: 1025,
        bytes: 0
    }
    .validate()
    .is_err());
}

#[test]
fn observation_completion_is_bound_to_its_own_request_kind() {
    let approved = observation_hello();
    let mut session = Session::new(approved.clone()).unwrap();
    session.approve(&approved).unwrap();
    let req = ClientMessage::Request {
        epoch: approved.epoch.clone(),
        id: 1,
        budget_ms: 1000,
        initial_credit: INITIAL_CREDIT_BYTES,
        initial_event_credit: INITIAL_CREDIT_EVENTS,
        operation: Operation::Health,
    };
    session.admit(req).unwrap();
    assert!(session.terminal(1, Outcome::Ready).is_err());
    assert!(session
        .terminal(
            1,
            Outcome::Health {
                snapshot: HealthSnapshot {
                    total: 0,
                    running: 0,
                    uptime_seconds: 0
                }
            }
        )
        .is_ok());
}

#[test]
fn parity_shared_fixtures_bind_sdk_identity_features_and_versioned_material() {
    let h = parity_hello();
    assert_eq!(h.major, 2);
    assert_eq!(h.minor, 0);
    assert_eq!(h.sdk.as_ref().unwrap().sdk_version, "1.22.0");
    assert_eq!(
        h.sdk
            .as_ref()
            .unwrap()
            .feature_versions
            .get("material_proofs"),
        Some(&2)
    );
    let versioned = parity_receipt();
    versioned.validate_for(2).unwrap();
    assert!(versioned.validate_for(1).is_err());
    assert!(receipt().validate_for(2).is_err());
    let value: Value =
        serde_json::from_str(include_str!("../fixtures/inspect-v2-request.json")).unwrap();
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    assert!(matches!(
        session
            .admit(ClientMessage::decode(value).unwrap())
            .unwrap(),
        ServerMessage::Accepted { .. }
    ));
}

#[test]
fn legacy_serialization_has_no_sdk_or_material_and_cannot_admit_new_proofs() {
    let serialized = serde_json::to_value(hello()).unwrap();
    assert!(serialized.get("sdk").is_none());
    assert!(serde_json::to_value(receipt())
        .unwrap()
        .get("material")
        .is_none());
    let operation = Operation::Inspect {
        receipt: parity_receipt(),
    };
    let mut session = session();
    let result = session.admit(request(1, operation)).unwrap();
    assert!(matches!(
        result,
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Ownership,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    assert_eq!(session.pending_count(), 0);
}

#[test]
fn parity_cannot_admit_legacy_receipt_or_downgraded_material() {
    let h = parity_hello();
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    let operation = Operation::Inspect { receipt: receipt() };
    assert!(matches!(
        session.admit(request(1, operation)).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Ownership,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    assert_eq!(session.pending_count(), 0);
}

#[test]
fn parity_hello_rejects_wrong_sdk_source_unknown_features_versions_and_legacy_approval() {
    let good = parity_hello();
    let mut variants = Vec::new();
    let mut wrong = good.clone();
    wrong.sdk = None;
    variants.push(wrong);
    let mut wrong = good.clone();
    wrong.sdk.as_mut().unwrap().source_revision = "00".repeat(20);
    variants.push(wrong);
    let mut wrong = good.clone();
    wrong
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("arbitrary".into(), 1);
    variants.push(wrong);
    let mut wrong = good.clone();
    wrong
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("networking".into(), 2);
    variants.push(wrong);
    let mut wrong = good.clone();
    wrong
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("material_proofs");
    variants.push(wrong);
    let mut wrong = good.clone();
    wrong.minor = 1;
    variants.push(wrong);
    for wrong in variants {
        assert!(wrong.validate().is_err());
    }
    assert!(good.approve(&hello()).is_err());
    let mut legacy = hello();
    legacy.sdk = good.sdk.clone();
    assert!(legacy.validate().is_err());
}

#[test]
fn material_proof_requires_exact_shape_root_hash_bounds_and_correlated_transition_identity() {
    let good = serde_json::to_value(parity_receipt()).unwrap();
    for (key, value) in [
        ("schema", json!(1)),
        ("revision", json!(1025)),
        ("record_sha256", json!("00".repeat(32))),
        ("operation_id", json!("unexpected-root-operation")),
        ("request_sha256", json!("aa".repeat(32))),
        ("unknown", json!(true)),
    ] {
        let mut wrong = good.clone();
        wrong["material"][key] = value;
        let parsed = serde_json::from_value::<Receipt>(wrong);
        assert!(parsed.is_err() || parsed.unwrap().validate_for(2).is_err());
    }
    let mut advanced = good.clone();
    advanced["material"]["revision"] = json!(1);
    advanced["material"]["record_sha256"] = json!("00".repeat(32));
    assert!(serde_json::from_value::<Receipt>(advanced.clone())
        .unwrap()
        .validate_for(2)
        .is_err());
    advanced["material"]["operation_id"] = json!("grow-1");
    advanced["material"]["request_sha256"] = json!("aa".repeat(32));
    serde_json::from_value::<Receipt>(advanced)
        .unwrap()
        .validate_for(2)
        .unwrap();
}

#[test]
fn qualification_has_no_receipt_or_stream_and_cannot_satisfy_a_command() {
    let operation = Operation::QualifyCreation {
        checkpointable: None,
        features: None,
        artifact: Artifact {
            path: "/approved.smolmachine".into(),
            sha256: "aa".repeat(32),
            max_bytes: 1024,
            guest_platform: "linux/arm64".into(),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        user: Some("65534:65534".into()),
    };
    assert!(operation.receipt().is_none());
    assert!(operation.validate(30_001).is_err());
    let mut s = session();
    s.admit(request(1, operation)).unwrap();
    assert!(s.event(1, Stream::Stdout, b"bad").is_err());
    roundtrip_server(s.terminal(1, Outcome::Qualified).unwrap());
    s.admit(request(2, command())).unwrap();
    assert!(s.terminal(2, Outcome::Qualified).is_err());
}
fn unknown() -> Outcome {
    Outcome::Command {
        completion: Completion::Unknown,
        dispatch: Dispatch::MayHaveDispatched,
        observed_exit: None,
        running_observed: false,
        output_bytes: 0,
    }
}

#[test]
fn intent_presence_is_streamless_and_cannot_mint_receipts_or_satisfy_commands() {
    let create = Create {
        checkpointable: None,
        volume_mounts: None,
        features: None,
        name: "candidate".into(),
        owner_token: "ab".repeat(32),
        incarnation: "cd".repeat(16),
        artifact: Artifact {
            path: "/approved.smolmachine".into(),
            sha256: "ef".repeat(32),
            max_bytes: 1024,
            guest_platform: "linux/arm64".into(),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        labels: Default::default(),
    };
    let query = Operation::InspectCreation {
        create: create.clone(),
    };
    assert!(query.receipt().is_none());
    assert!(query.validate(30_001).is_err());
    let mut s = session();
    s.admit(request(1, query)).unwrap();
    assert!(s.event(1, Stream::Stdout, b"bad").is_err());
    assert!(s
        .terminal(1, Outcome::Created { receipt: receipt() })
        .is_err());
    roundtrip_server(
        s.terminal(
            1,
            Outcome::CreationPresence {
                presence: CreationPresence::Unverified,
            },
        )
        .unwrap(),
    );
    s.admit(request(2, command())).unwrap();
    assert!(s
        .terminal(
            2,
            Outcome::CreationPresence {
                presence: CreationPresence::Absent
            }
        )
        .is_err());
    s.admit(request(3, Operation::Create { create })).unwrap();
    assert!(s
        .terminal(
            3,
            Outcome::CreationPresence {
                presence: CreationPresence::Absent
            }
        )
        .is_err());
    assert!(serde_json::from_value::<Outcome>(
        json!({"result":"creation_presence", "presence":"owned"})
    )
    .is_err());
    assert!(serde_json::from_value::<Outcome>(
        json!({"result":"creation_presence", "presence":"absent", "receipt":{}})
    )
    .is_err());
}
fn roundtrip_server(message: ServerMessage) {
    let value = serde_json::to_value(&message).unwrap();
    assert!(ServerMessage::decode(value.clone()).unwrap() == message);
    let mut framed = Vec::new();
    write_frame(&mut framed, &value).unwrap();
    assert_eq!(
        read_frame(&mut std::io::Cursor::new(framed)).unwrap(),
        Some(value)
    );
}

#[test]
fn startup_requires_exact_approved_tuple_and_failed_preflight_cannot_be_approved() {
    let h = hello();
    let mut s = Session::new(h.clone()).unwrap();
    assert!(s.admit(request(1, command())).is_err());
    for field in [
        "major",
        "minor",
        "epoch",
        "domain",
        "package",
        "capabilities",
        "limits",
    ] {
        let mut value = serde_json::to_value(&h).unwrap();
        value[field] = Value::Null;
        assert!(ClientMessage::decode(json!({"type": "approve", "hello": value})).is_err());
    }
    let mut wrong = h.clone();
    wrong.package.assets_sha256 = "00".repeat(32);
    assert!(s.approve(&wrong).is_err());
    s.approve(&h).unwrap();
    assert!(s.approve(&h).is_err());
    let mut failed = h;
    failed.preflight = Preflight::Rejected {
        code: SafeCode::Package,
    };
    roundtrip_server(ServerMessage::Hello {
        hello: failed.clone().into(),
    });
    assert!(Session::new(failed.clone())
        .unwrap()
        .approve(&failed)
        .is_err());
}

#[test]
fn unknown_fields_and_unsupported_requests_are_rejected_without_native_work() {
    let request_value = serde_json::to_value(request(1, command())).unwrap();
    let paths: &[&[&str]] = &[
        &[],
        &["operation"],
        &["operation", "command"],
        &["operation", "receipt"],
    ];
    for path in paths {
        let mut bad = request_value.clone();
        let mut object = &mut bad;
        for key in *path {
            object = &mut object[*key];
        }
        object["stdin"] = json!("private contents");
        let error = ClientMessage::decode(bad).err().unwrap();
        assert_eq!(error.to_string(), "invalid Port protocol message");
    }
    for name in [
        "terminal",
        "checkpoint",
        "expand_disk",
        "network",
        "rustler",
    ] {
        let mut bad = request_value.clone();
        bad["operation"]["operation"] = json!(name);
        assert!(ClientMessage::decode(bad).is_err());
    }
    let mut limited = hello();
    limited.capabilities = vec![Capability::Inspect];
    let mut s = Session::new(limited.clone()).unwrap();
    s.approve(&limited).unwrap();
    let response = s.admit(request(1, command())).unwrap();
    assert!(matches!(
        response,
        ServerMessage::Terminal {
            sequence: 0,
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    assert_eq!(s.pending_count(), 0);
    assert!(s.admit(request(1, command())).is_err());
}

#[test]
fn bounded_admission_reserves_control_and_never_reuses_an_id_or_epoch() {
    let mut s = session();
    for id in 1..=MAX_IN_FLIGHT as u64 {
        let accepted = s.admit(request(id, command())).unwrap();
        assert!(matches!(
            accepted,
            ServerMessage::Accepted { sequence: 0, .. }
        ));
        roundtrip_server(accepted);
    }
    assert!(matches!(
        s.admit(request(33, command())).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Overload,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    assert_eq!(s.pending_count(), 32);
    assert!(s.cancel(&hello().epoch, 1).unwrap());
    assert!(s.cancel(&"00".repeat(16), 1).is_err());
    assert!(s.cancel(&hello().epoch, 34).is_err());
    roundtrip_server(s.terminal(1, unknown()).unwrap());
    assert!(!s.cancel(&hello().epoch, 1).unwrap()); // Ordinary late cancel.
    s.credit(&hello().epoch, 1, 1, 1).unwrap(); // Ordinary late credit.
    assert!(s.admit(request(1, command())).is_err());
    s.admit(request(34, command())).unwrap();
    assert_eq!(s.pending_count(), 32);
}

#[test]
fn receipt_names_cannot_alias_native_storage_roots_before_admission() {
    let mut s = session();
    for name in [".", ".."] {
        let mut operation = command();
        if let Operation::Exec { receipt, .. } = &mut operation {
            receipt.name = name.into();
        }
        assert!(s.admit(request(1, operation)).is_err());
        assert_eq!(s.pending_count(), 0);
    }
}

#[test]
fn cross_domain_receipts_fail_before_scheduling_and_do_not_mint_authority() {
    let mut foreign = receipt();
    foreign.domain_generation = "00".repeat(16);
    let mut s = session();
    assert!(matches!(
        s.admit(request(1, Operation::Delete { receipt: foreign }))
            .unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Ownership,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    let create = Create {
        checkpointable: None,
        volume_mounts: None,
        features: None,
        name: "owned".into(),
        owner_token: receipt().owner_token,
        incarnation: receipt().incarnation,
        artifact: Artifact {
            path: "/approved/image.smolmachine".into(),
            sha256: "01".repeat(32),
            max_bytes: 1024,
            guest_platform: "linux/arm64".into(),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        labels: Default::default(),
    };
    s.admit(request(2, Operation::Create { create })).unwrap();
    let mut wrong = receipt();
    wrong.owner_token = "00".repeat(32);
    assert!(s.terminal(2, Outcome::Created { receipt: wrong }).is_err());
    roundtrip_server(
        s.terminal(2, Outcome::Created { receipt: receipt() })
            .unwrap(),
    );
}

#[test]
fn credit_cannot_be_fabricated_and_streams_preserve_sequence_and_byte_totals() {
    let mut s = session();
    s.admit(request(1, command())).unwrap();
    assert!(s.credit(&hello().epoch, 1, 1, 1).is_err());
    assert!(s.event(1, Stream::File, b"invalid stream").is_err());
    let first = s.event(1, Stream::Stdout, b"out").unwrap();
    let second = s.event(1, Stream::Stderr, b"err").unwrap();
    assert!(matches!(first, ServerMessage::Event { sequence: 1, .. }));
    assert!(matches!(second, ServerMessage::Event { sequence: 2, .. }));
    roundtrip_server(first);
    roundtrip_server(second);
    s.credit(&hello().epoch, 1, 6, 2).unwrap();
    assert!(s.credit(&hello().epoch, 1, 1, 1).is_err());
    let mut outcome = Outcome::Command {
        completion: Completion::Exited,
        dispatch: Dispatch::MayHaveDispatched,
        observed_exit: Some(0),
        running_observed: true,
        output_bytes: 7,
    };
    assert!(s.terminal(1, outcome.clone()).is_err()); // Cannot claim success after truncating output.
    if let Outcome::Command { output_bytes, .. } = &mut outcome {
        *output_bytes = 6;
    }
    let terminal = s.terminal(1, outcome.clone()).unwrap();
    assert!(matches!(
        terminal,
        ServerMessage::Terminal { sequence: 3, .. }
    ));
    roundtrip_server(terminal);
    assert!(s.event(1, Stream::Stdout, b"late").is_err());
    assert!(s.terminal(1, outcome).is_err());
    let mut request = request(2, command());
    if let ClientMessage::Request { initial_credit, .. } = &mut request {
        *initial_credit = 1;
    }
    s.admit(request).unwrap();
    assert!(s.event(2, Stream::Stdout, b"ab").is_err());
    assert!(s.cancel(&hello().epoch, 2).unwrap()); // Credit does not block control.
}

#[test]
fn strict_base64_rejects_noncanonical_and_oversized_chunks_before_dispatch() {
    for invalid in ["YQ", "YR==", "YQ==\n", "_w==", "?", "a==="] {
        assert!(decode_chunk(invalid).is_err());
    }
    let largest = vec![255; MAX_CHUNK_BYTES];
    let encoded = encode_chunk(&largest).unwrap();
    assert_eq!(decode_chunk(&encoded).unwrap(), largest);
    assert!(encode_chunk(&vec![0; MAX_CHUNK_BYTES + 1]).is_err());
    // Even a syntactically valid encoded body one byte over the decoded limit fails.
    let oversized = format!("{}AAA=", "AAAA".repeat(MAX_CHUNK_BYTES / 3));
    assert!(decode_chunk(&oversized).is_err());
    assert!(ClientMessage::decode(
        json!({"type": "upload", "epoch": hello().epoch, "id": 1, "offset": 0, "data_base64": ""})
    )
    .is_err());
}

#[test]
fn tiny_events_exhaust_message_credit_and_partial_consumption_cannot_restore_it() {
    let mut s = session();
    let mut operation = command();
    if let Operation::Exec { command, .. } = &mut operation {
        command.max_output_bytes = 4096;
    }
    s.admit(request(1, operation)).unwrap();
    for _ in 0..INITIAL_CREDIT_EVENTS {
        s.event(1, Stream::Stdout, b"ab").unwrap();
    }
    assert!(s.available_credit(1).unwrap() > 0);
    assert_eq!(s.available_event_credit(1).unwrap(), 0);
    assert!(s.event(1, Stream::Stdout, b"x").is_err());
    assert!(s.credit(&hello().epoch, 1, 1, 1).is_err());
    s.credit(&hello().epoch, 1, 1, 0).unwrap();
    assert_eq!(s.available_event_credit(1).unwrap(), 0);
    assert!(s.event(1, Stream::Stdout, b"x").is_err());
    s.credit(&hello().epoch, 1, 1, 1).unwrap();
    s.event(1, Stream::Stdout, b"x").unwrap();
    assert!(s
        .credit(&hello().epoch, 1, 127, INITIAL_CREDIT_EVENTS - 1)
        .is_err());
    s.credit(&hello().epoch, 1, 127, INITIAL_CREDIT_EVENTS)
        .unwrap();
    assert!(s.cancel(&hello().epoch, 1).unwrap());
}

#[test]
fn uploads_are_chunked_ordered_capped_and_not_complete_until_every_byte_arrives() {
    let mut s = session();
    let options = FileOptions {
        guest_path: "/workspace/a".into(),
        max_bytes: 5,
        mode: Some(0o600),
    };
    s.admit(request(
        1,
        Operation::WriteFile {
            receipt: receipt(),
            options,
            total_bytes: 5,
        },
    ))
    .unwrap();
    let encoded = encode_chunk(b"abc").unwrap();
    assert!(s.upload(&hello().epoch, 1, 1, &encoded).is_err());
    assert_eq!(s.upload(&hello().epoch, 1, 0, &encoded).unwrap(), b"abc");
    assert!(!s.upload_complete(1).unwrap());
    assert!(s.upload(&hello().epoch, 1, 0, &encoded).is_err());
    assert!(s.upload(&hello().epoch, 1, 3, &encoded).is_err());
    let completed = Outcome::File {
        completion: Completion::Completed,
        dispatch: Dispatch::MayHaveDispatched,
        observed_bytes: 5,
        native_acknowledged: true,
    };
    assert!(s.terminal(1, completed.clone()).is_err());
    s.upload(&hello().epoch, 1, 3, &encode_chunk(b"de").unwrap())
        .unwrap();
    assert!(s.upload_complete(1).unwrap());
    roundtrip_server(s.terminal(1, completed).unwrap());
    assert!(s.upload(&hello().epoch, 1, 5, &encoded).is_err());
}

#[test]
fn terminal_evidence_never_turns_missing_exit_or_ack_into_success() {
    unknown().validate().unwrap();
    for completion in [
        Completion::Cancelled,
        Completion::Deadline,
        Completion::OutputLimit,
        Completion::ConsumerLost,
        Completion::NativeError,
    ] {
        let outcome = Outcome::Command {
            completion,
            dispatch: Dispatch::MayHaveDispatched,
            observed_exit: Some(0),
            running_observed: true,
            output_bytes: 0,
        };
        outcome.validate().unwrap(); // Real Exit retained despite failed completion.
    }
    assert!(Outcome::Command {
        completion: Completion::Exited,
        dispatch: Dispatch::MayHaveDispatched,
        observed_exit: None,
        running_observed: true,
        output_bytes: 0
    }
    .validate()
    .is_err());
    assert!(Outcome::Command {
        completion: Completion::Exited,
        dispatch: Dispatch::NotDispatched,
        observed_exit: Some(0),
        running_observed: true,
        output_bytes: 0
    }
    .validate()
    .is_err());
    assert!(Outcome::File {
        completion: Completion::Completed,
        dispatch: Dispatch::MayHaveDispatched,
        observed_bytes: 0,
        native_acknowledged: false
    }
    .validate()
    .is_err());
    let mut s = session();
    s.admit(request(
        1,
        Operation::ReadFile {
            receipt: receipt(),
            options: FileOptions {
                guest_path: "/a".into(),
                max_bytes: 8,
                mode: None,
            },
        },
    ))
    .unwrap();
    let completed = Outcome::File {
        completion: Completion::Completed,
        dispatch: Dispatch::MayHaveDispatched,
        observed_bytes: 8,
        native_acknowledged: true,
    };
    assert!(s.terminal(1, completed).is_err()); // Ack is not proof all file bytes were delivered.
}

#[test]
fn scalar_and_resource_constraints_reject_silent_clamps_and_unsafe_paths() {
    let mut op = command();
    if let Operation::Exec { command, .. } = &mut op {
        command.argv = vec!["".into()];
    }
    assert!(op.validate(1000).is_err());
    let resources = Resources {
        cpus: 17,
        memory_mib: 512,
        storage_gib: 1,
        overlay_gib: 1,
    };
    assert!(resources.validate().is_err());
    for path in ["relative", "/", "/workspace/../a", "/a/", "/a\0"] {
        let op = Operation::ReadFile {
            receipt: receipt(),
            options: FileOptions {
                guest_path: path.into(),
                max_bytes: 1,
                mode: None,
            },
        };
        assert!(op.validate(1000).is_err());
    }
    assert!(command().validate(0).is_err());
    assert!(command().validate(86_400_001).is_err());
    let bad = json!({"type": "cancel", "epoch": hello().epoch, "id": MAX_SAFE_INTEGER + 1});
    assert!(ClientMessage::decode(bad).is_err());
}

#[test]
fn golden_request_and_terminal_fixtures_roundtrip() {
    let request_value: Value =
        serde_json::from_str(include_str!("../fixtures/exec-request.json")).unwrap();
    let terminal_value: Value =
        serde_json::from_str(include_str!("../fixtures/exec-terminal.json")).unwrap();
    assert_eq!(
        serde_json::to_value(ClientMessage::decode(request_value.clone()).unwrap()).unwrap(),
        request_value
    );
    assert_eq!(
        serde_json::to_value(ServerMessage::decode(terminal_value.clone()).unwrap()).unwrap(),
        terminal_value
    );
}

#[test]
fn event_and_credit_exhaustion_are_bounded_without_blocking_other_requests() {
    let mut s = session();
    let mut op = command();
    if let Operation::Exec { command, .. } = &mut op {
        command.max_output_bytes = MAX_TRANSFER_BYTES;
    }
    s.admit(request(1, op.clone())).unwrap();
    for _ in 0..4 {
        s.event(1, Stream::Stdout, &vec![0; MAX_CHUNK_BYTES])
            .unwrap();
    }
    assert!(s.event(1, Stream::Stdout, b"a").is_err());
    assert!(s.cancel(&hello().epoch, 1).unwrap());
    s.credit(&hello().epoch, 1, MAX_CHUNK_BYTES as u64, 1)
        .unwrap();
    s.event(1, Stream::Stderr, b"b").unwrap();
    s.admit(request(2, op)).unwrap();
    for _ in 0..MAX_EVENTS_PER_REQUEST {
        s.event(2, Stream::Stdout, b"a").unwrap();
        s.credit(&hello().epoch, 2, 1, 1).unwrap();
    }
    assert!(s.event(2, Stream::Stdout, b"a").is_err());
    assert!(s.cancel(&hello().epoch, 2).unwrap());
    s.event(1, Stream::Stdout, b"c").unwrap(); // The other request still progresses.
    let failure = Outcome::Command {
        completion: Completion::ConsumerLost,
        dispatch: Dispatch::MayHaveDispatched,
        observed_exit: Some(0),
        running_observed: true,
        output_bytes: MAX_EVENTS_PER_REQUEST,
    };
    let terminal = s.terminal(2, failure).unwrap();
    assert!(
        matches!(terminal, ServerMessage::Terminal { sequence, .. } if sequence == MAX_EVENTS_PER_REQUEST + 1)
    );
}

#[test]
fn terminal_zero_only_represents_a_pre_admission_rejection() {
    let h = hello();
    assert!(ServerMessage::Terminal {
        epoch: h.epoch.clone(),
        id: 1,
        sequence: 0,
        outcome: unknown()
    }
    .validate()
    .is_err());
    assert!(ServerMessage::Terminal {
        epoch: h.epoch.clone(),
        id: 1,
        sequence: 0,
        outcome: Outcome::Error {
            code: SafeCode::Overload,
            dispatch: Dispatch::NotDispatched
        }
    }
    .validate()
    .is_ok());
    assert!(ServerMessage::Event {
        epoch: h.epoch.clone(),
        id: 1,
        sequence: MAX_EVENTS_PER_REQUEST + 1,
        event: Event {
            stream: Stream::Stdout,
            data_base64: encode_chunk(b"x").unwrap()
        }
    }
    .validate()
    .is_err());
    assert!(ServerMessage::Terminal {
        epoch: h.epoch,
        id: 1,
        sequence: MAX_EVENTS_PER_REQUEST + 2,
        outcome: unknown()
    }
    .validate()
    .is_err());
}

#[test]
fn image_listing_is_versioned_capability_bound_and_uses_only_credited_file_output() {
    let mut h: Hello = match ServerMessage::decode(
        serde_json::from_str(include_str!("../fixtures/hello-v2-current.json")).unwrap(),
    )
    .unwrap()
    {
        ServerMessage::Hello { hello } => *hello,
        _ => unreachable!(),
    };
    let r = growth_fixture().previous;
    h.domain = DomainIdentity {
        target_id: r.target_id.clone(),
        generation: r.domain_generation.clone(),
    };
    let operation = Operation::ListImages { receipt: r };
    assert!(operation.validate(30000).is_ok());
    assert!(operation.validate(30001).is_err());
    let mut unsupported = Session::new(h.clone()).ok().unwrap();
    unsupported.approve(&h).unwrap();
    assert!(matches!(
        unsupported.admit(request(1, operation.clone())).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    let sdk = h.sdk.as_mut().unwrap();
    sdk.feature_versions.insert("images".into(), 1);
    h.capabilities = sdk.capabilities();
    h.validate().unwrap();
    let mut s = Session::new(h.clone()).ok().unwrap();
    s.approve(&h).unwrap();
    s.admit(request(1, operation.clone())).unwrap();
    assert!(s.event(1, Stream::Stdout, b"[]").is_err());
    assert!(s
        .terminal(1, Outcome::Images { count: 0, bytes: 2 })
        .is_err());
    s.event(1, Stream::File, b"[").unwrap();
    s.event(1, Stream::File, b"]").unwrap();
    assert!(s
        .terminal(1, Outcome::Inventory { count: 0, bytes: 2 })
        .is_err());
    assert!(s
        .terminal(1, Outcome::Images { count: 0, bytes: 3 })
        .is_err());
    s.terminal(1, Outcome::Images { count: 0, bytes: 2 })
        .unwrap();
    assert!(s
        .terminal(1, Outcome::Images { count: 0, bytes: 2 })
        .is_err());
    s.admit(request(2, operation)).unwrap();
    let chunk = vec![b' '; MAX_CHUNK_BYTES];
    for _ in 0..16 {
        s.event(2, Stream::File, &chunk).unwrap();
        s.credit(&h.epoch, 2, chunk.len() as u64, 1).unwrap();
    }
    s.terminal(
        2,
        Outcome::Images {
            count: 1024,
            bytes: 16 * MAX_CHUNK_BYTES as u64,
        },
    )
    .unwrap();
    assert!(Outcome::Images { count: 0, bytes: 2 }
        .validate_for(1)
        .is_err());
    for outcome in [
        Outcome::Images {
            count: 1025,
            bytes: 2,
        },
        Outcome::Images { count: 0, bytes: 1 },
        Outcome::Images {
            count: 0,
            bytes: 8388609,
        },
    ] {
        assert!(outcome.validate_for(2).is_err());
    }
    let sdk = h.sdk.as_mut().unwrap();
    sdk.feature_versions.insert("disk_growth".into(), 1);
    h.capabilities = sdk.capabilities();
    assert_eq!(h.capabilities.len(), 26);
    h.validate().unwrap();
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("job_resources");
    assert!(h.validate().is_err());
}

#[test]
fn pull_image_has_distinct_versioned_nonstreaming_evidence_bound_to_exact_oci_intent() {
    let mut h = growth_hello();
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("images".into(), 1);
    h.capabilities = h.sdk.as_ref().unwrap().capabilities();
    let source = OciSource {
        reference: format!("registry.example/app@sha256:{}", "a".repeat(64)),
        platform: "linux/arm64".into(),
    };
    let operation = Operation::PullImage {
        receipt: growth_fixture().previous,
        source: source.clone(),
    };
    operation.validate(86400000).unwrap();
    assert!(operation.validate(86400001).is_err());
    let image = ImageObservation {
        reference: source.reference.clone(),
        digest: format!("sha256:{}", "b".repeat(64)),
        size: 123,
        architecture: "arm64".into(),
        os: "linux".into(),
        layer_count: 2,
    };
    let mut s = Session::new(h.clone()).ok().unwrap();
    s.approve(&h).unwrap();
    s.admit(request(1, operation)).unwrap();
    assert!(s.event(1, Stream::File, b"[]").is_err());
    assert!(s
        .terminal(1, Outcome::Images { count: 1, bytes: 2 })
        .is_err());
    for invalid in [
        ImageObservation {
            digest: "packed".into(),
            ..image.clone()
        },
        ImageObservation {
            architecture: "amd64".into(),
            ..image.clone()
        },
        ImageObservation {
            reference: "different".into(),
            ..image.clone()
        },
    ] {
        assert!(s.terminal(1, Outcome::Pulled { image: invalid }).is_err());
    }
    assert!(Outcome::Pulled {
        image: image.clone()
    }
    .validate_for(1)
    .is_err());
    s.terminal(1, Outcome::Pulled { image }).unwrap();
    assert_eq!(s.pending_count(), 0);
    let value = serde_json::json!({"reference":source.reference,"platform":source.platform,"auth":{"password":"discard"}});
    assert!(serde_json::from_value::<OciSource>(value).is_err());
}

#[test]
fn registry_preparation_is_versioned_exact_and_has_no_events_or_credentials() {
    let mut h = growth_hello();
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("remote_sources".into(), 1);
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("compact_creation".into(), 1);
    h.capabilities = h.sdk.as_ref().unwrap().capabilities();
    let source = RegistrySource {
        reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
        platform: "linux/arm64".into(),
        content_sha256: "b".repeat(64),
    };
    let operation = Operation::PrepareArtifact {
        source: source.clone(),
        credential_ref: None,
        identity_token: None,
    };
    operation.validate(86400000).unwrap();
    let mut s = Session::new(h.clone()).ok().unwrap();
    s.approve(&h).unwrap();
    s.admit(request(1, operation)).unwrap();
    assert!(s.event(1, Stream::File, b"private").is_err());
    let mut crossed = source.clone();
    crossed.content_sha256 = "c".repeat(64);
    assert!(s
        .terminal(
            1,
            Outcome::PreparedArtifact {
                source: crossed,
                size_bytes: 12,
                already_cached: false
            }
        )
        .is_err());
    assert!(s.terminal(1, Outcome::Qualified).is_err());
    let outcome = Outcome::PreparedArtifact {
        source: source.clone(),
        size_bytes: 12,
        already_cached: false,
    };
    assert!(outcome.validate_for(1).is_err());
    s.terminal(1, outcome).unwrap();
    assert_eq!(s.pending_count(), 0);
    let mut value = serde_json::to_value(&source).unwrap();
    value["identity_token"] = serde_json::json!("private");
    assert!(serde_json::from_value::<RegistrySource>(value).is_err());
    let mut legacy = hello();
    let mut session = Session::new(legacy.clone()).ok().unwrap();
    session.approve(&legacy).unwrap();
    assert!(matches!(
        session
            .admit(request(
                1,
                Operation::PrepareArtifact {
                    source,
                    credential_ref: None,
                    identity_token: None
                }
            ))
            .unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    legacy.capabilities.push(Capability::PrepareArtifact);
    assert!(legacy.validate().is_err());
}

#[test]
fn registry_cached_creation_binds_fresh_receipt_and_absence_has_no_ownership_authority() {
    let mut h = growth_hello();
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("remote_sources".into(), 1);
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("compact_creation".into(), 1);
    h.capabilities = h.sdk.as_ref().unwrap().capabilities();
    let mut receipt = growth_fixture().previous;
    receipt.target_id = h.domain.target_id.clone();
    receipt.domain_generation = h.domain.generation.clone();
    let create = RegistryCreate {
        checkpointable: None,
        name: receipt.name.clone(),
        owner_token: receipt.owner_token.clone(),
        incarnation: receipt.incarnation.clone(),
        source: RegistryIdentity {
            kind: "registry".into(),
            id: "approved".into(),
            sha256: "a".repeat(64),
            architecture: "aarch64".into(),
            reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
            content_sha256: "b".repeat(64),
            credential_ref: Some("tenant-read".into()),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        labels: Default::default(),
        volume_mounts: None,
        features: None,
    };
    let operation = Operation::CreateRegistryPrepared {
        create: create.clone(),
        size_bytes: 123,
    };
    operation.validate(1000).unwrap();
    let mut session = Session::new(h.clone()).ok().unwrap();
    session.approve(&h).unwrap();
    session.admit(request(1, operation)).unwrap();
    assert!(session.event(1, Stream::File, b"private").is_err());
    let mut crossed = receipt.clone();
    crossed.incarnation = if receipt.incarnation == "0".repeat(32) {
        "1".repeat(32)
    } else {
        "0".repeat(32)
    };
    assert!(session
        .terminal(1, Outcome::Created { receipt: crossed })
        .is_err());
    assert!(session
        .terminal(
            1,
            Outcome::CreationPresence {
                presence: CreationPresence::Absent
            }
        )
        .is_err());
    session.terminal(1, Outcome::Created { receipt }).unwrap();
    let absence = Operation::InspectRegistryCreation {
        create: create.clone(),
    };
    assert!(absence.validate(30001).is_err());
    session.admit(request(2, absence)).unwrap();
    session
        .terminal(
            2,
            Outcome::CreationPresence {
                presence: CreationPresence::Unverified,
            },
        )
        .unwrap();
    let mut value = serde_json::to_value(&create).unwrap();
    value["source"]["identity_token"] = serde_json::json!("private");
    assert!(serde_json::from_value::<RegistryCreate>(value).is_err());
    let mut value = serde_json::to_value(&create).unwrap();
    value["source"]["sha256"] = serde_json::json!("c".repeat(64));
    assert!(serde_json::from_value::<RegistryCreate>(value)
        .unwrap()
        .validate()
        .is_err());
    assert!(Operation::CreateRegistryPrepared {
        create,
        size_bytes: 0
    }
    .validate(1000)
    .is_err());
}

#[test]
fn registry_creation_compact_features_use_existing_bounded_payload() {
    let mut value: serde_json::Value =
        serde_json::from_str(include_str!("../fixtures/compact-creation-request.json")).unwrap();
    let features = value["operation"]["features_payload"].take();
    let create = serde_json::json!({"name":"fresh","owner_token":"a".repeat(64),"incarnation":"b".repeat(32),"source":{"kind":"registry","id":"pack","sha256":"c".repeat(64),"architecture":"aarch64","reference":format!("registry.example/team/pack@sha256:{}","c".repeat(64)),"content_sha256":"d".repeat(64)},"resources":{"cpus":1,"memory_mib":512,"storage_gib":1,"overlay_gib":1},"labels":{},"features_payload":features});
    value["operation"] = serde_json::json!({"operation":"create_registry_prepared","create":create,"size_bytes":123});
    let request = ClientMessage::decode(value).unwrap();
    let ClientMessage::Request {
        operation: Operation::CreateRegistryPrepared { create, .. },
        ..
    } = request
    else {
        panic!()
    };
    assert!(create.features.unwrap().compact);
}

#[test]
fn registry_qualification_is_bounded_and_does_not_accept_creation_authority() {
    let mut h = growth_hello();
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("remote_sources".into(), 1);
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("compact_creation".into(), 1);
    h.capabilities = h.sdk.as_ref().unwrap().capabilities();
    let operation = Operation::QualifyRegistryCreation {
        checkpointable: None,
        source: RegistryIdentity {
            kind: "registry".into(),
            id: "pack".into(),
            sha256: "a".repeat(64),
            architecture: "aarch64".into(),
            reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
            content_sha256: "b".repeat(64),
            credential_ref: None,
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        user: None,
        features: None,
    };
    assert!(operation.validate(30001).is_err());
    let mut session = Session::new(h.clone()).ok().unwrap();
    session.approve(&h).unwrap();
    session.admit(request(1, operation)).unwrap();
    assert!(session.event(1, Stream::File, b"metadata").is_err());
    assert!(session
        .terminal(
            1,
            Outcome::CreationPresence {
                presence: CreationPresence::Absent
            }
        )
        .is_err());
    session.terminal(1, Outcome::Qualified).unwrap();
}

#[test]
fn registry_token_is_bounded_paired_redacted_and_removed_from_bookkeeping() {
    let source = RegistrySource {
        reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
        platform: "linux/arm64".into(),
        content_sha256: "b".repeat(64),
    };
    let secret: RegistryToken = serde_json::from_value(json!("private-token")).unwrap();
    assert!(!format!("{secret:?}").contains("private-token"));
    let operation = Operation::PrepareArtifact {
        source: source.clone(),
        credential_ref: Some("tenant".into()),
        identity_token: Some(secret),
    };
    operation.validate(1000).unwrap();
    assert!(!serde_json::to_string(&operation.sanitized())
        .unwrap()
        .contains("private-token"));
    for token in ["", "=", "a=b", "with space"] {
        let operation = Operation::PrepareArtifact {
            source: source.clone(),
            credential_ref: Some("tenant".into()),
            identity_token: Some(serde_json::from_value(json!(token)).unwrap()),
        };
        assert!(operation.validate(1000).is_err());
    }
    let missing = Operation::PrepareArtifact {
        source: source.clone(),
        credential_ref: Some("tenant".into()),
        identity_token: None,
    };
    assert!(missing.validate(1000).is_err());
    let mut h = growth_hello();
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("remote_sources".into(), 1);
    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("compact_creation".into(), 1);
    h.capabilities = h.sdk.as_ref().unwrap().capabilities();
    let mut session = Session::new(h.clone()).ok().unwrap();
    session.approve(&h).unwrap();
    session.admit(request(1, operation)).unwrap();
    session
        .terminal(
            1,
            Outcome::PreparedArtifact {
                source,
                size_bytes: 123,
                already_cached: true,
            },
        )
        .unwrap();
}

#[test]
fn shared_volume_authority_fixture_preserves_unsigned_identity_and_correlation() {
    let fixture: Value =
        serde_json::from_str(include_str!("../fixtures/volume-authority.json")).unwrap();
    let domain: DomainIdentity = serde_json::from_value(fixture["domain"].clone()).unwrap();
    let request: VolumeRequest = serde_json::from_value(fixture["request"].clone()).unwrap();
    request.validate(86_400_000).unwrap();
    let outcome: Outcome = serde_json::from_value(fixture["outcome"].clone()).unwrap();
    outcome.validate_for(2).unwrap();
    assert!(outcome.validate_for(1).is_err());
    let Outcome::Volume { volume } = outcome else {
        panic!("expected volume proof")
    };
    volume.matches(&request, &domain).unwrap();
    assert_eq!(volume.backing().unwrap().root_inode, u64::MAX);
    assert_eq!(volume.backing().unwrap().inode, u64::MAX - 1);
    assert_eq!(
        serde_json::to_value(Outcome::Volume { volume }).unwrap(),
        fixture["outcome"]
    );
}

#[test]
fn mounted_creation_fixture_is_exact_domain_bound_and_requires_future_volume_admission() {
    let value: Value =
        serde_json::from_str(include_str!("../fixtures/mounted-creation-request.json")).unwrap();
    let message = ClientMessage::decode(value.clone()).unwrap();
    let ClientMessage::Request { operation, .. } = &message else {
        panic!("request")
    };
    let mounts = operation.creation_mounts().unwrap();
    assert_eq!(mounts[0].proof.backing.inode, u64::MAX - 1);
    let future: ServerMessage =
        serde_json::from_str(include_str!("../fixtures/hello-v2-volumes.json")).unwrap();
    let ServerMessage::Hello { hello: boxed } = future else {
        panic!("hello")
    };
    let h = *boxed;
    VolumeMount::bound(mounts, &h.domain).unwrap();
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    assert!(matches!(
        session.admit(message).unwrap(),
        ServerMessage::Accepted { .. }
    ));
    let mut changed = value.clone();
    changed["operation"]["create"]["volume_mounts"][0]["proof"]["backing"]["domain_generation"] =
        json!("f".repeat(32));
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    assert!(matches!(
        session
            .admit(ClientMessage::decode(changed).unwrap())
            .unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                dispatch: Dispatch::NotDispatched,
                ..
            },
            ..
        }
    ));
    let mut old = h.clone();
    old.sdk.as_mut().unwrap().feature_versions.remove("volumes");
    old.capabilities = old.sdk.as_ref().unwrap().capabilities();
    old.limits = Limits::for_sdk(old.sdk.as_ref().unwrap());
    let mut session = Session::new(old.clone()).unwrap();
    session.approve(&old).unwrap();
    assert!(matches!(
        session
            .admit(ClientMessage::decode(value.clone()).unwrap())
            .unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                dispatch: Dispatch::NotDispatched,
                ..
            },
            ..
        }
    ));
    for field in [json!(null), json!([])] {
        let mut changed = value.clone();
        changed["operation"]["create"]["volume_mounts"] = field;
        assert!(ClientMessage::decode(changed).is_err());
    }
    let mut changed = value.clone();
    changed["operation"]["create"]["volume_mounts"][0]["source"] = json!("/caller/path");
    assert!(ClientMessage::decode(changed).is_err());
    let mut changed = value.clone();
    changed["operation"]["create"]["volume_mounts"][0]["target"] = json!("/etc");
    assert!(ClientMessage::decode(changed).is_err());
    let mut changed = value;
    let duplicate = changed["operation"]["create"]["volume_mounts"][0].clone();
    changed["operation"]["create"]["volume_mounts"]
        .as_array_mut()
        .unwrap()
        .push(duplicate);
    assert!(ClientMessage::decode(changed).is_err());
}

#[test]
fn mounted_observations_are_exact_bounded_and_protocol_two_only() {
    let value: Value =
        serde_json::from_str(include_str!("../fixtures/mounted-observation-v2.json")).unwrap();
    let outcome: Outcome = serde_json::from_value(value.clone()).unwrap();
    assert!(outcome.validate_for(2).is_ok());
    assert!(outcome.validate_for(1).is_err());
    assert_eq!(serde_json::to_value(&outcome).unwrap(), value);
    for invalid in [
        Value::Null,
        json!([]),
        json!(vec![
            value["observation"]["configuration"]["mounts"][0]
                .clone();
            9
        ]),
    ] {
        let mut changed = value.clone();
        changed["observation"]["configuration"]["mounts"] = invalid;
        assert!(
            serde_json::from_value::<Outcome>(changed).map_or(true, |v| v.validate_for(2).is_err())
        );
    }
    for (field, invalid) in [
        ("source", json!("/foreign/../data")),
        ("target", json!("/etc")),
        ("readonly", json!(1)),
        ("staged", json!(true)),
        ("unknown", json!(false)),
    ] {
        let mut changed = value.clone();
        changed["observation"]["configuration"]["mounts"][0][field] = invalid;
        assert!(
            serde_json::from_value::<Outcome>(changed).map_or(true, |v| v.validate_for(2).is_err())
        );
    }
}

#[test]
fn terminal_preflight_negotiates_separately_and_cannot_open_or_stream_a_terminal() {
    let ServerMessage::Hello { hello } = ServerMessage::decode(
        serde_json::from_str(include_str!("../fixtures/hello-v2-terminal-preflight.json")).unwrap(),
    )
    .unwrap() else {
        unreachable!()
    };
    let mut h = *hello;
    let message = ClientMessage::decode(
        serde_json::from_str(include_str!("../fixtures/terminal-preflight-request.json")).unwrap(),
    )
    .unwrap();
    let ClientMessage::Request { operation, .. } = &message else {
        unreachable!()
    };
    operation.validate(30000).unwrap();
    assert!(operation.validate(30001).is_err());
    h.domain = DomainIdentity {
        target_id: operation.receipt().unwrap().target_id.clone(),
        generation: operation.receipt().unwrap().domain_generation.clone(),
    };
    let mut legacy = h.clone();
    legacy
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("terminal_preflight");
    legacy.capabilities = legacy.sdk.as_ref().unwrap().capabilities();
    let mut session = Session::new(legacy.clone()).unwrap();
    session.approve(&legacy).unwrap();
    let mut request = message.clone();
    if let ClientMessage::Request { epoch, .. } = &mut request {
        *epoch = legacy.epoch.clone();
    }
    assert!(matches!(
        session.admit(request.clone()).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
    let mut admitted = Session::new(h.clone()).unwrap();
    admitted.approve(&h).unwrap();
    assert!(matches!(
        admitted.admit(request).unwrap(),
        ServerMessage::Accepted { .. }
    ));
    assert!(admitted.terminal_opened(1).is_err());
    assert!(admitted.event(1, Stream::Terminal, b"forbidden").is_err());
    assert!(admitted
        .terminal(
            1,
            Outcome::Observed {
                observation: Observation {
                    state: ObservedState::Stopped,
                    resources: None,
                    pid_identity: None,
                    configuration: None,
                }
            }
        )
        .is_err());
    admitted.terminal(1, Outcome::Ready).unwrap();
    assert!(admitted.terminal(1, Outcome::Ready).is_err());
    let mut invalid = h;
    invalid
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .remove("terminals");
    assert!(invalid.validate().is_err());
}
