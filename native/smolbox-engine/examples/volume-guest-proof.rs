//! Explicit ordinary Linux mounted-guest witness. No default runner selects it.
//! A failure retains its engine until explicit normal cleanup over a private
//! control socket. There are no signals, fault modes or automatic SDK retries.
#[path = "volume_guest/guest.rs"]
mod guest;
#[path = "volume_guest/support.rs"]
mod support;

use serde_json::json;
use smolbox_engine::{
    CreationReceipt, Engine, LocalVolumePolicy, ObservedState, VolumeProvisionReceipt,
};
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;
use support::{budget, read_private, retain_owner, save, ProofResult, Settings};

struct Session {
    engine: Engine,
    policy: LocalVolumePolicy,
    output: PathBuf,
    receipt: Option<CreationReceipt>,
    volumes: Vec<VolumeProvisionReceipt>,
    deleted: Vec<bool>,
    machine_deleted: bool,
    create_entered: bool,
    volume_pending: bool,
    start_entered: bool,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("ordinary mounted-guest proof failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> ProofResult<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() == 3 && args[0] == "control" {
        return control(Path::new(&args[1]), &args[2]);
    }
    if !cfg!(target_os = "linux")
        || args.len() != 3
        || !matches!(args[0].as_str(), "first" | "second" | "cleanup")
    {
        return Err("Linux only: volume-guest-proof first|second|cleanup SETTINGS_JSON OUTPUT | control OUTPUT ACTION".into());
    }
    let settings: Settings = read_private(Path::new(&args[1]))?;
    let output = PathBuf::from(&args[2]);
    support::output(&output, args[0] == "first")?;
    // A fresh socket can never replace a retained owner's control channel.
    let socket = output.join("control.sock");
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    let result = with_owner(&args[0], &settings, &output, &listener);
    // Only this listener created the socket, and with_owner returns only after
    // normal engine shutdown or an error before any engine work was entered.
    drop(listener);
    std::fs::remove_file(socket)?;
    result
}

fn with_owner(
    phase: &str,
    settings: &Settings,
    output: &Path,
    listener: &UnixListener,
) -> ProofResult<()> {
    let engine = support::open(settings)?;
    let mut session = Session {
        engine,
        policy: LocalVolumePolicy {
            id: "ordinary-guest-volume-proof".into(),
            root: LocalVolumePolicy::canonical_sdk_root()?,
        },
        output: output.into(),
        receipt: None,
        volumes: vec![],
        deleted: vec![],
        machine_deleted: false,
        create_entered: false,
        volume_pending: false,
        start_entered: false,
    };
    let result = match phase {
        "first" => guest::first(&mut session, settings),
        "second" => guest::second(&mut session, settings),
        "cleanup" => guest::cleanup(&mut session, settings),
        _ => unreachable!(),
    };
    let result = result.and_then(|mut report| {
        session.close(phase != "first")?;
        report["normal_owner_shutdown"] = json!(true);
        save(&output.join(format!("{phase}-completed.json")), &report)
    });
    match result {
        Ok(()) => {
            println!("ordinary mounted-guest {phase} completed with normal owner shutdown");
            Ok(())
        }
        Err(error) => {
            if save(
                &output.join(format!("{phase}-failure.json")),
                &json!({"phase":phase,"error":error.to_string(),"owner_retained":true}),
            )
            .is_err()
            {
                eprintln!("failure metadata could not be saved; original engine is still retained");
            }
            eprintln!("qualification failed; original engine retained for explicit normal cleanup");
            // Do not unwind the owner after a failed assertion or lost result.
            // Even diagnostic persistence/peer failures cannot release it.
            retain_owner(listener, |stream| handle_control(&mut session, stream));
            Err(error)
        }
    }
}

