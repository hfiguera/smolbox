//! Bounded read-only observations. Neither a snapshot nor a process sample is
//! creation authority. SDK state-probe/convenience inventory helpers may open a
//! writer DB or reconcile state, so this module never calls them.
use crate::{Cancellation, CreationReceipt, Engine, Error, ErrorCode, Observation, Result};
use smolvm::config::VmRecord;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::time::{Duration, Instant};

pub const MAX_RECORDS: usize = 1024;
pub const MAX_RECORD_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_SNAPSHOT_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_INVENTORY_BYTES: usize = 4 * 1024 * 1024;
const CPU_SAMPLE: Duration = Duration::from_millis(25);
const MIB: u64 = 1024 * 1024;

#[derive(Clone)]
pub struct ReadBudget {
    pub(crate) deadline: Instant,
    pub(crate) cancel: Cancellation,
}
impl ReadBudget {
    /// Volume mutation shares one caller deadline through filesystem stages.
    /// Read-only constructors retain their separate thirty-second ceiling.
    pub fn for_volume_work(remaining: Duration, cancel: Cancellation) -> Result<Self> {
        if remaining.is_zero() || remaining > Duration::from_millis(crate::VOLUME_WORK_MS) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            deadline: Instant::now() + remaining,
            cancel,
        })
    }

    pub fn new(remaining: Duration, cancel: Cancellation) -> Result<Self> {
        if remaining.is_zero() || remaining > Duration::from_secs(30) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            deadline: Instant::now() + remaining,
            cancel,
        })
    }
    pub(crate) fn check(&self) -> Result<()> {
        if self.cancel.is_cancelled() || Instant::now() >= self.deadline {
            Err(Error::before(ErrorCode::State))
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod volume_budget_tests {
    use super::*;
    #[test]
    fn volume_work_preserves_long_caller_budget_and_shared_cancellation_without_widening_observers()
    {
        let cancel = Cancellation::default();
        assert!(ReadBudget::new(Duration::from_secs(3600), cancel.clone()).is_err());
        let work = ReadBudget::for_volume_work(Duration::from_secs(3600), cancel.clone()).unwrap();
        work.check().unwrap();
        cancel.cancel();
        assert_eq!(work.check().unwrap_err().code, ErrorCode::State);
        assert!(ReadBudget::for_volume_work(Duration::ZERO, Cancellation::default()).is_err());
        assert!(
            ReadBudget::for_volume_work(Duration::from_secs(86_401), Cancellation::default())
                .is_err()
        );
    }
}
#[derive(Clone, Copy)]
pub struct HealthSnapshot {
    pub total: u64,
    pub running: u64,
    pub uptime_seconds: u64,
}
pub struct InventorySnapshot {
    pub count: u64,
    pub bytes: Vec<u8>,
}
#[derive(Clone, Default)]
pub struct MachineCounters {
    pub cpu_seconds: Option<u64>,
    pub cpu_millis: Option<u64>,
    pub rss_mb: Option<u64>,
    pub pss_mb: Option<u64>,
    pub private_memory_mb: Option<u64>,
    pub shared_memory_mapped_mb: Option<u64>,
    pub disk_used_mb: Option<u64>,
    pub egress_bytes: Option<u64>,
}
pub struct CapacitySnapshot {
    pub allocated_cpus: u64,
    pub allocated_memory_mb: u64,
    pub used_cpu_millis: u64,
    pub used_memory_mb: u64,
    pub used_memory_pss_mb: Option<u64>,
    pub used_memory_private_mb: Option<u64>,
    pub used_memory_shared_mapped_mb: Option<u64>,
    pub host_memory_total_mb: Option<u64>,
    pub host_memory_available_mb: Option<u64>,
    pub used_disk_gb: u64,
    pub boot_id: Option<String>,
}

impl Engine {
    pub fn node_health(&self, budget: &ReadBudget) -> Result<HealthSnapshot> {
        let _job = self.jobs.acquire(crate::jobs::Demand::observation())?;
        let records = self.observation_records(budget)?;
        let running = records.iter().try_fold(0, |sum, record| {
            budget.check()?;
            Ok::<_, Error>(sum + u64::from(live_pid(record)?.is_some()))
        })?;
        Ok(HealthSnapshot {
            total: records.len() as u64,
            running,
            uptime_seconds: self.observation_uptime(),
        })
    }

    pub fn inventory(&self, budget: &ReadBudget) -> Result<InventorySnapshot> {
        let _job = self.jobs.acquire(crate::jobs::Demand::observation())?;
        let records = self.observation_records(budget)?;
        let mut bytes = vec![b'['];
        for (index, record) in records.iter().enumerate() {
            budget.check()?;
            let has_children = records
                .iter()
                .any(|child| child.golden.as_deref() == Some(record.name.as_str()));
            let state = crate::identity::record_state(record, has_children);
            let state = match state {
                crate::ObservedState::Stopped => "stopped",
                crate::ObservedState::Running => {
                    let directory = self.vm_directory(&record.name);
                    crate::host::unredirected(&directory)?;
                    smolvm::agent::AgentClient::connect_for_state_probe(
                        directory.join("agent.sock"),
                    )
                    .and_then(|mut client| client.ping())
                    .map_err(|_| Error::before(ErrorCode::State))?;
                    budget.check()?;
                    if live_pid(record)?.is_none() {
                        return Err(Error::before(ErrorCode::State));
                    }
                    "running"
                }
                _ => return Err(Error::before(ErrorCode::State)),
            };
            let body = inventory_value(record, state)?;
            let encoded =
                serde_json::to_vec(&body).map_err(|_| Error::before(ErrorCode::Native))?;
            if bytes.len() + encoded.len() + 2 > MAX_INVENTORY_BYTES {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            if index != 0 {
                bytes.push(b',');
            }
            bytes.extend_from_slice(&encoded);
        }
        bytes.push(b']');
        budget.check()?;
        Ok(InventorySnapshot {
            count: records.len() as u64,
            bytes,
        })
    }

    pub fn node_capacity(&self, budget: &ReadBudget) -> Result<CapacitySnapshot> {
        let _job = self.jobs.acquire(crate::jobs::Demand::observation())?;
        let records = self.observation_records(budget)?;
        let mut first = Vec::new();
        let started = Instant::now();
        for record in &records {
            budget.check()?;
            if let Some((pid, birth)) = live_pid(record)? {
                let stats =
                    smolvm::process::process_stats(pid).ok_or(Error::before(ErrorCode::State))?;
                first.push((record, pid, birth, stats, Instant::now()));
            }
        }
        if !first.is_empty() {
            while started.elapsed() < CPU_SAMPLE {
                budget.check()?;
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        let mut result = CapacitySnapshot {
            allocated_cpus: 0,
            allocated_memory_mb: 0,
            used_cpu_millis: 0,
            used_memory_mb: 0,
            used_memory_pss_mb: Some(0),
            used_memory_private_mb: Some(0),
            used_memory_shared_mapped_mb: Some(0),
            host_memory_total_mb: None,
            host_memory_available_mb: None,
            used_disk_gb: 0,
            boot_id: self.observation_epoch(),
        };
        let mut rss = 0;
        let mut pss = Some(0);
        let mut private = Some(0);
        let mut shared = Some(0);
        let mut disk = 0;
        for (record, pid, birth, prior, at) in first {
            budget.check()?;
            let current =
                smolvm::process::process_stats(pid).ok_or(Error::before(ErrorCode::State))?;
            let sampled = Instant::now();
            let memory = smolvm::process::process_memory_stats(pid);
            if !smolvm::process::is_our_process_strict(pid, Some(birth))
                || current.cpu_time_ns < prior.cpu_time_ns
            {
                return Err(Error::before(ErrorCode::State));
            }
            result.allocated_cpus += u64::from(record.cpus);
            result.allocated_memory_mb += u64::from(record.mem);
            let rate: u64 = ((u128::from(current.cpu_time_ns - prior.cpu_time_ns) * 1000)
                / sampled.duration_since(at).as_nanos().max(1))
            .try_into()
            .map_err(|_| Error::before(ErrorCode::OutputLimit))?;
            add(&mut result.used_cpu_millis, rate)?;
            add(&mut rss, current.rss_bytes)?;
            add_optional(&mut pss, memory.and_then(|m| m.pss_bytes))?;
            add_optional(&mut private, memory.and_then(|m| m.private_bytes))?;
            add_optional(&mut shared, memory.and_then(|m| m.shared_mapped_bytes))?;
            let directory = self.vm_directory(&record.name);
            for filename in [
                smolvm::storage::STORAGE_DISK_FILENAME,
                smolvm::storage::OVERLAY_DISK_FILENAME,
            ] {
                let (path, _) = smolvm::agent::resolve_disk_image(&directory, filename);
                add(
                    &mut disk,
                    plain_file(&path)?
                        .metadata()
                        .map_err(|_| Error::before(ErrorCode::Io))?
                        .len(),
                )?;
            }
        }
        result.used_memory_mb = rss / MIB;
        result.used_memory_pss_mb = pss.map(|v| v / MIB);
        result.used_memory_private_mb = private.map(|v| v / MIB);
        result.used_memory_shared_mapped_mb = shared.map(|v| v / MIB);
        result.used_disk_gb = disk / (1024 * MIB);
        if let Some(host) = smolvm::process::host_memory_stats() {
            result.host_memory_total_mb = Some(host.total_bytes / MIB);
            result.host_memory_available_mb = Some(host.available_bytes / MIB);
        }
        let after = self.observation_records(budget)?;
        if records.len() != after.len() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        for (a, b) in records.iter().zip(&after) {
            budget.check()?;
            if a.name != b.name
                || a.pid != b.pid
                || a.pid_start_time != b.pid_start_time
                || crate::identity::material_hash(a)? != crate::identity::material_hash(b)?
            {
                return Err(Error::before(ErrorCode::Conflict));
            }
        }
        Ok(result)
    }

    pub fn machine_counters(
        &self,
        receipt: &CreationReceipt,
        budget: &ReadBudget,
    ) -> Result<(Observation, MachineCounters)> {
        let _job = self.jobs.acquire(crate::jobs::Demand::observation())?;
        budget.check()?;
        receipt.validate(self.binding())?;
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let records = self.observation_records(budget)?;
        let Some(record) = records.iter().find(|r| r.name == receipt.name) else {
            return Ok((
                self.observation_missing(receipt)?,
                MachineCounters::default(),
            ));
        };
        self.verify_record(receipt, record)?;
        let has_children = records
            .iter()
            .any(|child| child.golden.as_deref() == Some(record.name.as_str()));
        let mut state = crate::identity::record_state(record, has_children);
        let pid_identity = if state == crate::ObservedState::Running {
            let pid = live_pid(record)?;
            let socket = self.vm_directory(&record.name).join("agent.sock");
            if smolvm::agent::AgentClient::connect_for_state_probe(socket)
                .and_then(|mut client| client.ping())
                .is_err()
            {
                state = crate::ObservedState::Unreachable;
            }
            pid
        } else {
            None
        };
        let observation = Observation {
            state,
            configuration: crate::MachineConfiguration::observe(record),
            pid_identity,
            resources: Some(crate::Resources {
                cpus: record.cpus,
                memory_mib: record.mem,
                storage_gib: record
                    .storage_gb
                    .unwrap_or(smolvm::storage::DEFAULT_STORAGE_SIZE_GIB),
                overlay_gib: record
                    .overlay_gb
                    .unwrap_or(smolvm::storage::DEFAULT_OVERLAY_SIZE_GIB),
            }),
        };
        let mut result = MachineCounters::default();
        if let Some((pid, birth)) = observation.pid_identity {
            if let Some(stats) = smolvm::process::process_stats(pid) {
                result.cpu_seconds = Some(stats.cpu_time_ns / 1_000_000_000);
                result.cpu_millis = Some(stats.cpu_time_ns / 1_000_000);
                result.rss_mb = Some(stats.rss_bytes / MIB);
            }
            if let Some(memory) = smolvm::process::process_memory_stats(pid) {
                result.pss_mb = memory.pss_bytes.map(|v| v / MIB);
                result.private_memory_mb = memory.private_bytes.map(|v| v / MIB);
                result.shared_memory_mapped_mb = memory.shared_mapped_bytes.map(|v| v / MIB);
            }
            if !smolvm::process::is_our_process_strict(pid, Some(birth)) {
                return Err(Error::before(ErrorCode::State));
            }
        }
        let directory = self.vm_directory(&receipt.name);
        #[cfg(target_os = "linux")]
        {
            result.disk_used_mb = Some(disk_blocks(&directory, budget)? / MIB);
        }
        let telemetry = directory.join("egress");
        if telemetry.exists() {
            let mut body = Vec::new();
            plain_file(&telemetry)?
                .take(33)
                .read_to_end(&mut body)
                .map_err(|_| Error::before(ErrorCode::Io))?;
            if body.len() > 32 {
                return Err(Error::before(ErrorCode::OutputLimit));
            }
            result.egress_bytes = std::str::from_utf8(&body)
                .ok()
                .and_then(|text| text.trim().parse().ok());
        }
        budget.check()?;
        let after = self.observation_records(budget)?;
        let latest = after
            .iter()
            .find(|r| r.name == receipt.name)
            .ok_or(Error::before(ErrorCode::State))?;
        self.verify_record(receipt, latest)?;
        if latest.pid != record.pid || latest.pid_start_time != record.pid_start_time {
            return Err(Error::before(ErrorCode::Conflict));
        }
        Ok((observation, result))
    }
}

fn live_pid(record: &VmRecord) -> Result<Option<(i32, u64)>> {
    let Some(pid) = record.pid else {
        return Ok(None);
    };
    if !smolvm::process::is_alive(pid) {
        return Ok(None);
    }
    let birth = record
        .pid_start_time
        .ok_or(Error::before(ErrorCode::State))?;
    if !smolvm::process::is_our_process_strict(pid, Some(birth)) {
        return Err(Error::before(ErrorCode::State));
    }
    Ok(Some((pid, birth)))
}

fn plain_file(path: &Path) -> Result<File> {
    crate::host::unredirected(path)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(file)
}
#[cfg(target_os = "linux")]
fn disk_blocks(root: &Path, budget: &ReadBudget) -> Result<u64> {
    let mut entries = 0;
    let mut total = 0;
    walk_blocks(root, 0, &mut entries, &mut total, budget)?;
    Ok(total)
}
#[cfg(target_os = "linux")]
fn walk_blocks(
    path: &Path,
    depth: u32,
    entries: &mut u64,
    total: &mut u64,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check()?;
    if depth > 32 {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    crate::host::unredirected(path)?;
    for entry in std::fs::read_dir(path).map_err(|_| Error::before(ErrorCode::Io))? {
        budget.check()?;
        *entries += 1;
        if *entries > 65536 {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        let entry = entry.map_err(|_| Error::before(ErrorCode::Io))?;
        let metadata =
            std::fs::symlink_metadata(entry.path()).map_err(|_| Error::before(ErrorCode::Io))?;
        if metadata.is_dir() {
            walk_blocks(&entry.path(), depth + 1, entries, total, budget)?;
        } else {
            add(
                total,
                metadata
                    .blocks()
                    .checked_mul(512)
                    .ok_or(Error::before(ErrorCode::OutputLimit))?,
            )?;
        }
    }
    Ok(())
}
fn add(value: &mut u64, more: u64) -> Result<()> {
    *value = value
        .checked_add(more)
        .ok_or(Error::before(ErrorCode::OutputLimit))?;
    Ok(())
}
fn add_optional(value: &mut Option<u64>, more: Option<u64>) -> Result<()> {
    *value = match (*value, more) {
        (Some(a), Some(b)) => Some(
            a.checked_add(b)
                .ok_or(Error::before(ErrorCode::OutputLimit))?,
        ),
        _ => None,
    };
    Ok(())
}

fn inventory_value(record: &VmRecord, state: &str) -> Result<serde_json::Value> {
    if record.mounts.len() > 8
        || record.ports.len() > 32
        || record
            .dns_filter_hosts
            .as_ref()
            .is_some_and(|v| v.len() > 32)
        || record.allowed_cidrs.as_ref().is_some_and(|v| v.len() > 32)
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    let mounts = record.host_mounts().iter().map(|mount| serde_json::json!({
        "source": mount.source.to_str(), "target": mount.target.to_str(), "readonly": mount.read_only, "staged": mount.staged
    })).collect::<Vec<_>>();
    Ok(
        serde_json::json!({ "name": record.name, "state": state, "createdAt": record.created_at,
        "cpus": record.cpus, "memoryMb": record.mem,
        "storageGb": record.storage_gb.unwrap_or(smolvm::storage::DEFAULT_STORAGE_SIZE_GIB),
        "overlayGb": record.overlay_gb.unwrap_or(smolvm::storage::DEFAULT_OVERLAY_SIZE_GIB),
        "network": record.network, "networkBackend": record.network_backend,
        "allowedHosts": record.dns_filter_hosts, "allowedCidrs": record.allowed_cidrs,
        "gpu": record.gpu.unwrap_or(false), "cuda": record.cuda, "mounts": mounts,
        "ports": record.ports.iter().map(|(host, guest)| serde_json::json!({"host": host, "guest": guest})).collect::<Vec<_>>() }),
    )
}
