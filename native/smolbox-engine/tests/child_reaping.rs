//! The SDK reaper must leave exit status collection to unrelated subprocesses.
//! Children exit normally after a pipe release; no VM or signal is involved.
#![cfg(target_os = "linux")]

use std::io::Write;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

fn child(exit: u8) -> Child {
    Command::new("/bin/sh")
        .args(["-c", &format!("read release; exit {exit}")])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap()
}

fn exited(child: &mut Child) {
    child.stdin.take().unwrap().write_all(b"release\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        // Observe without consuming wait status, so the reaper remains exercised.
        let stat = std::fs::read_to_string(format!("/proc/{}/stat", child.id())).unwrap();
        if stat.rsplit_once(") ").unwrap().1.starts_with('Z') {
            return;
        }
        assert!(Instant::now() < deadline, "released child did not exit");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn registered_children_are_reaped_without_stealing_sibling_status() {
    for _ in 0..32 {
        let mut owned = child(23);
        let mut sibling = child(31);
        smolvm::process::register_vm_child(owned.id() as i32, None);
        smolvm::process::register_vm_child(i32::MAX, None); // Never our child: ECHILD.
        smolvm::process::reap_vm_children();
        assert!(owned.try_wait().unwrap().is_none());
        exited(&mut sibling);
        exited(&mut owned);
        smolvm::process::reap_vm_children();
        assert_eq!(owned.wait().unwrap_err().raw_os_error(), Some(libc::ECHILD));
        assert_eq!(sibling.wait().unwrap().code(), Some(31));
        smolvm::process::reap_vm_children(); // A second sweep cannot consume a sibling.
    }
}