impl Session {
    fn original(&self) -> ProofResult<&CreationReceipt> {
        self.receipt
            .as_ref()
            .ok_or("no returned original creation receipt; no adoption".into())
    }
    fn stop(&self) -> ProofResult<()> {
        let receipt = self.original()?;
        match self.engine.inspect(receipt)?.state {
            ObservedState::Running | ObservedState::Stopped => {
                if self.engine.stop_with_budget(receipt, &budget()?)?.state
                    != ObservedState::Stopped
                {
                    return Err("normal stop unverified".into());
                }
            }
            ObservedState::Missing => (),
            _ => return Err("machine state cannot authorize normal teardown".into()),
        }
        Ok(())
    }
    fn delete_machine(&mut self) -> ProofResult<()> {
        self.stop()?;
        let receipt = self.original()?;
        if self.engine.inspect(receipt)?.state == ObservedState::Missing {
            if !self.machine_deleted {
                return Err("missing machine without this session's deletion result".into());
            }
            return Ok(());
        }
        if self.engine.delete_with_budget(receipt, &budget()?)?.state != ObservedState::Missing {
            return Err("owned deletion unverified".into());
        }
        self.machine_deleted = true;
        save(
            &self.output.join("machine-deleted.json"),
            &json!({"owned_deleted":true}),
        )?;
        Ok(())
    }
    fn delete_volumes(&mut self) -> ProofResult<()> {
        let unentered = !self.create_entered
            && self.receipt.is_none()
            && self.engine.inventory(&budget()?)?.count == 0;
        if self.volume_pending
            || (!unentered
                && (!self.machine_deleted
                    || self.engine.inspect(self.original()?)?.state != ObservedState::Missing))
        {
            return Err(
                "positive original machine deletion or never-entered creation required".into(),
            );
        }
        for index in 0..self.volumes.len() {
            if self.deleted[index] {
                continue;
            }
            let provision = &self.volumes[index];
            let deletion =
                self.engine
                    .delete_volume(&self.policy, &provision.backing.intent, &budget()?)?;
            if deletion.provision != *provision {
                return Err("volume deletion authority differs".into());
            }
            self.deleted[index] = true;
            save(
                &self.output.join(format!("volume-{index}-deleted.json")),
                &deletion,
            )?;
        }
        Ok(())
    }
    fn close(&self, cleaned: bool) -> ProofResult<()> {
        if !self.engine.available() || self.volume_pending {
            return Err("retained work prevents owner shutdown".into());
        }
        if cleaned
            && !self.create_entered
            && self.receipt.is_none()
            && self.deleted.iter().all(|d| *d)
            && self.engine.inventory(&budget()?)?.count == 0
        {
            if self
                .engine
                .shutdown()
                .iter()
                .any(|(_, outcome)| outcome.is_err())
            {
                return Err("normal pre-creation shutdown incomplete".into());
            }
            return Ok(());
        }
        let state = self.engine.inspect(self.original()?)?.state;
        if cleaned {
            if !self.machine_deleted
                || state != ObservedState::Missing
                || self.deleted.iter().any(|d| !d)
                || self.engine.inventory(&budget()?)?.count != 0
            {
                return Err("original cleanup is incomplete".into());
            }
        } else if state != ObservedState::Stopped {
            return Err("positive stopped state required for replacement".into());
        }
        if self
            .engine
            .shutdown()
            .iter()
            .any(|(_, outcome)| outcome.is_err())
        {
            return Err("normal engine shutdown is incomplete".into());
        }
        Ok(())
    }
    fn close_unstarted(&self) -> ProofResult<()> {
        // This witness only uses create_with_volume_mounts on a local pack.
        // That path prepares storage/records and cannot boot. Unknown creation
        // results remain unknown with every original intent/proof retained.
        // Never use this action after any attempted start or guest dispatch.
        if self.start_entered || !self.engine.available() {
            return Err("start entry or retained work prevents unstarted shutdown".into());
        }
        if self
            .engine
            .shutdown()
            .iter()
            .any(|(_, result)| result.is_err())
        {
            return Err("unstarted actor epoch did not close normally".into());
        }
        Ok(())
    }
}

fn handle_control(session: &mut Session, stream: &mut UnixStream) -> ProofResult<bool> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut action = vec![];
    (&mut *stream).take(65).read_to_end(&mut action)?;
    let action = std::str::from_utf8(&action)?.trim();
    let result = match action {
        "status" => Ok(()),
        "stop" => session.stop(),
        "delete-machine" => session.delete_machine(),
        "delete-volumes" => session.delete_volumes(),
        "close-stopped" => session.close(false),
        "close-cleaned" => session.close(true),
        "close-unstarted" => session.close_unstarted(),
        _ => Err("unknown control action".into()),
    };
    let closed = result.is_ok()
        && matches!(
            action,
            "close-stopped" | "close-cleaned" | "close-unstarted"
        );
    let value = json!({"ok":result.is_ok(),"error":result.err().map(|e|e.to_string()),"available":session.engine.available(),"original_receipt_retained":session.receipt.is_some(),"volume_proofs_retained":session.volumes.len(),"machine_deleted":session.machine_deleted,"volumes_deleted":session.deleted,"closed":closed});
    stream.write_all(&serde_json::to_vec(&value)?)?;
    stream.write_all(b"\n")?;
    Ok(closed)
}

fn control(output: &Path, action: &str) -> ProofResult<()> {
    support::output(output, false)?;
    let mut stream = UnixStream::connect(output.join("control.sock"))?;
    stream.set_read_timeout(Some(Duration::from_secs(40)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    stream.write_all(action.as_bytes())?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut response = vec![];
    stream.take(4097).read_to_end(&mut response)?;
    if response.len() > 4096 {
        return Err("control response exceeded bound".into());
    }
    let value: serde_json::Value = serde_json::from_slice(&response)?;
    println!("{value}");
    if value["ok"] != true {
        return Err("control action did not complete".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    };

    #[test]
    fn malformed_or_failed_control_preserves_owner_until_an_explicit_successful_close() {
        let temp = tempfile::tempdir_in("/tmp").unwrap();
        let path = temp.path().join("control.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let dropped = Arc::new(AtomicBool::new(false));
        let owner = dropped.clone();
        let (notify, receive) = mpsc::channel();
        let thread = std::thread::spawn(move || {
            struct Guard(Arc<AtomicBool>);
            impl Drop for Guard {
                fn drop(&mut self) {
                    self.0.store(true, Ordering::Release);
                }
            }
            let _original_owner = Guard(owner);
            retain_owner(&listener, |stream| {
                let mut message = [0; 1];
                stream.read_exact(&mut message)?;
                let result = match message[0] {
                    0 => Err("malformed control".into()),
                    1 => Ok(false),
                    2 => Ok(true),
                    _ => unreachable!(),
                };
                notify.send(()).unwrap();
                result
            });
        });
        // A normally closed empty peer produces a real socket read error. The
        // next request must still reach the same original retained owner.
        drop(UnixStream::connect(&path).unwrap());
        for action in [0, 1] {
            UnixStream::connect(&path)
                .unwrap()
                .write_all(&[action])
                .unwrap();
            receive.recv_timeout(Duration::from_secs(2)).unwrap();
            assert!(!dropped.load(Ordering::Acquire));
        }
        UnixStream::connect(path).unwrap().write_all(&[2]).unwrap();
        receive.recv_timeout(Duration::from_secs(2)).unwrap();
        thread.join().unwrap();
        assert!(dropped.load(Ordering::Acquire));
    }
}
