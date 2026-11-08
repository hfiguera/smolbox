defmodule SmolBox.Backend.EmbeddedOperation do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext}
  alias SmolBox.Embedded.Request

  alias SmolBox.{Command, Error, Files, GuestPaths, MachineSpec, Validation}

  def build(context, operation, arguments, budget) do
    with true <- EmbeddedContext.scoped?(context),
         {:ok, request, constrained, input, callback} <-
           operation(context, operation, arguments, budget),
         true <- Request.valid?(request, constrained.timeout_ms) do
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
      overlay_gb: resources["overlay_gib"]
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

  defp operation(context, operation, [name, command], budget)
       when operation in [:exec, :exec_stream],
       do: operation(context, operation, [name, command, []], budget)

  defp operation(context, operation, [name, %Command{} = command, options], budget)
       when operation in [:exec, :exec_stream] do
    with :ok <- Command.validate(command),
         true <- name == context.name and command.stdin == nil and not command.background,
         true <- GuestPaths.allowed?(context.profile.guest_paths, :workdir, command.workdir),
         true <- Validation.keys?(options, [:max_output_bytes, :on_event]),
         max <- Keyword.get(options, :max_output_bytes, context.profile.max_output_bytes),
         true <- Validation.integer?(max, 1, min(16_777_216, context.profile.max_output_bytes)),
         callback <- Keyword.get(options, :on_event),
         true <- callback == nil or is_function(callback, 1),
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: command.timeout_secs * 1000) do
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

      {:ok, request, budget, <<>>, callback}
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
