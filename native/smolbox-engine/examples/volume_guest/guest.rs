use super::support::{budget, random, read_private, save, ProofResult, Settings};
use super::Session;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::json;
use sha2::{Digest, Sha256};
use smolbox_engine::{
    ApprovedArtifact, BufferedCommand, Cancellation, Command, CreateRequest, CreationFeatures,
    CreationReceipt, Dispatch, ErrorCode, FileCompletion, FileOptions, LocalVolumeIntent,
    NetworkPolicy, ObservedState, Resources, Stream, TerminalControl, TerminalEvent,
    TerminalMessage, TerminalOptions, TerminalRequest, VolumeMountRequest, VolumeProvisionPresence,
    VolumeProvisionReceipt,
};
use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::rc::Rc;
use std::time::{Duration, Instant};

const RW: &str = "/mnt/volumes/writable";
const RO: &str = "/mnt/volumes/readonly";

fn seed() -> Vec<u8> {
    (0..4096).map(|i| (i % 256) as u8).collect()
}
fn upload() -> Vec<u8> {
    (0..65553).map(|i| (i % 251) as u8).collect()
}

pub fn first(session: &mut Session, settings: &Settings) -> ProofResult<serde_json::Value> {
    if session.engine.inventory(&budget()?)?.count != 0 {
        return Err("fresh witness requires empty SDK inventory".into());
    }
    save(&session.output.join("settings.json"), settings)?;
    drop(
        session
            .engine
            .qualify_volume_root(&session.policy, &budget()?)?,
    );
    for index in 0..2 {
        let intent = LocalVolumeIntent {
            worker_volume_id: format!("sbv-{}", random(16)?),
            size_gb: 1,
        };
        save(
            &session.output.join(format!("volume-{index}-intent.json")),
            &intent,
        )?;
        session.volume_pending = true;
        let proof = session
            .engine
            .provision_volume(&session.policy, &intent, &budget()?)?;
        session.volume_pending = false;
        session.volumes.push(proof.clone());
        session.deleted.push(false);
        save(
            &session
                .output
                .join(format!("volume-{index}-provision.json")),
            &proof,
        )?;
    }
    let readonly = session.volumes[1].node_path();
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o644)
        .open(readonly.join("seed.bin"))?;
    file.write_all(&seed())?;
    file.set_permissions(std::fs::Permissions::from_mode(0o644))?;
    file.sync_all()?;
    std::fs::set_permissions(&readonly, std::fs::Permissions::from_mode(0o755))?;
    let requests = mounts(session);
    let qualified = session
        .engine
        .qualify_volume_mounts(&session.policy, &requests, &budget()?)?;
    let request = CreateRequest {
        name: format!("smolbox-volume-proof-{}", random(8)?),
        owner_token: random(32)?,
        incarnation: random(16)?,
        artifact: ApprovedArtifact {
            path: settings.artifact.clone(),
            sha256: settings.artifact_sha256.clone(),
            max_bytes: 128 * 1024 * 1024,
            guest_platform: "linux/amd64".into(),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        labels: BTreeMap::new(),
    };
    save(
        &session.output.join("machine-intent.json"),
        &json!({"target_id":session.engine.binding().target_id,"generation":session.engine.binding().generation,"name":request.name,"owner_token":request.owner_token,"incarnation":request.incarnation,"artifact_sha256":settings.artifact_sha256,"mounts":requests}),
    )?;
    session.create_entered = true;
    let receipt = session.engine.create_with_volume_mounts(
        request,
        CreationFeatures {
            network: NetworkPolicy {
                enabled: false,
                hosts: vec![],
                cidrs: vec![],
            },
            ports: vec![],
            workload: None,
        },
        qualified,
        Instant::now() + Duration::from_secs(120),
        &Cancellation::new(),
    )?;
    session.receipt = Some(receipt.clone());
    save(&session.output.join("receipt.json"), &receipt)?;
    start(session)?;
    check_io(session, false)?;
    session.stop()?;
    attachment_excludes_delete(session)?;
    Ok(
        json!({"source":"local-container-pack","offline":true,"writable_and_readonly_volumes":true,"commands_streaming_buffered_background_terminal_files":true,"guest_mode_evolution":true,"numeric_nonroot_user":true,"stopped_attachments_exclude_delete":true,"normal_stop":true,"ready_for_normal_owner_replacement":true,"public_volume_admission_enabled":false}),
    )
}

