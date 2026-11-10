//! Entirely synthetic wire/correlation models; no engine or SDK dispatch.
use crate::*;
fn rows() -> Vec<serde_json::Value> {
    serde_json::from_str(include_str!("../fixtures/branch-held-release-v1.json")).unwrap()
}
fn hello(request: &BranchHeldReleaseRequest) -> Hello {
    let ServerMessage::Hello { mut hello } = ServerMessage::decode(
        serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
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
    hello.package.platform = request.completion.publication.change.platform.clone();
    hello.package.architecture = if hello.package.platform == "linux" {
        "x86_64"
    } else {
        "aarch64"
    }
    .into();
    hello.domain.target_id = request.source.target_id.clone();
    hello.domain.generation = request.source.domain_generation.clone();
    *hello
}
fn admit(session: &mut Session, h: &Hello, operation: Operation) -> ServerMessage {
    session
        .admit(ClientMessage::Request {
            epoch: h.epoch.clone(),
            id: 1,
            budget_ms: 1000,
            initial_credit: 0,
            initial_event_credit: 0,
            operation,
        })
        .unwrap()
}

#[test]
fn release_environment_requires_negotiated_support() {
    let mut request: BranchHeldReleaseRequest =
        serde_json::from_value(rows()[0]["request"].clone()).unwrap();
    request.request.env = vec![("MODE".into(), "one = 'literal'".into())];
    request.validate().unwrap();
    let operation = Operation::ReleaseHeldBranch {
        request: Box::new(request.clone()),
    };
    let mut h = hello(&request);
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    assert!(matches!(
        admit(&mut session, &h, operation.clone()),
        ServerMessage::Terminal {
            outcome: Outcome::Error {
                code: SafeCode::Unsupported,
                dispatch: Dispatch::NotDispatched
            },
            ..
        }
    ));

    h.sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("branch_release_env".into(), 1);
    let mut session = Session::new(h.clone()).unwrap();
    session.approve(&h).unwrap();
    assert!(matches!(
        admit(&mut session, &h, operation),
        ServerMessage::Accepted { .. }
    ));
}

#[test]
fn shared_explicit_request_and_transition_preserve_both_platforms_and_finite_budgets() {
    for row in rows() {
        let request: BranchHeldReleaseRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: BranchReleaseTransition =
            serde_json::from_value(row["transition"].clone()).unwrap();
        request.validate().unwrap();
        request.matches(&proof).unwrap();
        for qualify in [false, true] {
            let op = if qualify {
                Operation::QualifyHeldBranchRelease {
                    request: Box::new(request.clone()),
                }
            } else {
                Operation::ReleaseHeldBranch {
                    request: Box::new(request.clone()),
                }
            };
            let limit = if qualify { 30000 } else { 900000 };
            op.validate(limit).unwrap();
            assert!(op.validate(limit + 1).is_err());
            assert!(op.requires_branches());
            assert!(op.branch_approval() == Some(request.approval()));
            let outcome = if qualify {
                Outcome::HeldBranchReleasePresence {
                    transition: Some(Box::new(proof.clone())),
                }
            } else {
                Outcome::HeldBranchReleased {
                    transition: Box::new(proof.clone()),
                }
            };
            outcome.validate_for(2).unwrap();
            assert!(outcome.validate_for(1).is_err());
        }
    }
}
#[test]
fn frozen_identity_source_request_and_shape_substitutions_reject() {
    for row in rows() {
        let wanted: BranchHeldReleaseRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: BranchReleaseTransition =
            serde_json::from_value(row["transition"].clone()).unwrap();
        let mut changed = wanted.clone();
        changed.request.operation_id = "other-release".into();
        changed.validate().unwrap();
        assert!(changed.matches(&proof).is_err());
        let mut changed = wanted.clone();
        changed.completion.identity_sha256 = "0".repeat(64);
        changed.validate().unwrap();
        assert!(changed.matches(&proof).is_err());
        let mut changed = wanted.clone();
        changed.source.owner_token = "0".repeat(64);
        assert!(changed.validate().is_err());
        let mut changed = wanted.clone();
        changed.request.operation_id = wanted
            .completion
            .publication
            .change
            .child_origin
            .intent
            .child
            .operation_id
            .clone();
        assert!(changed.validate().is_err());
        let mut changed = row["request"].clone();
        changed["path"] = serde_json::json!("/foreign");
        assert!(serde_json::from_value::<BranchHeldReleaseRequest>(changed).is_err());
        assert!(serde_json::from_value::<Outcome>(
            serde_json::json!({"result":"held_branch_release_presence"})
        )
        .is_err());
        let missing: Outcome = serde_json::from_value(
            serde_json::json!({"result":"held_branch_release_presence", "transition":null}),
        )
        .unwrap();
        missing.validate_for(2).unwrap();
    }
}
#[test]
fn session_distinguishes_release_from_qualification_and_binds_platform_before_work() {
    for row in rows() {
        let request: BranchHeldReleaseRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: BranchReleaseTransition =
            serde_json::from_value(row["transition"].clone()).unwrap();
        for qualify in [false, true] {
            let h = hello(&request);
            let mut session = Session::new(h.clone()).unwrap();
            session.approve(&h).unwrap();
            let op = if qualify {
                Operation::QualifyHeldBranchRelease {
                    request: Box::new(request.clone()),
                }
            } else {
                Operation::ReleaseHeldBranch {
                    request: Box::new(request.clone()),
                }
            };
            assert!(matches!(
                admit(&mut session, &h, op.clone()),
                ServerMessage::Accepted { .. }
            ));
            let wrong = if qualify {
                Outcome::HeldBranchReleased {
                    transition: Box::new(proof.clone()),
                }
            } else {
                Outcome::HeldBranchReleasePresence { transition: None }
            };
            assert!(session.terminal(1, wrong).is_err());
            let good = if qualify {
                Outcome::HeldBranchReleasePresence {
                    transition: Some(Box::new(proof.clone())),
                }
            } else {
                Outcome::HeldBranchReleased {
                    transition: Box::new(proof.clone()),
                }
            };
            session.terminal(1, good).unwrap();
            let mut other = h.clone();
            other.package.platform = if h.package.platform == "macos" {
                "linux"
            } else {
                "macos"
            }
            .into();
            other.package.architecture = if other.package.platform == "macos" {
                "aarch64"
            } else {
                "x86_64"
            }
            .into();
            let mut session = Session::new(other.clone()).unwrap();
            session.approve(&other).unwrap();
            assert!(matches!(
                admit(&mut session, &other, op),
                ServerMessage::Terminal {
                    outcome: Outcome::Error {
                        code: SafeCode::Ownership,
                        dispatch: Dispatch::NotDispatched
                    },
                    ..
                }
            ));
        }
    }
}
