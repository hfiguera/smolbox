defmodule SmolBox.Embedded.Health do
  @moduledoc false
  alias SmolBox.Embedded.Protocol

  def describe(config, health) do
    %{
      status: health.status,
      backend_kind: :embedded,
      bridge: config.bridge,
      domain_binding: %{target_id: config.id, generation: config.domain_generation},
      lifetime: :owner_bound,
      protocol_version: %{major: 1, minor: health.protocol_minor},
      package_identity: config.package_identity,
      package_manifest_sha256: config.package_manifest_sha256,
      capabilities: Protocol.capabilities(),
      engine_limits: Protocol.limits(health.protocol_minor),
      bridge_limits: Map.from_struct(config.limits),
      package_preflight: :passed
    }
  end
end