pub fn second(session: &mut Session, settings: &Settings) -> ProofResult<serde_json::Value> {
    let _: serde_json::Value = read_private(&session.output.join("first-completed.json"))?;
    load_original(session, settings)?;
    attachment_excludes_delete(session)?;
    start(session)?;
    check_io(session, true)?;
    session.stop()?;
    attachment_excludes_delete(session)?;
    session.delete_machine()?;
    session.delete_volumes()?;
    Ok(
        json!({"original_receipt_and_volume_proofs":true,"separate_process_stopped_owner_replacement":true,"retained_guest_data":true,"replacement_guest_writes":true,"writable_and_readonly_volumes":true,"commands_streaming_buffered_background_terminal_files":true,"numeric_nonroot_user":true,"guest_mode_evolution":true,"owned_machine_and_volumes_deleted":true,"public_volume_admission_enabled":false,"crash_validation_run":false}),
    )
}

pub fn cleanup(session: &mut Session, settings: &Settings) -> ProofResult<serde_json::Value> {
    load_original(session, settings)?;
    session.delete_machine()?;
    session.delete_volumes()?;
    Ok(
        json!({"explicit_original_cleanup":true,"original_receipt_and_volume_proofs":true,"vm_started_by_cleanup":false,"owned_machine_and_volumes_deleted":true,"guest_qualification_claimed":false}),
    )
}

fn load_original(session: &mut Session, settings: &Settings) -> ProofResult<()> {
    let original: Settings = read_private(&session.output.join("settings.json"))?;
    if serde_json::to_value(original)? != serde_json::to_value(settings)? {
        return Err("original approved settings required".into());
    }
    let receipt: CreationReceipt = read_private(&session.output.join("receipt.json"))?;
    session.receipt = Some(receipt);
    session.create_entered = true;
    session.start_entered = true;
    for index in 0..2 {
        let proof: VolumeProvisionReceipt = read_private(
            &session
                .output
                .join(format!("volume-{index}-provision.json")),
        )?;
        if session.engine.inspect_volume_provision(
            &session.policy,
            &proof.backing.intent,
            &budget()?,
        )? != VolumeProvisionPresence::Provisioned(Box::new(proof.clone()))
        {
            return Err("original protected volume completion differs".into());
        }
        session.volumes.push(proof);
        session.deleted.push(false);
    }
    if session.engine.inspect(session.original()?)?.state != ObservedState::Stopped {
        return Err("positive original stopped state required".into());
    }
    Ok(())
}

fn mounts(session: &Session) -> Vec<VolumeMountRequest> {
    let mut requests = session
        .volumes
        .iter()
        .enumerate()
        .map(|(index, proof)| VolumeMountRequest {
            proof: proof.clone(),
            target: if index == 0 { RW.into() } else { RO.into() },
            readonly: index == 1,
        })
        .collect::<Vec<_>>();
    // Canonical guest-target order is part of the shared engine contract;
    // volume gate order is independently selected by generated volume identity.
    requests.sort_by(|left, right| left.target.cmp(&right.target));
    requests
}

fn start(session: &mut Session) -> ProofResult<()> {
    session.start_entered = true;
    let observed = session.engine.start_with_volume_policy(
        session.original()?,
        &session.policy,
        Instant::now() + Duration::from_secs(120),
        &Cancellation::new(),
    )?;
    if observed.state != ObservedState::Running {
        return Err("mounted guest not observed running".into());
    }
    let configuration = observed
        .configuration
        .ok_or("missing mounted configuration")?;
    if configuration.network.enabled
        || !configuration.ports.is_empty()
        || configuration.mounts.len() != 2
    {
        return Err("mounted/offline SDK configuration differs".into());
    }
    for (actual, expected) in configuration.mounts.iter().zip(mounts(session)) {
        if actual.source
            != expected
                .proof
                .node_path()
                .to_str()
                .ok_or("non-UTF8 backing")?
            || actual.target != expected.target
            || actual.readonly != expected.readonly
            || actual.staged
        {
            return Err("actual SDK mount tuple differs".into());
        }
    }
    attachment_excludes_delete(session)
}

