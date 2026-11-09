//! Synthetic correlation only; no SDK owner, live process or VM is created.
use super::*;
use crate::*;
fn rows() -> Vec<serde_json::Value> {
    serde_json::from_str(include_str!(
        "../../fixtures/partial-branch-backing-release-v1.json"
    ))
    .unwrap()
}
fn hello(request: &PartialBranchBackingReleaseRequest) -> Hello {
    let ServerMessage::Hello { mut hello } = ServerMessage::decode(
        serde_json::from_str(include_str!("../../fixtures/hello-v2.json")).unwrap(),
    )
    .unwrap() else {
        panic!("hello")
    };
    hello
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("branches".into(), 1);
    hello.domain.target_id = request.child.target_id.clone();
    hello.domain.generation = request.child.domain_generation.clone();
    hello.epoch = request
        .disposal
        .publication
        .change
        .child_origin
        .intent
        .epoch
        .clone();
    hello.package.platform = request.disposal.publication.change.platform.clone();
    hello.package.architecture = if hello.package.platform == "macos" {
        "aarch64"
    } else {
        "x86_64"
    }
    .into();
    *hello
}
fn operation(request: &PartialBranchBackingReleaseRequest) -> Operation {
    Operation::ReleasePartialBranchBacking {
        request: Box::new(request.clone()),
    }
}
fn admit(
    session: &mut Session,
    h: &Hello,
    request: &PartialBranchBackingReleaseRequest,
) -> ServerMessage {
    session
        .admit(ClientMessage::Request {
            epoch: h.epoch.clone(),
            id: 1,
            budget_ms: 30000,
            initial_credit: 1024,
            initial_event_credit: 1,
            operation: operation(request),
        })
        .unwrap()
}
#[test]
fn synthetic_partial_backing_readers_bind_full_disposal_heads_request_and_native_charge() {
    for row in rows() {
        let request: PartialBranchBackingReleaseRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: BranchBackingRelease = serde_json::from_value(row["proof"].clone()).unwrap();
        request.matches(&proof).unwrap();
        let op = operation(&request);
        op.validate(30000).unwrap();
        assert!(op.validate(30001).is_err());
        assert!(op.requires_branches() && op.capability() == Capability::Inspect);
        assert!(op.branch_approval() == Some(request.approval()));
        assert!(op.receipt() == Some(&request.child));
        assert!(
            op.branch_epoch()
                == Some(
                    request
                        .disposal
                        .publication
                        .change
                        .child_origin
                        .intent
                        .epoch
                        .as_str()
                )
        );
        assert!(op.branch_platform() == Some(row["platform"].as_str().unwrap()));
        assert!(serde_json::to_value(&request).unwrap() == row["request"]);
        let out = Outcome::BranchBackingReleased {
            proof: Box::new(proof),
        };
        out.validate_for(2).unwrap();
        assert!(out.validate_for(1).is_err());
    }
}
#[test]
fn strict_partial_backing_request_requires_fresh_action_confirmation_and_exact_child_head() {
    for row in rows() {
        let request: PartialBranchBackingReleaseRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        for field in ["path", "pid", "native_bytes", "completion", "retirement"] {
            let mut wrong = row["request"].clone();
            wrong[field] = serde_json::json!(1);
            assert!(serde_json::from_value::<PartialBranchBackingReleaseRequest>(wrong).is_err());
        }
        let creation = &request.disposal.request.collection_request.creation;
        let mut ids = vec![
            creation.child.operation_id.clone(),
            request.disposal.request.operation_id.clone(),
            request
                .disposal
                .request
                .collection_request
                .operation_id
                .clone(),
        ];
        if let Some(release) = &request.disposal.release {
            ids.push(release.change.request.operation_id.clone());
        }
        if let Some(release) = &creation.initial_release {
            ids.push(release.operation_id.clone());
        }
        for id in ids {
            let mut wrong = request.clone();
            wrong.operation_id = id;
            wrong.request_sha256 = hash(&(
                "smolbox-partial-branch-backing-request-v1",
                &wrong.disposal,
                &wrong.source,
                &wrong.child,
                &wrong.operation_id,
                wrong.quiesced,
                wrong.backing_removed,
            ))
            .unwrap();
            assert!(wrong.validate().is_err());
        }
        let mut wrong = request.clone();
        wrong.quiesced = false;
        assert!(wrong.validate().is_err());
        let mut wrong = request;
        wrong.child.material = None;
        assert!(wrong.validate().is_err());
    }
}
#[test]
fn original_epoch_platform_domain_branch_feature_and_inspection_are_required_before_entry() {
    for row in rows() {
        let request: PartialBranchBackingReleaseRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        for case in 0..5 {
            let mut h = hello(&request);
            match case {
                0 => h.epoch = "0".repeat(32),
                1 => h.domain.generation = "0".repeat(32),
                2 => {
                    h.sdk.as_mut().unwrap().feature_versions.remove("branches");
                }
                3 => h.capabilities.retain(|c| *c != Capability::Inspect),
                _ => {
                    h.package.platform = if h.package.platform == "macos" {
                        "linux"
                    } else {
                        "macos"
                    }
                    .into();
                    h.package.architecture = if h.package.platform == "macos" {
                        "aarch64"
                    } else {
                        "x86_64"
                    }
                    .into();
                }
            }
            let mut session = Session::new(h.clone()).unwrap();
            session.approve(&h).unwrap();
            assert!(matches!(
                admit(&mut session, &h, &request),
                ServerMessage::Terminal {
                    outcome: Outcome::Error {
                        dispatch: Dispatch::NotDispatched,
                        ..
                    },
                    ..
                }
            ));
        }
    }
}
#[test]
fn only_the_exact_zero_output_backing_proof_can_acknowledge_the_original_action() {
    for row in rows() {
        let request: PartialBranchBackingReleaseRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: BranchBackingRelease = serde_json::from_value(row["proof"].clone()).unwrap();
        let h = hello(&request);
        let mut session = Session::new(h.clone()).unwrap();
        session.approve(&h).unwrap();
        assert!(matches!(
            admit(&mut session, &h, &request),
            ServerMessage::Accepted { .. }
        ));
        for stream in [
            Stream::Stdout,
            Stream::Stderr,
            Stream::File,
            Stream::Checkpoint,
            Stream::Log,
            Stream::Terminal,
        ] {
            assert!(session.event(1, stream, b"extra").is_err());
        }
        assert!(session.terminal(1, Outcome::Qualified).is_err());
        let mut wrong = proof.clone();
        wrong.request_sha256 = "f".repeat(64);
        assert!(session
            .terminal(
                1,
                Outcome::BranchBackingReleased {
                    proof: Box::new(wrong)
                }
            )
            .is_err());
        session
            .terminal(
                1,
                Outcome::BranchBackingReleased {
                    proof: Box::new(proof),
                },
            )
            .unwrap();
    }
}
