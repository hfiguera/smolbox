//! Explicit native qualification tool. It never enumerates names for cleanup.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use smolbox_engine::{
    ApprovedArtifact, Cancellation, Command, Completion, CreationReceipt, DomainBinding, Engine,
    FileOptions, ObservedState, Resources, Stream,
};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Write};
use std::path::Path;
use std::time::Duration;

type ProofResult<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn main() {
    if let Err(error) = run() {
        eprintln!("native proof failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> ProofResult<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.as_slice() == ["--file-worker"] {
        smolbox_engine::run_file_worker()?;
        return Ok(());
    }
    if args.first().map(String::as_str) == Some("_boot-vm") && args.len() == 2 {
        smolbox_engine::BootLauncher::arm_current(Path::new(&args[1]))?;
        smolvm::internal_boot::run((&args[1]).into())?;
        return Ok(());
    }
    std::env::set_var("SMOLVM_BOOT_BINARY", std::env::current_exe()?);
    std::env::set_var("SMOLVM_IMAGE_SEEDS", "0");
    std::env::remove_var("SMOLVM_BOOT_DEBUG");
    std::env::remove_var("SMOLVM_TEMPLATE_DIR");
    match args.first().map(String::as_str) {
        Some("fixture") if args.len() == 3 => fixture(Path::new(&args[1]), Path::new(&args[2])),
        Some("vm-seed") if args.len() == 3 => vm_seed(Path::new(&args[1]), Path::new(&args[2])),
        Some("vm-export") if args.len() == 5 => vm_export(Path::new(&args[1]), Path::new(&args[2]), Path::new(&args[3]), Path::new(&args[4])),
        Some("prove") if args.len() == 5 => prove(Path::new(&args[1]), &args[2], Path::new(&args[3]), Path::new(&args[4])),
        Some("cleanup") if args.len() == 2 => cleanup(Path::new(&args[1])),
        _ => Err("usage: owned-proof fixture OUTPUT ROOTFS | vm-seed OUTPUT PACKAGE | vm-export OUTPUT PACKAGE DOMAIN_JSON RECEIPT_JSON | prove ARTIFACT SHA256 DOMAIN_JSON RECEIPT_JSON | cleanup RECEIPT_JSON".into()),
    }
}

fn vm_seed(output: &Path, package: &Path) -> ProofResult<()> {
    if output.exists() {
        return Err("fixture output already exists".into());
    }
    let staged = tempfile::tempdir()?;
    let mut assets = smolvm_pack::assets::AssetCollector::new(staged.path().to_path_buf())?;
    assets.collect_agent_rootfs(&package.join("agent-rootfs"))?;
    assets.add_overlay_template(&package.join("overlay-template.ext4"))?;
    assets.add_vm_storage_template(&package.join("storage-template.ext4"))?;
    let mut manifest = smolvm_pack::format::PackManifest::new(
        "vm://smolbox-proof-seed".into(),
        "none".into(),
        guest_platform(),
        "proof".into(),
    );
    manifest.mode = smolvm_pack::format::PackMode::Vm;
    manifest.cpus = 1;
    manifest.mem = 512;
    manifest.entrypoint = vec!["/bin/sh".into(), "-c".into(), "exit 97".into()];
    write_vm_fixture(output, manifest, assets)
}

fn vm_export(
    output: &Path,
    package: &Path,
    domain_path: &Path,
    receipt_path: &Path,
) -> ProofResult<()> {
    if output.exists() || !domain_path.is_file() {
        return Err("invalid fixture output/domain".into());
    }
    std::env::set_var("SMOLVM_BOOT_BINARY", package.join("smolbox-port"));
    std::env::set_var("SMOLVM_AGENT_ROOTFS", package.join("agent-rootfs"));
    let engine = Engine::open(domain(domain_path)?, false)?;
    let receipt = read_receipt(receipt_path)?;
    let _source = smolvm::agent::fork::lock_fork_source(&receipt.name)?;
    if engine.inspect(&receipt)?.state != ObservedState::Stopped {
        return Err("export requires the saved receipt observed stopped".into());
    }
    let db = smolvm::db::SmolvmDb::open()?;
    let record = db
        .get_vm(&receipt.name)?
        .ok_or("source record disappeared")?;
    if record.image.is_some() {
        return Err("fixture source is not a bare VM".into());
    }
    let staged = tempfile::tempdir()?;
    let mut assets = smolvm_pack::assets::AssetCollector::new(staged.path().join("assets"))?;
    assets.collect_agent_rootfs(&package.join("agent-rootfs"))?;
    // This qualification tool supports bare snapshots only. The SDK's generic
    // exporter boots a temporary VM to flatten qcow2, outside engine accounting
    // and epoch enrollment. Never route that boot around the SmolBox guard.
    // Use a deliberately selected host converter for qcow2 fixture inputs and
    // the SDK's normal collector/packer for their raw results.
    let directory = smolvm::agent::vm_data_dir(&receipt.name);
    let (overlay, overlay_format) =
        smolvm::agent::resolve_disk_image(&directory, smolvm::storage::OVERLAY_DISK_FILENAME);
    let (storage, storage_format) =
        smolvm::agent::resolve_disk_image(&directory, smolvm::storage::STORAGE_DISK_FILENAME);
    let overlay = fixture_raw_disk(&overlay, overlay_format, &staged.path().join("overlay.raw"))?;
    let storage = fixture_raw_disk(&storage, storage_format, &staged.path().join("storage.raw"))?;
    assets.add_overlay_template(&overlay)?;
    assets.add_vm_storage_template(&storage)?;
    let exported = smolvm::pack_export::FromVmAssets {
        mode: smolvm_pack::format::PackMode::Vm,
        image: None,
        image_env: Vec::new(),
        image_user: None,
        layer_bytes: assets.staged_layer_bytes(),
    };
    let mut manifest = smolvm_pack::format::PackManifest::new(
        "vm://smolbox-proof-export".into(),
        "none".into(),
        guest_platform(),
        "proof".into(),
    );
    smolvm::pack_export::seed_manifest_from_vm(&mut manifest, &record, &exported);
    manifest.cpus = record.cpus;
    manifest.mem = record.mem;
    // A pack's workload must remain inert during embedded create/start.
    manifest.entrypoint = vec![
        "/bin/sh".into(),
        "-c".into(),
        "printf forbidden > /workspace/implicit-vm-workload".into(),
    ];
    if engine.inspect(&receipt)?.state != ObservedState::Stopped {
        return Err("source changed while preparing fixture".into());
    }
    write_vm_fixture(output, manifest, assets)
}

fn fixture_raw_disk(
    source: &Path,
    format: smolvm::storage::DiskFormat,
    destination: &Path,
) -> ProofResult<std::path::PathBuf> {
    if format == smolvm::storage::DiskFormat::Raw {
        return Ok(source.to_path_buf());
    }
    let tool = std::env::var_os("SMOLBOX_FIXTURE_QEMU_IMG")
        .ok_or("qcow2 fixture authoring requires an explicit approved host qemu-img; SDK temporary VM export is disabled")?;
    let tool = Path::new(&tool);
    use std::os::unix::fs::MetadataExt;
    let metadata = std::fs::symlink_metadata(tool)?;
    if !tool.is_absolute()
        || !metadata.is_file()
        || metadata.mode() & 0o022 != 0
        || metadata.mode() & 0o100 == 0
        || (metadata.uid() != 0 && metadata.uid() != unsafe { libc::geteuid() })
        || destination.exists()
    {
        return Err("invalid fixture converter or existing output".into());
    }
    let info = std::process::Command::new(tool)
        .args(["info", "--output=json", "-f", "qcow2"])
        .arg(source)
        .output()?;
    if !info.status.success() || info.stdout.len() > 16 * 1024 {
        return Err("fixture qcow2 observation failed".into());
    }
    let observed: Value = serde_json::from_slice(&info.stdout)?;
    let bytes = observed["virtual-size"]
        .as_u64()
        .ok_or("missing virtual disk size")?;
    if observed["format"] != "qcow2" || bytes == 0 || bytes > 32 * 1024 * 1024 * 1024 {
        return Err("fixture disk exceeds approved authoring bound".into());
    }
    let status = std::process::Command::new(tool)
        .args(["convert", "-f", "qcow2", "-O", "raw", "-S", "64k"])
        .arg(source)
        .arg(destination)
        .status()?;
    if !status.success() || std::fs::metadata(destination)?.len() != bytes {
        return Err("fixture conversion failed or changed geometry".into());
    }
    Ok(destination.to_path_buf())
}

fn write_vm_fixture(
    output: &Path,
    manifest: smolvm_pack::format::PackManifest,
    assets: smolvm_pack::assets::AssetCollector,
) -> ProofResult<()> {
    let (overlay, storage) = (
        assets.inventory().overlay_logical_size,
        assets.inventory().storage_logical_size,
    );
    smolvm_pack::packer::Packer::new(manifest)
        .with_assets(assets)
        .pack_artifact(output)?;
    println!(
        "{}",
        json!({"fixture":output,"sha256":hash_file(output)?,"mode":"vm",
        "overlay_logical_size":overlay,"storage_logical_size":storage})
    );
    Ok(())
}

fn guest_platform() -> String {
    format!(
        "linux/{}",
        if std::env::consts::ARCH == "aarch64" {
            "arm64"
        } else {
            "amd64"
        }
    )
}

fn fixture(output: &Path, rootfs: &Path) -> ProofResult<()> {
    if output.exists() {
        return Err("fixture output already exists".into());
    }
    let staged = tempfile::tempdir()?;
    let mut assets = smolvm_pack::assets::AssetCollector::new(staged.path().to_path_buf())?;
    assets.collect_agent_rootfs(rootfs)?;
    let layer = staged.path().join("agent-rootfs.tar");
    let digest = format!("sha256:{}", hash_file(&layer)?);
    assets.add_layer_from_file(&digest, &layer)?;
    let mut manifest = smolvm_pack::format::PackManifest::new(
        "smolbox-native-proof:offline".into(),
        digest,
        guest_platform(),
        format!("{}/{}", std::env::consts::OS, std::env::consts::ARCH),
    );
    // This must never be run implicitly by creation/start.
    manifest.entrypoint = vec!["/bin/sh".into(), "-c".into(), "exit 97".into()];
    manifest.image_size = assets.staged_layer_bytes();
    smolvm_pack::packer::Packer::new(manifest)
        .with_assets(assets)
        .pack_artifact(output)?;
    println!(
        "{}",
        json!({"fixture": output, "sha256": hash_file(output)?, "platform": guest_platform()})
    );
    Ok(())
}

fn hash_file(path: &Path) -> ProofResult<String> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(hex::encode(hash.finalize()))
}

