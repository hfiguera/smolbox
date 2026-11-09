//! Bounded Docker credential-provider observation. The containing owned registry
//! job keeps its admission until the exact direct child and both pipes collect.
//! Providers are trusted operator programs, not a sandbox for arbitrary code.
use crate::{registry_account::Context, Error, ErrorCode, Result};
use serde::Deserialize;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const OUTPUT_BYTES: usize = 128 * 1024;
const STDERR_BYTES: usize = 64 * 1024;
const PROVIDER_TIME: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(5);

pub(crate) fn get(
    helper: &str,
    server: &str,
    context: &Context<'_>,
) -> Result<Option<smolvm::docker_config::DockerCredential>> {
    run(
        Command::new(format!("docker-credential-{helper}")),
        server,
        context,
    )
}

#[derive(Default)]
struct Retirement {
    since: Option<Instant>,
    terminated: bool,
    killed: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Terminate,
    Kill,
    Quarantine,
}
impl Retirement {
    fn enter(&mut self, now: Instant) {
        self.since.get_or_insert(now);
    }
    fn step(&mut self, now: Instant) -> Option<Action> {
        let elapsed = now.saturating_duration_since(self.since?);
        if !self.terminated {
            self.terminated = true;
            Some(Action::Terminate)
        } else if !self.killed && elapsed >= Duration::from_secs(1) {
            self.killed = true;
            Some(Action::Kill)
        } else if elapsed >= Duration::from_secs(2) {
            Some(Action::Quarantine)
        } else {
            None
        }
    }
}

