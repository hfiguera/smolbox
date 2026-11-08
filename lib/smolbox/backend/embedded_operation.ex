defmodule SmolBox.Backend.EmbeddedOperation do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, Features}
  alias SmolBox.Embedded.{Config, Request}

  alias SmolBox.{Command, Error, Files, GuestPaths, LogOptions, MachineSpec, Validation}

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

  defp operation(context, :create, [%MachineSpec{} = spec], budget) do
    create = context.assignment.creation
    resources = create["resources"]

    expected = %MachineSpec{
      name: context.name,
      artifact_path: create["artifact"]["path"],
      cpus: resources["cpus"],
      memory_mb: resources["memory_mib"],
      storage_gb: resources["storage_gib"],
      overlay_gb: resources["overlay_gib"],
      network: context.spec.profile.network,
      ports: Map.get(context.spec, :ports, []),
      workload: Map.get(context.spec, :workload)
    }

    if spec == expected and MachineSpec.validate(spec) == :ok and context.identity == nil,
      do: ready(%{"operation" => "create", "create" => create}, budget),
      else: error(:identity_conflict, :create)
  end

  defp operation(%{identity: nil} = context, :inspect_creation, [], budget) do
    with {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384),
         do:
           ready(
             %{"operation" => "inspect_creation", "create" => context.assignment.creation},
             budget
           )
  end

  defp operation(context, operation, [name], budget)
       when operation in [:inspect_machine, :start, :stop, :delete] do
    native = if operation == :inspect_machine, do: "inspect", else: Atom.to_string(operation)

    with true <- name == context.name,
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         do: ready(%{"operation" => native, "receipt" => receipt}, budget),
         else: (_mismatch -> error(:identity_conflict, operation))
  end

  defp operation(context, :machine_measurements, [name], budget) do
    with true <- name == context.name,
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384),
         do: ready(%{"operation" => "measurements", "receipt" => receipt}, budget),
         else: (_invalid -> error(:identity_conflict, :machine_measurements))
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

  defp ready(request, budget), do: {:ok, request, budget, <<>>, nil}
  defp error(category, operation), do: {:error, %Error{category: category, operation: operation}}
end
