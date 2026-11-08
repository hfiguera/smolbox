//! Explicit ordinary SDK qualification. Never selected by the default test run.
//! Uses original Port-created authority and the actual default SDK namespace.
use smolbox_engine as engine;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

fn save(directory: &Path, name: &str, value: &impl serde::Serialize) {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(directory.join(name))
        .unwrap();
    serde_json::to_writer(&mut file, value).unwrap();
    file.sync_all().unwrap();
    File::open(directory).unwrap().sync_all().unwrap();
}
fn budget() -> engine::ReadBudget {
    engine::ReadBudget::for_export_work(Duration::from_secs(600), engine::Cancellation::default())
        .unwrap()
}
#[test]
#[ignore = "explicit ordinary SDK/package/default-domain export fixture; may start one owned helper VM"]
fn ordinary_owned_container_conversion() {
    let config_path =
        PathBuf::from(std::env::var_os("SMOLBOX_EXPORT_ORDINARY_CONFIG").expect("explicit config"));
    let package =
        PathBuf::from(std::env::var_os("SMOLBOX_EXPORT_PACKAGE").expect("explicit package"));
    let output = PathBuf::from(
        std::env::var_os("SMOLBOX_EXPORT_ORDINARY_OUTPUT").expect("new private output"),
    );
    let receipt_path = PathBuf::from(
        std::env::var_os("SMOLBOX_EXPORT_ORDINARY_RECEIPT").expect("original Port receipt"),
    );
    let phase =
        std::env::var("SMOLBOX_EXPORT_ORDINARY_PHASE").expect("explicit qualification phase");
    assert!(matches!(
        phase.as_str(),
        "storage" | "launch" | "convert" | "pack"
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&output)
        .unwrap();
    let config = crate::package::read_config(&config_path)
        .ok()
        .expect("operator config");
    assert!(
        !config.allow_initialize,
        "qualify only an already enrolled real domain"
    );
    let verified = crate::package::verify(
        &package.join("smolbox-port"),
        &config.package_manifest_sha256,
    )
    .ok()
    .expect("exact approved package");
    save(
        &output,
        "package-verified.json",
        &serde_json::json!({"package_manifest_sha256":config.package_manifest_sha256}),
    );
    let receipt: engine::CreationReceipt =
        serde_json::from_slice(&std::fs::read(receipt_path).unwrap()).unwrap();
    let binding =
        engine::DomainBinding::default_paths(config.target_id.clone(), config.generation.clone())
            .unwrap();
    assert_eq!(receipt.target_id, binding.target_id);
    assert_eq!(receipt.domain_generation, binding.generation);
    let epoch = std::env::var("SMOLBOX_EXPORT_ORDINARY_EPOCH").expect("preconfigured owner epoch");
    let executable = engine::Executable {
        path: package.join("smolbox-port"),
        sha256: verified.identity.build_sha256.clone(),
    };
    let host = engine::HostContext::capture(
        binding.clone(),
        epoch,
        config.package_manifest_sha256.clone(),
        engine::ExecutableLocator {
            boot: executable.clone(),
            file_worker: executable,
            library_directory: package.join("lib"),
        },
    )
    .unwrap();
    let mut native = engine::Engine::open_with_host(binding, false, host).unwrap();
    save(
        &output,
        "engine-opened.json",
        &serde_json::json!({"original_domain":true}),
    );
    let launcher = native.prepare_boot_launcher().unwrap();
    // Configure the expected path before starting this test process. Never
    // mutate process-wide SDK settings from a test-harness worker thread.
    assert_eq!(
        Some(launcher.as_os_str()),
        std::env::var_os("SMOLVM_BOOT_BINARY").as_deref()
    );
    native
        .prepare_templates(verified.templates, &config.package_manifest_sha256)
        .unwrap();
    save(
        &output,
        "templates-prepared.json",
        &serde_json::json!({"approved_templates":true}),
    );
    native
        .prepare_export_assets(
            verified.export_assets.expect("declared export inputs"),
            &config.package_manifest_sha256,
            &budget(),
        )
        .unwrap();
    save(
        &output,
        "assets-prepared.json",
        &serde_json::json!({"approved_export_assets":true}),
    );
    assert_eq!(
        native.inspect(&receipt).unwrap().state,
        engine::ObservedState::Stopped
    );
    let mut nonce = [0; 16];
    getrandom::fill(&mut nonce).unwrap();
    let intent = engine::ContainerExportIntent {
        operation_id: format!("ordinary-export-{}", hex::encode(nonce)),
        request_sha256: hex::encode(sha2::Sha256::digest(nonce)),
        request_identity_sha256: hex::encode(sha2::Sha256::digest(
            [nonce.as_slice(), b"identity"].concat(),
        )),
        max_artifact_bytes: 2 << 30,
        max_staging_bytes: 64 << 30,
    };
    save(
        &output,
        "intent.json",
        &serde_json::json!({
            "source": receipt, "operation_id": intent.operation_id, "request_sha256": intent.request_sha256,
            "request_identity_sha256": intent.request_identity_sha256, "max_artifact_bytes": intent.max_artifact_bytes,
            "max_staging_bytes": intent.max_staging_bytes, "phase": phase,
            "package_manifest_sha256": config.package_manifest_sha256, "identity": verified.identity,
        }),
    );
    let resources = engine::ExportConversionResources {
        slots: 1,
        cpus: 4,
        memory_mb: 1152,
        disk_gb: 64,
    };
    let work = budget();
    native
        .admit_export_intent(
            &receipt,
            &intent.operation_id,
            &intent.request_sha256,
            intent.max_staging_bytes,
            &intent.request_identity_sha256,
            &work,
        )
        .unwrap();
    let result = (|| -> engine::Result<serde_json::Value> {
        let source = native
            .qualify_export_source(&receipt, &work)?
            .prepare_container_export(&native)?;
        let scratch = source.prepare_conversion_scratch(&native, &resources, &intent)?;
        let retained = scratch.initialize_sdk_storage(&native)?;
        retained.recheck(&native, &work)?;
        retained.prepare_manager(&native, &work)?;
        if phase != "storage" {
            retained.start_manager(&native)?;
        }
        let mut layer = None;
        if matches!(phase.as_str(), "convert" | "pack") {
            let conversion = retained.run_conversion(&native)?;
            layer = Some(
                serde_json::json!({"bytes":conversion.layer().bytes,"sha256":conversion.layer().sha256}),
            );
            retained.register_conversion(&native, conversion)?;
        }
        if phase != "storage" {
            retained.collect_manager(&native, &work)?;
        }
        let artifact = if phase == "pack" {
            let packed = retained.pack(&native)?;
            let artifact = packed.artifact().clone();
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(output.join("artifact.smolmachine"))
                .map_err(|_| engine::Error {
                    code: engine::ErrorCode::Io,
                    dispatch: engine::Dispatch::MayHaveDispatched,
                })?;
            let mut buffer = [0; 65536];
            let mut offset = 0;
            while offset < artifact.size_bytes {
                let count = (artifact.size_bytes - offset).min(buffer.len() as u64) as usize;
                packed.read_at(offset, &mut buffer[..count])?;
                file.write_all(&buffer[..count])
                    .map_err(|_| engine::Error {
                        code: engine::ErrorCode::Io,
                        dispatch: engine::Dispatch::MayHaveDispatched,
                    })?;
                offset += count as u64;
            }
            file.sync_all().unwrap();
            drop(file);
            packed.close(&budget())?;
            Some(serde_json::json!({"bytes":artifact.size_bytes,"sha256":artifact.sha256}))
        } else {
            drop(retained);
            None
        };
        Ok(serde_json::json!({"layer":layer,"artifact":artifact}))
    })();
    if let Err(error) = &result {
        save(
            &output,
            "operation-error.json",
            &serde_json::json!({"code":format!("{:?}",error.code),"dispatch":format!("{:?}",error.dispatch)}),
        );
    }
    let mut cleanup = native.cleanup_export_staging(
        &receipt,
        &intent.operation_id,
        &intent.request_sha256,
        true,
        &budget(),
    );
    if let Err(error) = &cleanup {
        save(
            &output,
            "retained.json",
            &serde_json::json!({"code":format!("{:?}",error.code),"forced_termination":false,"deletion_authority":false}),
        );
        // Preserve the original owner/managers on uncertainty. No process-loss
        // experiment or reconstructed-manager cleanup is authorized by this test.
        eprintln!("ordinary export retained original authority; see private evidence");
        loop {
            // Explicit operator retry, always against the same original owner,
            // receipt and operation. The engine still rejects SDK stop replay,
            // foreign files and unresolved child authority independently.
            let retry = output.join("retry-cleanup");
            if let Ok(file) = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
                .open(&retry)
            {
                let mut bytes = Vec::new();
                if file.metadata().is_ok_and(|m| m.is_file())
                    && file.take(6).read_to_end(&mut bytes).is_ok()
                    && bytes == b"retry"
                {
                    let _ = std::fs::remove_file(retry);
                    cleanup = native.cleanup_export_staging(
                        &receipt,
                        &intent.operation_id,
                        &intent.request_sha256,
                        true,
                        &budget(),
                    );
                    if cleanup.is_ok() {
                        break;
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }
    save(&output, "cleanup.json", &cleanup.unwrap());
    assert_eq!(
        native.inspect(&receipt).unwrap().state,
        engine::ObservedState::Stopped
    );
    let result = result.expect("ordinary SDK operation; exact cleanup completed");
    save(
        &output,
        "evidence.json",
        &serde_json::json!({
            "status":"passed","phase":phase,"result":result,"package_manifest_sha256":config.package_manifest_sha256,
            "identity":verified.identity,"original_source_receipt":true,"source_stopped":true,
            "conversion_vm_started":phase != "storage","helper_collected":phase != "storage",
            "cleanup_verified":true,"public_export_capability_enabled":false,
            "crash_handling_qualified":false,"distribution_approved":false,
        }),
    );
}

use sha2::Digest;
