//! Bounded, single-entry bare-guest initialization. No launch, SDK convenience
//! rejuvenation, release, retry or caller-supplied guest program is accepted.
use crate::{Error, ErrorCode, OwnerIdentity, ReadBudget, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::time::SystemTime;

const PROGRAM: &str = include_str!("branch_identity.sh");
const OUTPUT_BYTES: u64 = 4096;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Intent {
    schema: u8,
    pub(crate) boot: crate::epoch::BootIntent,
    pub(crate) child: OwnerIdentity,
    name: String,
    nonce: String,
    host_epoch: u64,
    program_sha256: String,
}
impl Intent {
    pub(crate) fn new(name: &str, enrollment: &crate::epoch::BootEnrollment) -> Result<Self> {
        use sha2::{Digest, Sha256};
        let mut nonce = [0; 32];
        getrandom::fill(&mut nonce).map_err(|_| Error::before(ErrorCode::Native))?;
        let intent = Self {
            schema: 1,
            boot: enrollment.intent().clone(),
            child: enrollment.child(),
            name: name.into(),
            nonce: hex::encode(nonce),
            host_epoch: if cfg!(target_os = "linux") {
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .map_err(|_| Error::before(ErrorCode::State))?
                    .as_secs()
            } else {
                0
            },
            program_sha256: hex::encode(Sha256::digest(PROGRAM.as_bytes())),
        };
        intent.validate()?;
        Ok(intent)
    }
    pub(crate) fn validate(&self) -> Result<()> {
        use sha2::{Digest, Sha256};
        smolvm::data::validate_vm_name(&self.name, "branch child")
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        if self.schema != 1
            || !self.boot.valid_for(&self.name)
            || self.child.pid <= 0
            || self.child.birth == 0
            || self.child.uid != unsafe { libc::geteuid() }
            || !crate::domain::valid_hex(&self.nonce, 64)
            || self.program_sha256 != hex::encode(Sha256::digest(PROGRAM.as_bytes()))
            || (cfg!(target_os = "linux") && self.host_epoch == 0)
            || (!cfg!(target_os = "linux") && self.host_epoch != 0)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn matches(&self, name: &str, enrollment: &crate::epoch::BootEnrollment) -> bool {
        self.validate().is_ok()
            && self.name == name
            && self.boot == *enrollment.intent()
            && self.child == enrollment.child()
    }
    pub(crate) fn digest(&self) -> Result<String> {
        self.validate()?;
        crate::material::hash(self)
    }
    fn command(&self) -> Result<Vec<String>> {
        self.validate()?;
        Ok(vec![
            "/bin/sh".into(),
            "-c".into(),
            PROGRAM.into(),
            "smolbox-branch-identity-v1".into(),
            self.name.clone(),
            self.nonce.clone(),
            self.host_epoch.to_string(),
        ])
    }
    fn confirm(&self, code: i32, stdout: &[u8], stderr: &[u8]) -> Result<Verified> {
        self.validate()?;
        let expected = format!("smolbox-branch-identity-v1 {}\n", self.nonce);
        if code != 0
            || stdout != expected.as_bytes()
            || stdout.len() + stderr.len() > OUTPUT_BYTES as usize
            || (!stderr.is_empty() && stderr != b"clock-reset-unconfirmed\n")
        {
            return Err(Error::uncertain(ErrorCode::Native));
        }
        Ok(Verified {
            intent_sha256: self.digest()?,
        })
    }
    pub(crate) fn execute(
        &self,
        socket: &Path,
        staging: &Path,
        budget: &ReadBudget,
    ) -> Result<Verified> {
        self.validate()?;
        crate::branch_agent::exchange(
            socket,
            staging,
            OUTPUT_BYTES,
            budget,
            |client, remaining| {
                let (code, stdout, stderr) = client
                    .vm_exec(self.command()?, vec![], None, Some(remaining), None)
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                self.confirm(code, &stdout, &stderr)
            },
        )
    }
}
/// Opaque confirmation from this exact bounded agent exchange, never deserialized
/// from a caller, SDK row or a saved journal.
pub(crate) struct Verified {
    intent_sha256: String,
}
impl Verified {
    pub(crate) fn matches(&self, intent: &Intent) -> bool {
        intent.digest().ok().as_ref() == Some(&self.intent_sha256)
    }
    pub(crate) fn digest(&self) -> &str {
        &self.intent_sha256
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::time::Duration;

    fn model() -> (tempfile::TempDir, Intent, crate::epoch::BootEnrollment) {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let (_, _, epoch) = crate::epoch::tests::fixture_for_binding(
            &root,
            None,
            crate::DomainBinding {
                target_id: "owned".into(),
                generation: "a".repeat(32),
                database: root.join("db"),
                vm_root: root.join("vms"),
            },
        );
        let enrollment = crate::epoch::tests::complete_model(epoch.begin_boot("child").unwrap());
        let intent = Intent::new("child", &enrollment).unwrap();
        (temp, intent, enrollment)
    }
    /// Synthetic agent confirmation only; no guest program is run by models.
    pub(crate) fn confirmed_model(intent: &Intent) -> Verified {
        intent
            .confirm(
                0,
                format!("smolbox-branch-identity-v1 {}\n", intent.nonce).as_bytes(),
                b"",
            )
            .unwrap()
    }
    pub(crate) fn read_request(peer: &mut UnixStream) -> smolvm_protocol::AgentRequest {
        peer.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut header = [0; 4];
        peer.read_exact(&mut header).unwrap();
        let size = u32::from_be_bytes(header) as usize;
        assert!(size <= crate::AGENT_REQUEST_BYTES);
        let mut bytes = vec![0; size];
        peer.read_exact(&mut bytes).unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
    pub(crate) fn accept(listener: UnixListener) -> UnixStream {
        listener.set_nonblocking(true).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    return stream;
                }
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(1))
                }
                Err(error) => panic!("private model connection failed: {error}"),
            }
        }
    }

    #[test]
    fn intent_binds_original_boot_child_fixed_program_and_separate_arguments() {
        let (_temp, intent, enrolled) = model();
        assert!(intent.matches("child", &enrolled));
        assert!(!intent.matches("other", &enrolled));
        let command = intent.command().unwrap();
        assert_eq!(command[2], PROGRAM);
        assert!(!command[2].contains(&intent.nonce));
        assert_eq!(&command[4..6], &[intent.name.clone(), intent.nonce.clone()]);
        assert!(PROGRAM.contains(smolvm_protocol::forkpoint::RESTORED_PATH));
        assert!(PROGRAM.contains(smolvm_protocol::forkpoint::STATE_DIR));
        assert!(!PROGRAM.contains(smolvm_protocol::forkpoint::RELEASE_PATH));
        for key in ["program_sha256", "name", "nonce"] {
            let mut value = serde_json::to_value(&intent).unwrap();
            value[key] = "changed-model".into();
            assert!(serde_json::from_value::<Intent>(value)
                .unwrap()
                .validate()
                .is_err());
        }
        let mut crossed = intent.clone();
        crossed.child.birth += 1;
        assert!(!crossed.matches("child", &enrolled));
        assert_ne!(crossed.digest().unwrap(), intent.digest().unwrap());
    }

    #[test]
    fn only_exact_success_confirms_identity_and_clock_warning_does_not_grant_release() {
        let (_temp, intent, _) = model();
        let stdout = format!("smolbox-branch-identity-v1 {}\n", intent.nonce);
        let proof = intent
            .confirm(0, stdout.as_bytes(), b"clock-reset-unconfirmed\n")
            .unwrap();
        assert!(proof.matches(&intent));
        assert!(intent.confirm(1, stdout.as_bytes(), b"").is_err());
        assert!(intent.confirm(0, b"other-child", b"").is_err());
        assert!(intent
            .confirm(0, stdout.as_bytes(), b"unexpected warning")
            .is_err());
        assert!(intent
            .confirm(0, stdout.as_bytes(), &vec![b'x'; OUTPUT_BYTES as usize])
            .is_err());
        let mut changed = intent.clone();
        changed.nonce = "f".repeat(64);
        assert!(!proof.matches(&changed));
    }

    #[test]
    fn bounded_public_sdk_exchange_confirms_only_one_fixed_guest_request() {
        let (temp, intent, _) = model();
        let root = temp.path().canonicalize().unwrap();
        let socket = root.join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let expected_command = intent.command().unwrap();
        let stdout = format!("smolbox-branch-identity-v1 {}\n", intent.nonce).into_bytes();
        let peer = std::thread::spawn(move || {
            let mut stream = accept(listener);
            let smolvm_protocol::AgentRequest::VmExec {
                command,
                env,
                workdir,
                timeout_ms,
                interactive,
                tty,
                background,
                stdin_data,
            } = read_request(&mut stream)
            else {
                panic!()
            };
            assert_eq!(command, expected_command);
            assert!(env.is_empty() && workdir.is_none() && timeout_ms.is_some());
            assert!(!interactive && !tty && !background && stdin_data.is_none());
            let response = smolvm_protocol::AgentResponse::Completed {
                exit_code: 0,
                stdout,
                stderr: vec![],
            };
            stream
                .write_all(&smolvm_protocol::encode_message(&response).unwrap())
                .unwrap();
            let mut byte = [0];
            assert_eq!(stream.read(&mut byte).unwrap(), 0);
        });
        let budget =
            ReadBudget::new(Duration::from_secs(2), crate::Cancellation::default()).unwrap();
        let long_stage = root.join("long-owned-domain-path-model".repeat(5));
        std::fs::create_dir(&long_stage).unwrap();
        assert!(intent
            .execute(&socket, &long_stage, &budget)
            .unwrap()
            .matches(&intent));
        peer.join().unwrap();
    }

    #[test]
    fn absolute_budget_closes_only_observation_and_never_replays_an_agent_request() {
        for explicit_cancel in [false, true] {
            let (temp, intent, _) = model();
            let root = temp.path().canonicalize().unwrap();
            let socket = root.join("agent.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let cancel = crate::Cancellation::default();
            let peer_cancel = cancel.clone();
            let peer = std::thread::spawn(move || {
                let mut stream = accept(listener);
                read_request(&mut stream);
                if explicit_cancel {
                    peer_cancel.cancel();
                }
                let mut byte = [0];
                assert_eq!(stream.read(&mut byte).unwrap(), 0);
            });
            let budget = ReadBudget::new(
                if explicit_cancel {
                    Duration::from_secs(2)
                } else {
                    Duration::from_millis(500)
                },
                cancel,
            )
            .unwrap();
            assert!(intent.execute(&socket, &root, &budget).is_err());
            peer.join().unwrap();
            assert!(intent.execute(&socket, &root, &budget).is_err());
        }
    }

    #[test]
    fn oversized_reply_header_rejects_before_allocating_sdk_payload() {
        let (temp, intent, _) = model();
        let root = temp.path().canonicalize().unwrap();
        let socket = root.join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let peer = std::thread::spawn(move || {
            let mut stream = accept(listener);
            read_request(&mut stream);
            stream.write_all(&u32::MAX.to_be_bytes()).unwrap();
        });
        let budget =
            ReadBudget::new(Duration::from_secs(2), crate::Cancellation::default()).unwrap();
        assert!(intent.execute(&socket, &root, &budget).is_err());
        peer.join().unwrap();
    }
}
