//! Explicit ordinary Linux host-volume witness; never boots a VM or runs faults.
//! Invoke prepare and finish as separate processes with one existing enrolled
//! domain and a fresh private evidence directory. Neither phase initializes a
//! domain/root, adopts directories, repairs permissions or replays uncertain IO.
use serde::{Deserialize, Serialize};
use serde_json::json;
use smolbox_engine::{
    Cancellation, Dispatch, DomainBinding, Engine, ErrorCode, LocalVolumeIntent, LocalVolumePolicy,
    ReadBudget, VolumeDeletionPresence, VolumeMountRequest, VolumeProvisionPresence,
    VolumeProvisionReceipt,
};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::Duration;

type ProofResult<T> = Result<T, Box<dyn std::error::Error>>;
const SENTINEL: &[u8] = b"ordinary-volume-outside-sentinel\n";
const FILES: usize = 4096;
const DEPTH: usize = 32;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Intent {
    target_id: String,
    generation: String,
    policy: LocalVolumePolicy,
    volume: LocalVolumeIntent,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("ordinary host-volume proof failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> ProofResult<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if !cfg!(target_os = "linux") || args.len() != 3 {
        return Err("Linux only: volume-filesystem-proof prepare|verify-preparation|finish DOMAIN_JSON OUTPUT".into());
    }
    let phase = args[0].as_str();
    if !matches!(phase, "prepare" | "verify-preparation" | "finish") {
        return Err("unknown phase; no mutation".into());
    }
    let domain_path = Path::new(&args[1]);
    let output = Path::new(&args[2]);
    if !domain_path.is_absolute() || !output.is_absolute() {
        return Err("absolute domain and output paths required".into());
    }
    let domain: serde_json::Value = read_private(domain_path)?;
    let target = domain["target_id"].as_str().ok_or("missing target")?;
    let generation = domain["generation"].as_str().ok_or("missing generation")?;
    let binding = DomainBinding::default_paths(target.into(), generation.into())?;
    // No boot operation exists in this tool. Preserve any caller-supplied
    // unsupported SDK environment so Engine::open rejects it normally.
    std::env::set_var("SMOLVM_IMAGE_SEEDS", "0");
    std::env::set_var("SMOLVM_BOOT_BINARY", std::env::current_exe()?);
    let engine = Engine::open(binding, false)?;
    if engine.inventory(&budget()?)?.count != 0 {
        return Err("qualification requires empty SDK inventory; no cleanup by inventory".into());
    }
    match phase {
        "prepare" => prepare(&engine, output)?,
        "verify-preparation" => verify_preparation(&engine, output)?,
        "finish" => finish(&engine, output)?,
        _ => unreachable!(),
    }
    if engine.inventory(&budget()?)?.count != 0 {
        return Err("unexpected SDK inventory change".into());
    }
    println!("ordinary host-volume {phase} completed; no VM/guest qualification");
    Ok(())
}

fn budget() -> ProofResult<ReadBudget> {
    Ok(ReadBudget::new(
        Duration::from_secs(30),
        Cancellation::new(),
    )?)
}

fn write_once<T: Serialize>(path: &Path, value: &T) -> ProofResult<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    file.sync_all()?;
    File::open(path.parent().ok_or("missing parent")?)?.sync_all()?;
    Ok(())
}

fn read_private<T: serde::de::DeserializeOwned>(path: &Path) -> ProofResult<T> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > 16 * 1024
    {
        return Err("metadata must be a bounded private account-owned regular file".into());
    }
    let mut bytes = vec![];
    (&mut file).take(16 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 16 * 1024 {
        return Err("metadata exceeded bound".into());
    }
    Ok(serde_json::from_slice(&bytes)?)
}

