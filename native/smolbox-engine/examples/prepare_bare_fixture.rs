//! Maintainer-only bare artifact preparation through the unmodified SDK packer.
//! Reads an explicitly approved package and writes a new artifact. It opens no
//! SDK domain or manager, makes no registry request and launches no guest or
//! package executable.
use sha2::{Digest, Sha256};
use smolvm_pack::assets::AssetCollector;
use smolvm_pack::format::{PackManifest, PackMode};
use smolvm_pack::packer::{read_footer_from_file, read_manifest_from_sidecar, Packer};
use std::fs::{self, File};
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

fn digest(path: &Path) -> std::io::Result<String> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut bytes = [0; 65536];
    loop {
        let count = file.read(&mut bytes)?;
        if count == 0 {
            return Ok(hex::encode(hash.finalize()));
        }
        hash.update(&bytes[..count]);
    }
}

fn verify(package: &Path, expected: &str) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    assert_eq!(digest(&package.join("package.json"))?, expected);
    let approved: serde_json::Value =
        serde_json::from_reader(File::open(package.join("package.json"))?)?;
    assert_eq!(approved["policy"]["sdk"]["sdk_version"], "1.22.0");
    assert_eq!(
        approved["identity"]["smolvm_revision"],
        "9f446ae00219148ca4a703914f44a8e2fab11655"
    );
    assert_eq!(
        digest(&package.join("smolbox-port"))?,
        approved["identity"]["build_sha256"].as_str().unwrap()
    );
    for asset in approved["assets"].as_array().unwrap() {
        let name = asset["path"].as_str().unwrap();
        assert!(!Path::new(name).is_absolute());
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
    Ok(approved)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    assert_eq!(args.len(), 3, "PACKAGE PACKAGE_MANIFEST_SHA256 NEW_OUTPUT");
    let package = Path::new(&args[0]);
    let output = Path::new(&args[2]);
    assert!(!output.exists() && !output.is_symlink());
    let approved = verify(package, &args[1])?;
    let (guest, host) = match (
        approved["identity"]["platform"].as_str().unwrap(),
        approved["identity"]["architecture"].as_str().unwrap(),
    ) {
        ("linux", "x86_64") => ("linux/amd64", "linux/amd64"),
        ("macos", "aarch64") => ("linux/arm64", "darwin/arm64"),
        _ => panic!("unsupported approved fixture platform"),
    };
    let staging = tempfile::tempdir_in(output.parent().expect("explicit output parent"))?;
    let mut collector = AssetCollector::new(staging.path().join("assets"))?;
    collector.collect_agent_rootfs(&package.join("agent-rootfs"))?;
    collector.add_overlay_template(&package.join("overlay-template.ext4"))?;
    collector.add_vm_storage_template(&package.join("storage-template.ext4"))?;
    // No inline libraries, OCI layers, workspace seed, credentials or captured
    // state. The approved runtime package supplies its own host libraries.
    let mut manifest = PackManifest::new(String::new(), String::new(), guest.into(), host.into());
    manifest.mode = PackMode::Vm;
    manifest.mem = 512;
    Packer::new(manifest)
        .with_assets(collector)
        .pack_artifact(output)?;
    let mut file = File::open(output)?;
    let footer = read_footer_from_file(&mut file)?;
    assert!(smolvm_pack::packer::verify_sidecar_checksum_file(
        &mut file, &footer
    )?);
    let packed = read_manifest_from_sidecar(output)?;
    assert_eq!(packed.mode, PackMode::Vm);
    assert!(packed.assets.layers.is_empty() && packed.assets.libraries.is_empty());
    assert!(packed.assets.workspace_seed.is_none() && packed.checkpoint.is_none());
    assert!(packed.secret_refs.is_empty() && !packed.network && !packed.gpu && !packed.cuda);
    assert!(packed.assets.storage_template.is_some() && packed.assets.overlay_template.is_some());
    verify(package, &args[1])?;
    println!(
        "{}",
        serde_json::json!({"status":"created", "scope":"ordinary-bare-fixture-preparation",
            "package_manifest_sha256":args[1], "fixture_sha256":digest(output)?,
            "bytes":fs::metadata(output)?.len(), "guest_platform":guest, "host_platform":host,
            "mode":"vm", "source_package_unchanged":true, "inline_libraries":false,
            "oci_layers":false, "workspace_seed":false, "captured_state":false,
            "sdk_domain_opened":false, "sdk_vm_started":false, "sdk_source_modified":false})
    );
    Ok(())
}
