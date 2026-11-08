//! Maintainer-only data preparation through the unmodified SDK packer. No VM,
//! domain enrollment, registry request or SDK source modification occurs here.
use sha2::{Digest, Sha256};
use smolvm_pack::assets::AssetCollector;
use smolvm_pack::format::{PackManifest, PackMode};
use smolvm_pack::packer::{read_footer_from_file, read_manifest_from_sidecar, Packer};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::Path;

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct FixtureDefaults {
    entrypoint: Vec<String>,
    cmd: Vec<String>,
    env: Vec<String>,
    workdir: Option<String>,
    user: Option<String>,
}

fn digest(path: &Path) -> std::io::Result<String> {
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

fn main() -> Result<(), Box<dyn std::error::Error>> {
    assert_eq!(std::env::consts::OS, "linux");
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    assert!(
        (5..=6).contains(&args.len()),
        "SOURCE SOURCE_SHA256 PACKAGE PACKAGE_MANIFEST_SHA256 OUTPUT [FIXTURE_DEFAULTS_JSON]"
    );
    let source = Path::new(&args[0]);
    let package = Path::new(&args[2]);
    let output = Path::new(&args[4]);
    assert!(!output.exists() && !output.is_symlink());
    assert_eq!(digest(source)?, args[1]);
    assert_eq!(digest(&package.join("package.json"))?, args[3]);
    let approved: serde_json::Value =
        serde_json::from_reader(File::open(package.join("package.json"))?)?;
    assert_eq!(approved["identity"]["platform"], "linux");
    assert_eq!(approved["policy"]["sdk"]["sdk_version"], "1.22.0");
    // Verify the approved input package before the SDK collector reads it.
    for asset in approved["assets"].as_array().unwrap() {
        let path = package.join(asset["path"].as_str().unwrap());
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
    let original = read_manifest_from_sidecar(source)?;
    assert_eq!(original.mode, PackMode::Container);
    assert_eq!(original.platform, "linux/amd64");
    assert!(original.secret_refs.is_empty() && !original.gpu && !original.cuda);
    assert!(original.checkpoint.is_none() && original.assets.workspace_seed.is_none());
    assert!(!original.assets.layers.is_empty() && original.assets.layers.len() <= 8);
    assert!(original
        .assets
        .layers
        .iter()
        .all(|layer| layer.size <= 256 << 20));
    let mut source_file = File::open(source)?;
    let footer = read_footer_from_file(&mut source_file)?;
    assert_eq!(footer.stub_size, 0);
    assert_eq!(footer.assets_offset, 0);
    assert!(smolvm_pack::packer::verify_sidecar_checksum_file(
        &mut source_file,
        &footer
    )?);
    let temporary = tempfile::tempdir_in(output.parent().unwrap())?;
    let mut collector = AssetCollector::new(temporary.path().join("assets"))?;
    collector.collect_libraries(&package.join("lib"))?;
    collector.collect_agent_rootfs(&package.join("agent-rootfs"))?;
    source_file.seek(SeekFrom::Start(0))?;
    let mut decoder = zstd::stream::read::Decoder::new(source_file.take(footer.assets_size))?;
    decoder.window_log_max(23)?;
    let mut archive = tar::Archive::new(decoder.take(32 << 30));
    let mut remaining = original.assets.layers.clone();
    let mut layer_content = Vec::new();
    let mut staged_layers = std::collections::BTreeMap::new();
    for entry in archive.entries()? {
        let mut entry = entry?;
        let path = entry.path()?.into_owned();
        let Some(index) = remaining
            .iter()
            .position(|layer| Path::new(&layer.path) == path)
        else {
            continue;
        };
        let layer = remaining.remove(index);
        assert!(entry.header().entry_type().is_file());
        assert_eq!(entry.size(), layer.size);
        let staged = temporary.path().join(format!("layer-{}", remaining.len()));
        let mut file = File::create(&staged)?;
        assert_eq!(std::io::copy(&mut entry, &mut file)?, layer.size);
        file.sync_all()?;
        // Upstream layer labels can identify the OCI compressed blob; the
        // stored uncompressed tar has its own diff-id. Preserve both facts.
        layer_content.push(serde_json::json!({"upstream_layer_digest":layer.digest,
            "uncompressed_tar_sha256":digest(&staged)?, "tar_bytes":layer.size}));
        staged_layers.insert(layer.path, staged);
        if remaining.is_empty() {
            break; // Do not extract the unused legacy 20-GiB template.
        }
    }
    assert!(
        remaining.is_empty(),
        "all approved OCI layers must be present"
    );
    // Tar member ordering is independent of OCI overlay ordering.
    for layer in &original.assets.layers {
        collector.add_layer_from_file(&layer.digest, &staged_layers[&layer.path])?;
    }
    let mut manifest = PackManifest::new(
        original.image,
        original.digest,
        original.platform,
        "linux/amd64".into(),
    );
    manifest.entrypoint = original.entrypoint;
    manifest.cmd = original.cmd;
    manifest.env = original.env;
    manifest.workdir = original.workdir;
    manifest.user = original.user;
    manifest.image_size = original.image_size;
    let defaults_sha256 = if let Some(path) = args.get(5) {
        let mut bytes = Vec::new();
        File::open(path)?.take(262145).read_to_end(&mut bytes)?;
        assert!(bytes.len() <= 262144);
        let defaults: FixtureDefaults = serde_json::from_slice(&bytes)?;
        manifest.entrypoint = defaults.entrypoint;
        manifest.cmd = defaults.cmd;
        manifest.env.extend(defaults.env);
        manifest.workdir = defaults.workdir;
        manifest.user = defaults.user;
        Some(hex::encode(Sha256::digest(bytes)))
    } else {
        None
    };
    let image_digest = manifest.digest.clone();
    Packer::new(manifest)
        .with_assets(collector)
        .pack_artifact(output)?;
    assert!(smolvm_pack::packer::verify_sidecar_checksum_file(
        &mut File::open(output)?,
        &read_footer_from_file(&mut File::open(output)?)?
    )?);
    println!(
        "{}",
        serde_json::json!({"status":"created", "scope":"ordinary-python-container-fixture",
        "fixture_sha256":digest(output)?, "bytes":fs::metadata(output)?.len(),
        "source_fixture_sha256":args[1], "package_manifest_sha256":args[3],
        "image_digest":image_digest, "layer_content":layer_content, "storage_template_included":false,
        "fixture_defaults_sha256":defaults_sha256,
        "sdk_vm_started":false, "sdk_source_modified":false})
    );
    Ok(())
}
