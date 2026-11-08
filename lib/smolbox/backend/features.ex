defmodule SmolBox.Backend.Features do
  @moduledoc false
  alias SmolBox.Embedded.Config
  alias SmolBox.Runtime.Target

  # These versions describe the strict approved legacy 1.3/1.4 helper contract.
  # SDK availability and operator catalogs cannot add a feature. Protocol 2
  # binds its implemented descriptor through package policy and the handshake.
  @legacy_native %{
    lifecycle: 1,
    foreground_exec: 1,
    extended_exec: 1,
    files: 1,
    extended_files: 1
  }
  @current ~w(1.19.0 1.20.2 1.22.0)
  @extended ~w(1.17.0 1.19.0 1.20.2 1.22.0)
  @network ~w(1.16.0 1.16.1 1.17.0 1.19.0 1.20.2 1.22.0)
  @supported ~w(1.14.1 1.14.6 1.16.0 1.16.1 1.17.0 1.19.0 1.20.2 1.22.0)
  @http_versions %{
    lifecycle: @supported,
    foreground_exec: @supported,
    files: @supported,
    extended_exec: @extended,
    background_exec: @extended,
    terminals: @extended,
    workloads: @extended,
    networking: @network,
    extended_files: @extended,
    remote_sources: @current,
    images: @current,
    checkpoints: @current,
    exports: @current,
    branches: @current,
    disk_growth: ~w(1.20.2 1.22.0),
    volumes: ~w(1.20.2 1.22.0),
    ports: @extended
  }
  @native_names Map.new(
                  [
                    :material_proofs,
                    :observability,
                    :compact_creation,
                    :job_resources,
                    :logs,
                    :streaming_exec,
                    :buffered_exec | Map.keys(@http_versions)
                  ],
                  &{Atom.to_string(&1), &1}
                )

  def supports?(%{__struct__: Target, kind: :embedded, native_config: config}, feature),
    do: supports?(config, feature)

  def supports?(%Config{} = config, feature),
    do: Map.get(native_versions(config), feature) == 1

  def supports?(%{kind: :embedded}, _feature), do: false

  def supports?(%{runtime_version: version} = worker, feature),
    do: version in Map.get(@http_versions, feature, []) and platform_supported?(worker, feature)

  def supports?(_invalid, _feature), do: false

  def native_versions(%Config{} = config) do
    if Config.validate(config) == :ok and Config.sdk_version(config) == "1.22.0",
      do: approved_native_versions(config),
      else: %{}
  end

  def native_versions(_invalid), do: %{}

  defp approved_native_versions(config) do
    case Config.sdk_identity(config) do
      nil ->
        @legacy_native

      sdk ->
        Map.new(sdk["feature_versions"], fn {name, version} ->
          {Map.fetch!(@native_names, name), version}
        end)
    end
  end

  defp platform_supported?(worker, :volumes), do: Map.get(worker, :platform) == :linux

  defp platform_supported?(worker, :ports),
    do:
      {Map.get(worker, :platform), Map.get(worker, :architecture)} in [
        {:linux, "x86_64"},
        {:macos, "aarch64"}
      ]

  defp platform_supported?(_worker, _feature), do: true
end