fn random_hex(size: usize) -> ProofResult<String> {
    let mut bytes = vec![0; size];
    getrandom::fill(&mut bytes).map_err(|_| "entropy unavailable")?;
    Ok(hex::encode(bytes))
}

fn save(path: &Path, value: &Value) -> ProofResult<()> {
    let mut staged =
        tempfile::NamedTempFile::new_in(path.parent().ok_or("missing proof directory")?)?;
    staged.write_all(&serde_json::to_vec_pretty(value)?)?;
    staged.as_file().sync_all()?;
    staged.persist_noclobber(path)?;
    File::open(path.parent().unwrap())?.sync_all()?;
    Ok(())
}

fn read(path: &Path) -> ProofResult<Value> {
    let mut bytes = vec![];
    File::open(path)?.take(4097).read_to_end(&mut bytes)?;
    if bytes.len() > 4096 {
        return Err("proof metadata is too large".into());
    }
    Ok(serde_json::from_slice(&bytes)?)
}

fn field(value: &Value, key: &str) -> ProofResult<String> {
    value[key]
        .as_str()
        .filter(|s| s.len() <= 128)
        .map(str::to_owned)
        .ok_or("invalid proof metadata".into())
}

fn domain(path: &Path) -> ProofResult<DomainBinding> {
    if !path.exists() {
        save(
            path,
            &json!({"target_id": "embedded-local", "generation": random_hex(16)?}),
        )?;
    }
    let value = read(path)?;
    Ok(DomainBinding::default_paths(
        field(&value, "target_id")?,
        field(&value, "generation")?,
    )?)
}

