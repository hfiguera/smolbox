//! Engine-wide native admission. Leases belong to the executing/collecting job,
//! not a Port request or bridge. No timeout or cancellation releases a lease.
use crate::{Error, ErrorCode, Result};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const JOB_WORK_SLOTS: usize = 4;
pub const JOB_CONTROL_SLOTS: usize = 2;
pub const JOB_CHILDREN: usize = 4;
pub const JOB_STAGING_BYTES: u64 = 64 * 1024 * 1024;
pub const JOB_METADATA_BYTES: u64 = 32 * 1024 * 1024;
pub const JOB_DESCRIPTORS: usize = 32;
pub const JOB_CONTROL_HEADROOM: usize = 8;

#[derive(Clone, Copy)]
enum Lane {
    Work,
    Control,
}
#[derive(Clone, Copy)]
pub(crate) struct Demand {
    lane: Lane,
    children: usize,
    descriptors: usize,
    staging: u64,
    metadata: u64,
}
impl Demand {
    pub(crate) fn terminal(options: &crate::TerminalOptions, metadata: u64) -> Result<Self> {
        options.validate()?;
        if metadata == 0 || metadata > crate::COMMAND_METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            lane: Lane::Work,
            children: 1,
            descriptors: 20,
            staging: options.total_input_bytes * 3,
            metadata: metadata + options.max_buffer_bytes * 4 + 8 * 1024 * 1024,
        })
    }
    pub(crate) fn transfer(bytes: u64) -> Result<Self> {
        if bytes == 0 || bytes > 16 * 1024 * 1024 {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            lane: Lane::Work,
            children: 1,
            descriptors: 4,
            staging: bytes,
            metadata: 0,
        })
    }
    pub(crate) fn command(output: u64, metadata: u64) -> Result<Self> {
        if output == 0
            || output > 16 * 1024 * 1024
            || metadata == 0
            || metadata > crate::buffered::COMMAND_METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            lane: Lane::Work,
            children: 1,
            descriptors: 6,
            staging: output,
            metadata,
        })
    }
    pub(crate) fn streaming() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 4,
            staging: 0,
            metadata: 0,
        }
    }
    pub(crate) fn logs() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 2,
            staging: 0,
            metadata: crate::logs::LOG_MEMORY_BYTES,
        }
    }
    pub(crate) fn observation() -> Self {
        Self {
            lane: Lane::Control,
            children: 0,
            descriptors: 4,
            staging: 0,
            metadata: 0,
        }
    }
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Counts {
    pub work: usize,
    pub control: usize,
    pub children: usize,
    pub descriptors: usize,
    pub work_descriptors: usize,
    pub staging: u64,
    pub metadata: u64,
}
#[derive(Default)]
struct Shared {
    counts: Mutex<Counts>,
    quarantined: AtomicBool,
}
#[derive(Clone, Default)]
pub(crate) struct JobPool(Arc<Shared>);
pub(crate) struct JobLease {
    pool: JobPool,
    demand: Demand,
}
impl JobPool {
    pub(crate) fn available(&self) -> bool {
        !self.0.quarantined.load(Ordering::Acquire)
    }
    pub(crate) fn quarantine(&self) {
        self.0.quarantined.store(true, Ordering::Release);
    }
    pub(crate) fn acquire(&self, demand: Demand) -> Result<JobLease> {
        let mut counts = self
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
        if demand.children > JOB_CHILDREN
            || demand.descriptors > JOB_DESCRIPTORS
            || demand.staging > JOB_STAGING_BYTES
            || demand.metadata > JOB_METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        let (work, control) = match demand.lane {
            Lane::Work => (counts.work + 1, counts.control),
            Lane::Control => (counts.work, counts.control + 1),
        };
        let next = Counts {
            work,
            control,
            children: counts.children + demand.children,
            descriptors: counts.descriptors + demand.descriptors,
            work_descriptors: counts.work_descriptors
                + match demand.lane {
                    Lane::Work => demand.descriptors,
                    Lane::Control => 0,
                },
            staging: counts.staging + demand.staging,
            metadata: counts.metadata + demand.metadata,
        };
        if next.work > JOB_WORK_SLOTS
            || next.control > JOB_CONTROL_SLOTS
            || next.children > JOB_CHILDREN
            || next.descriptors > JOB_DESCRIPTORS
            || next.work_descriptors > JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            || next.staging > JOB_STAGING_BYTES
            || next.metadata > JOB_METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        fd_admission(next.descriptors)?;
        *counts = next;
        Ok(JobLease {
            pool: self.clone(),
            demand,
        })
    }
    #[cfg(test)]
    pub(crate) fn counts(&self) -> Counts {
        *self.0.counts.lock().unwrap()
    }
}
impl Drop for JobLease {
    fn drop(&mut self) {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        match self.demand.lane {
            Lane::Work => {
                counts.work -= 1;
                counts.work_descriptors -= self.demand.descriptors;
            }
            Lane::Control => counts.control -= 1,
        }
        counts.children -= self.demand.children;
        counts.descriptors -= self.demand.descriptors;
        counts.staging -= self.demand.staging;
        counts.metadata -= self.demand.metadata;
    }
}
fn fd_admission(reserved: usize) -> Result<()> {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        return Err(Error::before(ErrorCode::Io));
    }
    let path = if cfg!(target_os = "linux") {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    };
    let used = std::fs::read_dir(path)
        .map_err(|_| Error::before(ErrorCode::Io))?
        .count() as u64;
    // Count existing descriptors as well as all outstanding reservations. This
    // is conservative when an older job has already opened its reserved FDs.
    if used.saturating_add((JOB_CONTROL_HEADROOM + reserved) as u64) > limit.rlim_cur {
        return Err(Error::before(ErrorCode::Admission));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn terminal_reserves_peak_memory_child_and_descriptors_without_starving_observations() {
        let options = crate::TerminalOptions {
            program: "/bin/sh".into(),
            cols: 80,
            rows: 24,
            session: std::time::Duration::from_secs(30),
            idle: std::time::Duration::from_secs(30),
            attach: std::time::Duration::from_secs(5),
            close: std::time::Duration::from_secs(1),
            max_buffer_bytes: 1_048_576,
            max_input_bytes: 65536,
            total_input_bytes: crate::TERMINAL_INPUT_BYTES,
        };
        let pool = JobPool::default();
        let terminal = pool
            .acquire(Demand::terminal(&options, 8 * 1024 * 1024).unwrap())
            .unwrap();
        let before = pool.counts();
        assert_eq!(before.children, 1);
        assert_eq!(before.work_descriptors, 20);
        assert_eq!(before.staging, 48 * 1024 * 1024);
        assert_eq!(before.metadata, 20 * 1024 * 1024);
        assert!(pool
            .acquire(Demand::terminal(&options, 1).unwrap())
            .is_err());
        let file = pool.acquire(Demand::transfer(1).unwrap()).unwrap();
        assert!(pool.acquire(Demand::transfer(1).unwrap()).is_err());
        let observations = [
            pool.acquire(Demand::observation()).unwrap(),
            pool.acquire(Demand::observation()).unwrap(),
        ];
        assert_eq!(pool.counts().descriptors, 32);
        drop(observations);
        drop(file);
        drop(terminal);
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn log_buffers_share_metadata_and_work_admission_without_consuming_observation_slots() {
        let pool = JobPool::default();
        let mut leases = Vec::new();
        for _ in 0..3 {
            leases.push(
                pool.acquire(Demand::command(16 * 1024 * 1024, 8 * 1024 * 1024).unwrap())
                    .unwrap(),
            );
        }
        leases.push(pool.acquire(Demand::logs()).unwrap());
        let before = pool.counts();
        assert_eq!(before.metadata, 30 * 1024 * 1024);
        assert_eq!(before.work, 4);
        assert!(pool.acquire(Demand::logs()).is_err());
        assert_eq!(pool.counts(), before);
        let first = pool.acquire(Demand::observation()).unwrap();
        let second = pool.acquire(Demand::observation()).unwrap();
        drop((leases, first, second));
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn four_command_workers_charge_metadata_output_and_descriptors_without_consuming_observation_slots(
    ) {
        let pool = JobPool::default();
        let leases = (0..4)
            .map(|_| {
                pool.acquire(Demand::command(16 * 1024 * 1024, 8 * 1024 * 1024).unwrap())
                    .unwrap()
            })
            .collect::<Vec<_>>();
        let controls = [
            pool.acquire(Demand::observation()).unwrap(),
            pool.acquire(Demand::observation()).unwrap(),
        ];
        assert_eq!(pool.counts().metadata, JOB_METADATA_BYTES);
        assert_eq!(pool.counts().staging, JOB_STAGING_BYTES);
        assert_eq!(pool.counts().descriptors, JOB_DESCRIPTORS);
        assert_eq!(pool.counts().children, 4);
        assert!(pool.acquire(Demand::command(1, 1).unwrap()).is_err());
        drop(leases);
        drop(controls);
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn transfers_and_streams_share_work_admission_while_control_remains_independent() {
        let pool = JobPool::default();
        let mut leases = vec![pool.acquire(Demand::streaming()).unwrap()];
        for _ in 0..3 {
            leases.push(
                pool.acquire(Demand::transfer(16 * 1024 * 1024).unwrap())
                    .unwrap(),
            );
        }
        assert_eq!(
            pool.acquire(Demand::streaming()).err().unwrap().code,
            ErrorCode::Admission
        );
        let control = [
            pool.acquire(Demand::observation()).unwrap(),
            pool.acquire(Demand::observation()).unwrap(),
        ];
        assert_eq!(
            pool.acquire(Demand::observation()).err().unwrap().code,
            ErrorCode::Admission
        );
        assert_eq!(
            pool.counts(),
            Counts {
                work: 4,
                control: 2,
                children: 3,
                descriptors: 24,
                work_descriptors: 16,
                staging: 48 * 1024 * 1024,
                metadata: 0,
            }
        );
        drop(leases);
        drop(control);
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn a_collector_retains_all_reservations_and_collection_does_not_restore_quarantined_admission()
    {
        let pool = JobPool::default();
        let lease = pool
            .acquire(Demand::transfer(16 * 1024 * 1024).unwrap())
            .unwrap();
        pool.quarantine();
        assert!(!pool.available());
        assert_eq!(pool.counts().children, 1);
        assert_eq!(pool.counts().staging, 16 * 1024 * 1024);
        assert_eq!(
            pool.acquire(Demand::observation()).err().unwrap().code,
            ErrorCode::State
        );
        drop(lease);
        assert_eq!(pool.counts(), Counts::default());
        assert!(!pool.available());
    }
    #[test]
    fn failed_admission_never_increments_counters() {
        let pool = JobPool::default();
        assert!(Demand::transfer(0).is_err());
        let demand = Demand {
            lane: Lane::Work,
            children: JOB_CHILDREN + 1,
            descriptors: 1,
            staging: 0,
            metadata: 0,
        };
        assert_eq!(
            pool.acquire(demand).err().unwrap().code,
            ErrorCode::Admission
        );
        assert_eq!(pool.counts(), Counts::default());
    }
}
