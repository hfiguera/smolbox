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
/// Request-private checkpoint input plus bounded history objects; separate from
/// registry downloads, command spools and admitted guest disks.
pub const JOB_CHECKPOINT_STAGING_BYTES: u64 = 128 * 1024 * 1024 * 1024;
/// Request-private saved-state material (checkpoint decoding and retained branch
/// preparation backing), not the store's persistent guest capacity reservation.
pub const JOB_CHECKPOINT_MATERIAL_BYTES: u64 = crate::checkpoint_materialize::MATERIAL_BYTES;
/// Extra room for one bounded SDK history-index parser, separate from ordinary
/// work metadata and permanently reserved control headroom.
pub const JOB_CHECKPOINT_METADATA_BYTES: u64 = 128 * 1024 * 1024;
/// Work metadata allowance. Reserved control memory is independent.
pub const JOB_METADATA_BYTES: u64 = 32 * 1024 * 1024;
/// Two bounded volume observers remain admissible with full work metadata.
pub const JOB_CONTROL_METADATA_BYTES: u64 = 256 * 1024;
/// One bounded material-journal resolver remains admissible while unresolved
/// capture work retains its whole work metadata allowance. Volume/control
/// observation headroom stays independent; no checkpoint staging is released.
pub const JOB_MATERIAL_CONTROL_METADATA_BYTES: u64 = 32 * 1024 * 1024;
pub const JOB_EXPORT_STAGING_BYTES: u64 = 512 * 1024 * 1024 * 1024;
pub const JOB_DESCRIPTORS: usize = 32;
pub const JOB_CONTROL_HEADROOM: usize = 8;
/// Completed branch bookkeeping is independent of executing SDK-parser memory.
pub(crate) const BRANCH_BACKING_METADATA: u64 = 128 * 1024;
pub(crate) const BRANCH_BACKING_METADATA_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Clone, Copy)]
enum Lane {
    Work,
    Control,
    MaterialControl,
    Retired,
}
#[derive(Clone, Copy)]
pub(crate) struct Demand {
    lane: Lane,
    children: usize,
    descriptors: usize,
    staging: u64,
    registry_staging: u64,
    checkpoint_staging: u64,
    checkpoint_metadata: u64,
    checkpoint_material: u64,
    checkpoint_install: u64,
    metadata: u64,
}
impl Demand {
    pub(crate) fn branch_delete() -> Self {
        Self {
            descriptors: 24,
            checkpoint_metadata: JOB_CHECKPOINT_METADATA_BYTES,
            ..Self::branch_release()
        }
    }
    pub(crate) fn branch_probe() -> Self {
        // Sequential bounded dependency reads and short header-first agent relay.
        Self::branch_release()
    }
    pub(crate) fn branch_release() -> Self {
        Self {
            descriptors: 20,
            metadata: JOB_METADATA_BYTES,
            ..Self::streaming()
        }
    }
    pub(crate) fn branch_retirement() -> Self {
        let mut demand = Self::material_resolution();
        // Retained source root plus the read-only SQLite snapshot, actor-ledger
        // readers and protected journal replacement fit independently of work.
        demand.descriptors = 8;
        demand
    }
    pub(crate) fn branch_source() -> Self {
        let mut demand = Self::export_source();
        // Two stable gate/root identities plus bounded original-source checks.
        // This is no child/VMM/backing reservation or fork dispatch permission.
        demand.descriptors = 16;
        demand
    }
    pub(crate) fn export_observation() -> Self {
        // Two bounded publication record/proof readers fit reserved control
        // descriptors and metadata even while an export holds the work ceiling.
        Self::volume_observation()
    }
    pub(crate) fn export_cleanup() -> Self {
        let mut demand = Self::volume_observation();
        demand.descriptors = 8;
        demand
    }
    pub(crate) fn export_retirement() -> Self {
        // Full authenticated material-journal parsing shares the existing
        // independent resolver allowance; never consume observation headroom.
        let mut demand = Self::material_resolution();
        demand.descriptors = 8;
        demand
    }
    pub(crate) fn export_source() -> Self {
        let mut demand = Self::volume_root();
        demand.metadata = JOB_METADATA_BYTES;
        demand
    }

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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            // Optional operator credential provider precedes network/cache I/O.
            // Include all three pipes and spawn error-pipe transient descriptors.
            children: 1,
            descriptors: 20,
            staging: 0,
            registry_staging: bytes,
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
            metadata: JOB_METADATA_BYTES,
        })
    }

    pub(crate) fn checkpoint_prepare(bytes: u64) -> Result<Self> {
        if bytes == 0 || bytes > crate::CHECKPOINT_ARTIFACT_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        let staging = bytes
            .checked_add(crate::checkpoint::HISTORY_STAGING_BYTES)
            .ok_or(Error::before(ErrorCode::Admission))?;
        Ok(Self {
            lane: Lane::Work,
            children: 1,
            descriptors: 16,
            staging: 0,
            registry_staging: 0,
            checkpoint_staging: staging,
            checkpoint_metadata: JOB_CHECKPOINT_METADATA_BYTES,
            checkpoint_material: 0,
            checkpoint_install: 0,
            metadata: JOB_METADATA_BYTES,
        })
    }

    pub(crate) fn oci_metadata() -> Self {
        Self {
            lane: Lane::Work,
            children: 1,
            descriptors: 20,
            registry_staging: 0,
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
            staging: 0,
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn checkpoint_inspection() -> Self {
        // Public SDK CPU compatibility uses a normally collected sysctl child
        // on macOS. Keep one conservative slot on both qualified platforms.
        Self {
            children: 1,
            ..Self::oci_metadata()
        }
    }

    pub(crate) fn oci_start() -> Self {
        Self {
            lane: Lane::Work,
            children: 2, // the enrolled VMM and the agent bootstrap worker
            // Launch and bootstrap are sequential. Retained manager handles
            // coexist with the bootstrap/provider's 24-descriptor demand.
            descriptors: 24,
            registry_staging: 0,
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
            staging: 0,
            metadata: JOB_METADATA_BYTES,
        }
    }

    pub(crate) fn image_pull() -> Self {
        Self {
            lane: Lane::Work,
            children: 1,
            // Parent-side credential provider and guest worker are sequential.
            // Metadata/source guards remain held across both phases.
            descriptors: 24,
            registry_staging: 0,
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
            staging: options.total_input_bytes * 3,
            metadata: metadata + options.max_buffer_bytes * 4 + 8 * 1024 * 1024,
        })
    }
    pub(crate) fn image_transfer(bytes: u64, metadata: u64) -> Result<Self> {
        if metadata == 0 || metadata > crate::buffered::COMMAND_METADATA_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            // One worker, sequential activation/file relays, private metadata,
            // lifecycle/source descriptors and bounded parser/watch stacks.
            descriptors: 24,
            metadata: metadata + 8 * 1024 * 1024,
            ..Self::transfer(bytes)?
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
            staging: 0,
            metadata: 0,
        }
    }

    pub(crate) fn material_resolution() -> Self {
        Self {
            lane: Lane::MaterialControl,
            descriptors: 4,
            metadata: JOB_MATERIAL_CONTROL_METADATA_BYTES,
            ..Self::observation()
        }
    }
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Counts {
    pub branch_metadata: u64,
    pub work: usize,
    pub control: usize,
    pub children: usize,
    pub descriptors: usize,
    pub work_descriptors: usize,
    pub staging: u64,
    pub export_staging: u64,
    pub registry_staging: u64,
    pub checkpoint_staging: u64,
    pub checkpoint_metadata: u64,
    pub checkpoint_material: u64,
    pub checkpoint_install: u64,
    pub metadata: u64,
    pub work_metadata: u64,
    pub material_control_metadata: u64,
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
    pub(crate) fn branch_result_metadata(&self) -> Result<BranchBackingLease> {
        let mut counts = self
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if !self.available()
            || counts.branch_metadata + BRANCH_BACKING_METADATA > BRANCH_BACKING_METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        counts.branch_metadata += BRANCH_BACKING_METADATA;
        Ok(BranchBackingLease {
            pool: self.clone(),
            bytes: 0,
        })
    }
    pub(crate) fn available(&self) -> bool {
        !self.0.quarantined.load(Ordering::Acquire)
    }
    pub(crate) fn quarantine(&self) {
        self.0.quarantined.store(true, Ordering::Release);
    }
    pub(crate) fn acquire(&self, demand: Demand) -> Result<JobLease> {
        if matches!(demand.lane, Lane::Retired) {
            return Err(Error::before(ErrorCode::Ownership));
        }
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
            || demand.checkpoint_staging > JOB_CHECKPOINT_STAGING_BYTES
            || demand.checkpoint_metadata > JOB_CHECKPOINT_METADATA_BYTES
            || demand.checkpoint_material > JOB_CHECKPOINT_MATERIAL_BYTES
            || demand.checkpoint_install > JOB_CHECKPOINT_MATERIAL_BYTES
            || demand.staging > JOB_STAGING_BYTES
            || demand.metadata
                > match demand.lane {
                    Lane::Work => JOB_METADATA_BYTES,
                    Lane::Control => JOB_CONTROL_METADATA_BYTES,
                    Lane::MaterialControl => JOB_MATERIAL_CONTROL_METADATA_BYTES,
                    Lane::Retired => 0,
                }
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        let (work, control) = match demand.lane {
            Lane::Work => (counts.work + 1, counts.control),
            Lane::Control | Lane::MaterialControl => (counts.work, counts.control + 1),
            Lane::Retired => (counts.work, counts.control),
        };
        let next = Counts {
            branch_metadata: counts.branch_metadata,
            work,
            control,
            children: counts.children + demand.children,
            descriptors: counts.descriptors + demand.descriptors,
            work_descriptors: counts.work_descriptors
                + match demand.lane {
                    Lane::Work => demand.descriptors,
                    Lane::Control | Lane::MaterialControl | Lane::Retired => 0,
                },
            registry_staging: counts.registry_staging + demand.registry_staging,
            checkpoint_staging: counts.checkpoint_staging + demand.checkpoint_staging,
            checkpoint_metadata: counts.checkpoint_metadata + demand.checkpoint_metadata,
            checkpoint_material: counts.checkpoint_material + demand.checkpoint_material,
            checkpoint_install: counts.checkpoint_install + demand.checkpoint_install,
            staging: counts.staging + demand.staging,
            export_staging: counts.export_staging,
            metadata: counts.metadata + demand.metadata,
            work_metadata: counts.work_metadata
                + match demand.lane {
                    Lane::Work => demand.metadata,
                    Lane::Control | Lane::MaterialControl | Lane::Retired => 0,
                },
            material_control_metadata: counts.material_control_metadata
                + match demand.lane {
                    Lane::MaterialControl => demand.metadata,
                    Lane::Work | Lane::Control | Lane::Retired => 0,
                },
        };
        if next.work > JOB_WORK_SLOTS
            || next.control > JOB_CONTROL_SLOTS
            || next.children > JOB_CHILDREN
            || next.descriptors > JOB_DESCRIPTORS
            || next.work_descriptors > JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            || next.registry_staging > JOB_REGISTRY_STAGING_BYTES
            || next.checkpoint_staging > JOB_CHECKPOINT_STAGING_BYTES
            || next.checkpoint_metadata > JOB_CHECKPOINT_METADATA_BYTES
            || next.checkpoint_material > JOB_CHECKPOINT_MATERIAL_BYTES
            || next.checkpoint_install > JOB_CHECKPOINT_MATERIAL_BYTES
            || next.staging > JOB_STAGING_BYTES
            || next.work_metadata > JOB_METADATA_BYTES
            || next.material_control_metadata > JOB_MATERIAL_CONTROL_METADATA_BYTES
            || next.metadata - next.work_metadata - next.material_control_metadata
                > JOB_CONTROL_METADATA_BYTES
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
    pub(crate) fn export_staging(&self, bytes: u64, restore: bool) -> Result<ExportStagingLease> {
        let mut counts = self
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if (!restore && !self.available())
            || bytes == 0
            || bytes > JOB_EXPORT_STAGING_BYTES
            || counts
                .export_staging
                .checked_add(bytes)
                .is_none_or(|next| next > JOB_EXPORT_STAGING_BYTES)
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        counts.export_staging += bytes;
        Ok(ExportStagingLease {
            pool: self.clone(),
            bytes,
        })
    }
    #[cfg(test)]
    pub(crate) fn counts(&self) -> Counts {
        *self.0.counts.lock().unwrap()
    }
}
pub(crate) struct ExportStagingLease {
    pool: JobPool,
    bytes: u64,
}
impl Drop for ExportStagingLease {
    fn drop(&mut self) {
        self.pool
            .0
            .counts
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .export_staging -= self.bytes;
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
            Lane::MaterialControl => {
                counts.control -= 1;
                counts.material_control_metadata -= self.demand.metadata;
            }
            Lane::Retired => {}
        }
        counts.children -= self.demand.children;
        counts.descriptors -= self.demand.descriptors;
        counts.registry_staging -= self.demand.registry_staging;
        counts.checkpoint_staging -= self.demand.checkpoint_staging;
        counts.checkpoint_metadata -= self.demand.checkpoint_metadata;
        counts.checkpoint_material -= self.demand.checkpoint_material;
        counts.checkpoint_install -= self.demand.checkpoint_install;
        counts.staging -= self.demand.staging;
        counts.metadata -= self.demand.metadata;
    }
}

