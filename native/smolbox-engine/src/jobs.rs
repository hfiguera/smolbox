//! Engine-wide native admission. Leases belong to the executing/collecting job,
//! not a Port request or bridge. No timeout or cancellation releases a lease.
use crate::{Error, ErrorCode, Result};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const JOB_WORK_SLOTS: usize = 4;
pub const JOB_CONTROL_SLOTS: usize = 2;
pub const JOB_CHILDREN: usize = 4;
pub const JOB_STAGING_BYTES: u64 = 64 * 1024 * 1024;
/// Separate finite host artifact-download allowance; not guest disk authority.
pub const JOB_REGISTRY_STAGING_BYTES: u64 = 32 * 1024 * 1024 * 1024;
/// Work metadata allowance. Reserved control memory is independent.
pub const JOB_METADATA_BYTES: u64 = 32 * 1024 * 1024;
/// Two bounded volume observers remain admissible with full work metadata.
pub const JOB_CONTROL_METADATA_BYTES: u64 = 256 * 1024;
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
    registry_staging: u64,
    metadata: u64,
}
impl Demand {
    pub(crate) fn volume_mounts(count: usize) -> Result<Self> {
        if count == 0 || count > crate::VOLUME_MOUNTS {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 12 + count,
            staging: 0,
            registry_staging: 0,
            metadata: crate::VOLUME_OBSERVATION_METADATA_BYTES * (count as u64 + 1),
        })
    }

    pub(crate) fn volume_delete() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 8,
            staging: 0,
            registry_staging: 0,
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn volume_observation() -> Self {
        Self {
            lane: Lane::Control,
            children: 0,
            descriptors: 4,
            staging: 0,
            registry_staging: 0,
            // Two bounded records, decoded identities, read buffers and root
            // policy copies coexist; observation still consumes no work slot.
            metadata: crate::VOLUME_OBSERVATION_METADATA_BYTES,
        }
    }

    pub(crate) fn volume_root() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 4,
            staging: 0,
            registry_staging: 0,
            // Root qualification also enters staging/provisioning: reserve
            // bounded private-record and identity copies for that whole job.
            metadata: crate::VOLUME_OBSERVATION_METADATA_BYTES,
        }
    }

    pub(crate) fn registry_download(bytes: u64) -> Result<Self> {
        if bytes == 0 || bytes > JOB_REGISTRY_STAGING_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 16,
            staging: 0,
            registry_staging: bytes,
            metadata: JOB_METADATA_BYTES,
        })
    }

    pub(crate) fn oci_metadata() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 12,
            registry_staging: 0,
            staging: 0,
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn oci_start() -> Self {
        Self {
            lane: Lane::Work,
            children: 2, // the enrolled VMM and the agent bootstrap worker
            // Launch and bootstrap are sequential. Retained manager handles
            // coexist with the bootstrap's 21-descriptor demand.
            descriptors: 24,
            registry_staging: 0,
            staging: 1,
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn oci_create() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 12,
            registry_staging: 0,
            staging: 0,
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn image_pull() -> Self {
        Self {
            lane: Lane::Work,
            children: 1,
            descriptors: 21,
            registry_staging: 0,
            staging: 1,
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn images() -> Self {
        Self {
            lane: Lane::Work,
            children: 1,
            descriptors: 20,
            registry_staging: 0,
            staging: crate::images::IMAGE_OUTPUT_BYTES,
            // Header payload, bounded projection, normalized SDK response and
            // typed result coexist with relay/watch/collector stack headroom.
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn growth_repair() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 10,
            registry_staging: 0,
            staging: 0,
            // Qualification loads/stages the bounded journal as well as disk
            // scans. Reserve the whole metadata pool; control stays independent.
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn growth(metadata: u64) -> Result<Self> {
        if metadata == 0 || metadata > crate::growth::METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            lane: Lane::Work,
            children: 1,
            // Parent/worker disk + directory descriptors, source flock, two
            // spools, pipes, one backing-chain reader and worker stdio/scratch
            // opens. Keep the separate
            // control headroom available.
            descriptors: 21,
            registry_staging: 0,
            staging: 1,
            // Parser buffers plus owner-watch/retained-collector stack headroom.
            metadata: metadata + 8 * 1024 * 1024 + crate::qcow_geometry::MEMORY_BYTES,
        })
    }
    pub(crate) fn terminal(options: &crate::TerminalOptions, metadata: u64) -> Result<Self> {
        options.validate()?;
        if metadata == 0 || metadata > crate::COMMAND_METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            lane: Lane::Work,
            children: 1,
            descriptors: 20,
            registry_staging: 0,
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
            registry_staging: 0,
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
            registry_staging: 0,
            staging: output,
            metadata,
        })
    }
    pub(crate) fn streaming() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 4,
            registry_staging: 0,
            staging: 0,
            metadata: 0,
        }
    }
    pub(crate) fn logs() -> Self {
        Self {
            lane: Lane::Work,
            children: 0,
            descriptors: 2,
            registry_staging: 0,
            staging: 0,
            metadata: crate::logs::LOG_MEMORY_BYTES,
        }
    }
    pub(crate) fn observation() -> Self {
        Self {
            lane: Lane::Control,
            children: 0,
            descriptors: 4,
            registry_staging: 0,
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
    pub registry_staging: u64,
    pub metadata: u64,
    pub work_metadata: u64,
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
        // Quarantine fences work, not truthful read-only observations. Control
        // remains subject to its own slots, aggregate FDs and OS admission.
        if !self.available() && matches!(demand.lane, Lane::Work) {
            return Err(Error::before(ErrorCode::State));
        }
        if demand.children > JOB_CHILDREN
            || demand.descriptors > JOB_DESCRIPTORS
            || demand.registry_staging > JOB_REGISTRY_STAGING_BYTES
            || demand.staging > JOB_STAGING_BYTES
            || demand.metadata
                > match demand.lane {
                    Lane::Work => JOB_METADATA_BYTES,
                    Lane::Control => JOB_CONTROL_METADATA_BYTES,
                }
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
            registry_staging: counts.registry_staging + demand.registry_staging,
            staging: counts.staging + demand.staging,
            metadata: counts.metadata + demand.metadata,
            work_metadata: counts.work_metadata
                + match demand.lane {
                    Lane::Work => demand.metadata,
                    Lane::Control => 0,
                },
        };
        if next.work > JOB_WORK_SLOTS
            || next.control > JOB_CONTROL_SLOTS
            || next.children > JOB_CHILDREN
            || next.descriptors > JOB_DESCRIPTORS
            || next.work_descriptors > JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            || next.registry_staging > JOB_REGISTRY_STAGING_BYTES
            || next.staging > JOB_STAGING_BYTES
            || next.work_metadata > JOB_METADATA_BYTES
            || next.metadata - next.work_metadata > JOB_CONTROL_METADATA_BYTES
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
                counts.work_metadata -= self.demand.metadata;
            }
            Lane::Control => counts.control -= 1,
        }
        counts.children -= self.demand.children;
        counts.descriptors -= self.demand.descriptors;
        counts.registry_staging -= self.demand.registry_staging;
        counts.staging -= self.demand.staging;
        counts.metadata -= self.demand.metadata;
    }
}