fn prepare(engine: &Engine, output: &Path) -> ProofResult<()> {
    let policy = LocalVolumePolicy {
        id: "ordinary-volume-proof".into(),
        root: LocalVolumePolicy::canonical_sdk_root()?,
    };
    // Existing canonical operator root only: no implicit setup or chmod.
    drop(engine.qualify_volume_root(&policy, &budget()?)?);
    std::fs::DirBuilder::new().mode(0o700).create(output)?;
    let mut entropy = [0; 16];
    getrandom::fill(&mut entropy).map_err(|_| "entropy unavailable")?;
    let intent = Intent {
        target_id: engine.binding().target_id.clone(),
        generation: engine.binding().generation.clone(),
        policy,
        volume: LocalVolumeIntent {
            worker_volume_id: format!("sbv-{}", hex::encode(entropy)),
            size_gb: 1,
        },
    };
    write_once(&output.join("intent.json"), &intent)?;
    let provision = engine.provision_volume(&intent.policy, &intent.volume, &budget()?)?;
    write_once(&output.join("provision.json"), &provision)?;
    let backing = provision.node_path();
    let sentinel = output.join("outside-sentinel");
    let mut outside = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&sentinel)?;
    outside.write_all(SENTINEL)?;
    outside.sync_all()?;
    std::fs::hard_link(&sentinel, backing.join("outside-hardlink"))?;
    std::os::unix::fs::symlink(output, backing.join("outside-link"))?;
    for index in 0..FILES {
        let leaf = backing.join(format!("leaf-{index:04}"));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(leaf)?;
        file.write_all(b"ordinary bounded deletion\n")?;
    }
    let mut nested = backing.clone();
    for _ in 0..DEPTH {
        nested.push("ordinary-depth");
        std::fs::DirBuilder::new().mode(0o700).create(&nested)?;
    }
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::ffi::OsStringExt;
        let name = std::ffi::OsString::from_vec(vec![0xff, b'-', b'l', b'e', b'a', b'f']);
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(nested.join(name))?;
    }
    // Explicit ordinary permission evolution of this freshly proved backing.
    std::fs::set_permissions(&backing, std::fs::Permissions::from_mode(0o755))?;
    verify_preparation(engine, output)
}

// Explicitly verify an already created fixture after a harness assertion fails.
// No engine operation is replayed or repaired; every original proof and fixture
// byte is rechecked before the harness writes its own new success marker.
fn verify_preparation(engine: &Engine, output: &Path) -> ProofResult<()> {
    let (intent, provision) = original(engine, output)?;
    if output.join("deletion.json").exists() || output.join("completed.json").exists() {
        return Err("fixture already entered deletion; no preparation verification".into());
    }
    let rejections = check_mounts(engine, &intent, &provision)?;
    let backing = provision.node_path();
    if std::fs::read_dir(&backing)?.count() != FILES + 3 {
        return Err("fixture root entry count differs".into());
    }
    for index in 0..FILES {
        let path = backing.join(format!("leaf-{index:04}"));
        if !std::fs::symlink_metadata(&path)?.is_file()
            || std::fs::read(path)? != b"ordinary bounded deletion\n"
        {
            return Err("fixture file differs".into());
        }
    }
    let outside = std::fs::symlink_metadata(output.join("outside-sentinel"))?;
    let hardlink = std::fs::symlink_metadata(backing.join("outside-hardlink"))?;
    if !outside.is_file()
        || !hardlink.is_file()
        || (outside.dev(), outside.ino()) != (hardlink.dev(), hardlink.ino())
        || std::fs::read(output.join("outside-sentinel"))? != SENTINEL
        || std::fs::read_link(backing.join("outside-link"))? != output
    {
        return Err("outside link fixture differs".into());
    }
    let mut nested = backing.clone();
    for _ in 0..DEPTH {
        nested.push("ordinary-depth");
        if !std::fs::symlink_metadata(&nested)?.is_dir() || std::fs::read_dir(&nested)?.count() != 1
        {
            return Err("nested fixture differs".into());
        }
    }
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::ffi::OsStringExt;
        let name = std::ffi::OsString::from_vec(vec![0xff, b'-', b'l', b'e', b'a', b'f']);
        let metadata = std::fs::symlink_metadata(nested.join(name))?;
        if !metadata.is_file() || metadata.len() != 0 {
            return Err("raw-name fixture differs".into());
        }
    }
    if std::fs::symlink_metadata(&backing)?.mode() & 0o7777 != 0o755 {
        return Err("fixture permission evolution differs".into());
    }
    write_once(
        &output.join("prepared.json"),
        &json!({
            "scope":"linux-host-filesystem-only", "files":FILES, "depth":DEPTH,
            "mode":0o755, "mount_proof_checked":true, "held_mount_excludes_delete":true,
            "deletion_pre_dispatch_rejections":rejections,
            "inventory_empty":true, "guest_io_qualified":false
        }),
    )?;
    Ok(())
}