fn receipt_value(receipt: &CreationReceipt) -> Value {
    json!({"target_id":receipt.target_id,"domain_generation":receipt.domain_generation,"name":receipt.name,
        "owner_token":receipt.owner_token,"incarnation":receipt.incarnation,"material_sha256":receipt.material_sha256})
}

fn read_receipt(path: &Path) -> ProofResult<CreationReceipt> {
    let v = read(path)?;
    Ok(CreationReceipt {
        target_id: field(&v, "target_id")?,
        domain_generation: field(&v, "domain_generation")?,
        name: field(&v, "name")?,
        owner_token: field(&v, "owner_token")?,
        incarnation: field(&v, "incarnation")?,
        material_sha256: field(&v, "material_sha256")?,
    })
}

fn file_options(write: bool) -> FileOptions {
    FileOptions {
        guest_path: "/workspace/smolbox-proof.data".into(),
        max_bytes: 2 * 1024 * 1024,
        timeout: Duration::from_secs(30),
        mode: write.then_some(0o600),
    }
}

fn proof_templates(package: &Path) -> ProofResult<smolbox_engine::ApprovedTemplates> {
    // Qualification inputs are explicitly selected packages. Resolve template
    // approval from their existing manifest, never mint digests from inventory.
    let manifest: Value = serde_json::from_slice(&std::fs::read(package.join("package.json"))?)?;
    let evidence = |name: &str| -> ProofResult<smolbox_engine::TemplateFile> {
        let entry = manifest["assets"]
            .as_array()
            .ok_or("invalid package assets")?
            .iter()
            .find(|entry| entry["kind"] == "file" && entry["path"] == name)
            .ok_or("missing package template")?;
        Ok(smolbox_engine::TemplateFile {
            path: package.join(name).canonicalize()?,
            sha256: field(entry, "sha256")?,
            bytes: entry["bytes"].as_u64().ok_or("invalid template size")?,
        })
    };
    let template = |name: &str| -> ProofResult<smolbox_engine::ApprovedTemplate> {
        Ok(smolbox_engine::ApprovedTemplate {
            plain: evidence(name)?,
            compressed: evidence(&format!("{name}.zst"))?,
        })
    };
    Ok(smolbox_engine::ApprovedTemplates {
        storage: template("storage-template.ext4")?,
        overlay: template("overlay-template.ext4")?,
    })
}

