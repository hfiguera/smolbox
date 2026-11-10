defmodule SmolBox.Backend.EmbeddedReply do
  @moduledoc false
  alias SmolBox.Backend.EmbeddedContext

  alias SmolBox.Embedded.{
    CreationFeatures,
    GrowthTransition,
    Identity,
    ImageContract,
    LogStream,
    MountContract,
    Protocol
  }

  alias SmolBox.{
    Error,
    Image,
    ImageInventory,
    LaunchResult,
    LogResult,
    Machine,
    MachineMeasurements,
    Mount,
    Result
  }

  def decode(context, operation, request, {:ok, outcome, output, overlay}),
    do: response(context, operation, request, outcome, output, overlay)

  def decode(_context, operation, _request, {:error, %Error{} = error}),
    do: {:error, %{error | operation: error_operation(operation)}}

  defp response(
         context,
         :terminal_preflight,
         %{"operation" => "terminal_preflight", "receipt" => receipt},
         %{"result" => "ready"} = outcome,
         %{stdout: <<>>, stderr: <<>>, file: <<>>},
         nil
       ) do
    with {:ok, ^receipt} <- EmbeddedContext.receipt(context),
         true <- Protocol.valid_outcome?(outcome, 2),
         do: :ok,
         else: (_ -> error(:protocol, :terminal, :not_dispatched))
  end

  defp response(
         context,
         :branch_source,
         %{"operation" => "branch_preflight", "receipt" => receipt},
         %{"result" => "observed", "observation" => observed} = outcome,
         %{stdout: <<>>, stderr: <<>>, file: <<>>},
         nil
       ) do
    with true <- Protocol.valid_outcome?(outcome, 2),
         {:ok, ^receipt} <- EmbeddedContext.receipt(context),
         %{"configuration" => %{"ports" => []} = config} <- observed,
         true <- Map.get(config, "mounts") == nil,
         do: observation(context, :branch_source, observed),
         else: (_ -> error(:identity_conflict, :branch_source, :dispatch_uncertain))
  end

  defp response(
         %{identity: nil},
         :inspect_creation,
         %{"operation" => name},
         %{"result" => "creation_presence", "presence" => presence},
         %{stdout: <<>>, stderr: <<>>, file: <<>>},
         nil
       )
       when name in ~w(inspect_creation inspect_oci_creation inspect_registry_creation inspect_checkpoint_creation) do
    case presence do
      "absent" -> {:ok, :absent}
      "unverified" -> error(:identity_conflict, :inspect, :dispatch_uncertain)
    end
  end

  defp response(
         context,
         operation,
         _request,
         %{"result" => "created", "receipt" => receipt},
         _output,
         nil
       )
       when operation in [:create, :create_prepared] do
    identity = %Identity{receipt: receipt}

    if Identity.matches?(identity, context.assignment),
      do: {:ok, machine(context, :created, context.assignment.creation["resources"], identity)},
      else: error(:identity_conflict, :create, :dispatch_uncertain)
  end

  defp response(
         context,
         operation,
         request,
         %{"result" => kind, "transition" => wire, "observation" => observed},
         %{stdout: <<>>, stderr: <<>>, file: <<>>},
         nil
       )
       when operation in [:expand_disks, :qualify_growth] and kind in ~w(grown growth_qualified) do
    with true <- growth_kind?(operation, kind, request, context.growth),
         {:ok, proof} <- GrowthTransition.from_wire(wire),
         true <-
           GrowthTransition.bound?(
             proof,
             context.growth.receipt,
             context.growth.id,
             context.growth.request,
             context.growth.previous,
             context.growth.targets
           ),
         true <-
           request["receipt"] == context.growth.receipt and
             request["operation_id"] == context.growth.id and
             request["request"] == context.growth.request and
             request["previous"] == context.growth.previous do
      updated = %{context | identity: %Identity{receipt: proof.receipt, transition: proof}}
      observation(updated, :inspect_machine, observed)
    else
      _ -> error(:identity_conflict, operation, :dispatch_uncertain)
    end
  end

  defp response(
         context,
         operation,
         _request,
         %{"result" => "observed", "observation" => observation},
         _output,
         nil
       )
       when operation in [
              :inspect_machine,
              :start,
              :stop,
              :delete,
              :start_checkpointable,
              :checkpoint_preflight
            ],
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
         context,
         :pull_image,
         %{"operation" => "pull_image", "receipt" => receipt, "source" => source},
         %{"result" => "pulled", "image" => image} = outcome,
         %{stdout: <<>>, stderr: <<>>, file: <<>>},
         nil
       ) do
    with {:ok, ^receipt} <- EmbeddedContext.receipt(context),
         %{command: %SmolBox.ImagePull{source: expected}} <- context.spec,
         true <- source == ImageContract.source(expected),
         true <- Protocol.valid_outcome?(outcome, 2) and ImageContract.matches?(image, source),
         do: Image.from_wire(image),
         else: (_ -> error(:protocol, :pull_image, :dispatch_uncertain))
  end

  defp response(
         context,
         :list_images,
         %{"operation" => "list_images", "receipt" => receipt},
         %{"result" => "images", "count" => count, "bytes" => length} = outcome,
         %{stdout: <<>>, stderr: <<>>, file: bytes},
         nil
       ) do
    with {:ok, ^receipt} <- EmbeddedContext.receipt(context),
         true <- Protocol.valid_outcome?(outcome, 2) and byte_size(bytes) == length,
         {:ok, images} when is_list(images) <- Jason.decode(bytes),
         true <- length(images) == count,
         do: ImageInventory.from_wire(%{"images" => images}),
         else: (_ -> error(:protocol, :images, :dispatch_uncertain))
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

  defp growth_kind?(:expand_disks, "grown", %{"operation" => "expand_disks"}, %{
         state: :dispatching
       }),
       do: true

  defp growth_kind?(
         :qualify_growth,
         "growth_qualified",
         %{"operation" => "qualify_growth", "quiesced" => true},
         %{state: :unknown}
       ),
       do: true

  defp growth_kind?(_operation, _kind, _request, _growth), do: false

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
    expected = EmbeddedContext.resources(context)
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

  defp lifecycle_state?(operation, state)
       when operation in [:start_checkpointable, :checkpoint_preflight, :branch_source],
       do: state == "running"

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
      mounts: MountContract.paths(context.assignment.creation),
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
      {:ok, context.spec.profile.network, CreationFeatures.ports(context.assignment.creation)} and
      mounts_observed?(context, observed)
  end

  defp mounts_observed?(context, observed) do
    expected = MountContract.paths(context.assignment.creation)

    case get_in(observed, ["configuration", "mounts"]) do
      nil ->
        expected == []

      value ->
        case Mount.from_wire(value) do
          {:ok, mounts} -> mounts == expected
          _invalid -> false
        end
    end
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
  defp error_operation(:terminal_preflight), do: :terminal
  defp error_operation(:create_prepared), do: :create
  defp error_operation(:inspect_creation), do: :inspect
  defp error_operation(:list_images), do: :images
  defp error_operation(:qualify_growth), do: :expand_disks
  defp error_operation(:cleanup_capture), do: :checkpoint

  defp error_operation(operation)
       when operation in [
              :export_machine,
              :qualify_export,
              :admit_export,
              :inspect_export,
              :cleanup_export
            ],
       do: :export

  defp error_operation(operation), do: operation

  @counter_fields ~w(cpu_seconds cpu_millis rss_mb pss_mb private_memory_mb shared_memory_mapped_mb disk_used_mb egress_bytes)a
  defp counter_field(key), do: Enum.find(@counter_fields, &(Atom.to_string(&1) == key))
end
