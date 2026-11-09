//! Inert peer correlation only; no SDK work or live failure campaigns.
use super::*;
use crate::*;
fn rows() -> Vec<serde_json::Value> {
    serde_json::from_str(include_str!(
        "../../fixtures/unbooted-branch-disposal-candidate-v1.json"
    ))
    .unwrap()
}
fn operation(candidate: &UnbootedBranchDisposalCandidate) -> Operation {
    Operation::InspectUnbootedBranchDisposal {
        request: Box::new(candidate.creation.clone()),
        quiesced: true,
    }
}
fn hello(candidate: &UnbootedBranchDisposalCandidate) -> Hello {
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
    hello.domain.target_id = candidate.creation.source.target_id.clone();
    hello.domain.generation = candidate.creation.source.domain_generation.clone();
    hello.epoch = candidate
        .publication
        .change
        .child_origin
        .intent
        .epoch
        .clone();
    hello.package.platform = candidate.publication.change.platform.clone();
    hello.package.architecture = if hello.package.platform == "macos" {
        "aarch64"
    } else {
        "x86_64"
    }
    .into();
    *hello
}
fn admit(session: &mut Session, h: &Hello, op: Operation) -> ServerMessage {
    session
        .admit(ClientMessage::Request {
            epoch: h.epoch.clone(),
            id: 1,
            budget_ms: 30000,
            initial_credit: 1024,
            initial_event_credit: 1,
            operation: op,
        })
        .unwrap()
}
#[test]
fn candidate_readers_bound_full_creation_exact_keys_mode_and_budget() {
    for row in rows() {
        let candidate: UnbootedBranchDisposalCandidate =
            serde_json::from_value(row["candidate"].clone()).unwrap();
        candidate.matches(&candidate.creation).unwrap();
        let mut op = operation(&candidate);
        op.validate(30000).unwrap();
        assert!(op.validate(30001).is_err());
        assert!(op.requires_branches() && op.capability() == Capability::Inspect);
        assert!(op.branch_approval() == Some(&candidate.creation.approval));
        assert!(op.receipt() == Some(&candidate.creation.source));
        let Operation::InspectUnbootedBranchDisposal { quiesced, .. } = &mut op else {
            unreachable!()
        };
        *quiesced = false;
        assert!(op.validate(30000).is_err());
        let result = Outcome::UnbootedBranchDisposalCandidate {
            candidate: Box::new(candidate.clone()),
        };
        result.validate_for(2).unwrap();
        assert!(result.validate_for(1).is_err());
        for key in ["dispatched", "pid", "path", "child_absent"] {
            let mut wrong = row["candidate"].clone();
            wrong[key] = serde_json::json!(true);
            assert!(serde_json::from_value::<UnbootedBranchDisposalCandidate>(wrong).is_err());
        }
        for invalid in [
            serde_json::json!({"result":"unbooted_branch_disposal_candidate"}),
            serde_json::json!({"result":"unbooted_branch_disposal_candidate","candidate":null}),
        ] {
            assert!(serde_json::from_value::<Outcome>(invalid).is_err());
        }
    }
}
#[test]
fn candidate_sessions_require_original_epoch_platform_full_creation_and_zero_output() {
    for row in rows() {
        let candidate: UnbootedBranchDisposalCandidate =
            serde_json::from_value(row["candidate"].clone()).unwrap();
        for case in 0..4 {
            let mut h = hello(&candidate);
            if case == 1 {
                h.epoch = "0".repeat(32);
            }
            if case == 2 {
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
            let mut op = operation(&candidate);
            if case == 3 {
                let Operation::InspectUnbootedBranchDisposal { request, .. } = &mut op else {
                    unreachable!()
                };
                request.child.name = "another-child".into();
            }
            let mut session = Session::new(h.clone()).unwrap();
            session.approve(&h).unwrap();
            assert!(matches!(
                admit(&mut session, &h, op),
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
            let result = session.terminal(
                1,
                Outcome::UnbootedBranchDisposalCandidate {
                    candidate: Box::new(candidate.clone()),
                },
            );
            assert_eq!(result.is_ok(), case == 0);
        }
    }
}
#[test]
fn candidate_sessions_refuse_unapproved_features_domains_and_inspection() {
    for row in rows() {
        let candidate: UnbootedBranchDisposalCandidate =
            serde_json::from_value(row["candidate"].clone()).unwrap();
        for case in 0..3 {
            let mut h = hello(&candidate);
            match case {
                0 => {
                    h.sdk.as_mut().unwrap().feature_versions.remove("branches");
                }
                1 => h.domain.generation = "0".repeat(32),
                _ => h.capabilities.retain(|c| *c != Capability::Inspect),
            }
            let mut session = Session::new(h.clone()).unwrap();
            session.approve(&h).unwrap();
            assert!(matches!(
                admit(&mut session, &h, operation(&candidate)),
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