fn check_mounts(
    engine: &Engine,
    intent: &Intent,
    provision: &VolumeProvisionReceipt,
) -> ProofResult<Vec<String>> {
    if engine.inspect_volume_provision(&intent.policy, &intent.volume, &budget()?)?
        != VolumeProvisionPresence::Provisioned(Box::new(provision.clone()))
    {
        return Err("protected completed proof differs".into());
    }
    let mut rejections = vec![];
    for readonly in [false, true] {
        let request = VolumeMountRequest {
            proof: provision.clone(),
            target: "/mnt/volumes/ordinary".into(),
            readonly,
        };
        let mounts = engine.qualify_volume_mounts(&intent.policy, &[request], &budget()?)?;
        let projected = engine.volume_record_mounts(&mounts, &budget()?)?;
        if projected
            != vec![(
                provision
                    .node_path()
                    .to_str()
                    .ok_or("non-UTF-8 root")?
                    .into(),
                "/mnt/volumes/ordinary".into(),
                readonly,
            )]
        {
            return Err("SDK mount projection differs".into());
        }
        match engine.qualify_volume_deletion(&intent.policy, &intent.volume, &budget()?) {
            Err(error)
                if error.dispatch == Dispatch::NotDispatched
                    && matches!(error.code, ErrorCode::Admission | ErrorCode::Conflict) =>
            {
                rejections.push(format!("{:?}", error.code));
            }
            Err(error) => return Err(format!("unexpected deletion rejection: {error}").into()),
            Ok(_) => return Err("held mount did not exclude deletion".into()),
        }
        // Reopens protected proof and requires every cleanup journal absent.
        if engine.volume_record_mounts(&mounts, &budget()?)? != projected {
            return Err("mount changed after deletion rejection".into());
        }
        drop(mounts);
    }
    Ok(rejections)
}

fn original(engine: &Engine, output: &Path) -> ProofResult<(Intent, VolumeProvisionReceipt)> {
    let metadata = std::fs::symlink_metadata(output)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err("output must remain a private account-owned directory".into());
    }
    let intent: Intent = read_private(&output.join("intent.json"))?;
    let provision: VolumeProvisionReceipt = read_private(&output.join("provision.json"))?;
    if intent.target_id != engine.binding().target_id
        || intent.generation != engine.binding().generation
    {
        return Err("original enrolled domain required".into());
    }
    Ok((intent, provision))
}

fn finish(engine: &Engine, output: &Path) -> ProofResult<()> {
    let (intent, provision) = original(engine, output)?;
    let _: serde_json::Value = read_private(&output.join("prepared.json"))?;
    let rejections = check_mounts(engine, &intent, &provision)?;
    if std::fs::read(output.join("outside-sentinel"))? != SENTINEL {
        return Err("outside sentinel changed before deletion".into());
    }
    let deletion = engine.delete_volume(
        &intent.policy,
        &intent.volume,
        &ReadBudget::for_volume_work(Duration::from_secs(120), Cancellation::new())?,
    )?;
    write_once(&output.join("deletion.json"), &deletion)?;
    if deletion.provision != provision
        || provision.node_path().exists()
        || engine.inspect_volume_deletion(&intent.policy, &intent.volume, &budget()?)?
            != VolumeDeletionPresence::Deleted(Box::new(deletion))
        || std::fs::read(output.join("outside-sentinel"))? != SENTINEL
    {
        return Err("positive owned deletion/outside preservation not established".into());
    }
    write_once(
        &output.join("completed.json"),
        &json!({
            "scope":"linux-host-filesystem-only", "separate_process_reopen":true,
            "protected_provision_rechecked":true, "readonly_and_writable_projection":true,
            "deletion_pre_dispatch_rejections":rejections,
            "large_tree_owned_deletion":true, "outside_links_preserved":true,
            "positive_deletion_observed":true, "inventory_empty":true, "guest_io_qualified":false
        }),
    )?;
    Ok(())
}
