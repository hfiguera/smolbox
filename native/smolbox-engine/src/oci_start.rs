//! Root-process SDK launch with retained ownership and bounded observation.
use crate::{Cancellation, CreationReceipt, Error, ErrorCode, Observation, ObservedState, Result};
use smolvm::agent::{AgentManager, LaunchFeatures};
use smolvm::config::VmRecord;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(5);

enum BootstrapPlan {
    Prepared(Box<crate::transfer_supervisor::Prepared>),
    Pending {
        permit: crate::jobs::JobLease,
        directory: std::path::PathBuf,
        socket: std::path::PathBuf,
        metadata: Box<crate::bootstrap::Metadata>,
    },
}
impl BootstrapPlan {
    fn prepare(
        self,
        supervisor: &crate::transfer_supervisor::TransferSupervisor,
    ) -> Result<crate::transfer_supervisor::Prepared> {
        match self {
            Self::Prepared(prepared) => Ok(*prepared),
            Self::Pending {
                permit,
                directory,
                socket,
                metadata,
            } => supervisor.prepare_bootstrap_reserved(permit, &directory, socket, &metadata),
        }
    }
}

fn check(deadline: Instant, cancel: &Cancellation) -> Result<()> {
    if cancel.is_cancelled() || Instant::now() >= deadline {
        Err(Error::before(ErrorCode::State))
    } else {
        Ok(())
    }
}

// The blocking SDK call must run in the owner process: the enrolled boot guard
// verifies that exact parent. A subprocess cannot replace that owner. The job
// retains its leases until actual return, even if observation has already ended.
pub(crate) fn observe_owned<T: Send + 'static>(
    pool: crate::jobs::JobPool,
    deadline: Instant,
    cancel: Cancellation,
    action: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    observe_job(pool, deadline, cancel, action, false)
}

/// Only for jobs that cannot mutate SDK/material state, spawn children or return
/// reusable existing-machine ownership. Request-private temporary files may
/// belong to the result/closure. Their executing closure retains admission after caller
/// retirement; losing an observation cannot quarantine unrelated authority.
pub(crate) fn observe_readonly<T: Send + 'static>(
    pool: crate::jobs::JobPool,
    deadline: Instant,
    cancel: Cancellation,
    action: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    observe_job(pool, deadline, cancel, action, true)
}

fn observe_job<T: Send + 'static>(
    pool: crate::jobs::JobPool,
    deadline: Instant,
    cancel: Cancellation,
    action: impl FnOnce() -> Result<T> + Send + 'static,
    readonly: bool,
) -> Result<T> {
    check(deadline, &cancel)?;
    let (send, receive) = mpsc::sync_channel(1);
    let thread = std::thread::Builder::new()
        .name("smolbox-oci-start".into())
        .spawn(move || {
            let _ = send.send(action());
        })
        .map_err(|_| Error::before(ErrorCode::Native))?;
    loop {
        if cancel.is_cancelled() || Instant::now() >= deadline {
            if !readonly {
                pool.quarantine();
            }
            // Dropping JoinHandle detaches observation, not the owned work.
            // No signals, lease release, result promotion or automatic replay.
            return Err(if readonly {
                Error::before(ErrorCode::State)
            } else {
                Error::uncertain(ErrorCode::State)
            });
        }
        if thread.is_finished() {
            if thread.join().is_err() {
                if !readonly {
                    pool.quarantine();
                }
                return Err(if readonly {
                    Error::before(ErrorCode::Native)
                } else {
                    Error::uncertain(ErrorCode::Native)
                });
            }
            if let Err(error) = check(deadline, &cancel) {
                if !readonly {
                    pool.quarantine();
                }
                return Err(if readonly {
                    error
                } else {
                    Error::uncertain(error.code)
                });
            }
            return receive.try_recv().map_err(|_| {
                if readonly {
                    Error::before(ErrorCode::Native)
                } else {
                    Error::uncertain(ErrorCode::Native)
                }
            })?;
        }
        std::thread::sleep(POLL.min(deadline.saturating_duration_since(Instant::now())));
    }
}

#[cfg(test)]
fn launch_features(record: &VmRecord) -> Result<LaunchFeatures> {
    launch_features_qualified(record, false)
}

