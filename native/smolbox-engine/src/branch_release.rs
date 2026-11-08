//! One release of an originally initialized bare child. The SDK held flag and
//! process inventory never establish completion; only the exact exchange does.
use crate::branch_material::ChildOrigin;
use crate::{CreationReceipt, Error, ErrorCode, MaterialProof, ReadBudget, Result};
use serde::{Deserialize, Serialize};
use smolvm::config::VmRecord;
use std::path::Path;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchReleaseRequest {
    pub operation_id: String,
    pub request_sha256: String,
}
impl BranchReleaseRequest {
    pub fn validate(&self) -> Result<()> {
        if !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
impl std::fmt::Debug for BranchReleaseRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchReleaseRequest")
            .finish_non_exhaustive()
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Mode {
    Initial,
    Explicit,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchReleaseChange {
    pub request: BranchReleaseRequest,
    pub(crate) binding: ChildOrigin,
    pub(crate) identity_sha256: String,
    pub(crate) boot_sha256: String,
    pub(crate) mode: Mode,
    pub(crate) activation_token: String,
    pub(crate) invariant_sha256: String,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchReleaseTransition {
    pub schema: u8,
    pub previous: CreationReceipt,
    pub receipt: CreationReceipt,
    pub change: BranchReleaseChange,
}
impl std::fmt::Debug for BranchReleaseTransition {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchReleaseTransition")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl BranchReleaseTransition {
    pub fn validate(&self) -> Result<()> {
        self.change.request.validate()?;
        self.change.binding.verify_origin(&self.previous)?;
        let mut origin = self.previous.clone();
        origin.material = None;
        crate::material::check_origin(&origin, &self.receipt)?;
        let before = self
            .previous
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let after = self
            .receipt
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        before.validate()?;
        if self.schema != 1
            || *before != crate::material::root_proof(&origin)?
            || self.change.request.operation_id == self.change.binding.intent.child.operation_id
            || (self.change.mode == Mode::Explicit) != self.change.binding.intent.child.hold
            || [
                &self.change.identity_sha256,
                &self.change.boot_sha256,
                &self.change.activation_token,
                &self.change.invariant_sha256,
            ]
            .iter()
            .any(|hash| !crate::domain::valid_hex(hash, 64))
            || *after != self.next_proof(after.record_sha256.clone())?
            || before.record_sha256 == after.record_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn next_proof(&self, record_sha256: String) -> Result<MaterialProof> {
        let proof = MaterialProof {
            schema: 2,
            revision: 1,
            chain_sha256: crate::material::hash(&(
                "smolbox-branch-child-release-v1",
                &self.previous,
                &self.change,
                &record_sha256,
            ))?,
            record_sha256,
            operation_id: Some(self.change.request.operation_id.clone()),
            request_sha256: Some(self.change.request.request_sha256.clone()),
        };
        proof.validate()?;
        Ok(proof)
    }
    pub(crate) fn verify_record(&self, record: &VmRecord) -> Result<()> {
        self.validate()?;
        self.change.binding.verify_record(record)?;
        if record.forkpoint_held
            || !record.fork_env.is_empty()
            || !self.receipt.matches(record)?
            || invariant(record)? != self.change.invariant_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
pub(crate) fn invariant(record: &VmRecord) -> Result<String> {
    let mut value = crate::identity::material_value(record)?;
    value
        .as_object_mut()
        .ok_or(Error::before(ErrorCode::Ownership))?
        .remove("forkpoint_held");
    crate::material::hash(&value)
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Intent {
    pub transition: BranchReleaseTransition,
    pub boot: crate::epoch::BootIntent,
    pub child: crate::OwnerIdentity,
    pub before_sha256: String,
}
impl Intent {
    pub(crate) fn issue(
        publication: &crate::BranchPublication,
        record: &VmRecord,
        enrollment: &crate::epoch::BootEnrollment,
        identity_sha256: &str,
        request: &BranchReleaseRequest,
    ) -> Result<Self> {
        publication.validate()?;
        request.validate()?;
        publication.change.child_origin.verify_record(record)?;
        if !publication.child().matches(record)?
            || !record.forkpoint_held
            || !record.fork_env.is_empty()
            || record.state != smolvm::config::RecordState::Running
            || record.pid != Some(enrollment.child().pid)
            || record.pid_start_time != Some(enrollment.child().birth)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut token = [0; 32];
        getrandom::fill(&mut token).map_err(|_| Error::before(ErrorCode::Native))?;
        let mut released = record.clone();
        released.forkpoint_held = false;
        let mut transition = BranchReleaseTransition {
            schema: 1,
            previous: publication.child().clone(),
            receipt: publication.child().clone(),
            change: BranchReleaseChange {
                request: request.clone(),
                binding: publication.change.child_origin.clone(),
                identity_sha256: identity_sha256.into(),
                boot_sha256: crate::material::hash(enrollment.intent())?,
                mode: if publication.change.child_origin.intent.child.hold {
                    Mode::Explicit
                } else {
                    Mode::Initial
                },
                activation_token: hex::encode(token),
                invariant_sha256: invariant(record)?,
            },
        };
        transition.receipt.material =
            Some(transition.next_proof(crate::identity::material_hash(&released)?)?);
        let intent = Self {
            transition,
            boot: enrollment.intent().clone(),
            child: enrollment.child(),
            before_sha256: crate::material::hash(record)?,
        };
        intent.validate()?;
        Ok(intent)
    }
    pub(crate) fn validate(&self) -> Result<()> {
        self.transition.validate()?;
        let binding = &self.transition.change.binding;
        if !self
            .boot
            .matches(&binding.intent.child.name, &binding.intent.epoch)
            || self.transition.change.boot_sha256 != crate::material::hash(&self.boot)?
            || self.child.pid <= 0
            || self.child.birth == 0
            || self.child.uid != unsafe { libc::geteuid() }
            || !crate::domain::valid_hex(&self.before_sha256, 64)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn matches(&self, enrollment: &crate::epoch::BootEnrollment) -> bool {
        self.validate().is_ok()
            && self.boot == *enrollment.intent()
            && self.child == enrollment.child()
    }
    pub(crate) fn digest(&self) -> Result<String> {
        self.validate()?;
        crate::material::hash(self)
    }
    pub(crate) fn released_record(&self, before: &VmRecord) -> Result<VmRecord> {
        self.validate()?;
        if self.before_sha256 != crate::material::hash(before)? || !before.forkpoint_held {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut after = before.clone();
        after.forkpoint_held = false;
        self.transition.verify_record(&after)?;
        Ok(after)
    }
    fn request(&self) -> smolvm_protocol::AgentRequest {
        match self.transition.change.mode {
            Mode::Initial => smolvm_protocol::AgentRequest::BranchpointRelease {
                env_dotenv: Some(String::new()),
            },
            Mode::Explicit => smolvm_protocol::AgentRequest::BranchpointActivate {
                env_dotenv: String::new(),
                env_sourceable: String::new(),
                env_path: smolvm_protocol::forkpoint::FORK_ENV_PATH.into(),
                branch_env_path: smolvm_protocol::forkpoint::BRANCH_ENV_PATH.into(),
                require_dir: None,
                env_dir: "/etc/smolvm".into(),
                activation_token: self.transition.change.activation_token.clone(),
            },
        }
    }
    fn confirm(&self, response: smolvm_protocol::AgentResponse) -> Result<Verified> {
        self.validate()?;
        let expected = match self.transition.change.mode {
            Mode::Initial => None,
            Mode::Explicit => Some(serde_json::json!({"already_done": false})),
        };
        match response {
            smolvm_protocol::AgentResponse::Ok { data } if data == expected => Ok(Verified {
                intent_sha256: self.digest()?,
            }),
            _ => Err(Error::uncertain(ErrorCode::Native)),
        }
    }
    pub(crate) fn execute(
        &self,
        socket: &Path,
        staging: &Path,
        budget: &ReadBudget,
    ) -> Result<Verified> {
        self.validate()?;
        crate::branch_agent::exchange(socket, staging, 4096, budget, |client, remaining| {
            let _timeout = client
                .set_extended_read_timeout(remaining)
                .map_err(|_| Error::uncertain(ErrorCode::Native))?;
            if !client
                .supports_typed_branchpoint()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
            {
                return Err(Error::uncertain(ErrorCode::Unsupported));
            }
            budget.check().map_err(|e| Error::uncertain(e.code))?;
            client
                .send_raw(&self.request())
                .map_err(|_| Error::uncertain(ErrorCode::Native))?;
            self.confirm(
                client
                    .recv_raw()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?,
            )
        })
    }
}
/// Original bounded agent result, never reconstructed from a journal or caller.
pub(crate) struct Verified {
    intent_sha256: String,
}
impl Verified {
    pub(crate) fn matches(&self, intent: &Intent) -> bool {
        intent.digest().ok().as_ref() == Some(&self.intent_sha256)
    }
}

/// Shared one-shot SDK/database/journal sequence. Callers retain their original
/// context, machine/source gates and work admission through actual return.
pub(crate) struct Application {
    pub plan: crate::branch_boot::Plan,
    pub intent: Intent,
    pub before: VmRecord,
    pub source: VmRecord,
    pub enrollment: std::sync::Arc<crate::epoch::BootEnrollment>,
    pub database: std::path::PathBuf,
    pub database_identity: (u64, u64),
    pub db: smolvm::db::SmolvmDb,
    pub staging: std::path::PathBuf,
    pub budget: ReadBudget,
}
impl Application {
    pub(crate) fn run(
        &self,
        verify_live: impl Fn() -> Result<()>,
    ) -> Result<BranchReleaseTransition> {
        let expected = [
            (
                self.source.name.clone(),
                crate::material::hash(&self.source)?,
            ),
            (self.before.name.clone(), self.intent.before_sha256.clone()),
        ];
        let source_pid = self.plan.publication.change.child_origin.intent.source_pid;
        let unchanged = || -> Result<()> {
            unchanged_records(
                &self.database,
                self.database_identity,
                &expected,
                &self.budget,
            )?;
            if !smolvm::process::is_alive(source_pid.0)
                || smolvm::process::process_start_time(source_pid.0) != Some(source_pid.1)
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            Ok(())
        };
        self.intent.validate()?;
        let after = self.intent.released_record(&self.before)?;
        self.plan.verify()?;
        unchanged()?;
        verify_live()?;
        let lifecycle = crate::branch_boot::Lifecycle::at(&self.plan.child.path);
        let journal = crate::material::MaterialJournal::at(&self.plan.child.path);
        lifecycle.authorize_release(&self.plan, &self.intent, &self.enrollment)?;
        journal.authorize_branch_release(&self.intent)?;
        crate::machine::verify_branch_marker(
            &self.intent.transition.previous,
            &self.plan.child.path,
        )?;
        let proof = self.intent.execute(
            &self.plan.child.path.join("agent.sock"),
            &self.staging,
            &self.budget,
        )?;
        unchanged()?;
        verify_live()?;
        let mut changed = false;
        self.db
            .update_vm(&self.before.name, |actual| {
                if crate::material::hash(actual).ok().as_ref() == Some(&self.intent.before_sha256) {
                    actual.forkpoint_held = false;
                    changed = true;
                }
            })
            .map_err(|_| Error::uncertain(ErrorCode::Database))?;
        if !changed {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let actual = crate::sdk_compat::observe_record(
            &self.database,
            self.database_identity,
            &self.before.name,
            &self.budget,
        )?
        .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if crate::material::hash(&actual)? != crate::material::hash(&after)? {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        verify_live()?;
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        let release = journal.complete_branch_release(&self.intent, &proof, &actual)?;
        lifecycle.released(&self.plan, &self.intent, &self.enrollment)?;
        Ok(release)
    }
}
pub(crate) fn unchanged_records(
    database: &Path,
    identity: (u64, u64),
    expected: &[(String, String); 2],
    budget: &ReadBudget,
) -> Result<()> {
    for (name, hash) in expected {
        let record = crate::sdk_compat::observe_record(database, identity, name, budget)?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if crate::material::hash(&record)? != *hash {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::branch_boot::{tests::identity_model, Lifecycle};
    use crate::branch_identity::tests::{accept, read_request};
    use crate::material::MaterialJournal;
    use std::io::{Read, Write};
    use std::os::unix::net::UnixListener;
    use std::time::Duration;

    fn request() -> BranchReleaseRequest {
        BranchReleaseRequest {
            operation_id: "release-original-child".into(),
            request_sha256: "e".repeat(64),
        }
    }
    fn intent(model: &crate::branch_boot::tests::IdentityModel) -> Intent {
        Intent::issue(
            &model.plan.publication,
            &model.record,
            &model.enrollment,
            &model.identity_sha256,
            &request(),
        )
        .unwrap()
    }
    pub(crate) fn confirmed(intent: &Intent) -> Verified {
        intent
            .confirm(smolvm_protocol::AgentResponse::Ok {
                data: match intent.transition.change.mode {
                    Mode::Initial => None,
                    Mode::Explicit => Some(serde_json::json!({"already_done": false})),
                },
            })
            .unwrap()
    }
    fn enter(model: &crate::branch_boot::tests::IdentityModel, intent: &Intent) {
        Lifecycle::at(&model.plan.child.path)
            .enter_release(&model.plan, intent, &model.enrollment)
            .unwrap();
        MaterialJournal::at(&model.plan.child.path)
            .begin_branch_release(intent, &model.record)
            .unwrap();
    }
    fn complete_material(
        model: &crate::branch_boot::tests::IdentityModel,
        intent: &Intent,
    ) -> BranchReleaseTransition {
        // Synthetic SDK/agent result boundary; no process or guest is changed.
        let after = intent.released_record(&model.record).unwrap();
        model
            .engine
            .db
            .update_vm(&after.name, |actual| *actual = after.clone())
            .unwrap();
        MaterialJournal::at(&model.plan.child.path)
            .complete_branch_release(intent, &confirmed(intent), &after)
            .unwrap()
    }

    #[test]
    fn release_changes_only_held_material_and_preserves_independent_creation_identity() {
        for hold in [false, true] {
            let model = identity_model(hold);
            let intent = intent(&model);
            let after = intent.released_record(&model.record).unwrap();
            let mut expected = model.record.clone();
            expected.forkpoint_held = false;
            assert_eq!(
                crate::material::hash(&after).unwrap(),
                crate::material::hash(&expected).unwrap()
            );
            assert!(intent.transition.previous.matches(&model.record).unwrap());
            assert!(intent.transition.receipt.matches(&after).unwrap());
            assert_eq!(
                intent.transition.previous.material_sha256,
                intent.transition.receipt.material_sha256
            );
            assert_eq!(
                intent
                    .transition
                    .receipt
                    .material
                    .as_ref()
                    .unwrap()
                    .revision,
                1
            );
            assert_eq!(intent.transition.change.mode == Mode::Explicit, hold);
            for case in 0..3 {
                let mut changed = model.record.clone();
                match case {
                    0 => changed.pid = Some(999),
                    1 => changed.forkpoint_held = false,
                    _ => changed.env.push(("FOREIGN".into(), "changed".into())),
                }
                assert!(intent.released_record(&changed).is_err());
            }
            let mut crossed = intent.clone();
            crossed.transition.change.mode = if hold { Mode::Initial } else { Mode::Explicit };
            assert!(crossed.validate().is_err());
            assert!(!format!("{:?}", intent.transition)
                .contains(&intent.transition.change.activation_token));
        }
    }

    #[test]
    fn exact_agent_protocol_distinguishes_initial_ack_from_explicit_activation_without_retry() {
        for hold in [false, true] {
            let model = identity_model(hold);
            let intent = intent(&model);
            let socket = model.plan.child.path.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let expected = serde_json::to_value(intent.request()).unwrap();
            let response = match intent.transition.change.mode {
                Mode::Initial => None,
                Mode::Explicit => Some(serde_json::json!({"already_done": false})),
            };
            let peer = std::thread::spawn(move || {
                let mut stream = accept(listener);
                assert!(matches!(
                    read_request(&mut stream),
                    smolvm_protocol::AgentRequest::Ping
                ));
                stream
                    .write_all(
                        &smolvm_protocol::encode_message(&smolvm_protocol::AgentResponse::Pong {
                            version: smolvm_protocol::PROTOCOL_VERSION,
                            capabilities: vec![
                                smolvm_protocol::forkpoint::TYPED_BRANCHPOINT_CAPABILITY.into(),
                            ],
                        })
                        .unwrap(),
                    )
                    .unwrap();
                assert_eq!(
                    serde_json::to_value(read_request(&mut stream)).unwrap(),
                    expected
                );
                stream
                    .write_all(
                        &smolvm_protocol::encode_message(&smolvm_protocol::AgentResponse::Ok {
                            data: response,
                        })
                        .unwrap(),
                    )
                    .unwrap();
                let mut byte = [0];
                assert_eq!(stream.read(&mut byte).unwrap(), 0);
            });
            let budget =
                ReadBudget::new(Duration::from_secs(2), crate::Cancellation::default()).unwrap();
            assert!(intent
                .execute(&socket, &model.plan.child.path, &budget)
                .unwrap()
                .matches(&intent));
            peer.join().unwrap();
            assert!(
                model
                    .engine
                    .record(model.plan.publication.child())
                    .unwrap()
                    .forkpoint_held
            );
        }
    }

    #[test]
    fn malformed_duplicate_or_crossed_acknowledgement_never_becomes_release_proof() {
        let model = identity_model(true);
        let intent = intent(&model);
        for response in [
            smolvm_protocol::AgentResponse::Ok { data: None },
            smolvm_protocol::AgentResponse::Ok {
                data: Some(serde_json::json!({"already_done": true})),
            },
            smolvm_protocol::AgentResponse::Ok {
                data: Some(serde_json::json!({"already_done": false, "foreign": 1})),
            },
            smolvm_protocol::AgentResponse::Error {
                code: Some("NOT_READY".into()),
                message: "model".into(),
            },
        ] {
            assert!(intent.confirm(response).is_err());
        }
        let proof = confirmed(&intent);
        let mut crossed = intent.clone();
        crossed.transition.change.activation_token = "a".repeat(64);
        crossed.transition.receipt.material = Some(
            crossed
                .transition
                .next_proof(
                    crossed
                        .transition
                        .receipt
                        .material
                        .as_ref()
                        .unwrap()
                        .record_sha256
                        .clone(),
                )
                .unwrap(),
        );
        crossed.validate().unwrap();
        assert!(!proof.matches(&crossed));
    }

    #[test]
    fn missing_capability_oversized_reply_and_cancel_stop_without_another_dispatch() {
        for case in 0..3 {
            let model = identity_model(true);
            let intent = intent(&model);
            let socket = model.plan.child.path.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let cancel = crate::Cancellation::default();
            let peer_cancel = cancel.clone();
            let peer = std::thread::spawn(move || {
                let mut stream = accept(listener);
                assert!(matches!(
                    read_request(&mut stream),
                    smolvm_protocol::AgentRequest::Ping
                ));
                if case == 1 {
                    stream.write_all(&u32::MAX.to_be_bytes()).unwrap();
                } else {
                    stream.write_all(&smolvm_protocol::encode_message(&smolvm_protocol::AgentResponse::Pong {
                        version: smolvm_protocol::PROTOCOL_VERSION,
                        capabilities: if case == 0 { vec![] } else { vec![smolvm_protocol::forkpoint::TYPED_BRANCHPOINT_CAPABILITY.into()] },
                    }).unwrap()).unwrap();
                    if case == 2 {
                        assert!(matches!(
                            read_request(&mut stream),
                            smolvm_protocol::AgentRequest::BranchpointActivate { .. }
                        ));
                        peer_cancel.cancel();
                    }
                }
                let mut byte = [0];
                assert_eq!(stream.read(&mut byte).unwrap(), 0);
            });
            let budget = ReadBudget::new(Duration::from_secs(2), cancel).unwrap();
            assert!(intent
                .execute(&socket, &model.plan.child.path, &budget)
                .is_err());
            peer.join().unwrap();
            assert!(
                model
                    .engine
                    .record(model.plan.publication.child())
                    .unwrap()
                    .forkpoint_held
            );
        }
    }

    #[test]
    fn entered_release_cannot_replay_and_a_changed_held_flag_cannot_supply_completion() {
        let model = identity_model(true);
        let intent = intent(&model);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        let journal = MaterialJournal::at(&model.plan.child.path);
        assert!(lifecycle
            .authorize_release(&model.plan, &intent, &model.enrollment)
            .is_err());
        enter(&model, &intent);
        assert!(lifecycle
            .enter_release(&model.plan, &intent, &model.enrollment)
            .is_err());
        assert!(journal
            .begin_branch_release(&intent, &model.record)
            .is_err());
        assert!(journal.verify(model.plan.publication.child()).is_err());
        assert!(journal
            .completed_branch_release(model.plan.publication.child(), &request())
            .unwrap()
            .is_none());
        let after = intent.released_record(&model.record).unwrap();
        model
            .engine
            .db
            .update_vm(&after.name, |actual| *actual = after.clone())
            .unwrap();
        assert!(lifecycle
            .released(&model.plan, &intent, &model.enrollment)
            .is_err());
        assert!(lifecycle.uncertain(model.plan.publication.child()).unwrap());
        assert!(lifecycle
            .require_regular_restart(model.plan.publication.child())
            .is_err());
    }

    #[test]
    fn release_publication_requires_both_journals_and_exact_completed_lookup_never_rewrites() {
        let model = identity_model(false);
        let intent = intent(&model);
        enter(&model, &intent);
        let release = complete_material(&model, &intent);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        let journal = MaterialJournal::at(&model.plan.child.path);
        journal.verify(&release.receipt).unwrap();
        assert!(lifecycle
            .completed_release(&model.plan, &request(), &model.enrollment)
            .unwrap()
            .is_none());
        assert!(lifecycle.require_regular_restart(&release.receipt).is_err());
        lifecycle
            .released(&model.plan, &intent, &model.enrollment)
            .unwrap();
        lifecycle.require_regular_restart(&release.receipt).unwrap();
        assert!(!lifecycle.uncertain(&release.receipt).unwrap());
        let path = model.plan.child.path.join("smolbox.material-v2.json");
        let before = std::fs::read(&path).unwrap();
        for _ in 0..2 {
            assert_eq!(
                lifecycle
                    .completed_release(&model.plan, &request(), &model.enrollment)
                    .unwrap(),
                Some(release.clone())
            );
            assert_eq!(std::fs::read(&path).unwrap(), before);
        }
        let mut crossed = request();
        crossed.request_sha256 = "f".repeat(64);
        assert!(lifecycle
            .completed_release(&model.plan, &crossed, &model.enrollment)
            .is_err());
        assert!(journal
            .completed_branch_release(&release.previous, &crossed)
            .is_err());
        assert!(journal
            .complete_branch_release(
                &intent,
                &confirmed(&intent),
                &intent.released_record(&model.record).unwrap()
            )
            .is_err());
        assert!(lifecycle
            .enter_release(&model.plan, &intent, &model.enrollment)
            .is_err());
    }

    #[test]
    fn release_journal_rejects_altered_history_and_unbranched_bytes_omit_new_fields() {
        let model = identity_model(true);
        let intent = intent(&model);
        enter(&model, &intent);
        let release = complete_material(&model, &intent);
        let path = model.plan.child.path.join("smolbox.material-v2.json");
        let original = std::fs::read(&path).unwrap();
        for key in ["operation_id", "request_sha256"] {
            let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
            value["branch_release"]["change"]["request"][key] = "altered-model".into();
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(MaterialJournal::at(&model.plan.child.path)
                .verify(&release.receipt)
                .is_err());
        }
        std::fs::write(&path, original).unwrap();
        MaterialJournal::at(&model.plan.child.path)
            .verify(&release.receipt)
            .unwrap();
        let root = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(root.path(), false);
        let bytes = std::fs::read(
            engine
                .vm_directory(&receipt.name)
                .join("smolbox.material-v2.json"),
        )
        .unwrap();
        assert!(!String::from_utf8(bytes).unwrap().contains("branch_release"));
    }
}
