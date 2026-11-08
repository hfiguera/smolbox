//! Bounded owner-process agent exchanges shared by branch initialization/release.
use crate::{Error, ErrorCode, ReadBudget, Result};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

pub(crate) fn exchange<T>(
    socket: &Path,
    staging: &Path,
    output_bytes: u64,
    budget: &ReadBudget,
    action: impl FnOnce(&mut smolvm::agent::AgentClient, Duration) -> Result<T>,
) -> Result<T> {
    budget.check()?;
    let original_stage = crate::export_source::Root::open(staging)?;
    // Owner-process calls cannot change CWD as workers do. Keep the relay
    // endpoint short even when the admitted domain path exceeds sockaddr_un.
    // This private temporary directory carries no SDK or durable authority.
    let temporary_root = std::path::Path::new("/tmp")
        .canonicalize()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let socket_directory = tempfile::Builder::new()
        .prefix("sbx-branch-")
        .permissions(std::fs::Permissions::from_mode(0o700))
        .tempdir_in(temporary_root)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let socket_root = crate::export_source::Root::open(socket_directory.path())?;
    let mut agent =
        crate::agent_io::BoundedAgent::connect_in(socket, output_bytes, socket_directory.path())?;
    let _deadline = Deadline::new(agent.stopper(), budget)?;
    original_stage.verify()?;
    socket_root.verify()?;
    let remaining = budget
        .deadline
        .saturating_duration_since(std::time::Instant::now());
    if remaining.is_zero() {
        return Err(Error::uncertain(ErrorCode::State));
    }
    let result = action(&mut agent.client, remaining)?;
    budget.check().map_err(|e| Error::uncertain(e.code))?;
    if agent.limited() {
        return Err(Error::uncertain(ErrorCode::Admission));
    }
    original_stage
        .verify()
        .map_err(|e| Error::uncertain(e.code))?;
    socket_root.verify().map_err(|e| Error::uncertain(e.code))?;
    Ok(result)
}

struct Deadline {
    done: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Deadline {
    fn new(stopper: crate::agent_io::Stopper, budget: &ReadBudget) -> Result<Self> {
        budget.check()?;
        let done = Arc::new(AtomicBool::new(false));
        let finished = done.clone();
        let budget = budget.clone();
        let thread = std::thread::Builder::new()
            .name("smolbox-branch-agent-budget".into())
            .spawn(move || {
                while !finished.load(Ordering::Acquire) {
                    if budget.check().is_err() {
                        stopper.stop();
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
            })
            .map_err(|_| Error::before(ErrorCode::Native))?;
        Ok(Self {
            done,
            thread: Some(thread),
        })
    }
}
impl Drop for Deadline {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
