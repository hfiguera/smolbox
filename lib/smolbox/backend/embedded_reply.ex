defmodule SmolBox.Backend.EmbeddedReply do
  @moduledoc false
  alias SmolBox.Embedded.{CreationFeatures, Identity, LogStream}
  alias SmolBox.{Error, LaunchResult, LogResult, Machine, MachineMeasurements, Result}

  def decode(context, operation, request, {:ok, outcome, output, overlay}),
    do: response(context, operation, request, outcome, output, overlay)

  def decode(_context, operation, _request, {:error, %Error{} = error}),
    do: {:error, %{error | operation: error_operation(operation)}}

  defp response(
         %{identity: nil},
         :inspect_creation,
         %{"operation" => "inspect_creation"},
         %{"result" => "creation_presence", "presence" => presence},
         %{stdout: <<>>, stderr: <<>>, file: <<>>},
         nil
       ) do
    case presence do
      "absent" -> {:ok, :absent}
      "unverified" -> error(:identity_conflict, :inspect, :dispatch_uncertain)
    end
  end

  defp response(
         context,
         :create,
         _request,
         %{"result" => "created", "receipt" => receipt},
         _output,
         nil
       ) do
    identity = %Identity{receipt: receipt}

    if Identity.matches?(identity, context.assignment),
      do: {:ok, machine(context, :created, context.assignment.creation["resources"], identity)},
      else: error(:identity_conflict, :create, :dispatch_uncertain)
  end

  defp response(
         context,
         operation,
         _request,
         %{"result" => "observed", "observation" => observation},
         _output,
         nil
       ),
       do: observation(context, operation, observation)

  defp response(
         context,
         :machine_measurements,
         _request,
         %{"result" => "measurements", "observation" => observed, "counters" => counters},
         %{stdout: <<>>, stderr: <<>>, file: <<>>},
         nil
       ) do
    case observation(context, :inspect_machine, observed) do
      {:ok, machine} ->
        values = Map.new(counters, fn {key, value} -> {counter_field(key), value} end)

        {:ok,
         struct!(
           MachineMeasurements,
           Map.merge(values, %{machine: machine, checked_at_ms: System.system_time(:millisecond)})
         )}

      {:error, error} ->
        {:error, %{error | operation: :machine_measurements}}
    end
  end

  defp response(
         _context,
         :logs,
         request,
         %{"result" => "logs", "completion" => "completed"} = outcome,
         %{stdout: <<>>, stderr: <<>>, file: bytes},
         nil
       ) do
    with {:ok, lines, parser} <- LogStream.decode(bytes, request["max_bytes"]),
         true <-
           parser.count == outcome["lines"] and parser.bytes == outcome["bytes"] and
             byte_size(bytes) == outcome["wire_bytes"],
         do: {:ok, %LogResult{lines: lines}},
         else: (_ -> error(:protocol, :logs, :dispatch_uncertain))
  end

  defp response(
         _context,
         :exec,
         %{"operation" => "exec_background"},
         %{"result" => "launched", "pid" => pid},
         %{stdout: <<>>, stderr: <<>>, file: <<>>},
         nil
       ),
       do: {:ok, %LaunchResult{pid: pid}}

  defp response(
         _context,
         operation,
         _request,
         %{"result" => "command"} = outcome,
         output,
         overlay
       )
       when operation in [:exec, :exec_stream], do: command(operation, outcome, output, overlay)

  defp response(
         _context,
         :download,
         _request,
         %{
           "result" => "file",
           "completion" => "completed",
           "native_acknowledged" => true,
           "observed_bytes" => size
         },
         %{file: bytes, stdout: <<>>, stderr: <<>>},
         nil
       )
       when byte_size(bytes) == size,
       do: {:ok, bytes}

  defp response(
         _context,
         :upload,
         %{"total_bytes" => total},
         %{
           "result" => "file",
           "completion" => "completed",
           "native_acknowledged" => true,
           "observed_bytes" => total
         },
         %{file: <<>>, stdout: <<>>, stderr: <<>>},
         nil
       ),
       do: :ok

  defp response(_context, operation, _request, outcome, _output, overlay),
    do: {:error, operation_error(operation, outcome, overlay)}

  defp observation(_context, :delete, %{"state" => "missing"}), do: :ok

  defp observation(_context, operation, %{"state" => "missing"}),
    do: error(:not_found, operation, :not_dispatched)

  defp observation(
         context,
         operation,
         %{
           "state" => state,
           "resources" => resources,
           "pid_identity" => pid
         } = observed
       )
       when state in ["running", "stopped"] do
    expected = context.assignment.creation["resources"]
    identity = %{context.identity | pid_identity: pid}

    if resources == expected and valid_state?(state, pid) and lifecycle_state?(operation, state) and
         configuration_matches?(context, observed),
       do:
         {:ok,
          machine(
            context,
            if(state == "running", do: :running, else: :stopped),
            resources,
            identity
          )},
       else: error(:identity_conflict, operation, :dispatch_uncertain)
  end

  defp observation(_context, operation, %{"state" => "identity_unknown"}),
    do: error(:identity_conflict, operation, :dispatch_uncertain)

  defp observation(_context, operation, _observation),
    do: error(:unknown, operation, :dispatch_uncertain)

  defp valid_state?("running", pid), do: pid != nil
  defp valid_state?("stopped", pid), do: pid == nil
  defp lifecycle_state?(:start, state), do: state == "running"
  defp lifecycle_state?(:stop, state), do: state == "stopped"
  defp lifecycle_state?(:delete, _state), do: false
  defp lifecycle_state?(:inspect_machine, _state), do: true

  defp machine(context, state, resources, identity),
    do: %Machine{
      name: context.name,
      state: state,
      created_at: nil,
      cpus: resources["cpus"],
      memory_mb: resources["memory_mib"],
      storage_gb: resources["storage_gib"],
      overlay_gb: resources["overlay_gib"],
      network: context.spec.profile.network,
      ports: CreationFeatures.ports(context.assignment.creation),
      backend_identity: identity
    }

  defp command(operation, %{"observed_exit" => exit} = outcome, output, overlay)
       when is_integer(exit) do
    result = %Result{
      exit_code: exit,
      stdout: output.stdout,
      stderr: output.stderr,
      encoding: :bytes,
      truncated: overlay != nil or outcome["completion"] != "exited"
    }

    if outcome["completion"] == "exited" and overlay == nil and output.file == <<>>,
      do: {:ok, result},
      else: {:error, operation_error(operation, outcome, overlay), result}
  end

  defp command(operation, outcome, _output, overlay),
    do: {:error, operation_error(operation, outcome, overlay)}

  defp configuration_matches?(context, observed) do
    actual =
      case observed["configuration"] do
        nil -> {:ok, :offline, []}
        value -> CreationFeatures.observed(value)
      end

    actual ==
      {:ok, context.spec.profile.network, CreationFeatures.ports(context.assignment.creation)}
  end

  defp operation_error(operation, outcome, overlay) do
    category = if overlay, do: overlay.category, else: category(outcome)
    exit = outcome["observed_exit"]

    evidence =
      cond do
        is_integer(exit) -> :exited
        outcome["dispatch"] == "not_dispatched" -> :not_dispatched
        outcome["running_observed"] == true -> :running_observed
        true -> :dispatch_uncertain
      end

    %Error{
      category: category,
      operation: error_operation(operation),
      exit_code: exit,
      evidence: evidence
    }
  end

  defp category(%{"code" => code}), do: code_category(code)
  defp category(%{"completion" => "deadline"}), do: :expired
  defp category(%{"completion" => "output_limit"}), do: :output_limit

  defp category(%{"completion" => completion})
       when completion in ~w(cancelled consumer_lost native_error unknown), do: :unknown

  defp category(_outcome), do: :protocol
  defp code_category("validation"), do: :validation
  defp code_category("not_found"), do: :not_found
  defp code_category(code) when code in ~w(unsupported package), do: :unsupported_capability
  defp code_category(code) when code in ~w(conflict ownership), do: :identity_conflict
  defp code_category("database"), do: :store
  defp code_category("overload"), do: :admission_exhausted
  defp code_category("output_limit"), do: :output_limit
  defp code_category("port_conflict"), do: :port_conflict
  defp code_category("deadline"), do: :expired
  defp code_category(_code), do: :unknown

  defp error(category, operation, evidence),
    do:
      {:error,
       %Error{category: category, operation: error_operation(operation), evidence: evidence}}

  # Persist the established public error vocabulary, shared with the HTTP adapter.
  defp error_operation(:inspect_machine), do: :inspect
  defp error_operation(:inspect_creation), do: :inspect
  defp error_operation(operation), do: operation

  @counter_fields ~w(cpu_seconds cpu_millis rss_mb pss_mb private_memory_mb shared_memory_mapped_mb disk_used_mb egress_bytes)a
  defp counter_field(key), do: Enum.find(@counter_fields, &(Atom.to_string(&1) == key))
end
