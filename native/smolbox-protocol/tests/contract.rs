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
    }
}
fn receipt() -> Receipt {
    Receipt {
        target_id: "embedded-local".into(),
        domain_generation: "cd".repeat(16),
        name: "owned".into(),
        owner_token: "67".repeat(32),
        incarnation: "89".repeat(16),
        material_sha256: "ab".repeat(32),
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

#[test]
fn qualification_has_no_receipt_or_stream_and_cannot_satisfy_a_command() {
    let operation = Operation::QualifyCreation {
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
