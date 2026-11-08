mod adapter;
mod output;
mod package;
mod runtime;
use smolbox_protocol as wire;
use std::path::Path;

fn main() {
    std::panic::set_hook(Box::new(|_| eprintln!("smolbox-port: native panic")));
    if run().is_err() {
        // Native/protocol source text, argv, file content and paths never log.
        eprintln!("smolbox-port: startup or channel failure");
        std::process::exit(2);
    }
}
fn epoch() -> Result<String, ()> {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).map_err(|_| ())?;
    Ok(hex::encode(bytes))
}
fn run() -> Result<(), ()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.as_slice() == ["--terminal-worker"] {
        return smolbox_engine::run_terminal_worker().map_err(|_| ());
    }
    if args.as_slice() == ["--file-worker"] || args.as_slice() == ["--job-worker"] {
        return smolbox_engine::run_file_worker().map_err(|_| ());
    }
    if args.first().map(String::as_str) == Some("_boot-vm") && args.len() == 2 {
        smolbox_engine::BootLauncher::arm_current(Path::new(&args[1])).map_err(|_| ())?;
        return smolvm::internal_boot::run((&args[1]).into()).map_err(|_| ());
    }
    if args.len() != 2 || args[0] != "--config" || !Path::new(&args[1]).is_absolute() {
        return Err(());
    }
    let config = package::read_config(Path::new(&args[1])).map_err(|_| ())?;
    let sdk = package::sdk_identity().map_err(|_| ())?;
    let executable = std::env::current_exe().map_err(|_| ())?;
    let verified = match package::verify(&executable, &config.package_manifest_sha256) {
        Ok(package) => package,
        Err(code) => {
            let hello = wire::Hello {
                major: wire::PARITY_PROTOCOL_MAJOR,
                minor: wire::PARITY_PROTOCOL_MINOR,
                epoch: epoch()?,
                domain: wire::DomainIdentity {
                    target_id: config.target_id,
                    generation: config.generation,
                },
                package: wire::PackageIdentity {
                    engine_version: env!("CARGO_PKG_VERSION").into(),
                    smolvm_revision: smolbox_engine::SMOLVM_REVISION.into(),
                    source_sha256: package::source_sha256(),
                    build_sha256: "0".repeat(64),
                    assets_sha256: "0".repeat(64),
                    platform: if cfg!(target_os = "macos") {
                        "macos".into()
                    } else {
                        "linux".into()
                    },
                    architecture: std::env::consts::ARCH.into(),
                },
                capabilities: vec![],
                limits: wire::Limits::for_sdk(&sdk),
                preflight: wire::Preflight::Rejected { code },
                sdk: Some(Box::new(sdk)),
            };
            wire::write_frame(
                &mut std::io::stdout().lock(),
                &serde_json::to_value(wire::ServerMessage::Hello {
                    hello: hello.into(),
                })
                .map_err(|_| ())?,
            )
            .map_err(|_| ())?;
            return Err(());
        }
    };
    // Configure once, before any worker/reader threads or engine construction.
    // Never trust inherited overrides for packaged runtime resolution.
    if std::env::var_os("SMOLVM_DATA_DIR").is_some() {
        return Err(());
    }
    std::env::set_var("SMOLVM_BOOT_BINARY", &executable);
    std::env::set_var("SMOLVM_IMAGE_SEEDS", "0");
    std::env::set_var(
        "SMOLVM_PUBLISH_ADDR",
        config.publish_address.as_deref().unwrap_or("127.0.0.1"),
    );
    std::env::remove_var("SMOLVM_BOOT_DEBUG");
    std::env::remove_var("SMOLVM_AGENT_ROOTFS_TAR");
    std::env::set_var("SMOLVM_AGENT_ROOTFS", verified.root.join("agent-rootfs"));
    std::env::set_var("SMOLVM_LIB_DIR", verified.root.join("lib"));
    std::env::remove_var("SMOLVM_TEMPLATE_DIR");
    std::env::set_var("SMOLVM_KRUN_LOG_LEVEL", "0");
    let binding = smolbox_engine::DomainBinding::default_paths(
        config.target_id.clone(),
        config.generation.clone(),
    )
    .map_err(|_| ())?;
    let helper_epoch = epoch()?;
    let executable_identity = smolbox_engine::Executable {
        path: executable.clone(),
        sha256: verified.identity.build_sha256.clone(),
    };
    let host = smolbox_engine::HostContext::capture(
        binding.clone(),
        helper_epoch.clone(),
        config.package_manifest_sha256.clone(),
        smolbox_engine::ExecutableLocator {
            boot: executable_identity.clone(),
            file_worker: executable_identity,
            library_directory: verified.root.join("lib"),
        },
    )
    .map_err(|_| ())?;
    let mut engine = smolbox_engine::Engine::open_with_host(binding, config.allow_initialize, host)
        .map_err(|_| ())?;
    let boot = engine.prepare_boot_launcher().map_err(|_| ())?;
    std::env::set_var("SMOLVM_BOOT_BINARY", boot);
    engine
        .prepare_templates(verified.templates, &config.package_manifest_sha256)
        .map_err(|_| ())?;
    let hello = wire::Hello {
        major: wire::PARITY_PROTOCOL_MAJOR,
        minor: wire::PARITY_PROTOCOL_MINOR,
        epoch: helper_epoch,
        domain: wire::DomainIdentity {
            target_id: config.target_id.clone(),
            generation: config.generation.clone(),
        },
        package: verified.identity,
        capabilities: sdk.capabilities(),
        limits: wire::Limits::for_sdk(&sdk),
        preflight: wire::Preflight::Ready,
        sdk: Some(Box::new(sdk)),
    };
    runtime::serve(engine, hello, config)
}