fn attachment_excludes_delete(session: &Session) -> ProofResult<()> {
    for proof in &session.volumes {
        match session.engine.qualify_volume_deletion(
            &session.policy,
            &proof.backing.intent,
            &budget()?,
        ) {
            Err(error)
                if error.code == ErrorCode::Conflict
                    && error.dispatch == Dispatch::NotDispatched => {}
            _ => return Err("retained SDK mount did not exclude volume deletion".into()),
        }
    }
    Ok(())
}

fn command(script: String, user: &str) -> Command {
    Command {
        argv: vec!["python3".into(), "-c".into(), script],
        env: vec![],
        workdir: Some(RW.into()),
        user: Some(user.into()),
        timeout: Duration::from_secs(30),
        max_output_bytes: 65536,
    }
}

fn exec(session: &Session, script: String, user: &str) -> ProofResult<Vec<u8>> {
    let diagnostic_script = script.clone();
    let mut stdout = vec![];
    let mut stderr = vec![];
    let result = session.engine.exec_with_volume_policy(
        session.original()?,
        command(script, user),
        Cancellation::new(),
        |out| {
            let target = if out.stream == Stream::Stdout {
                &mut stdout
            } else {
                &mut stderr
            };
            if target.len() + out.bytes.len() > 65536 {
                return Err(());
            }
            target.extend(out.bytes);
            Ok(())
        },
        &session.policy,
    )?;
    if !result.success() || !stderr.is_empty() {
        save_command_failure(
            &session.output,
            &diagnostic_script,
            user,
            &result,
            &stdout,
            &stderr,
        )?;
        return Err(format!(
            "mounted command failed: {:?}, exit {:?}; stderr bytes={}; bounded diagnostic saved privately",
            result.completion,
            result.observed_exit,
            stderr.len()
        )
        .into());
    }
    Ok(stdout)
}

fn save_command_failure(
    output: &std::path::Path,
    script: &str,
    user: &str,
    outcome: &smolbox_engine::CommandOutcome,
    stdout: &[u8],
    stderr: &[u8],
) -> ProofResult<()> {
    const PREFIX: usize = 16384;
    save(
        &output.join(format!("command-{}-failure.json", random(8)?)),
        &json!({
            "scope":"private-fixed-fixture-guest-command", "fixture_script":script,"guest_user":user,
            "completion":format!("{:?}",outcome.completion),"observed_exit":outcome.observed_exit,
            "stdout_bytes":stdout.len(),"stderr_bytes":stderr.len(),
            "stdout_sha256":hex::encode(Sha256::digest(stdout)),"stderr_sha256":hex::encode(Sha256::digest(stderr)),
            "stdout_prefix_base64":STANDARD.encode(&stdout[..stdout.len().min(PREFIX)]),
            "stderr_prefix_base64":STANDARD.encode(&stderr[..stderr.len().min(PREFIX)]),
            "prefix_limit_bytes":PREFIX,"truncated":stdout.len()>PREFIX || stderr.len()>PREFIX
        }),
    )
}

#[cfg(test)]
mod diagnostic_tests {
    use super::*;
    #[test]
    fn binary_guest_failure_evidence_stays_private_bounded_and_preserves_full_hashes() {
        let root = tempfile::tempdir().unwrap();
        let stdout = vec![0xff; 65536];
        let stderr = vec![0; 65536];
        let outcome = smolbox_engine::CommandOutcome {
            dispatch: Dispatch::MayHaveDispatched,
            completion: smolbox_engine::Completion::Exited,
            observed_exit: Some(1),
            running_observed: false,
            output_bytes: 131072,
        };
        save_command_failure(
            root.path(),
            "fixed fixture",
            "0:0",
            &outcome,
            &stdout,
            &stderr,
        )
        .unwrap();
        let file = std::fs::read_dir(root.path())
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert!(std::fs::metadata(&file).unwrap().len() < 64 * 1024);
        assert_eq!(std::fs::metadata(&file).unwrap().mode() & 0o077, 0);
        let value: serde_json::Value =
            serde_json::from_slice(&std::fs::read(file).unwrap()).unwrap();
        assert_eq!(value["observed_exit"], 1);
        assert_eq!(value["truncated"], true);
        assert_eq!(value["stderr_sha256"], hex::encode(Sha256::digest(&stderr)));
        assert_eq!(
            STANDARD
                .decode(value["stdout_prefix_base64"].as_str().unwrap())
                .unwrap(),
            stdout[..16384]
        );
    }
}