struct Output {
    bytes: Vec<u8>,
    observed: usize,
    maximum: usize,
    eof: bool,
    readable: bool,
    retain: bool,
    blocked: bool,
}
impl Output {
    fn new(fd: i32, maximum: usize, retain: bool) -> Self {
        Self {
            bytes: Vec::new(),
            observed: 0,
            maximum,
            eof: false,
            readable: nonblocking(fd),
            retain,
            blocked: false,
        }
    }
    fn drain(&mut self, reader: &mut impl Read, retired: bool) -> bool {
        if !self.readable || self.eof {
            return self.readable;
        }
        let mut buffer = [0; 8192];
        let mut valid = true;
        self.blocked = false;
        // A continuously writable provider cannot starve deadline observation.
        for _ in 0..4 {
            match reader.read(&mut buffer) {
                Ok(0) => {
                    self.eof = true;
                    break;
                }
                Ok(count) => {
                    self.observed = self.observed.saturating_add(count);
                    if self.observed > self.maximum {
                        valid = false;
                    } else if self.retain && !retired {
                        self.bytes.extend_from_slice(&buffer[..count]);
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    self.blocked = true;
                    break;
                }
                Err(_) => {
                    self.readable = false;
                    return false;
                }
            }
        }
        valid
    }
}

fn nonblocking(fd: i32) -> bool {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == 0
}

fn signal(child: &mut Child, birth: Option<u64>, signal: i32) {
    // A live unreaped direct child cannot have its PID reused. Birth is an
    // additional check; an unavailable identity never authorizes a signal.
    if matches!(child.try_wait(), Ok(None))
        && birth.is_some_and(|birth| {
            smolvm::process::process_start_time(child.id() as i32) == Some(birth)
        })
    {
        unsafe { libc::kill(child.id() as i32, signal) };
    }
}

fn run(
    mut command: Command,
    server: &str,
    context: &Context<'_>,
) -> Result<Option<smolvm::docker_config::DockerCredential>> {
    if context.cancel.is_cancelled()
        || Instant::now() >= context.deadline
        || !context.pool.available()
    {
        return Err(Error::before(ErrorCode::State));
    }
    if server.is_empty() || server.len() > 2048 || server.contains(['\n', '\r', '\0']) {
        return Err(Error::before(ErrorCode::Validation));
    }
    let deadline = context.deadline.min(Instant::now() + PROVIDER_TIME);
    // No credential is put in argv or added to the inherited environment.
    let Ok(mut child) = command
        .arg("get")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    else {
        return Ok(None); // SDK-compatible missing-provider inline fallback.
    };
    let birth = smolvm::process::process_start_time(child.id() as i32);
    let (Some(input), Some(mut output), Some(mut error)) =
        (child.stdin.take(), child.stdout.take(), child.stderr.take())
    else {
        // A spawned child is never dropped while its collection is uncertain.
        context.pool.quarantine();
        Box::leak(Box::new(child));
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    };
    let writable = nonblocking(input.as_raw_fd());
    let mut stdout = Output::new(output.as_raw_fd(), OUTPUT_BYTES, true);
    let mut stderr = Output::new(error.as_raw_fd(), STDERR_BYTES, false);
    let mut input = Some(input);
    let mut sent = 0;
    let mut failure = if writable && stdout.readable && stderr.readable {
        None
    } else {
        Some(ErrorCode::Io)
    };
    let mut retirement = Retirement::default();
    let mut status = None;
    let mut exited_at = None;
    loop {
        let now = Instant::now();
        if context.cancel.is_cancelled() || now >= deadline {
            failure.get_or_insert(ErrorCode::State);
        }
        if failure.is_none() && sent < server.len() {
            if let Some(pipe) = input.as_mut() {
                match pipe.write(&server.as_bytes()[sent..]) {
                    Ok(0) => {
                        failure = Some(ErrorCode::Io);
                    }
                    Ok(count) => {
                        sent += count;
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                        ) => {}
                    Err(_) => {
                        failure = Some(ErrorCode::Io);
                    }
                }
            }
        }
        if sent == server.len() || failure.is_some() {
            input.take();
        }
        let stdout_valid = stdout.drain(&mut output, failure.is_some());
        let stderr_valid = stderr.drain(&mut error, failure.is_some());
        if !stdout_valid || !stderr_valid {
            failure.get_or_insert(ErrorCode::OutputLimit);
        }
        if status.is_none() {
            match child.try_wait() {
                Ok(Some(result)) => {
                    status = Some(result);
                    exited_at = Some(now);
                }
                Ok(None) => {}
                Err(_) => {
                    failure.get_or_insert(ErrorCode::Native);
                    context.pool.quarantine();
                }
            }
        }
        if let Some(status) = status {
            if stdout.eof && stderr.eof {
                if !context.pool.available() {
                    return Err(Error::uncertain(ErrorCode::State));
                }
                if failure.is_some() {
                    // Provider-local errors can fall back, but an expired or
                    // cancelled operation cannot dispatch registry traffic.
                    return if context.cancel.is_cancelled() || Instant::now() >= context.deadline {
                        Err(Error::before(ErrorCode::State))
                    } else {
                        Ok(None)
                    };
                }
                return Ok(reply(
                    status.success() && sent == server.len(),
                    &stdout.bytes,
                ));
            }
            if exited_at.is_some_and(|exit| now.duration_since(exit) >= POLL * 2)
                && ((!stdout.eof && stdout.blocked) || (!stderr.eof && stderr.blocked))
            {
                // A descendant writer is not collection evidence. Retain the
                // enclosing job/lease until both bounded pipes close; never
                // signal an unowned descendant or promote a late credential.
                failure.get_or_insert(ErrorCode::Native);
                context.pool.quarantine();
            }
        }
        if failure.is_some() {
            retirement.enter(now);
            match retirement.step(now) {
                Some(Action::Terminate) if status.is_none() => {
                    signal(&mut child, birth, libc::SIGTERM)
                }
                Some(Action::Kill) if status.is_none() => signal(&mut child, birth, libc::SIGKILL),
                Some(Action::Quarantine) => context.pool.quarantine(),
                _ => {}
            }
        }
        std::thread::sleep(POLL);
    }
}

fn reply(success: bool, bytes: &[u8]) -> Option<smolvm::docker_config::DockerCredential> {
    #[derive(Deserialize)]
    struct Reply {
        #[serde(rename = "Username", default)]
        username: String,
        #[serde(rename = "Secret", default)]
        secret: String,
    }
    if !success || bytes.len() > OUTPUT_BYTES {
        return None;
    }
    let reply: Reply = serde_json::from_slice(bytes).ok()?;
    if reply.username.is_empty() || reply.secret.is_empty() {
        return None;
    }
    Some(smolvm::docker_config::DockerCredential {
        username: reply.username,
        secret: reply.secret,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        jobs::{Demand, JobPool},
        Cancellation,
    };
    use std::io::Cursor;
    use std::os::unix::fs::PermissionsExt;

    fn output(maximum: usize, retain: bool) -> Output {
        Output {
            bytes: Vec::new(),
            observed: 0,
            maximum,
            eof: false,
            readable: true,
            retain,
            blocked: false,
        }
    }

    #[test]
    fn output_bounds_discard_stderr_and_never_promote_retired_bytes() {
        let mut reader = Cursor::new(vec![b'x'; OUTPUT_BYTES + 1]);
        let mut capture = output(OUTPUT_BYTES, true);
        let mut valid = true;
        while !capture.eof {
            valid &= capture.drain(&mut reader, false);
        }
        assert!(!valid);
        assert!(capture.bytes.len() <= OUTPUT_BYTES);
        let mut capture = output(STDERR_BYTES, false);
        assert!(capture.drain(&mut Cursor::new(b"private provider diagnostic"), false));
        assert!(capture.bytes.is_empty());
        let mut capture = output(OUTPUT_BYTES, true);
        assert!(capture.drain(&mut Cursor::new(b"late-private"), true));
        assert!(capture.bytes.is_empty());
    }

    #[test]
    fn descendant_pipe_model_distinguishes_blocked_writer_from_finite_buffer() {
        struct Pending;
        impl Read for Pending {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                Err(std::io::ErrorKind::WouldBlock.into())
            }
        }
        let mut capture = output(OUTPUT_BYTES, true);
        assert!(capture.drain(&mut Cursor::new(vec![0; 65536]), false));
        assert!(!capture.eof && !capture.blocked); // finite batch still pending
        assert!(capture.drain(&mut Pending, true));
        assert!(!capture.eof && capture.blocked); // no collection/credential proof
    }

    #[test]
    fn retirement_model_has_finite_signals_and_never_grants_collection() {
        let origin = Instant::now();
        let mut policy = Retirement::default();
        assert_eq!(policy.step(origin), None);
        policy.enter(origin);
        assert_eq!(policy.step(origin), Some(Action::Terminate));
        assert_eq!(policy.step(origin), None);
        policy.enter(origin + Duration::from_millis(500));
        assert_eq!(
            policy.step(origin + Duration::from_secs(1)),
            Some(Action::Kill)
        );
        assert_eq!(
            policy.step(origin + Duration::from_secs(2)),
            Some(Action::Quarantine)
        );
        assert_eq!(
            policy.step(origin + Duration::from_secs(3)),
            Some(Action::Quarantine)
        );
        assert!(policy.since.is_some()); // no release action exists
    }

    #[test]
    fn malformed_nonzero_and_empty_replies_never_yield_credentials() {
        let valid = br#"{"Username":"user","Secret":"private"}"#;
        assert!(reply(false, valid).is_none());
        assert!(reply(true, b"private diagnostic").is_none());
        assert!(reply(true, br#"{"Username":"user","Secret":""}"#).is_none());
        assert_eq!(reply(true, valid).unwrap().secret, "private");
    }

    #[test]
    fn ordinary_provider_success_and_missing_entry_collect_normally_with_reserved_child() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("provider");
        let pool = JobPool::default();
        let permit = pool.acquire(Demand::oci_metadata()).unwrap();
        assert_eq!(pool.counts().children, 1);
        let cancel = Cancellation::new();
        let context = Context {
            deadline: Instant::now() + Duration::from_secs(10),
            cancel: &cancel,
            pool: &pool,
        };
        for (exit, expected) in [(0, true), (1, false)] {
            std::fs::write(&path, format!("#!/bin/sh\nIFS= read -r server || :\n[ \"$server\" = registry.example ] && [ \"$1\" = get ] || exit 2\nprintf '%s' '{{\"Username\":\"user\",\"Secret\":\"private\"}}'\nprintf '%s' 'private stderr' >&2\nexit {exit}\n")).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
            let result = run(Command::new(&path), "registry.example", &context).unwrap();
            assert_eq!(result.is_some(), expected);
            assert!(pool.available());
            assert_eq!(pool.counts().children, 1); // original job still owns admission
        }
        drop(permit);
        assert_eq!(pool.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn pre_cancelled_provider_never_spawns_or_changes_admission() {
        let pool = JobPool::default();
        let permit = pool.acquire(Demand::registry_download(1).unwrap()).unwrap();
        let before = pool.counts();
        let cancel = Cancellation::new();
        cancel.cancel();
        let context = Context {
            deadline: Instant::now() + Duration::from_secs(1),
            cancel: &cancel,
            pool: &pool,
        };
        assert!(run(Command::new("never-executed"), "registry.example", &context).is_err());
        assert_eq!(pool.counts(), before);
        assert!(pool.available());
        drop(permit);
    }

    #[test]
    fn ordinary_large_escaped_reply_drains_before_collecting_without_quarantine() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("provider");
        let secret = "\\u0078".repeat(16000);
        std::fs::write(&path, format!("#!/bin/sh\nIFS= read -r server || :\nprintf '%s' '{{\"Username\":\"user\",\"Secret\":\"{secret}\"}}'\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let pool = JobPool::default();
        let _permit = pool.acquire(Demand::oci_metadata()).unwrap();
        let cancel = Cancellation::new();
        let context = Context {
            deadline: Instant::now() + Duration::from_secs(10),
            cancel: &cancel,
            pool: &pool,
        };
        let credential = run(Command::new(&path), "registry.example", &context)
            .unwrap()
            .unwrap();
        assert_eq!(credential.secret, "x".repeat(16000));
        assert!(pool.available());
    }
}
