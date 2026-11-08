//! Explicit ordinary SDK fixture preparation, never consumer startup or recovery.
//! Runs only in a fresh dedicated qualification account. Errors retain the
//! original runtime; no signal, replay, source-record rewrite or artifact adoption.
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::Duration;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn digest(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            return Ok(hex::encode(hash.finalize()));
        }
        hash.update(&buffer[..count]);
    }
}
fn verify(package: &Path, expected: &str) -> Result<()> {
    assert_eq!(digest(&package.join("package.json"))?, expected);
    let manifest: serde_json::Value =
        serde_json::from_reader(File::open(package.join("package.json"))?)?;
    assert_eq!(
        manifest["policy"]["sdk"]["source_revision"],
        smolbox_engine::SMOLVM_REVISION
    );
    for asset in manifest["assets"].as_array().unwrap() {
        let name = asset["path"].as_str().unwrap();
        assert!(Path::new(name)
            .components()
            .all(|part| matches!(part, std::path::Component::Normal(_))));
        let path = package.join(name);
        if asset["kind"] == "symlink" {
            assert_eq!(
                fs::read_link(path)?.to_str().unwrap(),
                asset["target"].as_str().unwrap()
            );
        } else {
            let metadata = fs::symlink_metadata(&path)?;
            assert!(metadata.is_file());
            assert_eq!(metadata.len(), asset["bytes"].as_u64().unwrap());
            assert_eq!(
                u64::from(metadata.mode() & 0o777),
                asset["mode"].as_u64().unwrap()
            );
            assert_eq!(digest(&path)?, asset["sha256"].as_str().unwrap());
        }
    }
    Ok(())
}
fn save(path: &Path, value: serde_json::Value) -> Result<()> {
    let bytes = serde_json::to_vec(&value)?;
    let temporary = path.with_extension("new");
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, path)?;
    Ok(())
}
fn main() -> Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() == 2 && args[0] == "_boot-vm" {
        return smolvm::internal_boot::run((&args[1]).into()).map_err(Into::into);
    }
    assert_eq!(
        args.len(),
        4,
        "PACKAGE MANIFEST_SHA256 NEW_OUTPUT NEW_MACHINE_NAME"
    );
    assert!(
        unsafe { libc::geteuid() } >= 506,
        "dedicated qualification account required"
    );
    assert!(std::env::var_os("SMOLVM_DATA_DIR").is_none());
    unsafe {
        libc::umask(0o077);
    }
    let package = Path::new(&args[0]);
    let output = Path::new(&args[2]);
    assert!(package.is_absolute() && output.is_absolute() && !output.exists());
    verify(package, &args[1])?;
    let tools = std::env::current_exe()?.parent().unwrap().to_path_buf();
    let home = std::path::PathBuf::from(std::env::var("HOME")?);
    assert!(
        !home.join(".smolvm").exists(),
        "unexpected template search root"
    );
    for name in ["storage-template.ext4", "overlay-template.ext4"] {
        assert_eq!(digest(&tools.join(name))?, digest(&package.join(name))?);
    }
    let uid = unsafe { libc::geteuid() };
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(format!("/tmp/smolbox-native-{uid}.lock"))?;
    assert_eq!(lock.metadata()?.uid(), uid);
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    std::env::set_var("SMOLVM_BOOT_BINARY", std::env::current_exe()?);
    std::env::set_var("SMOLVM_AGENT_ROOTFS", package.join("agent-rootfs"));
    std::env::set_var("SMOLVM_LIB_DIR", package.join("lib"));
    std::env::set_var("SMOLVM_IMAGE_SEEDS", "0");
    let db = smolvm::db::SmolvmDb::open()?;
    assert!(db.list_vms()?.is_empty());
    let runtime = smolvm::embedded::EmbeddedRuntime::with_db(db.clone());
    let name = args[3].clone();
    smolvm::data::validate_vm_name(&name, "fixture")?;
    let report = output.with_extension("report.json");
    let created = std::cell::Cell::new(false);
    let stop_entered = std::cell::Cell::new(false);
    let stop_confirmed = std::cell::Cell::new(false);
    let delete_entered = std::cell::Cell::new(false);
    let ordinary = || -> Result<()> {
        runtime.create_machine(smolvm::embedded::MachineSpec {
            name: name.clone(),
            persistent: true,
            forkable: true,
            resources: smolvm::agent::VmResources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: Some(1),
                overlay_gib: Some(1),
                network: false,
                allowed_cidrs: Some(vec![]),
                ..Default::default()
            },
            ..Default::default()
        })?;
        created.set(true);
        // Use the SDK's ordinary sparse raw-disk seeding API. The qualified Mac
        // libkrun bundle cannot boot the default qcow2 creation path. No pack
        // reference or persisted record field is invented or rewritten here.
        let directory = smolvm::agent::ensure_vm_dir(&name)?;
        smolvm::storage::seed_vm_mode_disks(
            &directory,
            &tools,
            smolvm::storage::VmModeDiskSeedSpec {
                artifact_sha256: None,
                overlay_template: Some("overlay-template.ext4"),
                storage_template: Some("storage-template.ext4"),
                overlay_logical_size: Some(1 << 30),
                storage_logical_size: Some(1 << 30),
                overlay_gb: Some(1),
                storage_gb: Some(1),
            },
        )?;
        // clonefile preserves the approved input's read-only mode. These are
        // new private mutable VM disks, not the templates or an existing run.
        for disk in ["overlay.raw", "storage.raw"] {
            let path = directory.join(disk);
            let metadata = fs::symlink_metadata(&path)?;
            assert!(metadata.is_file() && metadata.uid() == uid && metadata.nlink() == 1);
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        }
        runtime.start_forkable_machine(&name)?;
        let before = db.get_vm(&name)?.unwrap();
        assert!(before.source_smolmachine.is_none() && before.image.is_none());
        let (code, _, stderr) = runtime.exec(
            &name,
            vec!["/bin/true".into()],
            vec![],
            Some("/".into()),
            Some(Duration::from_secs(30)),
        )?;
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        let staging = output.with_extension("staging");
        fs::create_dir(&staging)?;
        runtime.checkpoint_machine(
            &name,
            output,
            &smolvm::portable_checkpoint::CaptureOptions {
                prepared_cache_budget_bytes: Some(0),
                staging_dir: Some(staging),
                lib_dir: Some(package.join("lib")),
                rootfs_dir: Some(package.join("agent-rootfs")),
                ..Default::default()
            },
        )?;
        let manifest = smolvm_pack::packer::read_manifest_from_sidecar(output)?;
        let checkpoint = manifest.checkpoint.as_ref().unwrap();
        assert_eq!(
            checkpoint.device_profile,
            smolvm::portable_checkpoint::DEVICE_PROFILE
        );
        assert!(checkpoint.packed_layers.is_none() && checkpoint.workload.is_none());
        stop_entered.set(true);
        runtime.stop_machine(&name)?;
        stop_confirmed.set(true);
        let stopped = db.get_vm(&name)?.unwrap();
        assert!(stopped.pid.is_none());
        delete_entered.set(true);
        runtime.delete_machine(&name)?;
        assert!(db.list_vms()?.is_empty());
        verify(package, &args[1])?;
        save(
            &report,
            serde_json::json!({"status":"prepared", "sha256":digest(output)?,
            "bytes":fs::metadata(output)?.len(), "sdk_version":smolvm::VERSION,
            "device_profile":checkpoint.device_profile, "packed_dependency":false,
            "ordinary_stop_delete":true, "sdk_inventory_empty":true,
            "crash_validation_deferred":true, "source_record_rewritten":false}),
        )?;
        Ok(())
    };
    if !matches!(
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(ordinary)),
        Ok(Ok(()))
    ) {
        let _ = save(
            &report,
            serde_json::json!({"status":"failed-retained", "original_runtime_retained":true,
            "mutation_replay":false, "crash_validation_deferred":true}),
        );
        // Only an empty failed preparation can normally exit. Otherwise retain
        // the original SDK runtime for explicit diagnosis, never terminate it.
        loop {
            std::thread::sleep(Duration::from_millis(250));
            if db.list_vms().is_ok_and(|rows| rows.is_empty()) {
                break;
            }
            let control = output.with_extension("control.json");
            if let Ok(bytes) = fs::read(&control) {
                if bytes.len() > 1024 {
                    continue;
                }
                let request: serde_json::Value = match serde_json::from_slice(&bytes) {
                    Ok(value) => value,
                    Err(_) => continue,
                };
                let Some(id) = request["id"].as_str().filter(|id| {
                    !id.is_empty()
                        && id.len() <= 64
                        && id.bytes().all(|b| b.is_ascii_alphanumeric())
                }) else {
                    continue;
                };
                let processed = output.with_extension(format!("processed-{id}.json"));
                if processed.exists() || fs::rename(&control, processed).is_err() {
                    continue;
                }
                if request["action"] == "stop" && created.get() && !stop_entered.get() {
                    stop_entered.set(true);
                    if runtime.stop_machine(&name).is_ok() {
                        stop_confirmed.set(true);
                    }
                } else if request["action"] == "delete"
                    && stop_confirmed.get()
                    && !delete_entered.get()
                {
                    delete_entered.set(true);
                    let _ = runtime.delete_machine(&name);
                }
                let _ = save(
                    &report,
                    serde_json::json!({"status":"failed-retained", "original_runtime_retained":true,
                    "stop_entered":stop_entered.get(),"stop_confirmed":stop_confirmed.get(),
                    "delete_entered":delete_entered.get(),"mutation_replay":false,"crash_validation_deferred":true}),
                );
            }
        }
        return Err("fixture preparation failed; evidence preserved".into());
    }
    Ok(())
}
