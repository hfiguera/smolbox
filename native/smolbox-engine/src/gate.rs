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

/// Acquire distinct names in stable order. A second-lock failure drops the first
/// immediately; no partial source/child exclusion escapes to a caller.
pub(crate) fn lock_pair(
    a: (&str, &Arc<MachineGate>),
    b: (&str, &Arc<MachineGate>),
) -> std::result::Result<[MachineLease; 2], ()> {
    if a.0 == b.0 {
        return Err(());
    }
    let (first, second) = if a.0 < b.0 { (a, b) } else { (b, a) };
    let first = first.1.try_lock()?;
    let second = second.1.try_lock()?;
    Ok([first, second])
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paired_names_lock_in_either_caller_order_and_release_partial_acquisition() {
        let a = Arc::new(MachineGate::default());
        let z = Arc::new(MachineGate::default());
        for reversed in [false, true] {
            let held = z.try_lock().unwrap();
            assert!(if reversed {
                lock_pair(("z", &z), ("a", &a))
            } else {
                lock_pair(("a", &a), ("z", &z))
            }
            .is_err());
            drop(a.try_lock().unwrap()); // The first lock rolled back immediately.
            drop(held);
            let both = if reversed {
                lock_pair(("z", &z), ("a", &a))
            } else {
                lock_pair(("a", &a), ("z", &z))
            }
            .unwrap();
            assert!(a.try_lock().is_err());
            assert!(z.try_lock().is_err());
            drop(both);
            drop((a.try_lock().unwrap(), z.try_lock().unwrap()));
        }
        assert!(lock_pair(("same", &a), ("same", &z)).is_err());
        assert!(lock_pair(("a", &a), ("z", &a)).is_err());
        drop(a.try_lock().unwrap());
    }
}
