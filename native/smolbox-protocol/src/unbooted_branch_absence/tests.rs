//! Synthetic correlation only; no SDK owner or VM is created.
use super::*;
use crate::*;
fn rows() -> Vec<serde_json::Value> {
    serde_json::from_str(include_str!(
        "../../fixtures/unbooted-branch-child-absence-v1.json"
    ))
    .unwrap()
}
fn hello(proof: &UnbootedBranchChildAbsence) -> Hello {
    let ServerMessage::Hello { mut hello } = ServerMessage::decode(
        serde_json::from_str(include_str!("../../fixtures/hello-v2.json")).unwrap(),
    )
    .unwrap() else {
        panic!("hello")
    };
    let disposal = &proof.request.disposal;
    hello
        .sdk
        .as_mut()
        .unwrap()
        .feature_versions
        .insert("branches".into(), 1);
    hello.domain.target_id = disposal.creation.source.target_id.clone();
    hello.domain.generation = disposal.creation.source.domain_generation.clone();
    hello.epoch = disposal
        .publication
        .change
        .child_origin
        .intent
        .epoch
        .clone();
    hello.package.platform = disposal.publication.change.platform.clone();
    hello.package.architecture = if hello.package.platform == "macos" {
        "aarch64"
    } else {
        "x86_64"
    }
    .into();
    *hello
}
fn admit(
    session: &mut Session,
    h: &Hello,
    request: &UnbootedBranchChildAbsenceRequest,
) -> ServerMessage {
    session
        .admit(ClientMessage::Request {
            epoch: h.epoch.clone(),
            id: 1,
            budget_ms: 30000,
            initial_credit: 1024,
            initial_event_credit: 1,
            operation: Operation::QualifyUnbootedBranchChildAbsence {
                request: Box::new(request.clone()),
            },
        })
        .unwrap()
}
#[test]
fn exact_synthetic_disposal_provenance_request_hash_and_strict_readers_agree() {
    for row in rows() {
        let proof: UnbootedBranchChildAbsence =
            serde_json::from_value(row["proof"].clone()).unwrap();
        proof.request.matches(&proof).unwrap();
        let operation = Operation::QualifyUnbootedBranchChildAbsence {
            request: Box::new(proof.request.clone()),
        };
        operation.validate(30000).unwrap();
        assert!(operation.validate(30001).is_err());
        assert!(operation.requires_branches() && operation.capability() == Capability::Inspect);
        assert!(operation.branch_approval() == Some(proof.request.approval()));
        assert!(operation.receipt() == Some(&proof.request.disposal.creation.source));
        let outcome = Outcome::UnbootedBranchChildAbsent {
            proof: Box::new(proof.clone()),
        };
        outcome.validate_for(2).unwrap();
        assert!(outcome.validate_for(1).is_err());
        for key in ["path", "pid", "completion", "backing_removed"] {
            let mut wrong = row["proof"].clone();
            wrong[key] = serde_json::json!(true);
            assert!(serde_json::from_value::<UnbootedBranchChildAbsence>(wrong).is_err());
        }
        for outcome in [
            serde_json::json!({"result":"unbooted_branch_child_absent"}),
            serde_json::json!({"result":"unbooted_branch_child_absent","proof":null}),
        ] {
            assert!(serde_json::from_value::<Outcome>(outcome).is_err());
        }
        let mut changed = proof.request.clone();
        changed.operation_id = "other-retirement".into();
        changed.request_sha256 = changed.digest().unwrap();
        changed.validate().unwrap();
        assert!(changed.matches(&proof).is_err());
        changed.quiesced = false;
        changed.request_sha256 = changed.digest().unwrap();
        assert!(changed.validate().is_err());
    }
}
#[test]
fn original_epoch_platform_domain_feature_and_inspection_are_required_before_admission() {
    for row in rows() {
        let proof: UnbootedBranchChildAbsence =
            serde_json::from_value(row["proof"].clone()).unwrap();
        for case in 0..5 {
            let mut h = hello(&proof);
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
                admit(&mut session, &h, &proof.request),
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
fn only_exact_zero_output_absence_can_complete_the_original_request() {
    for row in rows() {
        let proof: UnbootedBranchChildAbsence =
            serde_json::from_value(row["proof"].clone()).unwrap();
        let h = hello(&proof);
        let mut session = Session::new(h.clone()).unwrap();
        session.approve(&h).unwrap();
        assert!(matches!(
            admit(&mut session, &h, &proof.request),
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
        assert!(session
            .terminal(
                1,
                Outcome::UnbootedBranchDisposed {
                    proof: Box::new(proof.request.disposal.clone())
                }
            )
            .is_err());
        session
            .terminal(
                1,
                Outcome::UnbootedBranchChildAbsent {
                    proof: Box::new(proof),
                },
            )
            .unwrap();
    }
}