fn file_options(path: String, write: bool) -> FileOptions {
    FileOptions {
        guest_path: path,
        max_bytes: 2 * 1024 * 1024,
        timeout: Duration::from_secs(30),
        mode: write.then_some(0o600),
    }
}

fn check_io(session: &Session, second: bool) -> ProofResult<()> {
    let phase = if second { "second" } else { "first" };
    let script = format!(
        r#"import errno,json,os,pathlib
rw=pathlib.Path('{RW}');ro=pathlib.Path('{RO}')
assert os.getcwd()==str(rw)
assert (ro/'seed.bin').read_bytes()==bytes(range(256))*16
if {second}:
    assert (rw/'guest-first.bin').read_bytes()==bytes(range(256))*16
    assert (rw/'upload-first.bin').read_bytes()==bytes(i%251 for i in range(65553))
(rw/'guest-{phase}.bin').write_bytes(bytes(range(256))*16)
os.chmod(rw,0o755)
(rw/'shared').mkdir(exist_ok=True);os.chmod(rw/'shared',0o777)
workspace=pathlib.Path('/workspace');os.chmod(workspace,0o755)
(workspace/'volume-proof-user').mkdir(exist_ok=True);os.chmod(workspace/'volume-proof-user',0o777)
try:
    (ro/'denied.bin').write_bytes(b'forbidden')
    raise AssertionError('readonly mount allowed a write')
except OSError as e:
    assert e.errno==errno.EROFS
print(json.dumps({{'uid':os.getuid(),'gid':os.getgid(),'readonly_errno':errno.EROFS}}))
"#,
        second = if second { "True" } else { "False" }
    );
    let value: serde_json::Value = serde_json::from_slice(&exec(session, script, "0:0")?)?;
    if value["uid"] != 0 || value["gid"] != 0 || value["readonly_errno"] != libc::EROFS {
        return Err("guest account/readonly witness differs".into());
    }
    for proof in &session.volumes {
        if session.engine.inspect_volume_provision(
            &session.policy,
            &proof.backing.intent,
            &budget()?,
        )? != VolumeProvisionPresence::Provisioned(Box::new(proof.clone()))
            || std::fs::metadata(proof.node_path())?.mode() & 0o7777 != 0o755
        {
            return Err("guest mode evolution changed ownership".into());
        }
    }
    let account = &session.volumes[0].account;
    let mapped_user = format!("{}:{}", account.uid, account.gid);
    let mapped_script = format!("import os,pathlib; assert os.getuid()=={}; assert os.getgid()=={}; assert pathlib.Path('{RO}/seed.bin').read_bytes()==bytes(range(256))*16; pathlib.Path('{RW}/shared/mapped-{phase}').write_text('mapped'); print('numeric-user-ok')",account.uid,account.gid);
    if exec(session, mapped_script, &mapped_user)? != b"numeric-user-ok\n" {
        return Err("mapped numeric guest user differs".into());
    }
    // Plain virtiofs shares enforce the unprivileged server's credential range.
    // Keep unrelated guest-user execution/reads and guest-disk writes positive,
    // while checking the pinned SDK's explicit EPERM for host-volume creation.
    let unrelated = if account.uid != 65534 && account.gid != 65534 {
        65534
    } else {
        65533
    };
    let other_script = format!(
        r#"import errno,json,os,pathlib
assert os.getuid()=={unrelated} and os.getgid()=={unrelated}
assert pathlib.Path('{RO}/seed.bin').read_bytes()==bytes(range(256))*16
pathlib.Path('/workspace/volume-proof-user/unrelated-{phase}').write_text('guest-storage')
try:
    pathlib.Path('{RW}/shared/unrelated-{phase}').write_text('forbidden-unmapped-write')
    raise AssertionError('unexpected unrelated UID/GID write to unprivileged host share')
except OSError as e:
    assert e.errno==errno.EPERM
print(json.dumps({{'uid':os.getuid(),'guest_storage_write':True,'host_volume_errno':errno.EPERM}}))
"#
    );
    let observed: serde_json::Value = serde_json::from_slice(&exec(
        session,
        other_script,
        &format!("{unrelated}:{unrelated}"),
    )?)?;
    if observed["uid"] != unrelated
        || observed["guest_storage_write"] != true
        || observed["host_volume_errno"] != libc::EPERM
    {
        return Err("unrelated guest user/shared-filesystem boundary differs".into());
    }
    let buffered=BufferedCommand {argv:vec!["python3".into(),"-c".into(),format!("import pathlib,sys; s=sys.stdin.read(); assert s=='mounted stdin\\n'; pathlib.Path('{RW}/stdin-{phase}.txt').write_text(s); print('stdin-ok')")],env:vec![],workdir:Some(RW.into()),user:Some("0:0".into()),stdin:Some("mounted stdin\n".into()),timeout:Duration::from_secs(30),max_output_bytes:65536};
    let mut buffered_bytes = vec![];
    let outcome = session.engine.exec_buffered_with_volume_policy(
        session.original()?,
        buffered,
        Cancellation::new(),
        |out| {
            if buffered_bytes.len() + out.bytes.len() > 65536 {
                return Err(());
            }
            buffered_bytes.extend(out.bytes);
            Ok(())
        },
        &session.policy,
    )?;
    if !outcome.success() || buffered_bytes != b"stdin-ok\n" {
        return Err("mounted buffered stdin differs".into());
    }
    let background = BufferedCommand {
        argv: vec![
            "python3".into(),
            "-c".into(),
            format!(
                "import pathlib; pathlib.Path('{RW}/background-{phase}').write_text('launched')"
            ),
        ],
        env: vec![],
        workdir: Some(RW.into()),
        user: Some("0:0".into()),
        stdin: None,
        timeout: Duration::from_secs(30),
        max_output_bytes: 65536,
    };
    let launched = session.engine.exec_background_with_volume_policy(
        session.original()?,
        background,
        Cancellation::new(),
        &session.policy,
    )?;
    if !launched.transfer.success()
        || !launched.transfer.native_acknowledged
        || launched.pid.is_none()
    {
        return Err("mounted background launch lacks acknowledgement".into());
    }
    exec(session,format!("import pathlib,time; p=pathlib.Path('{RW}/background-{phase}'); deadline=time.monotonic()+3\nwhile not p.exists() and time.monotonic()<deadline: time.sleep(0.05)\nassert p.read_text()=='launched'"),"0:0")?;
    let data = upload();
    let write = session.engine.write_file_with_volume_policy(
        session.original()?,
        file_options(format!("{RW}/upload-{phase}.bin"), true),
        &data,
        Cancellation::new(),
        &session.policy,
    )?;
    if !write.success() || !write.native_acknowledged || write.observed_bytes != data.len() as u64 {
        return Err("mounted upload not acknowledged".into());
    }
    for (path, expected) in [
        (format!("{RW}/upload-{phase}.bin"), data),
        (format!("{RO}/seed.bin"), seed()),
    ] {
        let mut bytes = vec![];
        let read = session.engine.read_file_with_volume_policy(
            session.original()?,
            file_options(path, false),
            Cancellation::new(),
            |b| {
                if bytes.len() + b.len() > 2 * 1024 * 1024 {
                    return Err(());
                }
                bytes.extend(b);
                Ok(())
            },
            &session.policy,
        )?;
        if !read.success() || !read.native_acknowledged || bytes != expected {
            return Err("mounted read differs".into());
        }
    }
    let denied = session.engine.write_file_with_volume_policy(
        session.original()?,
        file_options(format!("{RO}/denied-file.bin"), true),
        b"forbidden",
        Cancellation::new(),
        &session.policy,
    )?;
    if denied.completion != FileCompletion::NativeError
        || denied.native_acknowledged
        || !session.engine.available()
        || session.volumes[1]
            .node_path()
            .join("denied-file.bin")
            .exists()
    {
        return Err("readonly file write did not fail as a collected native error".into());
    }
    save(
        &session.output.join(format!("{phase}-pre-terminal-io.json")),
        &json!({"mapped_volume_uid":account.uid,"mapped_volume_gid":account.gid,"unrelated_guest_uid":unrelated,"guest_storage_and_unmapped_EPERM_checked":true,"buffered_stdin_checked":true,"background_launch_and_bytes_checked":true,"binary_upload_and_reads_checked":true,"readonly_file_write_rejected":true,"terminal_checked":false}),
    )?;
    terminal(session)?;
    if std::fs::read(
        session.volumes[0]
            .node_path()
            .join(format!("guest-{phase}.bin")),
    )? != seed()
        || std::fs::read(session.volumes[0].node_path().join("pty.txt"))? != b"mounted-terminal\n"
        || std::fs::read(session.volumes[0].node_path().join("pty-size.txt"))? != b"43 120\n"
    {
        return Err("guest/PTY bytes not observed in original backing".into());
    }
    save(
        &session.output.join(format!("{phase}-io.json")),
        &json!({"guest_root_uid":0,"mapped_volume_uid":account.uid,"mapped_volume_gid":account.gid,"unrelated_guest_uid":unrelated,"unrelated_guest_storage_write_verified":true,"unrelated_host_volume_write_errno":"EPERM","guest_mode":"0755","original_device_inode_uid_gid_preserved":true,"readonly_errno":"EROFS","streaming_command_exit":0,"buffered_stdin_verified":true,"background_launch_and_guest_bytes_observed":true,"background_exit_claimed":false,"upload_bytes":65553,"readonly_binary_read_bytes":4096,"readonly_file_write_rejected":true,"terminal_observed_exit":7,"terminal_resize":{"cols":120,"rows":43},"host_backing_bytes_verified":true}),
    )?;
    Ok(())
}

