//! Owned, movable machine operation guard. Retired transfer collectors must be
//! able to retain this lease without borrowing a caller's stack or BEAM resource.
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Default)]
pub(crate) struct MachineGate(AtomicBool);
pub(crate) struct MachineLease(Arc<MachineGate>);
impl MachineGate {
    pub(crate) fn try_lock(self: &Arc<Self>) -> std::result::Result<MachineLease, ()> {
        self.0
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .map_err(|_| ())?;
        Ok(MachineLease(self.clone()))
    }
}
impl Drop for MachineLease {
    fn drop(&mut self) {
        self.0 .0.store(false, Ordering::Release);
    }
}
