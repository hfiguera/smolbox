defmodule SmolBox.Embedded.Health do
  @moduledoc false
  alias SmolBox.Backend.Features
  alias SmolBox.Embedded.{Config, Protocol}

  def describe(config, health) do
    %{
      status: health.status,
      backend_kind: :embedded,
      bridge: config.bridge,
      domain_binding: %{target_id: config.id, generation: config.domain_generation},
      lifetime: :owner_bound,
      protocol_version: %{major: Config.protocol_major(config), minor: health.protocol_minor},
      package_identity: config.package_identity,
      sdk_version: Config.sdk_version(config),
      engine_version: config.package_identity["engine_version"],
      package_manifest_sha256: config.package_manifest_sha256,
      capabilities: Protocol.capabilities(Config.sdk_identity(config)),
      feature_versions: Features.native_versions(config),
      engine_limits:
        Protocol.limits(
          Config.protocol_major(config),
          health.protocol_minor,
          Config.sdk_identity(config)
        ),
      bridge_limits: Map.from_struct(config.limits),
      package_preflight: :passed
    }
  end
end