fn terminal(session: &Session) -> ProofResult<()> {
    let queue = Rc::new(RefCell::new(VecDeque::new()));
    let controls = queue.clone();
    let events = queue.clone();
    let mut output = vec![];
    let outcome=session.engine.terminal_owned_with_volume_policy(session.original()?,TerminalRequest {options:TerminalOptions {program:"/bin/sh".into(),cols:80,rows:24,session:Duration::from_secs(30),idle:Duration::from_secs(10),attach:Duration::from_secs(5),close:Duration::from_secs(2),max_buffer_bytes:65536,max_input_bytes:65536,total_input_bytes:65536},deadline:Instant::now()+Duration::from_secs(30),cancel:Cancellation::new()},move ||Ok(controls.borrow_mut().pop_front()),|event|{
        match event {
            TerminalEvent::Opened=>{events.borrow_mut().push_back(TerminalMessage::Attach);events.borrow_mut().push_back(TerminalMessage::Command(TerminalControl::Resize { cols:120, rows:43 }));events.borrow_mut().push_back(TerminalMessage::Command(TerminalControl::Input(format!("stty -echo\nstty size > {RW}/pty-size.txt; printf 'mounted-terminal\\n' > {RW}/pty.txt; test -r {RO}/seed.bin; printf 'terminal-complete\\n'; exit 7\n").into_bytes())));},
            TerminalEvent::Output(chunk)=>{if output.len()+chunk.bytes.len()>65536 {return Err(());}events.borrow_mut().push_back(TerminalMessage::Consumed {sequence:chunk.sequence,bytes:chunk.bytes.len() as u64});output.extend(chunk.bytes);},
        }Ok(())
    },&session.policy)?;
    let marker = output
        .windows(b"terminal-complete".len())
        .any(|s| s == b"terminal-complete");
    save(
        &session
            .output
            .join(format!("terminal-{}-result.json", random(8)?)),
        &json!({
            "collected":outcome.collected,"dispatch":format!("{:?}",outcome.dispatch),
            "observed_exit":outcome.outcome.observed_exit,"failure":outcome.outcome.failure.map(|value|format!("{value:?}")),
            "completion_marker_observed":marker,"output_bytes":output.len(),"output_sha256":hex::encode(Sha256::digest(&output)),
            "output_prefix_base64":STANDARD.encode(&output[..output.len().min(16384)]),"truncated":output.len()>16384
        }),
    )?;
    if !outcome.collected || outcome.outcome.confirmed_exit() != Some(7) || !marker {
        return Err(format!(
            "mounted terminal result: collected={}, exit={:?}, failure={:?}, marker={marker}",
            outcome.collected, outcome.outcome.observed_exit, outcome.outcome.failure
        )
        .into());
    }
    Ok(())
}