fn launch_features_qualified(record: &VmRecord, mounted: bool) -> Result<LaunchFeatures> {
    // This first direct-OCI path has no auxiliary device, source, restore,
    // secret resolver, shell init, or implicit lifecycle behavior. Other parity
    // combinations remain pending until their approvals/owners are integrated.
    if record.source_smolmachine.is_some()
        || record.image.is_none()
        || !record.network
        || (!mounted && !record.mounts.is_empty())
        || !record.staged_mounts.is_empty()
        || !record.disks.is_empty()
        || !record.published_sockets.is_empty()
        || !record.remote_volumes.is_empty()
        || !record.init.is_empty()
        || !record.secret_refs.is_empty()
        || record.ssh_agent
        || record.docker_socket
        || record.cuda
        || record.gpu == Some(true)
        || record.nested_virt == Some(true)
        || record.rosetta == Some(true)
        || record.gpu_vram_mib.is_some()
        || record.forkable
        || record.detached
        || record.stop_on_exit
        || record.ephemeral
        || record.runtime_managed
        || record.cuda_fork_pool_size.is_some()
        || record.cuda_vram_limit_mib.is_some()
        || record.cuda_preload_modules
        || record.credential_policy.is_some()
        || !record.credential_placeholders.is_empty()
        || record.external_interceptor_required
        || record.credentials_supplied_by_api
        || record.paused_checkpoint.is_some()
        || record.checkpoint_head.is_some()
        || record.golden.is_some()
        || record.fork_generation.is_some()
        || record.fork_lineage_pid_start_time.is_some()
        || record.fork_overlay_owner.is_some()
        || record.host_uid_owner.is_some()
        || record.forkpoint_held
        || !record.fork_env.is_empty()
        || record.source_registry_ref.is_some()
        || record.network_name.is_some()
        || record.guest_subnet.is_some()
        || record.dns.is_some()
        || record.health_cmd.is_some()
        || record.health_interval_secs.is_some()
        || record.health_timeout_secs.is_some()
        || record.health_retries.is_some()
        || record.health_startup_grace_secs.is_some()
        || record.restart.policy != smolvm::config::RestartPolicy::Never
        || record.network_backend != Some(smolvm::network::NetworkBackend::VirtioNet)
        || record.allowed_cidrs.is_none()
        || record.dns_filter_hosts.is_none()
    {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(LaunchFeatures {
        dns_filter_hosts: record.dns_filter_hosts.clone(),
        watch_parent: Some(true),
        // Do not call allow_image_pull_egress or resolve packed layers/settings.
        ..Default::default()
    })
}

impl crate::Engine {
    /// Bind the bridge's approved original source to saved creation authority
    /// before startup. A later image pull cannot substitute this origin.
    pub fn start_oci_source_owned(
        &self,
        receipt: &CreationReceipt,
        source: &crate::ImagePullRequest,
        deadline: Instant,
        cancel: Cancellation,
    ) -> Result<Observation> {
        source.validate()?;
        self.start_oci_inner(receipt, Some(source), None, deadline, cancel)
    }

    /// Owned direct-OCI boot and one bounded agent bootstrap. The bridge must
    /// already have selected the operator-approved creation source/profile and
    /// durable startup slot. This does not activate public source capabilities.
    pub fn start_oci_owned(
        &self,
        receipt: &CreationReceipt,
        deadline: Instant,
        cancel: Cancellation,
    ) -> Result<Observation> {
        self.start_oci_inner(receipt, None, None, deadline, cancel)
    }

    /// OCI launch with current operator policy and fresh journal-bound backing
    /// authority. Mount descriptors are retained until the SDK confirms readiness.
    pub fn start_oci_source_with_volume_policy(
        &self,
        receipt: &CreationReceipt,
        source: &crate::ImagePullRequest,
        policy: &crate::LocalVolumePolicy,
        deadline: Instant,
        cancel: Cancellation,
    ) -> Result<Observation> {
        check(deadline, &cancel)?;
        source.validate()?;
        if deadline.saturating_duration_since(Instant::now()) > Duration::from_secs(86400) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let budget = crate::ReadBudget::new(
            deadline
                .saturating_duration_since(Instant::now())
                .min(Duration::from_secs(30)),
            cancel.clone(),
        )?;
        let record = self.record(receipt)?;
        let material = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
            .mount_material(receipt, &record)?;
        let mounts = match material {
            Some(material) => {
                Some(self.qualify_volume_mounts(policy, &material.mounts, &budget)?)
            }
            None => None,
        };
        self.start_oci_inner(receipt, Some(source), mounts, deadline, cancel)
    }

    fn start_oci_inner(
        &self,
        receipt: &CreationReceipt,
        approved_source: Option<&crate::ImagePullRequest>,
        mut mounts: Option<crate::QualifiedVolumeMounts>,
        deadline: Instant,
        cancel: Cancellation,
    ) -> Result<Observation> {
        check(deadline, &cancel)?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining > Duration::from_secs(86400) {
            return Err(Error::before(ErrorCode::Validation));
        }
        receipt.validate(self.binding())?;
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?
            .clone();
        let permit = match &mut mounts {
            Some(mounts) => {
                let budget =
                    crate::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel.clone())?;
                self.volume_record_mounts(mounts, &budget)?;
                mounts.take_oci_lease()?
            }
            None => self.jobs.acquire(crate::jobs::Demand::oci_start())?,
        };
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source = self.source_lease(receipt)?;
        let budget =
            crate::ReadBudget::new(remaining.min(Duration::from_secs(30)), cancel.clone())?;
        let record = self
            .observation_record(&receipt.name, &budget)?
            .ok_or(Error::before(ErrorCode::State))?;
        self.verify_record(receipt, &record)?;
        if approved_source.is_some_and(|source| {
            source.platform != crate::oci::native_oci_platform()
                || record.image.as_deref() != Some(source.reference.as_str())
        }) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let intent = crate::ImagePullRequest {
            reference: record
                .image
                .clone()
                .ok_or(Error::before(ErrorCode::Unsupported))?,
            platform: crate::oci::native_oci_platform().into(),
        };
        self.qualified_pull_record(receipt, &intent, &budget)?;
        match &mounts {
            Some(mounts) => self.verify_machine_mounts(receipt, &record, mounts, &budget)?,
            None if record.mounts.is_empty() => {}
            None => return Err(Error::before(ErrorCode::Ownership)),
        }
        let features = launch_features_qualified(&record, mounts.is_some())?;
        let expected = self.inspect(receipt)?;
        if expected.state != ObservedState::Stopped {
            return Err(Error::before(ErrorCode::State));
        }
        self.verify_templates()?;
        self.verify_lifecycle_preconditions(receipt, &expected)?;
        let epoch = self.boot_epoch()?.clone();
        let directory = self.vm_directory(&receipt.name);
        // The SDK auto-discovers portable restore inputs. Never let an ordinary
        // OCI boot accidentally consume one, even if its row has no checkpoint.
        if smolvm::portable_checkpoint::pending_dir(&directory).is_some() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let deadline_ns = crate::buffered::monotonic_ns()?
            .checked_add(
                u64::try_from(
                    deadline
                        .saturating_duration_since(Instant::now())
                        .as_nanos(),
                )
                .map_err(|_| Error::before(ErrorCode::Validation))?,
            )
            .ok_or(Error::before(ErrorCode::Validation))?;
        let metadata = crate::bootstrap::Metadata::from_record(&record, deadline_ns)?;
        let proof_intent = metadata.expected()?;
        let transfer_directory = self.transfer_directory()?;
        let plan = if mounts.is_some() {
            // Keep the reserved job, but do not open bootstrap spools or spawn
            // its worker while parent backing descriptors are held for launch.
            BootstrapPlan::Pending {
                permit,
                directory: transfer_directory,
                socket: directory.join("agent.sock"),
                metadata: Box::new(metadata),
            }
        } else {
            // Preserve existing pre-launch spool publication for unmounted OCI.
            BootstrapPlan::Prepared(Box::new(supervisor.prepare_bootstrap_reserved(
                permit,
                &transfer_directory,
                directory.join("agent.sock"),
                &metadata,
            )?))
        };
        check(deadline, &cancel)?;
        let manager = Arc::new(Mutex::new(
            AgentManager::for_vm_with_sizes(&record.name, record.storage_gb, record.overlay_gb)
                .map_err(|_| Error::before(ErrorCode::Native))?,
        ));
        {
            let mut handles = self
                .owned_managers
                .lock()
                .map_err(|_| Error::before(ErrorCode::Native))?;
            if handles.contains_key(&record.name) {
                return Err(Error::before(ErrorCode::Conflict));
            }
            handles.insert(record.name.clone(), manager.clone());
        }
        if let Some(mounts) = &mounts {
            self.verify_machine_mounts(receipt, &self.record(receipt)?, mounts, &budget)?;
        }
        self.track_handle(receipt)?;
        let db = self.db.clone();
        let database = self.binding().database.clone();
        let database_identity = self.database_identity;
        let domain = self.domain.clone();
        let receipt = receipt.clone();
        let work_cancel = cancel.clone();
        observe_owned(self.jobs.clone(), deadline, cancel, move || {
            check(deadline, &work_cancel)?;
            if let Some(mounts) = &mounts {
                let budget = crate::ReadBudget::new(
                    deadline
                        .saturating_duration_since(Instant::now())
                        .min(Duration::from_secs(30)),
                    work_cancel.clone(),
                )?;
                mounts.recheck_before_launch(&budget)?;
            }
            let dispatch = epoch.begin_boot(&receipt.name)?;
            let (started, pid) = {
                let manager = manager
                    .lock()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                let started = manager.start_with_full_config(
                    record.host_mounts(),
                    record.port_mappings(),
                    record.vm_resources(),
                    features,
                );
                (started, manager.child_pid())
            };
            let enrolled = dispatch
                .finish_enrollment(pid)
                .map_err(|e| Error::uncertain(e.code))?;
            if !enrolled.intent().matches(&receipt.name, &epoch.identity()) {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            started.map_err(|e| Error::uncertain(crate::sdk_compat::launch_error(&e)))?;
            let pid = pid
                .filter(|pid| *pid > 0)
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            let child = enrolled.child();
            if child.pid != pid || child.birth == 0 {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            let birth = child.birth;
            // Preserve actual launch identity even if observation expired during
            // the SDK call; no late bootstrap or success result follows it.
            db.update_vm(&receipt.name, |record| {
                record.state = smolvm::config::RecordState::Running;
                record.pid = Some(pid);
                record.pid_start_time = Some(birth);
            })
            .map_err(|_| Error::uncertain(ErrorCode::Database))?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            check(deadline, &work_cancel).map_err(|e| Error::uncertain(e.code))?;
            // SDK success includes agent readiness. Close mount descriptors before
            // spawning the bootstrap worker; volume gates/proof follow collection.
            let mount_authority = mounts
                .map(|mounts| mounts.into_worker_authority())
                .transpose()
                .map_err(|e| Error::uncertain(e.code))?;
            let prepared = plan
                .prepare(&supervisor)
                .map_err(|e| Error::uncertain(e.code))?;
            let crate::transfer_supervisor::RunResult::Collected(collected) = supervisor.run(
                prepared,
                Box::new((machine, source, domain.clone(), mount_authority)),
                deadline,
                &work_cancel,
            )?
            else {
                return Err(Error::uncertain(ErrorCode::Native));
            };
            if !collected.outcome.success()
                || !collected
                    .bootstrapped
                    .as_ref()
                    .is_some_and(|proof| proof.matches(&proof_intent))
            {
                return Err(Error::uncertain(ErrorCode::Native));
            }
            check(deadline, &work_cancel).map_err(|e| Error::uncertain(e.code))?;
            domain.verify().map_err(|e| Error::uncertain(e.code))?;
            let budget = crate::ReadBudget::new(
                deadline
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_secs(30)),
                work_cancel.clone(),
            )
            .map_err(|e| Error::uncertain(e.code))?;
            let after = crate::sdk_compat::observe_record(
                &database,
                database_identity,
                &receipt.name,
                &budget,
            )?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            if !receipt.matches(&after)?
                || !crate::machine::marker_matches(&receipt, &directory)?
                || after.pid.zip(after.pid_start_time) != Some((pid, birth))
                || crate::identity::record_state(&after, false) != ObservedState::Running
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            let journal = crate::material::MaterialJournal::at(&directory);
            journal.verify(&receipt)?;
            journal.verify_mount_record(&receipt, &after)?;
            budget.check().map_err(|e| Error::uncertain(e.code))?;
            Ok(Observation {
                state: ObservedState::Running,
                resources: Some(crate::Resources {
                    cpus: after.cpus,
                    memory_mib: after.mem,
                    storage_gib: after
                        .storage_gb
                        .ok_or(Error::uncertain(ErrorCode::Ownership))?,
                    overlay_gib: after
                        .overlay_gb
                        .ok_or(Error::uncertain(ErrorCode::Ownership))?,
                }),
                pid_identity: Some((pid, birth)),
                configuration: crate::MachineConfiguration::observe(&after),
            })
        })
        .map_err(|error| Error::uncertain(error.code))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_mounted_bootstrap_keeps_admission_without_opening_spools() {
        let pool = crate::jobs::JobPool::default();
        let mut permit = pool
            .acquire(crate::jobs::Demand::volume_mounts(8).unwrap())
            .unwrap();
        permit.promote_mount_oci_start().unwrap();
        let directory = tempfile::tempdir().unwrap();
        let metadata = crate::bootstrap::Metadata::from_record(&record(), 1).unwrap();
        let plan = BootstrapPlan::Pending {
            permit,
            directory: directory.path().into(),
            socket: directory.path().join("agent.sock"),
            metadata: Box::new(metadata),
        };
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
        assert_eq!(pool.counts().work, 1);
        assert_eq!(pool.counts().children, 2);
        drop(plan);
        assert_eq!(pool.counts(), crate::jobs::Counts::default());
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
    }

    fn record() -> VmRecord {
        crate::oci::tests::verified()
            .record(
                "owned",
                crate::Resources {
                    cpus: 1,
                    memory_mib: 256,
                    storage_gib: 1,
                    overlay_gib: 1,
                },
                Default::default(),
                &crate::oci::tests::features(),
            )
            .unwrap()
    }

    #[test]
    fn mounted_launch_and_bootstrap_preserve_guest_bindings_without_extra_devices() {
        let mut record = record();
        record.mounts = vec![("/approved/volume".into(), "/mnt/volumes/data".into(), true)];
        assert!(launch_features(&record).is_err());
        let features = launch_features_qualified(&record, true).unwrap();
        assert_eq!(features.watch_parent, Some(true));
        assert!(features.extra_disks.is_empty() && features.packed_layers_dir.is_none());
        let metadata = crate::bootstrap::Metadata::from_record(&record, 1).unwrap();
        let value = serde_json::to_value(metadata).unwrap();
        let bytes = serde_json::to_string(&value).unwrap();
        assert!(!bytes.contains("/approved/volume"));
        assert_eq!(
            value["launch"]["mounts"],
            serde_json::json!([["smolvm0", "/mnt/volumes/data", true]])
        );
        record
            .staged_mounts
            .push((0, "/staged".into(), "/mnt/volumes/staged".into()));
        assert!(launch_features_qualified(&record, true).is_err());
    }

    #[test]
    fn launch_preserves_exact_egress_without_registry_expansion_or_auxiliary_features() {
        let mut record = record();
        record.dns_filter_hosts = Some(vec!["service.example".into()]);
        record.allowed_cidrs = Some(vec!["192.0.2.0/24".into()]);
        let features = launch_features(&record).unwrap();
        assert_eq!(features.dns_filter_hosts, record.dns_filter_hosts);
        assert_eq!(record.vm_resources().allowed_cidrs, record.allowed_cidrs);
        assert_eq!(features.watch_parent, Some(true));
        assert!(features.credentials.is_none() && features.packed_layers_dir.is_none());
        assert!(features.snapshot_dir.is_none() && features.extra_disks.is_empty());
        assert!(!features.forkable && !features.cuda && !features.expose_docker);
        assert!(features.pod_netns.is_none() && features.uid_share_dir.is_none());
    }

    #[test]
    fn unsupported_implicit_startup_behavior_rejects_before_sdk_entry() {
        let original = serde_json::to_value(record()).unwrap();
        for (key, value) in [
            ("detached", serde_json::json!(true)),
            ("forkable", serde_json::json!(true)),
            ("cuda", serde_json::json!(true)),
            ("stop_on_exit", serde_json::json!(true)),
            ("init", serde_json::json!(["true"])),
            ("dns_filter_hosts", serde_json::Value::Null),
            ("allowed_cidrs", serde_json::Value::Null),
            ("golden", serde_json::json!("foreign")),
            ("source_smolmachine", serde_json::json!("/foreign")),
            ("network", serde_json::json!(false)),
            ("network_backend", serde_json::Value::Null),
            ("mounts", serde_json::json!([["/host", "/guest", false]])),
            ("external_interceptor_required", serde_json::json!(true)),
        ] {
            let mut changed = original.clone();
            changed[key] = value;
            let record: VmRecord = serde_json::from_value(changed).unwrap();
            assert!(launch_features(&record).is_err(), "{key}");
        }
    }

    #[test]
    fn ordinary_blocking_call_retains_leases_after_cancellation_without_late_success_or_replay() {
        let pool = crate::jobs::JobPool::default();
        let permit = pool.acquire(crate::jobs::Demand::oci_start()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let cancel = Cancellation::new();
        let work_cancel = cancel.clone();
        let work_pool = pool.clone();
        let (entered_send, entered) = mpsc::sync_channel(1);
        let (finish, finishing) = mpsc::sync_channel(1);
        let observer = std::thread::spawn(move || {
            observe_owned(work_pool, deadline, work_cancel, move || {
                let _permit = permit;
                entered_send.send(()).unwrap();
                finishing.recv_timeout(Duration::from_secs(5)).unwrap();
                Ok(7)
            })
        });
        entered.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(pool.counts().children, 2);
        let control = pool.acquire(crate::jobs::Demand::observation()).unwrap();
        let second_control = pool.acquire(crate::jobs::Demand::observation()).unwrap();
        assert_eq!(pool.counts().descriptors, crate::JOB_DESCRIPTORS);
        cancel.cancel();
        let error = observer.join().unwrap().unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        assert!(!pool.available());
        assert_eq!(pool.counts().work, 1);
        finish.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while pool.counts().work != 0 {
            assert!(Instant::now() < deadline);
            std::thread::sleep(POLL);
        }
        assert!(!pool.available());
        assert_eq!(pool.counts().control, 2);
        drop(control);
        drop(second_control);
    }

    #[test]
    fn readonly_cancellation_retains_executing_lease_without_quarantining_sibling_controls() {
        let pool = crate::jobs::JobPool::default();
        let permit = pool.acquire(crate::jobs::Demand::oci_metadata()).unwrap();
        let cancel = Cancellation::new();
        let work_cancel = cancel.clone();
        let work_pool = pool.clone();
        let (entered_send, entered) = mpsc::sync_channel(1);
        let (finish, finishing) = mpsc::sync_channel(1);
        let (collected_send, collected) = mpsc::sync_channel(1);
        let observer = std::thread::spawn(move || {
            observe_readonly(
                work_pool,
                Instant::now() + Duration::from_secs(5),
                work_cancel,
                move || {
                    entered_send.send(()).unwrap();
                    finishing.recv_timeout(Duration::from_secs(5)).unwrap();
                    drop(permit);
                    collected_send.send(()).unwrap();
                    Ok(7)
                },
            )
        });
        entered.recv_timeout(Duration::from_secs(2)).unwrap();
        cancel.cancel();
        let error = observer.join().unwrap().unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(pool.available());
        assert_eq!(pool.counts().work, 1);
        assert!(pool.acquire(crate::jobs::Demand::oci_metadata()).is_err());
        let control = pool.acquire(crate::jobs::Demand::observation()).unwrap();
        let sibling_control = pool.acquire(crate::jobs::Demand::observation()).unwrap();
        finish.send(()).unwrap();
        collected.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(pool.counts().work, 0);
        assert!(pool.acquire(crate::jobs::Demand::oci_metadata()).is_ok());
        assert_eq!(pool.counts().control, 2);
        drop((control, sibling_control));
    }

    #[test]
    fn successful_owned_call_collects_and_expired_admission_never_invokes_action() {
        let pool = crate::jobs::JobPool::default();
        let permit = pool.acquire(crate::jobs::Demand::oci_start()).unwrap();
        assert_eq!(
            observe_owned(
                pool.clone(),
                Instant::now() + Duration::from_secs(2),
                Cancellation::new(),
                move || {
                    let _permit = permit;
                    Ok(7)
                }
            )
            .unwrap(),
            7
        );
        assert_eq!(pool.counts(), crate::jobs::Counts::default());
        assert!(pool.available());
        let cancel = Cancellation::new();
        cancel.cancel();
        assert!(observe_owned::<()>(
            pool.clone(),
            Instant::now() + Duration::from_secs(2),
            cancel,
            || panic!("must not enter")
        )
        .is_err());
        assert!(
            observe_owned::<()>(pool, Instant::now(), Cancellation::new(), || panic!(
                "must not enter"
            ))
            .is_err()
        );
    }
}