impl JobLease {
    /// Promote retained mount qualification to one complete creation job without
    /// dropping authority or transiently freeing admission for another worker.
    pub(crate) fn promote_mount_creation(&mut self) -> Result<()> {
        self.promote_mount_work(0, 0)
    }

    pub(crate) fn promote_mount_start(&mut self) -> Result<()> {
        self.promote_mount_work(1, 0)
    }

    pub(crate) fn promote_mount_oci_start(&mut self) -> Result<()> {
        self.promote_mount_work(2, 1)
    }

    pub(crate) fn promote_mount_worker(&mut self, demand: Demand) -> Result<()> {
        if !matches!(demand.lane, Lane::Work)
            || demand.children != 1
            || demand.descriptors > JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            || demand.metadata > JOB_METADATA_BYTES
            || demand.staging > JOB_STAGING_BYTES
            || demand.registry_staging != 0
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        self.promote_mount_work(demand.children, demand.staging)
    }

    fn promote_mount_work(&mut self, children: usize, staging: u64) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if !self.pool.available()
            || !matches!(self.demand.lane, Lane::Work)
            || self.demand.children > children
            || self.demand.staging > staging
            || self.demand.registry_staging != 0
        {
            return Err(Error::before(ErrorCode::State));
        }
        let descriptors = JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM;
        if self.demand.descriptors > descriptors || self.demand.metadata > JOB_METADATA_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        let fd_delta = descriptors - self.demand.descriptors;
        let metadata_delta = JOB_METADATA_BYTES - self.demand.metadata;
        let child_delta = children - self.demand.children;
        let staging_delta = staging - self.demand.staging;
        if counts.work_descriptors + fd_delta > descriptors
            || counts.descriptors + fd_delta > JOB_DESCRIPTORS
            || counts.work_metadata + metadata_delta > JOB_METADATA_BYTES
            || counts.children + child_delta > JOB_CHILDREN
            || counts.staging + staging_delta > JOB_STAGING_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        fd_admission(counts.descriptors + fd_delta)?;
        counts.work_descriptors += fd_delta;
        counts.descriptors += fd_delta;
        counts.work_metadata += metadata_delta;
        counts.metadata += metadata_delta;
        counts.children += child_delta;
        counts.staging += staging_delta;
        self.demand.descriptors = descriptors;
        self.demand.metadata = JOB_METADATA_BYTES;
        self.demand.children = children;
        self.demand.staging = staging;
        Ok(())
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
    fn mounted_terminal_accounts_maximum_input_and_preserves_reserved_control() {
        let pool = JobPool::default();
        let mut mounts = pool.acquire(Demand::volume_mounts(8).unwrap()).unwrap();
        let first = pool.acquire(Demand::volume_observation()).unwrap();
        let second = pool.acquire(Demand::volume_observation()).unwrap();
        let options = crate::TerminalOptions {
            program: "/bin/sh".into(),
            cols: 80,
            rows: 24,
            session: std::time::Duration::from_secs(1),
            idle: std::time::Duration::from_secs(1),
            attach: std::time::Duration::from_millis(100),
            close: std::time::Duration::from_millis(1),
            max_buffer_bytes: 1048576,
            max_input_bytes: 65536,
            total_input_bytes: crate::TERMINAL_INPUT_BYTES,
        };
        let demand = Demand::terminal(&options, crate::COMMAND_METADATA_BYTES).unwrap();
        mounts.promote_mount_worker(demand).unwrap();
        let counts = pool.counts();
        assert_eq!(counts.children, 1);
        assert_eq!(counts.staging, crate::TERMINAL_INPUT_BYTES * 3);
        assert_eq!(counts.work, 1);
        assert_eq!(counts.control, 2);
        assert_eq!(counts.descriptors, JOB_DESCRIPTORS);
        mounts.promote_mount_worker(demand).unwrap();
        assert_eq!(pool.counts(), counts);
        let mut excessive = demand;
        excessive.metadata = JOB_METADATA_BYTES + 1;
        assert!(mounts.promote_mount_worker(excessive).is_err());
        assert_eq!(pool.counts(), counts);
        drop(mounts);
        drop((first, second));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn mounted_command_admission_accounts_output_staging_without_releasing_qualification() {
        let pool = JobPool::default();
        let mut mount = pool.acquire(Demand::volume_mounts(8).unwrap()).unwrap();
        let first = pool.acquire(Demand::volume_observation()).unwrap();
        let second = pool.acquire(Demand::volume_observation()).unwrap();
        let demand = Demand::command(16 * 1024 * 1024, 8 * 1024 * 1024).unwrap();
        mount.promote_mount_worker(demand).unwrap();
        let before = pool.counts();
        assert_eq!(before.work, 1);
        assert_eq!(before.children, 1);
        assert_eq!(before.staging, 16 * 1024 * 1024);
        assert_eq!(before.descriptors, JOB_DESCRIPTORS);
        assert_eq!(before.work_metadata, JOB_METADATA_BYTES);
        mount.promote_mount_worker(demand).unwrap();
        assert_eq!(pool.counts(), before);
        assert!(mount
            .promote_mount_worker(Demand::volume_observation())
            .is_err());
        assert_eq!(pool.counts(), before);
        drop(mount);
        drop((first, second));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn mount_oci_promotion_keeps_one_job_two_children_and_both_control_observers() {
        let pool = JobPool::default();
        let mut mount = pool.acquire(Demand::volume_mounts(8).unwrap()).unwrap();
        let first = pool.acquire(Demand::volume_observation()).unwrap();
        let second = pool.acquire(Demand::volume_observation()).unwrap();
        mount.promote_mount_oci_start().unwrap();
        let counts = pool.counts();
        assert_eq!(counts.work, 1);
        assert_eq!(counts.children, 2);
        assert_eq!(counts.staging, 1);
        assert_eq!(counts.descriptors, JOB_DESCRIPTORS);
        assert_eq!(counts.work_metadata, JOB_METADATA_BYTES);
        mount.promote_mount_oci_start().unwrap();
        assert_eq!(pool.counts(), counts);
        assert!(mount.promote_mount_start().is_err());
        assert_eq!(pool.counts(), counts);
        drop(mount);
        assert_eq!(pool.counts().children, 0);
        assert_eq!(pool.counts().staging, 0);
        drop((first, second));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn exhausted_staging_cannot_partially_promote_oci_mounts() {
        let pool = JobPool::default();
        let mut mounts = pool.acquire(Demand::volume_mounts(1).unwrap()).unwrap();
        let staging = pool
            .acquire(Demand {
                lane: Lane::Work,
                children: 0,
                descriptors: 0,
                staging: JOB_STAGING_BYTES,
                registry_staging: 0,
                metadata: 0,
            })
            .unwrap();
        let before = pool.counts();
        assert!(mounts.promote_mount_oci_start().is_err());
        assert_eq!(pool.counts(), before);
        drop(staging);
        mounts.promote_mount_oci_start().unwrap();
        drop(mounts);
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn mount_start_promotes_child_admission_atomically_and_retains_control() {
        let pool = JobPool::default();
        let mut mounts = pool.acquire(Demand::volume_mounts(8).unwrap()).unwrap();
        let first = pool.acquire(Demand::volume_observation()).unwrap();
        let second = pool.acquire(Demand::volume_observation()).unwrap();
        mounts.promote_mount_start().unwrap();
        assert_eq!(pool.counts().children, 1);
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().descriptors, JOB_DESCRIPTORS);
        mounts.promote_mount_start().unwrap();
        let before = pool.counts();
        assert!(mounts.promote_mount_creation().is_err());
        assert_eq!(pool.counts(), before);
        drop(mounts);
        assert_eq!(pool.counts().children, 0);
        assert_eq!(pool.counts().work, 0);
        drop((first, second));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn exhausted_children_cannot_partially_promote_or_release_mount_admission() {
        let pool = JobPool::default();
        let mut mounts = pool.acquire(Demand::volume_mounts(1).unwrap()).unwrap();
        let children = pool
            .acquire(Demand {
                lane: Lane::Work,
                children: JOB_CHILDREN,
                descriptors: 0,
                staging: 0,
                registry_staging: 0,
                metadata: 0,
            })
            .unwrap();
        let before = pool.counts();
        assert!(mounts.promote_mount_start().is_err());
        assert_eq!(pool.counts(), before);
        drop(children);
        mounts.promote_mount_start().unwrap();
        drop(mounts);
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn mount_creation_promotion_is_atomic_and_preserves_both_control_jobs() {
        let pool = JobPool::default();
        let mut mount = pool.acquire(Demand::volume_mounts(8).unwrap()).unwrap();
        let first = pool.acquire(Demand::volume_observation()).unwrap();
        let second = pool.acquire(Demand::volume_observation()).unwrap();
        mount.promote_mount_creation().unwrap();
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().control, 2);
        assert_eq!(pool.counts().descriptors, JOB_DESCRIPTORS);
        assert_eq!(pool.counts().work_metadata, JOB_METADATA_BYTES);
        mount.promote_mount_creation().unwrap();
        pool.quarantine();
        let before = pool.counts();
        assert!(mount.promote_mount_creation().is_err());
        assert_eq!(pool.counts(), before);
        drop(mount);
        assert_eq!(pool.counts().work, 0);
        assert_eq!(pool.counts().work_metadata, 0);
        drop((first, second));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn failed_mount_promotion_cannot_free_or_partially_change_existing_admission() {
        let pool = JobPool::default();
        let mut mount = pool.acquire(Demand::volume_mounts(1).unwrap()).unwrap();
        let other = pool.acquire(Demand::volume_root()).unwrap();
        let before = pool.counts();
        assert!(mount.promote_mount_creation().is_err());
        assert_eq!(pool.counts(), before);
        drop(other);
        mount.promote_mount_creation().unwrap();
        drop(mount);
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn mount_descriptors_and_metadata_are_retained_without_consuming_control_admission() {
        let pool = JobPool::default();
        assert!(Demand::volume_mounts(0).is_err());
        assert!(Demand::volume_mounts(9).is_err());
        let mount = pool.acquire(Demand::volume_mounts(8).unwrap()).unwrap();
        let first = pool.acquire(Demand::volume_observation()).unwrap();
        let second = pool.acquire(Demand::volume_observation()).unwrap();
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().work_descriptors, 20);
        assert_eq!(pool.counts().descriptors, 28);
        assert!(pool.acquire(Demand::volume_mounts(1).unwrap()).is_err());
        // Creation must integrate the existing grant into its own whole-job
        // budget; silently stacking the full SDK allowance is not authorized.
        assert!(pool.acquire(Demand::oci_create()).is_err());
        pool.quarantine();
        assert!(pool.acquire(Demand::volume_mounts(1).unwrap()).is_err());
        drop(mount);
        assert_eq!(pool.counts().work_descriptors, 0);
        assert_eq!(pool.counts().work_metadata, 0);
        drop((first, second));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn full_work_metadata_cannot_starve_bounded_volume_control_observers() {
        let pool = JobPool::default();
        let work = pool.acquire(Demand::registry_download(1).unwrap()).unwrap();
        let first = pool.acquire(Demand::volume_observation()).unwrap();
        let second = pool.acquire(Demand::volume_observation()).unwrap();
        assert_eq!(pool.counts().work_metadata, JOB_METADATA_BYTES);
        assert_eq!(
            pool.counts().metadata,
            JOB_METADATA_BYTES + JOB_CONTROL_METADATA_BYTES
        );
        assert!(pool.acquire(Demand::volume_root()).is_err());
        assert!(pool.acquire(Demand::volume_observation()).is_err());
        pool.quarantine();
        drop(first);
        let replacement = pool.acquire(Demand::volume_observation()).unwrap();
        drop(work);
        assert_eq!(pool.counts().work_metadata, 0);
        assert_eq!(pool.counts().metadata, JOB_CONTROL_METADATA_BYTES);
        drop((second, replacement));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn control_memory_is_finite_and_cannot_consume_the_work_allowance() {
        let pool = JobPool::default();
        let mut demand = Demand::volume_observation();
        demand.metadata = JOB_CONTROL_METADATA_BYTES;
        let control = pool.acquire(demand).unwrap();
        let before = pool.counts();
        assert!(pool.acquire(Demand::volume_observation()).is_err());
        assert_eq!(pool.counts(), before);
        let work = pool.acquire(Demand::growth_repair()).unwrap();
        let empty_observer = pool.acquire(Demand::observation()).unwrap();
        demand.metadata += 1;
        assert!(pool.acquire(demand).is_err());
        assert_eq!(
            pool.counts().metadata,
            JOB_METADATA_BYTES + JOB_CONTROL_METADATA_BYTES
        );
        drop((control, work, empty_observer));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn registry_staging_is_separate_finite_and_retained_until_job_returns() {
        let pool = JobPool::default();
        assert!(Demand::registry_download(0).is_err());
        assert!(Demand::registry_download(JOB_REGISTRY_STAGING_BYTES + 1).is_err());
        let lease = pool
            .acquire(Demand::registry_download(JOB_REGISTRY_STAGING_BYTES).unwrap())
            .unwrap();
        assert_eq!(pool.counts().registry_staging, JOB_REGISTRY_STAGING_BYTES);
        assert_eq!(pool.counts().staging, 0);
        assert!(pool.acquire(Demand::registry_download(1).unwrap()).is_err());
        let control = pool.acquire(Demand::observation()).unwrap();
        let second = pool.acquire(Demand::observation()).unwrap();
        pool.quarantine();
        assert_eq!(pool.counts().registry_staging, JOB_REGISTRY_STAGING_BYTES);
        drop(lease);
        assert_eq!(pool.counts().registry_staging, 0);
        assert_eq!(pool.counts().control, 2);
        drop((control, second));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn growth_qualification_reserves_journal_memory_without_a_child_or_control_starvation() {
        let pool = JobPool::default();
        let repair = pool.acquire(Demand::growth_repair()).unwrap();
        assert_eq!(pool.counts().metadata, JOB_METADATA_BYTES);
        assert_eq!(pool.counts().children, 0);
        assert_eq!(pool.counts().staging, 0);
        assert!(pool.acquire(Demand::command(1, 1).unwrap()).is_err());
        let first = pool.acquire(Demand::observation()).unwrap();
        let second = pool.acquire(Demand::observation()).unwrap();
        assert_eq!(pool.counts().control, 2);
        drop((repair, first, second));
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn growth_reserves_geometry_child_and_memory_while_control_stays_available() {
        let pool = JobPool::default();
        assert!(Demand::growth(0).is_err());
        assert!(Demand::growth(crate::growth::METADATA_BYTES + 1).is_err());
        let growth = pool
            .acquire(Demand::growth(crate::growth::METADATA_BYTES).unwrap())
            .unwrap();
        assert_eq!(pool.counts().children, 1);
        assert_eq!(pool.counts().work_descriptors, 21);
        assert_eq!(
            pool.counts().metadata,
            crate::growth::METADATA_BYTES + 8 * 1024 * 1024 + crate::qcow_geometry::MEMORY_BYTES
        );
        assert!(pool.acquire(Demand::growth(1).unwrap()).is_err());
        let observation = pool.acquire(Demand::observation()).unwrap();
        let second = pool.acquire(Demand::observation()).unwrap();
        assert_eq!(pool.counts().control, 2);
        drop((growth, observation, second));
        assert_eq!(pool.counts(), Counts::default());
    }
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
                registry_staging: 0,
                staging: 48 * 1024 * 1024,
                metadata: 0,
                work_metadata: 0,
            }
        );
        drop(leases);
        drop(control);
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn pull_reserves_worker_projection_resources_without_consuming_control_capacity() {
        let pool = JobPool::default();
        let pull = pool.acquire(Demand::image_pull()).unwrap();
        assert_eq!(pool.counts().metadata, JOB_METADATA_BYTES);
        assert_eq!(pool.counts().children, 1);
        assert_eq!(pool.counts().staging, 1);
        assert_eq!(
            pool.acquire(Demand::image_pull()).err().unwrap().code,
            ErrorCode::Admission
        );
        let controls = [
            pool.acquire(Demand::observation()).unwrap(),
            pool.acquire(Demand::observation()).unwrap(),
        ];
        assert_eq!(pool.counts().control, 2);
        drop(pull);
        drop(controls);
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn oci_creation_reserves_metadata_and_descriptors_before_sdk_entry() {
        let pool = JobPool::default();
        let creation = pool.acquire(Demand::oci_create()).unwrap();
        assert_eq!(pool.counts().metadata, JOB_METADATA_BYTES);
        assert_eq!(pool.counts().children, 0);
        assert_eq!(pool.counts().staging, 0);
        assert_eq!(
            pool.acquire(Demand::oci_create()).err().unwrap().code,
            ErrorCode::Admission
        );
        let controls = [
            pool.acquire(Demand::observation()).unwrap(),
            pool.acquire(Demand::observation()).unwrap(),
        ];
        assert_eq!(pool.counts().control, 2);
        drop(creation);
        drop(controls);
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
            pool.acquire(Demand::streaming()).err().unwrap().code,
            ErrorCode::State
        );
        let controls = [
            pool.acquire(Demand::observation()).unwrap(),
            pool.acquire(Demand::observation()).unwrap(),
        ];
        assert_eq!(
            pool.acquire(Demand::observation()).err().unwrap().code,
            ErrorCode::Admission
        );
        drop(lease);
        assert_eq!(pool.counts().work, 0);
        assert_eq!(pool.counts().control, 2);
        drop(controls);
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
            registry_staging: 0,
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
