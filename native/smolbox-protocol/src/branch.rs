//! Semantic branch source preflight contracts; no native VM or SDK entry.
use crate::*;

fn fixture() -> (Operation, Outcome) {
    let value: serde_json::Value =
        serde_json::from_str(include_str!("../fixtures/branch-preflight-v1.json")).unwrap();
    (
        serde_json::from_value(value["operation"].clone()).unwrap(),
        serde_json::from_value(value["outcome"].clone()).unwrap(),
    )
}
fn hello() -> Hello {
    let ServerMessage::Hello { hello } = ServerMessage::decode(
        serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
    )
    .unwrap() else {
        unreachable!()
    };
    *hello
}
fn request(hello: &Hello, operation: Operation) -> ClientMessage {
    ClientMessage::Request {
        epoch: hello.epoch.clone(),
        id: 1,
        budget_ms: 30000,
        initial_credit: 1024,
        initial_event_credit: 1,
        operation,
    }
}
#[test]
fn branch_preflight_requires_bounded_material_receipt_and_exact_request_shape() {
    let (operation, _) = fixture();
    operation.validate(30000).unwrap();
    assert!(operation.validate(30001).is_err());
    assert!(operation.requires_branches() && !operation.requires_checkpoints());
    assert!(operation.capability() == Capability::Inspect);
    let mut invalid = operation.clone();
    if let Operation::BranchPreflight { receipt } = &mut invalid {
        receipt.material = None;
    }
    assert!(invalid.validate(1).is_err());
    for field in ["path", "pid", "idle", "policy", "create", "quiesced"] {
        let mut value = serde_json::to_value(&operation).unwrap();
        value[field] = serde_json::json!(true);
        assert!(serde_json::from_value::<Operation>(value).is_err());
    }
}
#[test]
fn branch_preflight_needs_negotiated_feature_and_matching_domain() {
    let (operation, _) = fixture();
    let mut hello = hello();
    for enabled in [false, true] {
        if enabled {
            hello
                .sdk
                .as_mut()
                .unwrap()
                .feature_versions
                .insert("branches".into(), 1);
        }
        let mut session = Session::new(hello.clone()).unwrap();
        session.approve(&hello).unwrap();
        let response = session.admit(request(&hello, operation.clone())).unwrap();
        if enabled {
            assert!(matches!(response, ServerMessage::Accepted { .. }));
        } else {
            assert!(matches!(
                response,
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
    let mut crossed = operation;
    if let Operation::BranchPreflight { receipt } = &mut crossed {
        receipt.domain_generation = "a".repeat(32);
    }
    let mut session = Session::new(hello.clone()).unwrap();
    session.approve(&hello).unwrap();
    assert!(matches!(
        session.admit(request(&hello, crossed)).unwrap(),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Ownership,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));
}
#[test]
fn source_reply_is_running_offline_unmounted_and_never_stream_or_creation_authority() {
    let (operation, outcome) = fixture();
    let mut hello = hello();
    hello
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("branches".into(), 1);
    let mut session = Session::new(hello.clone()).unwrap();
    session.approve(&hello).unwrap();
    session.admit(request(&hello, operation)).unwrap();
    for stream in [
        Stream::Stdout,
        Stream::Stderr,
        Stream::File,
        Stream::Checkpoint,
    ] {
        assert!(session.event(1, stream, b"unexpected").is_err());
    }
    for change in 0..6 {
        let mut wrong = outcome.clone();
        if let Outcome::Observed { observation } = &mut wrong {
            match change {
                0 => {
                    observation.state = ObservedState::Stopped;
                    observation.pid_identity = None;
                }
                1 => observation.resources = None,
                2 => observation.configuration = None,
                3 => {
                    let config = observation.configuration.as_mut().unwrap();
                    config.backend = Some("virtio-net".into());
                    config.ports.push(PortMapping {
                        host: 43000,
                        guest: 8080,
                    });
                }
                4 => {
                    let config = observation.configuration.as_mut().unwrap();
                    config.backend = Some("virtio-net".into());
                    config.network.enabled = true;
                    config.network.hosts = vec!["example.invalid".into()];
                }
                _ => {
                    observation.configuration.as_mut().unwrap().mounts = Some(vec![ObservedMount {
                        source: "/private/volume".into(),
                        target: "/mnt/volumes/owned".into(),
                        readonly: false,
                        staged: false,
                    }])
                }
            }
        }
        assert!(session.terminal(1, wrong).is_err());
    }
    assert!(session.terminal(1, Outcome::Qualified).is_err());
    assert!(session.terminal(1, outcome).is_ok());
}

#[test]
fn source_reply_accepts_a_network_allowlist_when_static_egress_is_negotiated() {
    let (operation, mut outcome) = fixture();
    let mut hello = hello();
    let features = &mut hello.sdk.as_mut().unwrap().feature_versions;
    for feature in [
        "branches",
        "checkpoints",
        "networking",
        "branch_static_egress",
    ] {
        features.insert(feature.into(), 1);
    }
    if let Outcome::Observed { observation } = &mut outcome {
        let config = observation.configuration.as_mut().unwrap();
        config.backend = Some("virtio-net".into());
        config.network.enabled = true;
        config.network.hosts = vec!["example.invalid".into()];
    }
    let mut session = Session::new(hello.clone()).unwrap();
    session.approve(&hello).unwrap();
    session.admit(request(&hello, operation)).unwrap();
    assert!(session.terminal(1, outcome).is_ok());
}
