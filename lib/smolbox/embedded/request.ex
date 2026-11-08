defmodule SmolBox.Embedded.Request do
  @moduledoc false
  alias SmolBox.Embedded.{
    CreationFeatures,
    ImageContract,
    NativeSource,
    RegistryContract,
    Shape,
    TerminalContract
  }

  alias SmolBox.Validation

  @lifecycle ~w(inspect start stop delete)

  def observation?(%{"operation" => name}),
    do:
      name in ~w(health capacity metrics readiness list measurements inspect_growth inspect_oci_creation inspect_registry_creation)

  def observation?(_request), do: false

  def valid?(operation, budget_ms, major \\ 1) do
    major in [1, 2] and Validation.integer?(budget_ms, 1, 86_400_000) and
      operation?(operation, budget_ms, major)
  end

  def command_valid?(command), do: command?(command)

  def buffered_command_valid?(command) do
    Shape.keys?(command, ~w(argv env workdir user stdin max_output_bytes)) and
      is_map(command["env"]) and
      Validation.integer?(command["max_output_bytes"], 1, 16_777_216) and
      match?(
        {:ok, _},
        SmolBox.Command.new(command["argv"],
          env: Map.to_list(command["env"]),
          workdir: command["workdir"],
          user: command["user"],
          stdin: command["stdin"]
        )
      )
  end

  def growth_request?(request, previous) do
    Shape.keys?(request, ~w(storage_gib overlay_gib)) and
      Shape.keys?(previous, ~w(storage_gib overlay_gib)) and
      Enum.all?(~w(storage_gib overlay_gib), fn key ->
        Validation.integer?(previous[key], 1, 64) and
          (request[key] == nil or Validation.integer?(request[key], previous[key], 64))
      end) and
      Enum.any?(~w(storage_gib overlay_gib), fn key ->
        request[key] != nil and request[key] > previous[key]
      end)
  end

  defp operation?(%{"operation" => "terminal_open"} = operation, budget, 2),
    do:
      Shape.keys?(operation, ~w(operation receipt terminal)) and
        Shape.receipt?(operation["receipt"], 2) and
        TerminalContract.spec?(operation["terminal"]) and
        budget <= operation["terminal"]["session_ms"]

  defp operation?(%{"operation" => name} = operation, budget, 2)
       when name in ~w(expand_disks inspect_growth),
       do:
         Shape.keys?(operation, ~w(operation receipt operation_id request previous)) and
           Shape.receipt?(operation["receipt"], 2) and Shape.id?(operation["operation_id"]) and
           growth_request?(operation["request"], operation["previous"]) and
           budget <= if(name == "inspect_growth", do: 30_000, else: 600_000)

  defp operation?(%{"operation" => "qualify_growth", "quiesced" => true} = operation, budget, 2),
    do:
      Shape.keys?(operation, ~w(operation receipt operation_id request previous quiesced)) and
        Shape.receipt?(operation["receipt"], 2) and Shape.id?(operation["operation_id"]) and
        growth_request?(operation["request"], operation["previous"]) and budget <= 30_000

  defp operation?(%{"operation" => name} = operation, budget, 2)
       when name in ~w(health capacity metrics readiness list),
       do:
         Shape.keys?(operation, ~w(operation)) and
           budget <= if(name == "readiness", do: 2000, else: 30_000)

  defp operation?(%{"operation" => name, "create" => create} = operation, budget, 2)
       when name in ~w(create_oci inspect_oci_creation),
       do:
         Shape.keys?(operation, ~w(operation create)) and NativeSource.creation?(create) and
           (name == "create_oci" or budget <= 30_000)

  defp operation?(%{"operation" => "qualify_oci_creation"} = operation, budget, 2),
    do:
      feature_keys?(operation, ~w(operation source resources user), 2) and budget <= 30_000 and
        NativeSource.artifact?(operation["source"]) and Shape.resources?(operation["resources"]) and
        Shape.optional?(operation["user"], &Shape.text?(&1, 16_384, false))

  defp operation?(%{"operation" => "start_oci"} = operation, _budget, 2),
    do:
      Shape.keys?(operation, ~w(operation receipt source)) and
        Shape.receipt?(operation["receipt"], 2) and
        NativeSource.artifact?(operation["source"])

  defp operation?(%{"operation" => "create_registry_prepared"} = operation, _budget, 2),
    do:
      Shape.keys?(operation, ~w(operation create size_bytes)) and
        NativeSource.registry_creation?(operation["create"]) and
        Validation.integer?(operation["size_bytes"], 1, 34_359_738_368)

  defp operation?(%{"operation" => "inspect_registry_creation"} = operation, budget, 2),
    do:
      Shape.keys?(operation, ~w(operation create)) and budget <= 30_000 and
        NativeSource.registry_creation?(operation["create"])

  defp operation?(%{"operation" => "qualify_registry_creation"} = operation, budget, 2),
    do:
      feature_keys?(operation, ~w(operation source resources user), 2) and budget <= 30_000 and
        NativeSource.registry_artifact?(operation["source"]) and
        Shape.resources?(operation["resources"]) and
        Shape.optional?(operation["user"], &Shape.text?(&1, 16_384, false))

  defp operation?(%{"operation" => "prepare_artifact"} = operation, _budget, 2),
    do:
      (Shape.keys?(operation, ~w(operation source)) or
         Shape.keys?(operation, ~w(operation source credential_ref identity_token))) and
        RegistryContract.source?(operation["source"]) and RegistryContract.credentials?(operation)

  defp operation?(%{"operation" => "pull_image"} = operation, _budget, 2),
    do:
      Shape.keys?(operation, ~w(operation receipt source)) and
        Shape.receipt?(operation["receipt"], 2) and ImageContract.source?(operation["source"])

  defp operation?(%{"operation" => "list_images", "receipt" => receipt} = operation, budget, 2),
    do:
      Shape.keys?(operation, ~w(operation receipt)) and budget <= 30_000 and
        Shape.receipt?(receipt, 2)

  defp operation?(%{"operation" => "measurements", "receipt" => receipt} = operation, budget, 2),
    do:
      Shape.keys?(operation, ~w(operation receipt)) and budget <= 30_000 and
        Shape.receipt?(receipt, 2)

  defp operation?(%{"operation" => "logs"} = operation, budget, 2),
    do:
      Shape.keys?(operation, ~w(operation receipt tail follow max_bytes)) and
        Shape.receipt?(operation["receipt"], 2) and budget <= 300_000 and
        Validation.integer?(operation["tail"], 0, 10_000) and is_boolean(operation["follow"]) and
        Validation.integer?(operation["max_bytes"], 1, 8_388_608)

  defp operation?(
         %{
           "operation" => "qualify_creation",
           "artifact" => artifact,
           "resources" => resources,
           "user" => user
         } = operation,
         budget,
         major
       ),
       do:
         feature_keys?(operation, ~w(operation artifact resources user), major) and
           budget <= 30_000 and
           artifact?(artifact) and Shape.resources?(resources) and
           Shape.optional?(user, &Shape.text?(&1, 16_384, false))

  defp operation?(%{"operation" => "create", "create" => create} = operation, _budget, major),
    do: Shape.keys?(operation, ~w(operation create)) and create?(create, major)

  defp operation?(
         %{"operation" => "inspect_creation", "create" => create} = operation,
         budget,
         major
       ),
       do:
         Shape.keys?(operation, ~w(operation create)) and budget <= 30_000 and
           create?(create, major)

  defp operation?(
         %{"operation" => "exec", "receipt" => receipt, "command" => command} = operation,
         _budget,
         major
       ),
       do:
         Shape.keys?(operation, ~w(operation receipt command)) and Shape.receipt?(receipt, major) and
           command?(command)

  defp operation?(
         %{"operation" => name, "receipt" => receipt, "command" => command} = operation,
         _budget,
         2
       )
       when name in ~w(exec_buffered exec_background exec_stream),
       do:
         Shape.keys?(operation, ~w(operation receipt command)) and Shape.receipt?(receipt, 2) and
           buffered_command_valid?(command) and
           (name == "exec_buffered" or command["stdin"] == nil)

  defp operation?(%{"operation" => name, "receipt" => receipt} = operation, _budget, major)
       when name in @lifecycle,
       do: Shape.keys?(operation, ~w(operation receipt)) and Shape.receipt?(receipt, major)

  defp operation?(
         %{"operation" => "read_file", "receipt" => receipt, "options" => options} = operation,
         budget,
         major
       ),
       do:
         Shape.keys?(operation, ~w(operation receipt options)) and Shape.receipt?(receipt, major) and
           budget <= 600_000 and file?(options) and options["mode"] == nil

  defp operation?(
         %{
           "operation" => "write_file",
           "receipt" => receipt,
           "options" => options,
           "total_bytes" => total
         } = operation,
         budget,
         major
       ),
       do:
         Shape.keys?(operation, ~w(operation receipt options total_bytes)) and
           Shape.receipt?(receipt, major) and
           budget <= 600_000 and file?(options) and
           Validation.integer?(total, 0, options["max_bytes"])

  defp operation?(_operation, _budget, _major), do: false

  defp create?(create, major) do
    feature_keys?(create, ~w(name owner_token incarnation artifact resources labels), major) and
      Shape.id?(create["name"]) and Shape.hex?(create["owner_token"], 64) and
      Shape.hex?(create["incarnation"], 32) and artifact?(create["artifact"]) and
      Shape.resources?(create["resources"]) and labels?(create["labels"])
  end

  defp feature_keys?(value, keys, major) do
    Shape.keys?(value, keys) or
      (major == 2 and Shape.keys?(value, keys ++ ["features"]) and
         CreationFeatures.valid?(value["features"]))
  end

  defp artifact?(artifact),
    do:
      Shape.keys?(artifact, ~w(path sha256 max_bytes guest_platform)) and
        Shape.path?(artifact["path"]) and Validation.digest?(artifact["sha256"]) and
        Validation.integer?(artifact["max_bytes"], 1, 34_359_738_368) and
        artifact["guest_platform"] in ["linux/arm64", "linux/amd64"]

  defp labels?(labels),
    do:
      is_map(labels) and map_size(labels) <= 64 and
        Enum.all?(labels, fn {key, value} ->
          Shape.text?(key, 128, false) and not String.starts_with?(key, "smolbox.") and
            Shape.text?(value, 1024, true)
        end)

  defp command?(command) do
    Shape.keys?(command, ~w(argv env workdir user max_output_bytes)) and
      argv?(command["argv"]) and environment?(command["env"]) and
      command_bytes(command) <= 131_072 and
      Shape.optional?(command["workdir"], &Shape.path?/1) and
      Shape.optional?(command["user"], &Shape.text?(&1, 16_384, false)) and
      Validation.integer?(command["max_output_bytes"], 1, 16_777_216)
  end

  defp argv?([first | rest] = argv),
    do:
      Validation.list?(argv, 256) and Shape.text?(first, 16_384, false) and
        Enum.all?(rest, &Shape.text?(&1, 16_384, true))

  defp argv?(_argv), do: false

  defp environment?(environment),
    do:
      is_map(environment) and map_size(environment) <= 256 and
        Enum.all?(environment, fn {key, value} ->
          Shape.text?(key, 16_384, false) and not String.contains?(key, "=") and
            Shape.text?(value, 16_384, true)
        end)

  defp command_bytes(command),
    do:
      Enum.reduce(command["argv"], 0, fn value, total -> total + byte_size(value) end) +
        Enum.reduce(command["env"], 0, fn {key, value}, total ->
          total + byte_size(key) + byte_size(value)
        end)

  defp file?(options),
    do:
      Shape.keys?(options, ~w(guest_path max_bytes mode)) and Shape.path?(options["guest_path"]) and
        options["guest_path"] != "/" and not String.ends_with?(options["guest_path"], "/") and
        Validation.integer?(options["max_bytes"], 1, 16_777_216) and
        Shape.optional?(options["mode"], &Validation.integer?(&1, 0, 511))
end