impl JobLease {
    pub(crate) fn check_branch_handoff(&self) -> Result<()> {
        let counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        self.check_branch_handoff_counts(&counts, false)
    }
    pub(crate) fn check_disposed_branch_handoff(&self) -> Result<()> {
        let counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        self.check_branch_handoff_counts(&counts, true)
    }
    // An explicitly fenced original ready result may retire transient work even
    // while new work is quarantined. This grants no new admission or disk release.
    pub(crate) fn check_resolved_branch_handoff(&self) -> Result<()> {
        self.check_disposed_branch_handoff()
    }
    fn check_branch_handoff_counts(&self, counts: &Counts, retained_cleanup: bool) -> Result<()> {
        let demand = self.demand;
        if (!retained_cleanup && !self.pool.available())
            || !matches!(demand.lane, Lane::Work)
            || demand.metadata != JOB_METADATA_BYTES
            || demand.descriptors != JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            || demand.children != 2
            || demand.staging
                != crate::branch_worker::METADATA_BYTES + crate::branch_worker::OUTPUT_BYTES
            || demand.checkpoint_metadata != JOB_CHECKPOINT_METADATA_BYTES
            || demand.checkpoint_material == 0
            || demand.checkpoint_install != 0
            || demand.registry_staging != 0
            || demand.checkpoint_staging != 0
            || counts.branch_metadata + BRANCH_BACKING_METADATA > BRANCH_BACKING_METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        Ok(())
    }
    /// Only after actual dispatch return, collected spools, original-manager
    /// installation and synchronized completion. Backing never becomes free.
    pub(crate) fn handoff_branch(&mut self) -> Result<BranchBackingLease> {
        self.handoff_branch_accounting(false)
    }
    /// Only after synchronized disposal of the original never-booted child or
    /// the positively collected original pre-handoff child. No manager or boot
    /// completion is manufactured; backing remains charged.
    pub(crate) fn handoff_disposed_branch(&mut self) -> Result<BranchBackingLease> {
        self.handoff_branch_accounting(true)
    }
    /// Only after explicit original-context ready-result qualification and actual
    /// manager installation. The exact original backing remains charged.
    pub(crate) fn handoff_resolved_branch(&mut self) -> Result<BranchBackingLease> {
        self.handoff_branch_accounting(true)
    }
    fn handoff_branch_accounting(&mut self, retained_cleanup: bool) -> Result<BranchBackingLease> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        self.check_branch_handoff_counts(&counts, retained_cleanup)?;
        counts.work -= 1;
        counts.children -= self.demand.children;
        counts.descriptors -= self.demand.descriptors;
        counts.work_descriptors -= self.demand.descriptors;
        counts.staging -= self.demand.staging;
        counts.checkpoint_metadata -= self.demand.checkpoint_metadata;
        counts.metadata -= self.demand.metadata;
        counts.work_metadata -= self.demand.metadata;
        counts.branch_metadata += BRANCH_BACKING_METADATA;
        let backing = BranchBackingLease {
            pool: self.pool.clone(),
            bytes: self.demand.checkpoint_material,
        };
        self.demand = Demand {
            lane: Lane::Retired,
            descriptors: 0,
            ..Demand::streaming()
        };
        Ok(backing)
    }
    pub(crate) fn promote_branch_backing(&mut self, bytes: u64) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if !self.pool.available()
            || !matches!(self.demand.lane, Lane::Work)
            || bytes == 0
            || bytes > JOB_CHECKPOINT_MATERIAL_BYTES
            || self.demand.metadata != JOB_METADATA_BYTES
            || self.demand.descriptors != JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            || self.demand.children != 2
            || self.demand.staging
                != crate::branch_worker::METADATA_BYTES + crate::branch_worker::OUTPUT_BYTES
            || self.demand.checkpoint_metadata != JOB_CHECKPOINT_METADATA_BYTES
            || self.demand.registry_staging != 0
            || self.demand.checkpoint_staging != 0
            || self.demand.checkpoint_install != 0
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        if self.demand.checkpoint_material == bytes {
            return Ok(());
        }
        if self.demand.checkpoint_material != 0
            || counts.checkpoint_material + bytes > JOB_CHECKPOINT_MATERIAL_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        counts.checkpoint_material += bytes;
        self.demand.checkpoint_material = bytes;
        Ok(())
    }
    pub(crate) fn promote_branch_preparation(&mut self) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let staging = crate::branch_worker::METADATA_BYTES + crate::branch_worker::OUTPUT_BYTES;
        if !self.pool.available()
            || !matches!(self.demand.lane, Lane::Work)
            || self.demand.metadata != JOB_METADATA_BYTES
            || self.demand.registry_staging != 0
            || self.demand.checkpoint_staging != 0
            || self.demand.checkpoint_install != 0
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        if self.demand.descriptors == JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            && self.demand.children == 2
            && self.demand.staging == staging
            && self.demand.checkpoint_metadata == JOB_CHECKPOINT_METADATA_BYTES
        {
            return Ok(());
        }
        if self.demand.descriptors != 16
            || self.demand.checkpoint_material != 0
            || self.demand.children != 0
            || self.demand.staging != 0
            || self.demand.checkpoint_metadata != 0
            || counts.descriptors + 8 > JOB_DESCRIPTORS
            || counts.work_descriptors + 8 > JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            || counts.children + 2 > JOB_CHILDREN
            || counts.staging + staging > JOB_STAGING_BYTES
            || counts.checkpoint_metadata + JOB_CHECKPOINT_METADATA_BYTES
                > JOB_CHECKPOINT_METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        fd_admission(counts.descriptors + 8)?;
        counts.descriptors += 8;
        counts.work_descriptors += 8;
        counts.children += 2;
        counts.staging += staging;
        counts.checkpoint_metadata += JOB_CHECKPOINT_METADATA_BYTES;
        self.demand.descriptors = JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM;
        self.demand.children = 2;
        self.demand.staging = staging;
        self.demand.checkpoint_metadata = JOB_CHECKPOINT_METADATA_BYTES;
        Ok(())
    }
    pub(crate) fn promote_export_stage(&mut self) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let wanted = JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM;
        if self.pool.available()
            && matches!(self.demand.lane, Lane::Work)
            && self.demand.descriptors == wanted
            && self.demand.children == 2
            && self.demand.metadata == JOB_METADATA_BYTES
        {
            // An admitted conversion already holds the whole export pipeline.
            return Ok(());
        }
        if !self.pool.available()
            || !matches!(self.demand.lane, Lane::Work)
            || self.demand.descriptors != 12
            || self.demand.children != 0
            || self.demand.metadata != JOB_METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        let extra = wanted - self.demand.descriptors;
        if counts.descriptors + extra > JOB_DESCRIPTORS || counts.work_descriptors + extra > wanted
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        fd_admission(counts.descriptors + extra)?;
        counts.descriptors += extra;
        counts.work_descriptors += extra;
        self.demand.descriptors = wanted;
        Ok(())
    }

    pub(crate) fn promote_export_conversion(&mut self) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let wanted = JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM;
        if !self.pool.available()
            || !matches!(self.demand.lane, Lane::Work)
            || self.demand.metadata != JOB_METADATA_BYTES
            || self.demand.registry_staging != 0
            || self.demand.checkpoint_staging != 0
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        if self.demand.descriptors == wanted && self.demand.children == 2 {
            return Ok(());
        }
        if self.demand.descriptors != 12 || self.demand.children != 0 {
            return Err(Error::before(ErrorCode::Admission));
        }
        let extra = wanted - self.demand.descriptors;
        if counts.descriptors + extra > JOB_DESCRIPTORS
            || counts.work_descriptors + extra > wanted
            || counts.children + 2 > JOB_CHILDREN
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        fd_admission(counts.descriptors + extra)?;
        counts.descriptors += extra;
        counts.work_descriptors += extra;
        counts.children += 2;
        self.demand.descriptors = wanted;
        self.demand.children = 2;
        Ok(())
    }

    pub(crate) fn promote_export_disks(&mut self) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        // Source/root and disk descriptors, bounded SQLite rechecks, backing
        // reopen and one coordinator-owned output must coexist.
        let wanted = 12;
        if !self.pool.available()
            || !matches!(self.demand.lane, Lane::Work)
            || self.demand.children != 0
            || self.demand.descriptors != 4
            || self.demand.metadata != JOB_METADATA_BYTES
            || self.demand.checkpoint_staging != 0
            || self.demand.registry_staging != 0
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        let extra = wanted - self.demand.descriptors;
        if counts.descriptors + extra > JOB_DESCRIPTORS
            || counts.work_descriptors + extra > JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        fd_admission(counts.descriptors + extra)?;
        counts.descriptors += extra;
        counts.work_descriptors += extra;
        self.demand.descriptors = wanted;
        Ok(())
    }

    pub(crate) fn promote_checkpoint_install(&mut self, bytes: u64) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let descriptors = JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM;
        if !self.pool.available()
            || bytes == 0
            || bytes > JOB_CHECKPOINT_MATERIAL_BYTES
            || self.demand.checkpoint_material == 0
            || self.demand.checkpoint_install != 0
            || self.demand.children != 1
            || self.demand.descriptors > descriptors
            || self.demand.staging != 0
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        let extra = descriptors - self.demand.descriptors;
        if counts.children + 1 > JOB_CHILDREN
            || counts.descriptors + extra > JOB_DESCRIPTORS
            || counts.work_descriptors + extra > descriptors
            || counts.staging + crate::checkpoint_install::METADATA_BYTES > JOB_STAGING_BYTES
            || counts.checkpoint_install + bytes > JOB_CHECKPOINT_MATERIAL_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        fd_admission(counts.descriptors + extra)?;
        counts.children += 1;
        counts.descriptors += extra;
        counts.work_descriptors += extra;
        counts.staging += crate::checkpoint_install::METADATA_BYTES;
        counts.checkpoint_install += bytes;
        self.demand.children = 2;
        self.demand.descriptors = descriptors;
        self.demand.staging = crate::checkpoint_install::METADATA_BYTES;
        self.demand.checkpoint_install = bytes;
        Ok(())
    }
    pub(crate) fn promote_checkpoint_material(&mut self, bytes: u64) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let staging = crate::checkpoint_materialize::METADATA_BYTES;
        let descriptors = JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM;
        if !self.pool.available()
            || !matches!(self.demand.lane, Lane::Work)
            || bytes == 0
            || bytes > JOB_CHECKPOINT_MATERIAL_BYTES
            || self.demand.checkpoint_metadata != JOB_CHECKPOINT_METADATA_BYTES
            || self.demand.checkpoint_staging == 0
            || self.demand.checkpoint_material != 0
            || self.demand.checkpoint_install != 0
            || self.demand.children != 1
            || self.demand.descriptors > descriptors
            || self.demand.staging != 0
            || self.demand.registry_staging != 0
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        let extra_fd = descriptors - self.demand.descriptors;
        if counts.children + 1 > JOB_CHILDREN
            || counts.descriptors + extra_fd > JOB_DESCRIPTORS
            || counts.work_descriptors + extra_fd > descriptors
            || counts.staging + staging > JOB_STAGING_BYTES
            || counts.checkpoint_material + bytes > JOB_CHECKPOINT_MATERIAL_BYTES
        {
            return Err(Error::before(ErrorCode::Admission));
        }
        fd_admission(counts.descriptors + extra_fd)?;
        counts.children += 1;
        counts.descriptors += extra_fd;
        counts.work_descriptors += extra_fd;
        counts.staging += staging;
        counts.checkpoint_material += bytes;
        self.demand.children = 2;
        self.demand.descriptors = descriptors;
        self.demand.staging = staging;
        self.demand.checkpoint_material = bytes;
        Ok(())
    }

    /// Only after exact worker collection and metadata/spool cleanup. The
    /// decoded-material allowance follows the returned input until destruction.
    pub(crate) fn collected_checkpoint_material(&mut self) -> Result<()> {
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if self.demand.children != 2
            || self.demand.descriptors != JOB_DESCRIPTORS - JOB_CONTROL_HEADROOM
            || self.demand.checkpoint_material == 0
            || self.demand.staging != crate::checkpoint_materialize::METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        counts.children -= 1;
        counts.descriptors -= self.demand.descriptors - 16;
        counts.work_descriptors -= self.demand.descriptors - 16;
        counts.staging -= self.demand.staging;
        self.demand.children = 1;
        self.demand.descriptors = 16;
        self.demand.staging = 0;
        Ok(())
    }

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
            || demand.checkpoint_staging != 0
            || demand.checkpoint_metadata != 0
            || demand.checkpoint_material != 0
            || demand.checkpoint_install != 0
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
            || self.demand.checkpoint_staging != 0
            || self.demand.checkpoint_metadata != 0
            || self.demand.checkpoint_material != 0
            || self.demand.checkpoint_install != 0
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