fn prove(
    artifact: &Path,
    sha256: &str,
    domain_path: &Path,
    receipt_path: &Path,
) -> ProofResult<()> {
    let intent_path = receipt_path.with_extension("intent.json");
    if receipt_path.exists() || intent_path.exists() {
        return Err("proof receipt exists; use explicit cleanup, never replay create".into());
    }
    let binding = domain(domain_path)?;
    let executable = std::env::current_exe()?;
    let build = hex::encode(Sha256::digest(std::fs::read(&executable)?));
    let library_directory = std::env::var_os("SMOLVM_LIB_DIR")
        .or_else(|| std::env::var_os("LIBKRUN_BUNDLE"))
        .ok_or("explicit approved library directory required")?;
    let identity = smolbox_engine::Executable {
        path: executable,
        sha256: build.clone(),
    };
    let host = smolbox_engine::HostContext::capture(
        binding.clone(),
        random_hex(16)?,
        build,
        smolbox_engine::ExecutableLocator {
            boot: identity.clone(),
            file_worker: identity,
            library_directory: Path::new(&library_directory).canonicalize()?,
        },
    )?;
    let mut engine = Engine::open_with_host(binding, true, host)?;
    let boot = engine.prepare_boot_launcher()?;
    std::env::set_var("SMOLVM_BOOT_BINARY", boot);
    let rootfs = std::env::var_os("SMOLVM_AGENT_ROOTFS")
        .ok_or("explicit approved package rootfs required")?;
    let package = Path::new(&rootfs)
        .parent()
        .ok_or("invalid package rootfs")?;
    let manifest = std::fs::read(package.join("package.json"))?;
    engine.prepare_templates(
        proof_templates(package)?,
        &hex::encode(Sha256::digest(manifest)),
    )?;
    let request = smolbox_engine::CreateRequest {
        name: format!("smolbox-proof-{}", random_hex(8)?),
        owner_token: random_hex(32)?,
        incarnation: random_hex(16)?,
        artifact: ApprovedArtifact {
            path: artifact.canonicalize()?,
            sha256: sha256.into(),
            max_bytes: 128 * 1024 * 1024,
            guest_platform: guest_platform(),
        },
        resources: Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        },
        labels: BTreeMap::new(),
    };
    save(
        &intent_path,
        &json!({"target_id":engine.binding().target_id,
        "domain_generation":engine.binding().generation,"name":request.name,
        "owner_token":request.owner_token,"incarnation":request.incarnation,
        "artifact_sha256":request.artifact.sha256,"cpus":1,"memory_mib":512,
        "storage_gib":1,"overlay_gib":1}),
    )?;
    let receipt = engine.create(request)?;
    save(receipt_path, &receipt_value(&receipt))?;
    if engine.start(&receipt)?.state != ObservedState::Running {
        return Err("VM is not running".into());
    }
    let mut stdout = vec![];
    let mut stderr = vec![];
    let command = engine.exec(&receipt, Command { argv: vec!["/bin/sh".into(), "-c".into(),
        "printf 'cpu=%s mem_kib=%s storage_sectors=%s overlay_sectors=%s env=%s cwd=%s user=%s\\n' \"$(nproc)\" \"$(awk '/MemTotal/{print $2}' /proc/meminfo)\" \"$(cat /sys/class/block/vda/size)\" \"$(cat /sys/class/block/vdb/size)\" \"$SMOLBOX_PROOF\" \"$PWD\" \"$(id -u)\"; printf 'stderr-proof\\n' >&2".into()],
        env: vec![("SMOLBOX_PROOF".into(), "set".into())], workdir: Some("/workspace".into()), user: Some("0:0".into()),
        timeout: Duration::from_secs(30), max_output_bytes: 16384 }, Cancellation::new(), |output| {
            match output.stream { Stream::Stdout => stdout.extend(output.bytes), Stream::Stderr => stderr.extend(output.bytes) }
            Ok(())
        })?;
    if !command.success() {
        return Err("foreground command lacks successful exit evidence".into());
    }
    let applied = String::from_utf8(stdout)?;
    let memory_kib: u64 = applied
        .split_whitespace()
        .find_map(|value| value.strip_prefix("mem_kib="))
        .ok_or("missing memory witness")?
        .parse()?;
    if !applied.contains("cpu=1 ")
        || !applied.contains("storage_sectors=2097152 ")
        || !applied.contains("overlay_sectors=2097152 ")
        || !applied.contains("env=set cwd=/workspace user=0")
        || !(400000..=524288).contains(&memory_kib)
        || stderr != b"stderr-proof\n"
    {
        return Err("applied resource/exec witness mismatch".into());
    }
    let mut user_stdout = vec![];
    let user = engine.exec(
        &receipt,
        Command {
            argv: vec!["/usr/bin/id".into(), "-u".into()],
            env: vec![],
            workdir: Some("/".into()),
            user: Some("65534:65534".into()),
            timeout: Duration::from_secs(10),
            max_output_bytes: 1024,
        },
        Cancellation::new(),
        |output| {
            if output.stream == Stream::Stdout {
                user_stdout.extend(output.bytes);
            }
            Ok(())
        },
    )?;
    if !user.success() || user_stdout != b"65534\n" {
        return Err("qualified non-root user mismatch".into());
    }
    let deadline = engine.exec(
        &receipt,
        Command {
            argv: vec![
                "/bin/sh".into(),
                "-c".into(),
                "printf 'started\\n'; sleep 5".into(),
            ],
            env: vec![],
            workdir: None,
            user: None,
            timeout: Duration::from_millis(500),
            max_output_bytes: 1024,
        },
        Cancellation::new(),
        |_| Ok(()),
    )?;
    if deadline.completion != Completion::Deadline
        || deadline.observed_exit.is_some()
        || deadline.success()
    {
        return Err("deadline fabricated completion evidence".into());
    }
    let bytes = vec![0x5a; 1024 * 1024 + 17];
    let write = engine.write_file(&receipt, file_options(true), &bytes, Cancellation::new())?;
    if !write.success() || !write.native_acknowledged || write.observed_bytes != bytes.len() as u64
    {
        return Err("file upload not acknowledged".into());
    }
    let mut collected = vec![];
    let read = engine.read_file(
        &receipt,
        file_options(false),
        Cancellation::new(),
        |chunk| {
            collected.extend(chunk);
            Ok(())
        },
    )?;
    if !read.success() || !read.native_acknowledged || collected != bytes {
        return Err("file collection differs".into());
    }
    if engine.stop(&receipt)?.state != ObservedState::Stopped {
        return Err("stop unverified".into());
    }
    if engine.start(&receipt)?.state != ObservedState::Running {
        return Err("restart unverified".into());
    }
    let mut retained = vec![];
    let read_retained = engine.read_file(
        &receipt,
        file_options(false),
        Cancellation::new(),
        |chunk| {
            retained.extend(chunk);
            Ok(())
        },
    )?;
    if !read_retained.success() || retained != bytes {
        return Err("retained file did not survive stop/start".into());
    }
    if engine.stop(&receipt)?.state != ObservedState::Stopped
        || engine.delete(&receipt)?.state != ObservedState::Missing
    {
        return Err("owned cleanup unverified".into());
    }
    if !engine.shutdown().is_empty() {
        return Err("owned handle inventory is not empty".into());
    }
    println!(
        "{}",
        json!({"source_revision":smolbox_engine::SMOLVM_REVISION,"name":receipt.name,
        "applied_witness":applied.trim(),"observed_exit":command.observed_exit,"file_bytes":bytes.len(),
        "qualified_user":65534,"deadline_without_exit_verified":true,
        "retained_file_verified":true,"owned_machine_missing":true,"owned_handles_empty":true})
    );
    Ok(())
}

fn cleanup(path: &Path) -> ProofResult<()> {
    let receipt = read_receipt(path)?;
    let engine = Engine::open(
        DomainBinding::default_paths(receipt.target_id.clone(), receipt.domain_generation.clone())?,
        false,
    )?;
    if engine.inspect(&receipt)?.state == ObservedState::Running {
        engine.stop(&receipt)?;
    }
    if engine.delete(&receipt)?.state != ObservedState::Missing {
        return Err("cleanup unverified".into());
    }
    println!(
        "{}",
        json!({"name":receipt.name,"owned_machine_missing":true})
    );
    Ok(())
}
