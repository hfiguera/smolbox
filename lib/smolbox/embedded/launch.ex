defmodule SmolBox.Embedded.Launch do
  @moduledoc false
  import Bitwise
  alias SmolBox.Embedded.{Config, ImageContract, Protocol, RegistryContract}

  @cleared ~w(DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH LD_LIBRARY_PATH LD_PRELOAD)

  def directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-port-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    with :ok <- File.mkdir(path), :ok <- File.chmod(path, 0o700), do: {:ok, path}
  end

  def prepare(config, directory) do
    executable = Config.executable(config)

    with :ok <- plain_path(executable),
         :ok <- plain_path(Path.join(config.package_path, "package.json")),
         {:ok, protocol} <- protocol(Path.join(config.package_path, "package.json"), config),
         {:ok, digest} <- hash(executable, 268_435_456),
         true <- digest == config.package_identity["build_sha256"],
         {:ok, %{mode: mode}} <- File.lstat(executable),
         true <- (mode &&& 0o111) != 0,
         {:ok, body} <- Jason.encode(helper_config(config)),
         true <- byte_size(body) <= 65_536,
         path = Path.join(directory, "config.json"),
         :ok <- File.write(path, body, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok,
       %{
         executable: executable,
         config_path: path,
         directory: directory,
         protocol_major: protocol.major,
         protocol_minor: protocol.minor
       }}
    else
      _invalid -> :error
    end
  rescue
    _redacted -> :error
  end

  def open(prepared) do
    options = [
      :binary,
      :stream,
      :exit_status,
      :use_stdio,
      :hide,
      {:args, [~c"--config", String.to_charlist(prepared.config_path)]},
      {:cd, String.to_charlist(Path.dirname(prepared.executable))},
      {:env, Enum.map(@cleared, &{String.to_charlist(&1), false})},
      {:busy_limits_port, {65_536, 131_072}},
      {:busy_limits_msgq, {65_536, 131_072}}
    ]

    {:ok, Port.open({:spawn_executable, String.to_charlist(prepared.executable)}, options)}
  rescue
    _redacted -> :error
  end

  def cleanup(nil), do: :ok

  def cleanup(directory) do
    File.rm(Path.join(directory, "config.json"))
    File.rmdir(directory)
    :ok
  end

  # One monitor per owner also cleans its private config after an untrappable
  # owner kill. It holds only the current directory across helper restarts.
  def watch(owner) do
    spawn(fn -> watch_directory(Process.monitor(owner), nil) end)
  end

  def remember(watcher, directory), do: send(watcher, {:directory, directory})

  defp watch_directory(ref, directory) do
    receive do
      {:directory, current} ->
        cleanup(directory)
        watch_directory(ref, current)

      {:DOWN, ^ref, :process, _owner, _reason} ->
        cleanup_after_exit(directory, 5)
    end
  end

  defp cleanup_after_exit(nil, _attempts), do: :ok
  defp cleanup_after_exit(_directory, 0), do: :ok

  defp cleanup_after_exit(directory, attempts) do
    cleanup(directory)

    if File.exists?(directory) do
      receive do
      after
        20 -> cleanup_after_exit(directory, attempts - 1)
      end
    end
  end

  def artifact(approval) do
    %{
      "path" => approval["path"],
      "sha256" => approval["sha256"],
      "max_bytes" => approval["max_bytes"],
      "guest_platform" =>
        if(approval["architecture"] == "aarch64", do: "linux/arm64", else: "linux/amd64")
    }
  end

  @doc false
  def helper_config(config) do
    values = %{
      "schema" => Config.protocol_major(config),
      "target_id" => config.id,
      "generation" => config.domain_generation,
      "allow_initialize" => config.allow_initialize,
      "package_manifest_sha256" => config.package_manifest_sha256,
      "approved_artifacts" => Enum.map(config.artifacts, &artifact/1)
    }

    features =
      case Config.sdk_identity(config) do
        %{"feature_versions" => features} -> features
        _ -> %{}
      end

    values =
      if features["images"] == 1 or features["remote_sources"] == 1 do
        Map.put(
          values,
          "approved_oci_sources",
          config.sources
          |> Enum.filter(&(&1.kind == :oci))
          |> Enum.map(&ImageContract.source/1)
          |> Enum.uniq()
        )
      else
        values
      end

    values = registry_config(values, config, features)

    case Config.sdk_identity(config) do
      %{"feature_versions" => %{"ports" => 1}} ->
        Map.put(values, "publish_address", config.publish_address)

      _legacy ->
        values
    end
  end

  defp registry_config(values, config, %{"remote_sources" => 1}) do
    case RegistryContract.approvals(config) do
      [] -> values
      registry -> Map.put(values, "approved_registry_sources", registry)
    end
  end

  defp registry_config(values, _config, _features), do: values

  defp protocol(path, config) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, bytes} <- :file.read(file, 4_194_305),
             true <- byte_size(bytes) <= 4_194_304,
             true <-
               Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
                 config.package_manifest_sha256,
             {:ok, manifest} <- Jason.decode(bytes),
             true <- manifest["identity"] == config.package_identity do
          manifest_protocol(manifest, config)
        else
          _invalid -> :error
        end
      after
        File.close(file)
      end
    end
  end

  defp manifest_protocol(%{"schema" => 3, "policy" => policy}, config) do
    if Config.protocol_major(config) == 2 and
         policy["schema"] == 2 and policy["port_protocol_major"] == 2 and
         policy["port_protocol_minor"] == 0 and policy["sdk"] == Config.sdk_identity(config) and
         publisher_policy?(policy, Config.sdk_identity(config)) and
         limit_policy?(policy, config),
       do: {:ok, %{major: 2, minor: 0}},
       else: :error
  end

  defp manifest_protocol(%{"schema" => 2, "policy" => %{"port_protocol_minor" => 4}}, config),
    do: legacy_protocol(config, 4)

  defp manifest_protocol(%{"schema" => 1}, config), do: legacy_protocol(config, 3)
  defp manifest_protocol(_manifest, _config), do: :error

  defp limit_policy?(policy, config) do
    limits = Protocol.limits(2, 0, Config.sdk_identity(config))

    Enum.all?(
      [
        {"creation_limits", "creation"},
        {"job_limits", "jobs"},
        {"buffered_limits", "buffered"},
        {"log_limits", "logs"},
        {"observation_limits", "observations"}
      ],
      fn {field, key} -> policy[field] == limits[key] end
    )
  end

  defp publisher_policy?(policy, sdk),
    do: sdk["feature_versions"]["ports"] != 1 or policy["publish_address_default"] == "127.0.0.1"

  defp legacy_protocol(config, minor),
    do: if(Config.protocol_major(config) == 1, do: {:ok, %{major: 1, minor: minor}}, else: :error)

  defp plain_path(path) do
    [root | parts] = Path.split(path)

    Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, prefix} ->
      current = Path.join(prefix, part)

      case File.lstat(current) do
        {:ok, %{type: type}} when type in [:regular, :directory] -> {:cont, {:ok, current}}
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      _invalid -> :error
    end
  end

  defp hash(path, maximum) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size > 0 and size <= maximum,
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        hash_chunks(file, :crypto.hash_init(:sha256), maximum)
      after
        File.close(file)
      end
    else
      _invalid -> :error
    end
  end

  defp hash_chunks(file, context, remaining) do
    case :file.read(file, min(65_536, remaining + 1)) do
      :eof ->
        {:ok, Base.encode16(:crypto.hash_final(context), case: :lower)}

      {:ok, bytes} when byte_size(bytes) <= remaining ->
        hash_chunks(file, :crypto.hash_update(context, bytes), remaining - byte_size(bytes))

      _invalid ->
        :error
    end
  end
end