pub(crate) struct BranchBackingLease {
    pool: JobPool,
    bytes: u64,
}
impl BranchBackingLease {
    /// Caller holds original branch authority and has synchronized its exact
    /// backing-release receipt. Result metadata survives material retirement.
    pub(crate) fn release_material(&mut self, expected: u64) -> Result<()> {
        if expected == 0 || (self.bytes != 0 && self.bytes != expected) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut counts = self
            .pool
            .0
            .counts
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if counts.checkpoint_material < self.bytes {
            return Err(Error::before(ErrorCode::Ownership));
        }
        counts.checkpoint_material -= self.bytes;
        self.bytes = 0;
        Ok(())
    }
    pub(crate) fn material_bytes(&self) -> u64 {
        self.bytes
    }
}
impl Drop for BranchBackingLease {
    fn drop(&mut self) {
        let mut counts = self.pool.0.counts.lock().unwrap_or_else(|e| e.into_inner());
        counts.checkpoint_material -= self.bytes;
        counts.branch_metadata -= BRANCH_BACKING_METADATA;
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
    fn later_branch_release_has_fresh_work_and_metadata_without_a_second_backing_charge() {
        let pool = JobPool::default();
        let mut creation = pool.acquire(Demand::branch_source()).unwrap();
        creation.promote_branch_preparation().unwrap();
        creation.promote_branch_backing(7 << 30).unwrap();
        let backing = creation.handoff_branch().unwrap();
        drop(creation);
        let old = crate::ReadBudget::new(
            std::time::Duration::from_secs(1),
            crate::Cancellation::default(),
        )
        .unwrap();
        old.cancel.cancel();
        let fresh = crate::ReadBudget::new(
            std::time::Duration::from_secs(1),
            crate::Cancellation::default(),
        )
        .unwrap();
        assert!(old.check().is_err());
        fresh.check().unwrap();
        let release = pool.acquire(Demand::branch_release()).unwrap();
        let result = pool.branch_result_metadata().unwrap();
        assert_eq!(pool.counts().checkpoint_material, 7 << 30);
        assert_eq!(pool.counts().branch_metadata, 2 * BRANCH_BACKING_METADATA);
        assert_eq!(
            (
                pool.counts().work,
                pool.counts().children,
                pool.counts().work_descriptors
            ),
            (1, 0, 20)
        );
        let observers = [
            pool.acquire(Demand::volume_observation()).unwrap(),
            pool.acquire(Demand::volume_observation()).unwrap(),
        ];
        drop((release, observers));
        assert_eq!(
            pool.counts(),
            Counts {
                checkpoint_material: 7 << 30,
                branch_metadata: 2 * BRANCH_BACKING_METADATA,
                ..Counts::default()
            }
        );
        drop((backing, result)); // Pure accounting model, no backing disposal claim.
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn full_or_quarantined_result_metadata_rejects_before_changing_accounting() {
        let pool = JobPool::default();
        pool.0.counts.lock().unwrap().branch_metadata = BRANCH_BACKING_METADATA_BYTES;
        let before = pool.counts();
        assert!(pool.branch_result_metadata().is_err());
        assert_eq!(pool.counts(), before);
        pool.0.counts.lock().unwrap().branch_metadata = 0;
        pool.quarantine();
        assert!(pool.branch_result_metadata().is_err());
        assert_eq!(pool.counts(), Counts::default());
        assert!(pool.acquire(Demand::volume_observation()).is_ok());
    }
    #[test]
    fn branch_handoff_frees_execution_and_parser_capacity_without_freeing_backing() {
        let pool = JobPool::default();
        let mut work = pool.acquire(Demand::branch_source()).unwrap();
        work.promote_branch_preparation().unwrap();
        work.promote_branch_backing(7 << 30).unwrap();
        let backing = work.handoff_branch().unwrap();
        let retained = Counts {
            checkpoint_material: 7 << 30,
            branch_metadata: BRANCH_BACKING_METADATA,
            ..Counts::default()
        };
        assert_eq!(pool.counts(), retained);
        assert!(work.handoff_branch().is_err());
        drop(work);
        assert_eq!(pool.counts(), retained);
        let mut next = pool.acquire(Demand::branch_source()).unwrap();
        next.promote_branch_preparation().unwrap();
        next.promote_branch_backing(7 << 30).unwrap();
        let controls = [
            pool.acquire(Demand::volume_observation()).unwrap(),
            pool.acquire(Demand::volume_observation()).unwrap(),
        ];
        assert_eq!(pool.counts().checkpoint_material, 14 << 30);
        assert_eq!(pool.counts().branch_metadata, BRANCH_BACKING_METADATA);
        drop((controls, next));
        assert_eq!(pool.counts(), retained);
        // Lease destruction here is a pure accounting model, never disposal proof.
        drop(backing);
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn unfunded_or_quarantined_branch_cannot_retire_its_work_charge() {
        let pool = JobPool::default();
        let mut work = pool.acquire(Demand::branch_source()).unwrap();
        let before = pool.counts();
        assert!(work.handoff_branch().is_err());
        assert_eq!(pool.counts(), before);
        work.promote_branch_preparation().unwrap();
        let before = pool.counts();
        assert!(work.handoff_branch().is_err());
        assert_eq!(pool.counts(), before);
        work.promote_branch_backing(7 << 30).unwrap();
        pool.quarantine();
        let before = pool.counts();
        assert!(work.handoff_branch().is_err());
        assert_eq!(pool.counts(), before);
    }
    #[test]
    fn resolved_original_handoff_preserves_backing_under_quarantine_and_never_grants_new_work() {
        let pool = JobPool::default();
        let mut original = pool.acquire(Demand::branch_source()).unwrap();
        original.promote_branch_preparation().unwrap();
        original.promote_branch_backing(7 << 30).unwrap();
        pool.quarantine();
        let before = pool.counts();
        assert!(original.check_branch_handoff().is_err());
        original.check_resolved_branch_handoff().unwrap();
        assert_eq!(pool.counts(), before);
        let backing = original.handoff_resolved_branch().unwrap();
        assert_eq!(
            pool.counts(),
            Counts {
                checkpoint_material: 7 << 30,
                branch_metadata: BRANCH_BACKING_METADATA,
                ..Counts::default()
            }
        );
        assert!(original.handoff_resolved_branch().is_err());
        assert!(pool.acquire(Demand::branch_source()).is_err());
        let observers = [
            pool.acquire(Demand::volume_observation()).unwrap(),
            pool.acquire(Demand::volume_observation()).unwrap(),
        ];
        drop((observers, original));
        assert_eq!(pool.counts().checkpoint_material, 7 << 30);
        drop(backing); // Private accounting model, never proof of disk cleanup.
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn branch_backing_promotion_is_exact_retained_and_competes_with_saved_state_material() {
        let pool = JobPool::default();
        let mut branch = pool.acquire(Demand::branch_source()).unwrap();
        branch.promote_branch_preparation().unwrap();
        let occupied = pool
            .acquire(Demand {
                checkpoint_material: JOB_CHECKPOINT_MATERIAL_BYTES,
                ..Demand::observation()
            })
            .unwrap();
        let before = pool.counts();
        assert!(branch.promote_branch_backing(7 << 30).is_err());
        assert_eq!(pool.counts(), before);
        drop(occupied);
        branch.promote_branch_backing(7 << 30).unwrap();
        let funded = pool.counts();
        assert_eq!(funded.checkpoint_material, 7 << 30);
        branch.promote_branch_backing(7 << 30).unwrap();
        branch.promote_branch_preparation().unwrap();
        assert_eq!(pool.counts(), funded);
        assert!(branch.promote_branch_backing(8 << 30).is_err());
        assert_eq!(pool.counts(), funded);
        let first = pool.acquire(Demand::volume_observation()).unwrap();
        let second = pool.acquire(Demand::volume_observation()).unwrap();
        drop((first, second, branch));
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn branch_preparation_promotes_original_admission_atomically_and_keeps_both_observers() {
        for held in [
            Demand {
                children: JOB_CHILDREN,
                ..Demand::observation()
            },
            Demand {
                checkpoint_metadata: JOB_CHECKPOINT_METADATA_BYTES,
                ..Demand::observation()
            },
        ] {
            let pool = JobPool::default();
            let mut source = pool.acquire(Demand::branch_source()).unwrap();
            let occupied = pool.acquire(held).unwrap();
            let before = pool.counts();
            assert!(source.promote_branch_preparation().is_err());
            assert_eq!(pool.counts(), before);
            drop(occupied);
            source.promote_branch_preparation().unwrap();
            let ready = pool.counts();
            assert_eq!(
                (ready.work, ready.children, ready.work_descriptors),
                (1, 2, 24)
            );
            assert_eq!(ready.work_metadata, JOB_METADATA_BYTES);
            assert_eq!(ready.checkpoint_metadata, JOB_CHECKPOINT_METADATA_BYTES);
            assert_eq!(
                ready.staging,
                crate::branch_worker::METADATA_BYTES + crate::branch_worker::OUTPUT_BYTES
            );
            source.promote_branch_preparation().unwrap();
            assert_eq!(pool.counts(), ready);
            let first = pool.acquire(Demand::volume_observation()).unwrap();
            let second = pool.acquire(Demand::volume_observation()).unwrap();
            assert!(pool.acquire(Demand::volume_observation()).is_err());
            drop((first, second, source));
            assert_eq!(pool.counts(), Counts::default());
        }
    }

    #[test]
    fn export_conversion_promotes_one_job_atomically_and_keeps_reserved_controls() {
        let pool = JobPool::default();
        let mut source = pool.acquire(Demand::export_source()).unwrap();
        source.promote_export_disks().unwrap();
        let occupied = pool
            .acquire(Demand {
                children: JOB_CHILDREN,
                ..Demand::observation()
            })
            .unwrap();
        let before = pool.counts();
        assert!(source.promote_export_conversion().is_err());
        assert_eq!(before, pool.counts());
        drop(occupied);
        source.promote_export_conversion().unwrap();
        let reserved = pool.counts();
        assert_eq!(
            (reserved.work, reserved.work_descriptors, reserved.children),
            (1, 24, 2)
        );
        source.promote_export_conversion().unwrap();
        source.promote_export_stage().unwrap();
        assert_eq!(reserved, pool.counts());
        let first = pool.acquire(Demand::observation()).unwrap();
        let second = pool.acquire(Demand::observation()).unwrap();
        assert_eq!(pool.counts().descriptors, JOB_DESCRIPTORS);
        assert_eq!(pool.counts().control, 2);
        pool.quarantine();
        let held = pool.counts();
        assert!(source.promote_export_conversion().is_err());
        assert_eq!(held, pool.counts());
        drop(source);
        assert_eq!((pool.counts().children, pool.counts().work), (0, 0));
        drop((first, second));
        assert_eq!(pool.counts(), Counts::default());
        assert!(!pool.available());
    }

    #[test]
    fn material_resolution_has_finite_independent_room_while_capture_work_is_retained() {
        let pool = JobPool::default();
        let mut capture = pool
            .acquire(Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        capture
            .promote_checkpoint_material(JOB_CHECKPOINT_MATERIAL_BYTES)
            .unwrap();
        let retained = pool.counts();
        let resolution = pool.acquire(Demand::material_resolution()).unwrap();
        assert_eq!(pool.counts().work_metadata, retained.work_metadata);
        assert_eq!(
            pool.counts().checkpoint_staging,
            retained.checkpoint_staging
        );
        assert_eq!(
            pool.counts().material_control_metadata,
            JOB_MATERIAL_CONTROL_METADATA_BYTES
        );
        assert!(pool.acquire(Demand::material_resolution()).is_err());
        let observer = pool.acquire(Demand::volume_observation()).unwrap();
        assert_eq!(pool.counts().control, 2);
        drop(observer);
        drop(resolution);
        assert_eq!(pool.counts(), retained);
        pool.quarantine();
        assert!(pool.acquire(Demand::growth_repair()).is_err());
        let resolution = pool.acquire(Demand::material_resolution()).unwrap();
        let observer = pool.acquire(Demand::volume_observation()).unwrap();
        drop((observer, resolution));
        assert_eq!(pool.counts(), retained);
        drop(capture);
        assert_eq!(pool.counts(), Counts::default());
    }

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
    fn mounted_file_promotion_keeps_one_job_and_both_control_observers() {
        let pool = JobPool::default();
        let mut mount = pool.acquire(Demand::volume_mounts(8).unwrap()).unwrap();
        let controls = [
            pool.acquire(Demand::volume_observation()).unwrap(),
            pool.acquire(Demand::volume_observation()).unwrap(),
        ];
        let demand = Demand::image_transfer(16 * 1024 * 1024, 1024).unwrap();
        mount.promote_mount_worker(demand).unwrap();
        let counts = pool.counts();
        assert_eq!(counts.work, 1);
        assert_eq!(counts.children, 1);
        assert_eq!(counts.staging, 16 * 1024 * 1024);
        assert_eq!(counts.work_descriptors, 24);
        assert_eq!(counts.work_metadata, JOB_METADATA_BYTES);
        mount.promote_mount_worker(demand).unwrap();
        assert_eq!(pool.counts(), counts);
        pool.quarantine();
        assert!(pool.acquire(Demand::transfer(1).unwrap()).is_err());
        assert_eq!(pool.counts(), counts);
        drop(controls);
        drop(mount);
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
                checkpoint_staging: 0,
                checkpoint_metadata: 0,
                checkpoint_material: 0,
                checkpoint_install: 0,
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
                checkpoint_staging: 0,
                checkpoint_metadata: 0,
                checkpoint_material: 0,
                checkpoint_install: 0,
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
    fn install_promotion_retains_source_material_and_charges_distinct_output_work() {
        let pool = JobPool::default();
        let mut lease = pool
            .acquire(Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        lease.promote_checkpoint_material(4096).unwrap();
        lease.collected_checkpoint_material().unwrap();
        let before = pool.counts();
        assert!(lease
            .promote_checkpoint_install(JOB_CHECKPOINT_MATERIAL_BYTES + 1)
            .is_err());
        assert_eq!(pool.counts(), before);
        lease.promote_checkpoint_install(4096).unwrap();
        assert_eq!(pool.counts().checkpoint_material, 4096);
        assert_eq!(pool.counts().checkpoint_install, 4096);
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().children, 2);
        let control = pool.acquire(Demand::observation()).unwrap();
        let sibling = pool.acquire(Demand::observation()).unwrap();
        assert!(lease.promote_checkpoint_install(4096).is_err());
        assert!(lease.collected_checkpoint_material().is_err());
        drop((lease, control, sibling));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn checkpoint_material_promotion_is_atomic_and_collection_keeps_private_bytes_charged() {
        let pool = JobPool::default();
        let mut lease = pool
            .acquire(Demand::checkpoint_prepare(1024).unwrap())
            .unwrap();
        let before = pool.counts();
        assert!(lease
            .promote_checkpoint_material(JOB_CHECKPOINT_MATERIAL_BYTES + 1)
            .is_err());
        assert_eq!(pool.counts(), before);
        lease.promote_checkpoint_material(4096).unwrap();
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().children, 2);
        assert_eq!(pool.counts().checkpoint_material, 4096);
        assert_eq!(pool.counts().checkpoint_staging, before.checkpoint_staging);
        let control = pool.acquire(Demand::observation()).unwrap();
        let sibling = pool.acquire(Demand::observation()).unwrap();
        assert!(lease.promote_checkpoint_material(4096).is_err());
        lease.collected_checkpoint_material().unwrap();
        assert_eq!(pool.counts().children, 1);
        assert_eq!(pool.counts().staging, 0);
        assert_eq!(pool.counts().checkpoint_material, 4096);
        assert_eq!(pool.counts().control, 2);
        assert!(lease.collected_checkpoint_material().is_err());
        drop((lease, control, sibling));
        assert_eq!(pool.counts(), Counts::default());
    }

    #[test]
    fn checkpoint_prepare_has_separate_finite_staging_parser_room_and_control_headroom() {
        assert!(Demand::checkpoint_prepare(0).is_err());
        assert!(Demand::checkpoint_prepare(crate::CHECKPOINT_ARTIFACT_BYTES + 1).is_err());
        let pool = JobPool::default();
        let demand = Demand::checkpoint_prepare(crate::CHECKPOINT_ARTIFACT_BYTES).unwrap();
        let lease = pool.acquire(demand).unwrap();
        assert_eq!(
            pool.counts().checkpoint_staging,
            crate::CHECKPOINT_ARTIFACT_BYTES + crate::checkpoint::HISTORY_STAGING_BYTES
        );
        assert!(pool.counts().checkpoint_staging <= JOB_CHECKPOINT_STAGING_BYTES);
        assert_eq!(pool.counts().registry_staging, 0);
        assert_eq!(pool.counts().staging, 0);
        assert_eq!(
            pool.counts().checkpoint_metadata,
            JOB_CHECKPOINT_METADATA_BYTES
        );
        assert_eq!(pool.counts().work_metadata, JOB_METADATA_BYTES);
        assert!(pool.acquire(demand).is_err());
        let control = pool.acquire(Demand::observation()).unwrap();
        let sibling = pool.acquire(Demand::observation()).unwrap();
        drop(lease);
        assert_eq!(pool.counts().checkpoint_staging, 0);
        assert_eq!(pool.counts().checkpoint_metadata, 0);
        assert!(pool
            .acquire(Demand::registry_download(JOB_REGISTRY_STAGING_BYTES).unwrap())
            .is_ok());
        drop((control, sibling));
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
    fn registry_provider_reservation_preserves_two_control_observers_during_retirement() {
        for demand in [
            Demand::oci_metadata(),
            Demand::registry_download(1).unwrap(),
        ] {
            let pool = JobPool::default();
            let work = pool.acquire(demand).unwrap();
            assert_eq!(pool.counts().children, 1);
            assert_eq!(pool.counts().work_descriptors, 20);
            assert_eq!(pool.counts().work_metadata, JOB_METADATA_BYTES);
            pool.quarantine();
            let controls = [
                pool.acquire(Demand::observation()).unwrap(),
                pool.acquire(Demand::observation()).unwrap(),
            ];
            assert_eq!(pool.counts().children, 1);
            assert_eq!(pool.counts().control, 2);
            assert!(pool.acquire(Demand::oci_metadata()).is_err());
            drop(work); // modeled exact-child + both-pipe collection, never timeout
            assert_eq!(pool.counts().children, 0);
            assert_eq!(pool.counts().control, 2);
            assert!(!pool.available());
            drop(controls);
            assert_eq!(pool.counts(), Counts::default());
        }
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
    fn activated_file_job_retains_metadata_and_descriptors_while_control_stays_available() {
        let pool = JobPool::default();
        let lease = pool
            .acquire(Demand::image_transfer(16 * 1024 * 1024, 1024).unwrap())
            .unwrap();
        let charged = pool.counts();
        assert_eq!(charged.children, 1);
        assert_eq!(charged.work, 1);
        assert_eq!(charged.staging, 16 * 1024 * 1024);
        assert_eq!(charged.metadata, 8 * 1024 * 1024 + 1024);
        assert_eq!(charged.work_descriptors, 24);
        assert!(pool.acquire(Demand::image_transfer(1, 1).unwrap()).is_err());
        assert!(Demand::image_transfer(1, 0).is_err());
        assert!(Demand::image_transfer(1, crate::buffered::COMMAND_METADATA_BYTES + 1).is_err());
        let controls = [
            pool.acquire(Demand::observation()).unwrap(),
            pool.acquire(Demand::observation()).unwrap(),
        ];
        assert_eq!(pool.counts().work_descriptors, charged.work_descriptors);
        drop(controls);
        assert_eq!(pool.counts(), charged);
        drop(lease);
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
                branch_metadata: 0,
                control: 2,
                children: 3,
                descriptors: 24,
                work_descriptors: 16,
                registry_staging: 0,
                checkpoint_staging: 0,
                checkpoint_metadata: 0,
                checkpoint_material: 0,
                checkpoint_install: 0,
                staging: 48 * 1024 * 1024,
                export_staging: 0,
                metadata: 0,
                work_metadata: 0,
                material_control_metadata: 0,
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
            checkpoint_staging: 0,
            checkpoint_metadata: 0,
            checkpoint_material: 0,
            checkpoint_install: 0,
            staging: 0,
            metadata: 0,
        };
        assert_eq!(
            pool.acquire(demand).err().unwrap().code,
            ErrorCode::Admission
        );
        assert_eq!(pool.counts(), Counts::default());
    }
    #[test]
    fn export_byte_allowance_is_aggregate_retained_and_independent_of_control_or_work_slots() {
        let pool = JobPool::default();
        let lease = pool
            .export_staging(JOB_EXPORT_STAGING_BYTES, false)
            .unwrap();
        assert_eq!(pool.counts().work, 0);
        assert_eq!(pool.counts().export_staging, JOB_EXPORT_STAGING_BYTES);
        assert!(pool.export_staging(1, false).is_err());
        let control = pool.acquire(Demand::observation()).unwrap();
        assert_eq!(pool.counts().export_staging, JOB_EXPORT_STAGING_BYTES);
        drop(control);
        drop(lease);
        assert_eq!(pool.counts(), Counts::default());
        pool.quarantine();
        assert!(pool.export_staging(1, false).is_err());
        let restored = pool.export_staging(1, true).unwrap();
        assert_eq!(pool.counts().export_staging, 1);
        drop(restored);
    }
}
