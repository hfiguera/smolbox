//! Explicit ordinary branch witness; default tests are pure input/state models.
//! Failed SDK work retains its original engine. No process signals, reconstruction
//! from saved receipts, fault modes or automatic replay are available.
#[path = "branch_proof/cancellation.rs"]
mod cancellation;
#[path = "branch_proof/recovery.rs"]
mod recovery;
#[path = "proof_support/mod.rs"]
mod support;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
#[cfg(test)]
use smolbox_engine::BranchResources;
use smolbox_engine::{
    ApprovedArtifact, BranchApproval, BranchBackingRelease, BranchBackingReleaseRequest,
    BranchChildAbsence, BranchChildAbsenceRequest, BranchChildIntent, BranchCompletion,
    BranchCreateRequest, BranchReleaseRequest, Cancellation, Command, CreateRequest,
    CreationReceipt, Dispatch, Engine, ObservedState, ReadBudget, Resources, Stream,
};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use support::{budget, read_private, save, PackageSettings, ProofResult};

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Artifact {
    path: PathBuf,
    sha256: String,
    max_bytes: u64,
    guest_platform: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    package: PathBuf,
    manifest_sha256: String,
    domain_json: PathBuf,
    artifact: Artifact,
    branch_approval: BranchApproval,
}
fn normalized(path: &Path) -> bool {
    path.is_absolute()
        && path.to_str().is_some_and(|s| {
            s.split('/')
                .skip(1)
                .all(|p| !p.is_empty() && p != "." && p != "..")
        })
}
fn hex64(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn resources() -> Resources {
    Resources {
        cpus: 1,
        memory_mib: 512,
        storage_gib: 1,
        overlay_gib: 1,
    }
}
impl Settings {
    fn validate(&self) -> ProofResult<()> {
        if ![&self.package, &self.domain_json, &self.artifact.path]
            .into_iter()
            .all(|p| normalized(p))
            || !hex64(&self.manifest_sha256)
            || !hex64(&self.artifact.sha256)
            || !(1..=32 * 1024 * 1024 * 1024).contains(&self.artifact.max_bytes)
            || self.artifact.guest_platform != "linux/amd64"
        {
            return Err(
                "explicit normalized Linux package/domain/bare-artifact approvals required".into(),
            );
        }
        self.branch_approval.plan(resources())?;
        Ok(())
    }
    fn artifact(&self) -> ApprovedArtifact {
        ApprovedArtifact {
            path: self.artifact.path.clone(),
            sha256: self.artifact.sha256.clone(),
            max_bytes: self.artifact.max_bytes,
            guest_platform: self.artifact.guest_platform.clone(),
        }
    }
    fn package(&self) -> PackageSettings {
        PackageSettings {
            package: self.package.clone(),
            manifest_sha256: self.manifest_sha256.clone(),
            domain_json: self.domain_json.clone(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum State {
    Missing,
    Stopped,
    Running,
    Held,
    Unknown,
    Deleted,
}
struct Member {
    receipt: Option<CreationReceipt>,
    state: State,
    creation: Option<BranchCreateRequest>,
    completion: Option<BranchCompletion>,
    release: Option<BranchReleaseRequest>,
    absence_request: Option<BranchChildAbsenceRequest>,
    absence: Option<BranchChildAbsence>,
    backing: Option<BranchBackingReleaseRequest>,
    backing_proof: Option<BranchBackingRelease>,
    recovery: recovery::Recovery,
}
impl Member {
    fn empty() -> Self {
        Self {
            receipt: None,
            state: State::Missing,
            creation: None,
            completion: None,
            release: None,
            absence_request: None,
            absence: None,
            backing: None,
            backing_proof: None,
            recovery: recovery::Recovery::default(),
        }
    }
    fn receipt(&self) -> ProofResult<&CreationReceipt> {
        self.receipt
            .as_ref()
            .ok_or("no returned original receipt; no adoption".into())
    }
    fn unentered(&self) -> bool {
        (self.state == State::Missing && self.receipt.is_none() && self.creation.is_none())
            || (self.state == State::Deleted
                && self.receipt.is_none()
                && self.recovery.retired_unentered())
    }
    fn known_absent(&self) -> bool {
        self.unentered() || self.state == State::Deleted
    }
    fn child_closed(&self) -> bool {
        self.unentered()
            || (self.state == State::Deleted
                && (self.absence.is_some() || self.recovery.has_absence())
                && self.recovery.cleanup_complete()
                && self.backing_proof.is_some())
    }
    fn enter(&mut self, permitted: &[State]) -> ProofResult<()> {
        if !permitted.contains(&self.state) {
            return Err(
                "original state does not permit this step; uncertain work cannot replay".into(),
            );
        }
        self.state = State::Unknown;
        Ok(())
    }
    fn returned<T>(&mut self, before: State, result: smolbox_engine::Result<T>) -> ProofResult<T> {
        result.map_err(|error| {
            // Only the engine's positive pre-dispatch refusal preserves the
            // previous known state. May-have-dispatched work cannot replay.
            if error.dispatch == Dispatch::NotDispatched {
                self.state = before;
            }
            Box::new(error) as Box<dyn std::error::Error>
        })
    }
}
struct Session {
    engine: Engine,
    driver_sha256: String,
    output: PathBuf,
    members: [Member; 3], // source, initially released child, initially held child
    create_entered: bool,
    closed: bool,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("ordinary branch proof failed: {error}");
        std::process::exit(1);
    }
}
fn run() -> ProofResult<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() == 3 && args[0] == "control" {
        return control(Path::new(&args[1]), &args[2]);
    }
    if args.len() != 3
        || !matches!(
            args[0].as_str(),
            "ordinary" | "ordinary-partial-cancellation"
        )
        || !cfg!(all(target_os = "linux", target_arch = "x86_64"))
    {
        return Err("Linux x86_64: branch-guest-proof ordinary|ordinary-partial-cancellation SETTINGS_JSON OUTPUT | control OUTPUT ACTION".into());
    }
    let settings: Settings = read_private(Path::new(&args[1]))?;
    settings.validate()?;
    let output = PathBuf::from(&args[2]);
    support::output(&output, true)?;
    let socket = output.join("control.sock");
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    let driver_sha256 = executable_sha256()?;
    let mut session = Session {
        engine: support::open_package(&settings.package())?,
        driver_sha256,
        output: output.clone(),
        members: std::array::from_fn(|_| Member::empty()),
        create_entered: false,
        closed: false,
    };
    let result = (if args[0] == "ordinary-partial-cancellation" {
        session.exercise_partial_cancellation(&settings)
    } else {
        session.exercise(&settings)
    })
    .and_then(|mut report| {
        session.close_cleaned()?;
        report["normal_owner_shutdown"] = json!(true);
        save(&output.join("evidence.json"), &report)
    });
    if let Err(error) = &result {
        // Neither diagnostic IO nor a control failure may unwind an entered owner.
        let _ = save(
            &output.join("failure.json"),
            &json!({
                "error":error.to_string(), "owner_retained":!session.closed, "forced_termination":false
            }),
        );
        if !session.closed {
            eprintln!(
                "ordinary branch witness retained original engine; use explicit normal controls"
            );
            support::retain_owner(&listener, |stream| session.control(stream));
        }
    }
    drop(listener);
    std::fs::remove_file(socket)?;
    result
}

impl Session {
    fn stage(&self, name: &str, value: &impl Serialize) -> ProofResult<()> {
        save(&self.output.join(format!("{name}.json")), value)
    }
    fn stage_observation(
        &self,
        name: &str,
        observed: &smolbox_engine::Observation,
    ) -> ProofResult<()> {
        self.stage(
            name,
            &json!({
                "state":format!("{:?}", observed.state), "pid_identity":observed.pid_identity
            }),
        )
    }
    fn receipt(&self, index: usize) -> ProofResult<&CreationReceipt> {
        self.members[index].receipt()
    }
    fn command(&self, index: usize, script: &str, expected: &[u8]) -> ProofResult<()> {
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let result = self.engine.exec(
            self.receipt(index)?,
            Command {
                argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
                env: vec![],
                workdir: Some("/".into()),
                // Bare guests use the agent's ordinary user; the numeric user
                // selector is an image-only SDK/SmolBox option.
                user: None,
                timeout: Duration::from_secs(30),
                max_output_bytes: 4096,
            },
            Cancellation::new(),
            |chunk| {
                match chunk.stream {
                    Stream::Stdout => stdout.extend(chunk.bytes),
                    Stream::Stderr => stderr.extend(chunk.bytes),
                }
                Ok(())
            },
        )?;
        if !result.success() || stdout != expected || !stderr.is_empty() {
            return Err("ordinary branch command or expected guest state differs".into());
        }
        Ok(())
    }
    fn check_data(&self, index: usize, value: &str, memory: bool) -> ProofResult<()> {
        let script = if memory {
            "cat /workspace/smolbox-branch-disk /dev/shm/smolbox-branch-memory"
        } else {
            "test ! -e /dev/shm/smolbox-branch-memory; cat /workspace/smolbox-branch-disk"
        };
        self.command(index, script, value.as_bytes())
    }
    fn stop(&mut self, index: usize) -> ProofResult<()> {
        if index == 0 && self.members[1..].iter().any(|m| !m.known_absent()) {
            return Err("retain original source context until every entered child is proved absent or unentered".into());
        }
        if self.members[index].state == State::Stopped {
            return Ok(());
        }
        let before = self.members[index].state;
        self.members[index].enter(&[State::Running])?;
        let result = self
            .engine
            .stop_with_budget(self.receipt(index)?, &budget()?);
        let observation = self.members[index].returned(before, result)?;
        if observation.state != ObservedState::Stopped {
            return Err("normal stop unverified".into());
        }
        self.members[index].state = State::Stopped;
        Ok(())
    }
    fn delete(&mut self, index: usize) -> ProofResult<()> {
        if index == 0 && self.members[1..].iter().any(|m| !m.known_absent()) {
            return Err("original child cleanup must precede source deletion".into());
        }
        if self.members[index].state == State::Deleted {
            return Ok(());
        }
        if self.members[index].state == State::Running {
            self.stop(index)?;
        }
        let before = self.members[index].state;
        self.members[index].enter(&[State::Stopped, State::Held])?;
        let result = self
            .engine
            .delete_with_budget(self.receipt(index)?, &budget()?);
        if self.members[index].returned(before, result)?.state != ObservedState::Missing {
            return Err("original owned deletion unverified".into());
        }
        self.members[index].state = State::Deleted;
        Ok(())
    }
    fn block_stop(&mut self, index: usize) -> ProofResult<()> {
        match self
            .engine
            .stop_with_budget(self.receipt(index)?, &budget()?)
        {
            Err(error)
                if error.dispatch == Dispatch::NotDispatched
                    && error.code == smolbox_engine::ErrorCode::State =>
            {
                Ok(())
            }
            _ => {
                self.members[index].state = State::Unknown;
                Err("dependency/held stop was not rejected before dispatch".into())
            }
        }
    }
    fn create_child(&mut self, index: usize, settings: &Settings) -> ProofResult<()> {
        let request = BranchCreateRequest {
            source: self.receipt(0)?.clone(),
            child: BranchChildIntent {
                operation_id: format!("branch-{}", support::random(12)?),
                name: format!("sb-branch-{index}-{}", support::random(8)?),
                owner_token: support::random(32)?,
                incarnation: support::random(16)?,
                idle: true,
                hold: index == 2,
            },
            approval: settings.branch_approval.clone(),
            initial_release: if index == 1 {
                Some(release_request("initial")?)
            } else {
                None
            },
        };
        self.stage(&format!("child-{index}-request"), &request)?;
        self.members[index].creation = Some(request.clone());
        self.members[index].enter(&[State::Missing])?;
        let result = self.engine.create_branch(
            &request,
            &ReadBudget::for_checkpoint_work(Duration::from_secs(120), Cancellation::new())?,
        )?;
        // Retain every returned original fact before fallible evidence publication.
        self.members[0].receipt = Some(result.publication.receipt.clone());
        self.members[index].receipt = Some(result.child.clone());
        self.members[index].state = if result.held {
            State::Held
        } else {
            State::Running
        };
        self.members[index].completion = Some(result.clone());
        self.stage(&format!("child-{index}-completion"), &result)?;
        if self
            .engine
            .inspect_branch_completion(&request, &budget()?)?
            .as_ref()
            != Some(&result)
        {
            return Err("historical original creation lookup differs".into());
        }
        Ok(())
    }
    fn release_held(&mut self) -> ProofResult<()> {
        if self.members[2].state == State::Running {
            return Ok(());
        }
        let request = release_request("explicit")?;
        self.stage("held-release-request", &request)?;
        self.members[2].release = Some(request.clone());
        self.members[2].enter(&[State::Held])?;
        let completion = self.members[2]
            .completion
            .as_ref()
            .ok_or("missing original held completion")?;
        let result = self.engine.release_held_branch_checked(
            completion,
            self.receipt(0)?,
            &request,
            &budget()?,
        )?;
        self.members[2].receipt = Some(result.receipt.clone());
        self.members[2].state = State::Running;
        self.stage("held-release-result", &result)
    }
    fn absence(&mut self, index: usize) -> ProofResult<()> {
        if self.members[index].recovery.has_disposal() {
            return self.disposal_absence(index);
        }
        if self.members[index].absence.is_some() {
            return Ok(());
        }
        if self.members[index].state != State::Deleted {
            return Err("owned deletion required".into());
        }
        if self.members[index].absence_request.is_none() {
            let request = BranchChildAbsenceRequest {
                completion: self.members[index]
                    .completion
                    .clone()
                    .ok_or("missing original completion")?,
                child: self.receipt(index)?.clone(),
                operation_id: format!("absent-{index}"),
                request_sha256: digest(&("ordinary-branch-absence-v1", self.receipt(index)?))?,
                quiesced: true,
            };
            self.stage(&format!("child-{index}-absence-request"), &request)?;
            self.members[index].absence_request = Some(request);
        }
        let request = self.members[index]
            .absence_request
            .as_ref()
            .ok_or("missing exact absence request")?;
        let proof = self
            .engine
            .qualify_branch_child_absence(request, &budget()?)?;
        self.members[index].absence = Some(proof.clone());
        self.stage(&format!("child-{index}-absence-proof"), &proof)
    }
    fn release_backing(&mut self, index: usize) -> ProofResult<()> {
        if self.members[index].recovery.has_disposal() {
            return self.disposal_backing(index);
        }
        if self.members[index].backing_proof.is_some() {
            return Ok(());
        }
        if self.members[index].absence.is_none() || self.members.iter().any(|m| !m.known_absent()) {
            return Err("all original members deleted and selected absence proof required".into());
        }
        // SDK source deletion removed the original source snapshot tree.
        // Verify all three owned directories absent before confirming backing removal.
        for member in &self.members {
            if member.unentered() {
                continue;
            }
            let path = smolvm::agent::vm_data_dir(&member.receipt()?.name);
            if !matches!(std::fs::symlink_metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound)
            {
                return Err("original backing namespace remains; no removal confirmation".into());
            }
        }
        if self.members[index].backing.is_none() {
            let request = backing_request(
                self.members[index]
                    .completion
                    .clone()
                    .ok_or("missing original completion")?,
                self.receipt(0)?.clone(),
                self.receipt(index)?.clone(),
                format!("backing-{index}"),
            )?;
            self.stage(&format!("child-{index}-backing-request"), &request)?;
            self.members[index].backing = Some(request);
        }
        let request = self.members[index]
            .backing
            .as_ref()
            .ok_or("missing exact backing request")?;
        let proof = self
            .engine
            .release_branch_backing_checked(request, &budget()?)?;
        self.members[index].backing_proof = Some(proof.clone());
        self.stage(&format!("child-{index}-backing-proof"), &proof)
    }
    fn close_cleaned(&mut self) -> ProofResult<()> {
        if self.closed {
            return Ok(());
        }
        if !self.engine.available()
            || self.members[0].state != State::Deleted
            || self.members[1..].iter().any(|m| !m.child_closed())
            || self.engine.inventory(&budget()?)?.count != 0
        {
            return Err("all original members must be positively deleted before close".into());
        }
        self.close()
    }
    fn close(&mut self) -> ProofResult<()> {
        if self
            .engine
            .shutdown()
            .iter()
            .any(|(_, result)| result.is_err())
        {
            return Err("normal engine shutdown incomplete".into());
        }
        self.closed = true;
        Ok(())
    }
    fn prepare_source(&mut self, settings: &Settings) -> ProofResult<()> {
        if self.engine.inventory(&budget()?)?.count != 0 {
            return Err("fresh dedicated account with empty SDK inventory required".into());
        }
        self.stage("settings", settings)?;
        self.engine
            .qualify_checkpointable_creation(&settings.artifact(), resources(), None)?;
        let request = CreateRequest {
            name: format!("sb-branch-source-{}", support::random(8)?),
            owner_token: support::random(32)?,
            incarnation: support::random(16)?,
            artifact: settings.artifact(),
            resources: resources(),
            labels: BTreeMap::new(),
        };
        self.stage(
            "source-intent",
            &json!({"name":request.name,"owner_token":request.owner_token,
            "incarnation":request.incarnation,"checkpointable":true,"artifact":settings.artifact}),
        )?;
        self.create_entered = true;
        self.members[0].state = State::Unknown;
        let source = self.engine.create_checkpointable(
            request,
            Instant::now() + Duration::from_secs(120),
            &Cancellation::new(),
        )?;
        self.members[0].receipt = Some(source);
        self.members[0].state = State::Stopped;
        self.stage("source-created", self.receipt(0)?)?;
        self.members[0].enter(&[State::Stopped])?;
        let started = self.engine.start_checkpointable(
            self.receipt(0)?,
            Instant::now() + Duration::from_secs(120),
            &Cancellation::new(),
        )?;
        if started.state != ObservedState::Running {
            return Err("checkpointable source startup unverified".into());
        }
        self.members[0].state = State::Running;
        self.stage_observation("source-started", &started)?;
        self.stage_observation(
            "source-before-setup",
            &self.engine.inspect(self.receipt(0)?)?,
        )?;
        self.command(0, "set -eu; mkdir -p /workspace; test -d /dev/shm; printf source-disk > /workspace/smolbox-branch-disk; printf source-memory > /dev/shm/smolbox-branch-memory; command -v smolvm-branch-ready >/dev/null; smolvm-branch-ready </dev/null >/tmp/smolbox-branch-ready.log 2>&1 &", b"")
            .map_err(|error| format!("source marker setup: {error}"))?;
        self.stage(
            "source-markers-installed",
            &json!({"command_completed":true}),
        )?;
        self.command(0, "set -eu; i=0; while [ ! -f /run/smolvm/forkpoint/ready ]; do i=$((i+1)); test \"$i\" -lt 200; sleep 0.05; done", b"")
            .map_err(|error| format!("source branch-ready observation: {error}"))?;
        self.stage("source-branch-ready", &json!({"marker_observed":true}))?;
        let preflight = self
            .engine
            .branch_preflight(self.receipt(0)?, &budget()?)
            .map_err(|error| format!("source branch preflight: {error}"))?;
        self.stage_observation("source-branch-preflight", &preflight)?;
        Ok(())
    }
    fn exercise(&mut self, settings: &Settings) -> ProofResult<Value> {
        self.prepare_source(settings)?;
        self.create_child(1, settings)?;
        self.create_child(2, settings)?;
        self.block_stop(0)?;
        self.block_stop(2)?;
        self.check_data(0, "source-disksource-memory", true)?;
        self.check_data(1, "source-disksource-memory", true)?;
        self.command(1, "printf first-disk > /workspace/smolbox-branch-disk; printf first-memory > /dev/shm/smolbox-branch-memory", b"")?;
        self.release_held()?;
        self.check_data(2, "source-disksource-memory", true)?;
        self.command(2, "printf second-disk > /workspace/smolbox-branch-disk; printf second-memory > /dev/shm/smolbox-branch-memory", b"")?;
        self.check_data(0, "source-disksource-memory", true)?;
        self.check_data(1, "first-diskfirst-memory", true)?;
        self.check_data(2, "second-disksecond-memory", true)?;
        self.stage(
            "sibling-independence",
            &json!({"source_and_children_disk_and_memory_independent":true}),
        )?;
        self.stop(1)
            .map_err(|error| format!("first child normal stop: {error}"))?;
        self.stage(
            "first-child-stopped",
            &json!({"normal_stop_completed":true}),
        )?;
        self.members[1].enter(&[State::Stopped])?;
        let restarted = self
            .engine
            .start(self.receipt(1)?)
            .map_err(|error| format!("first child normal restart: {error}"))?;
        if restarted.state != ObservedState::Running {
            return Err("normal child restart unverified".into());
        }
        self.members[1].state = State::Running;
        self.stage_observation("first-child-restarted", &restarted)?;
        self.check_data(1, "first-disk", false)?;
        self.check_data(0, "source-disksource-memory", true)?;
        self.check_data(2, "second-disksecond-memory", true)?;
        self.stage(
            "cold-restart-and-siblings-verified",
            &json!({"disk_retained":true,"ram_not_restored":true,"siblings_unchanged":true}),
        )?;
        self.delete(1)
            .map_err(|error| format!("first child normal deletion: {error}"))?;
        self.stage(
            "first-child-deleted",
            &json!({"normal_delete_completed":true}),
        )?;
        self.absence(1)?;
        self.block_stop(0)?;
        self.check_data(2, "second-disksecond-memory", true)?;
        self.delete(2)
            .map_err(|error| format!("held child normal deletion: {error}"))?;
        self.absence(2)?;
        self.delete(0)
            .map_err(|error| format!("source normal deletion: {error}"))?;
        for index in [1, 2] {
            self.release_backing(index)?;
        }
        Ok(
            json!({"status":"passed","scope":"ordinary-shared-engine-branches-linux-local-bare",
            "package_manifest_sha256":settings.manifest_sha256,"sdk_revision":smolbox_engine::SMOLVM_REVISION,
            "witness_executable_sha256":self.driver_sha256,
            "source_and_two_children_independent":true,"held_release":true,"normal_child_restart":true,
            "cold_restart_does_not_restore_ram":true,"owned_child_absence_proofs":2,"owned_deleted":true,
            "native_backing_acknowledgements":2,"durable_dependency_retirement_qualified":false,
            "port_branch_routing_qualified":false,"public_consumer_qualified":false,
            "public_native_branch_admission_enabled":false,"crash_validation_performed":false,
            "distribution_approved":false}),
        )
    }
    fn control(&mut self, stream: &mut UnixStream) -> ProofResult<bool> {
        stream.set_read_timeout(Some(Duration::from_secs(2)))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;
        let mut bytes = Vec::new();
        (&mut *stream).take(65).read_to_end(&mut bytes)?;
        let action = parse_action(&bytes)?;
        let result = match action {
            Action::Status => Ok(()),
            Action::Stop(index) => self.stop(index),
            Action::Delete(index) => self.delete(index),
            Action::ReleaseHeld => self.release_held(),
            Action::Absence(index) => self.absence(index),
            Action::Backing(index) => self.release_backing(index),
            Action::Recovery(action) => self.recover(action),
            Action::CloseCleaned => self.close_cleaned(),
            // Graceful owner shutdown preserves all uncertain SDK rows/disks.
            // It proves neither disposal nor release of a durable reservation.
            Action::CloseRetained => self.close(),
            Action::CloseUnstarted => {
                if self.create_entered
                    || !self.engine.available()
                    || self.engine.inventory(&budget()?)?.count != 0
                {
                    Err("only never-entered empty owner can close unstarted".into())
                } else {
                    self.close()
                }
            }
        };
        let response = json!({"ok":result.is_ok(),"error":result.err().map(|e|e.to_string()),
            "states":self.members.iter().map(|m|m.state).collect::<Vec<_>>(),"closed":self.closed,
            "last_observed_retained_phases":self.members.iter().map(|m|m.recovery.last_observed_phase()).collect::<Vec<_>>(),
            "partial_original_requests_retained":self.members.iter().filter(|m|m.creation.is_some()&&m.completion.is_none()).count()});
        stream.write_all(&serde_json::to_vec(&response)?)?;
        Ok(self.closed)
    }
}
fn digest(value: &impl Serialize) -> ProofResult<String> {
    Ok(hex::encode(Sha256::digest(serde_json::to_vec(value)?)))
}
fn executable_sha256() -> ProofResult<String> {
    let file = std::fs::File::open(std::env::current_exe()?)?;
    let expected = file.metadata()?.len();
    let maximum = 256 * 1024 * 1024;
    if expected == 0 || expected > maximum {
        return Err("optimized witness executable must fit the 256-MiB identity bound".into());
    }
    let mut file = file.take(maximum + 1);
    let mut hash = Sha256::new();
    let mut buffer = [0_u8; 65536];
    let mut count = 0_u64;
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        count += n as u64;
        if count > maximum {
            return Err("witness executable grew beyond bound".into());
        }
        hash.update(&buffer[..n]);
    }
    if count != expected {
        return Err("witness executable length changed".into());
    }
    Ok(hex::encode(hash.finalize()))
}
fn release_request(kind: &str) -> ProofResult<BranchReleaseRequest> {
    Ok(BranchReleaseRequest {
        operation_id: format!("{kind}-{}", support::random(12)?),
        request_sha256: support::random(32)?,
        env: Vec::new(),
    })
}
fn backing_request(
    completion: BranchCompletion,
    source: CreationReceipt,
    child: CreationReceipt,
    operation_id: String,
) -> ProofResult<BranchBackingReleaseRequest> {
    let mut request = BranchBackingReleaseRequest {
        completion,
        source,
        child,
        operation_id,
        request_sha256: String::new(),
        quiesced: true,
        backing_removed: true,
    };
    request.request_sha256 = digest(&(
        "smolbox-branch-backing-request-v1",
        &request.completion,
        &request.source,
        &request.child,
        &request.operation_id,
        request.quiesced,
        request.backing_removed,
    ))?;
    request.validate()?;
    Ok(request)
}
#[derive(Debug, PartialEq, Eq)]
enum Action {
    Status,
    Stop(usize),
    Delete(usize),
    ReleaseHeld,
    Absence(usize),
    Backing(usize),
    Recovery(recovery::Action),
    CloseCleaned,
    CloseRetained,
    CloseUnstarted,
}
fn parse_action(bytes: &[u8]) -> ProofResult<Action> {
    if bytes.len() > 64 {
        return Err("control action exceeds bound".into());
    }
    match std::str::from_utf8(bytes)?.trim() {
        "status" => Ok(Action::Status),
        "stop-source" => Ok(Action::Stop(0)),
        "stop-first" => Ok(Action::Stop(1)),
        "stop-held" => Ok(Action::Stop(2)),
        "delete-source" => Ok(Action::Delete(0)),
        "delete-first" => Ok(Action::Delete(1)),
        "delete-held" => Ok(Action::Delete(2)),
        "release-held" => Ok(Action::ReleaseHeld),
        "qualify-first-absence" => Ok(Action::Absence(1)),
        "qualify-held-absence" => Ok(Action::Absence(2)),
        "release-first-backing" => Ok(Action::Backing(1)),
        "release-held-backing" => Ok(Action::Backing(2)),
        "close-cleaned" => Ok(Action::CloseCleaned),
        "close-retained" => Ok(Action::CloseRetained),
        "close-unstarted" => Ok(Action::CloseUnstarted),
        action => recovery::parse(action)
            .map(Action::Recovery)
            .ok_or("unknown ordinary control action".into()),
    }
}
fn control(output: &Path, action: &str) -> ProofResult<()> {
    parse_action(action.as_bytes())?;
    support::output(output, false)?;
    let mut stream = UnixStream::connect(output.join("control.sock"))?;
    stream.set_read_timeout(Some(Duration::from_secs(40)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    stream.write_all(action.as_bytes())?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut bytes = Vec::new();
    stream.take(4097).read_to_end(&mut bytes)?;
    if bytes.len() > 4096 {
        return Err("control response exceeds bound".into());
    }
    let response: Value = serde_json::from_slice(&bytes)?;
    println!("{response}");
    if response["ok"] != true {
        return Err("ordinary control did not complete".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn settings() -> Settings {
        Settings {
            package: "/approved/package".into(),
            manifest_sha256: "a".repeat(64),
            domain_json: "/approved/domain.json".into(),
            artifact: Artifact {
                path: "/approved/bare.smolmachine".into(),
                sha256: "b".repeat(64),
                max_bytes: 1 << 30,
                guest_platform: "linux/amd64".into(),
            },
            branch_approval: BranchApproval {
                id: "branches".into(),
                host_overhead_mb: 128,
                resources: BranchResources {
                    slots: 1,
                    cpus: 1,
                    memory_mb: 640,
                    disk_gb: 5,
                },
            },
        }
    }
    #[test]
    fn explicit_approval_and_finite_backing_plan_are_checked_without_package_or_sdk_io() {
        let settings = settings();
        settings.validate().unwrap();
        let plan = settings.branch_approval.plan(resources()).unwrap();
        assert_eq!(plan.total_additional.memory_mb, 1280);
        assert_eq!(plan.minimum_extra_disk_gb, 5);
        assert_eq!(plan.total_additional.disk_gb, 7);
    }
    #[test]
    fn redirected_inputs_wrong_platform_digests_and_underfunded_approval_reject_cold() {
        for field in 0..10 {
            let mut settings = settings();
            match field {
                0 => settings.package = "relative".into(),
                1 => settings.domain_json = "/approved/../other.json".into(),
                2 => settings.artifact.path = "/approved/./bare".into(),
                3 => settings.artifact.guest_platform = "linux/arm64".into(),
                4 => settings.manifest_sha256 = "A".repeat(64),
                5 => settings.artifact.sha256 = "bad".into(),
                6 => settings.artifact.max_bytes = 0,
                7 => settings.artifact.max_bytes = (32 << 30) + 1,
                8 => settings.branch_approval.resources.disk_gb = 4,
                _ => settings.branch_approval.resources.memory_mb = 639,
            }
            assert!(settings.validate().is_err());
        }
        let mut value = serde_json::to_value(settings()).unwrap();
        value["crash_mode"] = json!(true);
        assert!(serde_json::from_value::<Settings>(value).is_err());
    }
    #[test]
    fn unknown_entered_lifecycle_cannot_replay_or_adopt_observed_stopped_state() {
        let mut member = Member::empty();
        assert!(member.unentered() && member.known_absent() && member.child_closed());
        member.enter(&[State::Missing]).unwrap();
        assert_eq!(member.state, State::Unknown);
        assert!(!member.unentered() && !member.known_absent() && !member.child_closed());
        assert!(member
            .enter(&[State::Missing, State::Stopped, State::Running, State::Held])
            .is_err());
        assert!(member.receipt().is_err());
    }
    #[test]
    fn positive_pre_dispatch_refusal_preserves_state_but_ambiguous_return_stays_unknown() {
        for dispatch in [Dispatch::NotDispatched, Dispatch::MayHaveDispatched] {
            let mut member = Member::empty();
            member.state = State::Running;
            member.enter(&[State::Running]).unwrap();
            let result = member.returned::<()>(
                State::Running,
                Err(smolbox_engine::Error {
                    code: smolbox_engine::ErrorCode::State,
                    dispatch,
                }),
            );
            assert!(result.is_err());
            assert_eq!(
                member.state,
                if dispatch == Dispatch::NotDispatched {
                    State::Running
                } else {
                    State::Unknown
                }
            );
        }
    }
    #[test]
    fn controls_are_bounded_and_have_no_process_signal_crash_replay_or_arbitrary_command_action() {
        for action in [
            "status",
            "stop-source",
            "stop-first",
            "stop-held",
            "delete-source",
            "delete-first",
            "delete-held",
            "release-held",
            "qualify-first-absence",
            "qualify-held-absence",
            "release-first-backing",
            "release-held-backing",
            "close-cleaned",
            "close-retained",
            "close-unstarted",
        ] {
            parse_action(action.as_bytes()).unwrap();
        }
        for action in [
            "kill",
            "crash",
            "replay",
            "exec true",
            "start",
            "close",
            "adopt",
            "pause-before-main",
        ] {
            assert!(parse_action(action.as_bytes()).is_err());
        }
        assert!(parse_action(&[b'x'; 65]).is_err());
        assert!(parse_action(&[0xff]).is_err());
    }
    #[test]
    fn typed_backing_builder_matches_frozen_cross_reader_request_bytes() {
        let rows: Vec<Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-backing-release-v1.json"
        ))
        .unwrap();
        for row in rows {
            let original: BranchBackingReleaseRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let built = backing_request(
                original.completion.clone(),
                original.source.clone(),
                original.child.clone(),
                original.operation_id.clone(),
            )
            .unwrap();
            assert_eq!(built.request_sha256, original.request_sha256);
            assert_eq!(serde_json::to_value(built).unwrap(), row["request"]);
        }
    }
}
