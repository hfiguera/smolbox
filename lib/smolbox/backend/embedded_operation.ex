defmodule SmolBox.Backend.EmbeddedOperation do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedPreparation, Features}
  alias SmolBox.Embedded.{Config, ImageContract, Request}

  alias SmolBox.{
    ArtifactPreparation,
    Command,
    DiskExpansion,
    Error,
    Files,
    GuestPaths,
    ImagePull,
    LogOptions,
    MachineSpec,
    Source,
    Validation
  }

  alias SmolBox.Machine

  def build(context, operation, arguments, budget) do
    with true <- EmbeddedContext.scoped?(context),
         {:ok, request, constrained, input, callback} <-
           operation(context, operation, arguments, budget),
         true <-
           Request.valid?(request, constrained.timeout_ms, Config.protocol_major(context.config)) do
      {:ok, request, constrained, input, callback}
    else
      {:error, _error} = error -> error
      _invalid -> error(:identity_conflict, operation)
    end
  end

  def prepared_request(
        %{"operation" => "create_registry_prepared", "create" => create} = request,
        %ArtifactPreparation{} = prepared
      ) do
    if ArtifactPreparation.matches?(prepared, create["source"]) and prepared.size_bytes > 0,
      do: {:ok, Map.put(request, "size_bytes", prepared.size_bytes)},
      else: error(:identity_conflict, :create)
  end

  def prepared_request(_request, _prepared), do: error(:identity_conflict, :create)

  defp creation_source(%{"source" => source}) do
    {:ok, source} = Source.from_artifact(source)
    source
  end

  defp creation_source(_local), do: :image

  defp creation_operation(%{"source" => %{"kind" => "registry"}}, "create"),
    do: "create_registry_prepared"

  defp creation_operation(%{"source" => %{"kind" => "registry"}}, "inspect_creation"),
    do: "inspect_registry_creation"

  defp creation_operation(%{"source" => _source}, "create"), do: "create_oci"
  defp creation_operation(%{"source" => _source}, "inspect_creation"), do: "inspect_oci_creation"
  defp creation_operation(_local, operation), do: operation

  defp lifecycle_request(%{"source" => %{"kind" => "oci"} = source}, "start", receipt),
    do: %{"operation" => "start_oci", "receipt" => receipt, "source" => source}

  defp lifecycle_request(_creation, operation, receipt),
    do: %{"operation" => operation, "receipt" => receipt}

  defp operation(context, :create, [%MachineSpec{} = spec], budget) do
    create = context.assignment.creation
    resources = create["resources"]

    expected = %MachineSpec{
      name: context.name,
      artifact_path: if(create["source"], do: nil, else: create["artifact"]["path"]),
      source: creation_source(create),
      cpus: resources["cpus"],
      memory_mb: resources["memory_mib"],
      storage_gb: resources["storage_gib"],
      overlay_gb: resources["overlay_gib"],
      network: context.spec.profile.network,
      ports: Map.get(context.spec, :ports, []),
      workload: Map.get(context.spec, :workload)
    }

    if spec == expected and MachineSpec.validate(spec) == :ok and context.identity == nil,
      do:
        ready(%{"operation" => creation_operation(create, "create"), "create" => create}, budget),
      else: error(:identity_conflict, :create)
  end

  defp operation(context, :create_prepared, [spec, prepared], budget),
    do: operation(context, :create_prepared, [spec, prepared, []], budget)

  defp operation(
         context,
         :create_prepared,
         [
           %MachineSpec{source: %Source{kind: :registry}} = spec,
           %ArtifactPreparation{} = prepared,
           options
         ],
         budget
       ) do
    create = context.assignment.creation

    with true <- create["source"] == Source.artifact(spec.source),
         {:ok, _credentials} <- EmbeddedPreparation.credentials(spec.source, options),
         true <- ArtifactPreparation.matches?(prepared, create["source"]),
         {:ok, request, budget, _input, _callback} <- operation(context, :create, [spec], budget) do
      with {:ok, request} <- prepared_request(request, prepared), do: ready(request, budget)
    else
      _invalid -> error(:identity_conflict, :create)
    end
  end

  defp operation(%{identity: nil} = context, :inspect_creation, [], budget) do
    with {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384),
         do:
           ready(
             %{
               "operation" => creation_operation(context.assignment.creation, "inspect_creation"),
               "create" => context.assignment.creation
             },
             budget
           )
  end

  defp operation(context, operation, [name], budget)
       when operation in [:inspect_machine, :start, :stop, :delete] do
    native = if operation == :inspect_machine, do: "inspect", else: Atom.to_string(operation)

    with true <- name == context.name,
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         do: ready(lifecycle_request(context.assignment.creation, native, receipt), budget),
         else: (_mismatch -> error(:identity_conflict, operation))
  end

  defp operation(context, :pull_image, [name, %Source{kind: :oci} = source], budget) do
    with true <- name == context.name and Features.supports?(context.config, :images),
         :ok <- Source.validate(source),
         true <- source in context.config.sources and context.profile.network != :offline,
         %{command: %ImagePull{source: ^source}} <- context.spec,
         %{spec: %{artifact: %{"kind" => "oci"}}} <- context.managed_machine,
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <-
           Budget.constrain(budget,
             timeout_ms: context.profile.execution_ms,
             max_response_bytes: 16_384
           ),
         do:
           ready(
             %{
               "operation" => "pull_image",
               "receipt" => receipt,
               "source" => ImageContract.source(source)
             },
             budget
           ),
         else: (_ -> error(:unsupported_capability, :pull_image))
  end

  defp operation(context, :list_images, [name], budget) do
    with true <- name == context.name,
         true <- Features.supports?(context.config, :images),
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <-
           Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 8_388_608),
         do: ready(%{"operation" => "list_images", "receipt" => receipt}, budget),
         else: (_invalid -> error(:unsupported_capability, :list_images))
  end

  defp operation(context, :machine_measurements, [name], budget) do
    with true <- name == context.name,
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384),
         do: ready(%{"operation" => "measurements", "receipt" => receipt}, budget),
         else: (_invalid -> error(:identity_conflict, :machine_measurements))
  end

  defp operation(context, :qualify_growth, [true], budget) do
    with true <- Features.supports?(context.config, :disk_growth),
         %{state: :unknown} = intent <- context.growth,
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384) do
      ready(
        %{
          "operation" => "qualify_growth",
          "quiesced" => true,
          "receipt" => intent.receipt,
          "operation_id" => intent.id,
          "request" => intent.request,
          "previous" => intent.previous
        },
        budget
      )
    else
      _ -> error(:identity_conflict, :qualify_growth)
    end
  end

  defp operation(context, :expand_disks, [%Machine{} = observed, options], budget) do
    with true <- Features.supports?(context.config, :disk_growth),
         %{state: :dispatching} = intent <- context.growth,
         {:ok, _} <- DiskExpansion.targets(options),
         true <-
           Map.new(options) == %{
             storage_gb: intent.targets["storage_gib"],
             overlay_gb: intent.targets["overlay_gib"]
           },
         true <- growth_observed?(context, intent, observed),
         {:ok, budget} <-
           Budget.constrain(budget,
             timeout_ms: min(context.profile.preparation_ms, 600_000),
             max_response_bytes: 16_384
           ) do
      ready(
        %{
          "operation" => "expand_disks",
          "receipt" => intent.receipt,
          "operation_id" => intent.id,
          "request" => intent.request,
          "previous" => intent.previous
        },
        budget
      )
    else
      _ -> error(:identity_conflict, :expand_disks)
    end
  end

  defp operation(context, :logs, [name, options], budget) do
    with true <- name == context.name and Features.supports?(context.config, :logs),
         {:ok, options} <- LogOptions.validate(options),
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <-
           Budget.constrain(budget,
             timeout_ms: options.timeout_ms,
             max_response_bytes: options.max + 30_000
           ) do
      {:ok,
       %{
         "operation" => "logs",
         "receipt" => receipt,
         "tail" => options.tail,
         "follow" => options.follow,
         "max_bytes" => options.max
       }, budget, <<>>, options.callback}
    else
      {:error, _} = error -> error
      _ -> error(:unsupported_capability, :logs)
    end
  end

  defp operation(context, :logs, [name], budget),
    do: operation(context, :logs, [name, []], budget)

  defp operation(context, operation, [name, command], budget)
       when operation in [:exec, :exec_stream],
       do: operation(context, operation, [name, command, []], budget)

  defp operation(context, operation, [name, %Command{} = command, options], budget)
       when operation in [:exec, :exec_stream] do
    with :ok <- Command.validate(command),
         true <-
           name == context.name and background_allowed?(context, operation, command) and
             (command.stdin == nil or
                (operation == :exec and Features.supports?(context.config, :buffered_exec))),
         true <- GuestPaths.allowed?(context.profile.guest_paths, :workdir, command.workdir),
         true <- Validation.keys?(options, [:max_output_bytes, :on_event]),
         max <- Keyword.get(options, :max_output_bytes, context.profile.max_output_bytes),
         true <- Validation.integer?(max, 1, min(16_777_216, context.profile.max_output_bytes)),
         callback <- Keyword.get(options, :on_event),
         true <- callback_valid?(command, callback),
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: command_budget(context, command)) do
      request = %{
        "operation" => "exec",
        "receipt" => receipt,
        "command" => %{
          "argv" => command.argv,
          "env" => Map.new(command.env),
          "workdir" => command.workdir,
          "user" => command.user,
          "max_output_bytes" => max
        }
      }

      {:ok, command_request(context, operation, command, request), budget, <<>>, callback}
    else
      _unsupported -> error(:unsupported_capability, operation)
    end
  end

  defp operation(context, :upload, [name, path, bytes, digest], budget) do
    with true <-
           is_binary(bytes) and
             byte_size(bytes) <= min(context.profile.max_file_bytes, 16_777_216),
         true <- Files.sha256(bytes) == digest,
         {:ok, request, budget, _input, _callback} <-
           file(context, name, path, :upload, context.profile.max_file_bytes, budget) do
      {:ok, Map.merge(request, %{"operation" => "write_file", "total_bytes" => byte_size(bytes)}),
       budget, bytes, nil}
    else
      _invalid -> error(:validation, :upload)
    end
  end

  defp operation(context, :download, [name, path, max], budget),
    do: file(context, name, path, :download, max, budget)

  defp operation(_context, operation, _arguments, _budget),
    do: error(:unsupported_capability, operation)

  defp background_allowed?(context, operation, command),
    do:
      not command.background or
        (operation == :exec and context.managed_machine != nil and
           Features.supports?(context.config, :background_exec))

  defp command_budget(context, %{background: true}), do: context.profile.execution_ms
  defp command_budget(_context, command), do: command.timeout_secs * 1000

  defp callback_valid?(command, callback),
    do:
      (callback == nil or is_function(callback, 1)) and
        (not command.background or callback == nil)

  defp command_request(_context, :exec, %{background: true}, request),
    do: request |> Map.put("operation", "exec_background") |> put_in(["command", "stdin"], nil)

  defp command_request(context, :exec_stream, _command, request) do
    if Features.supports?(context.config, :streaming_exec),
      do: request |> Map.put("operation", "exec_stream") |> put_in(["command", "stdin"], nil),
      else: request
  end

  defp command_request(context, :exec, command, request) do
    if Features.supports?(context.config, :buffered_exec),
      do:
        request
        |> Map.put("operation", "exec_buffered")
        |> put_in(["command", "stdin"], command.stdin),
      else: request
  end

  defp file(context, name, path, direction, max, budget) do
    with true <-
           name == context.name and
             GuestPaths.allowed?(context.profile.guest_paths, direction, path),
         true <- path != "/" and not String.ends_with?(path, "/"),
         true <- Validation.integer?(max, 1, min(16_777_216, context.profile.max_file_bytes)),
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 600_000) do
      ready(
        %{
          "operation" => "read_file",
          "receipt" => receipt,
          "options" => %{"guest_path" => path, "max_bytes" => max, "mode" => nil}
        },
        budget
      )
    else
      _invalid -> error(:validation, direction)
    end
  end

  defp growth_observed?(context, intent, %{backend_identity: %{receipt: receipt}} = observed),
    do:
      observed.state in [:created, :stopped] and observed.name == context.name and
        receipt == intent.receipt and
        %{"storage_gib" => observed.storage_gb, "overlay_gib" => observed.overlay_gb} ==
          intent.previous

  defp growth_observed?(_context, _intent, _observed), do: false

  defp ready(request, budget), do: {:ok, request, budget, <<>>, nil}
  defp error(category, :list_images), do: {:error, %Error{category: category, operation: :images}}
  defp error(category, operation), do: {:error, %Error{category: category, operation: operation}}
end
