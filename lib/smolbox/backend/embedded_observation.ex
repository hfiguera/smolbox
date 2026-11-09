defmodule SmolBox.Backend.EmbeddedObservation do
  @moduledoc false
  alias SmolBox.Backend.Budget
  alias SmolBox.Embedded.{Call, Config}
  alias SmolBox.{Error, Health, Machine, Validation, WorkerCapacity}

  def run(context, operation, budget) do
    with {:ok, budget} <-
           Budget.constrain(budget,
             timeout_ms: if(operation == :readiness, do: 2000, else: 30_000),
             max_request_bytes: 4096,
             max_response_bytes: if(operation == :list, do: 8_388_608, else: 131_072)
           ),
         {:ok, result, output, nil} <-
           Call.run(context, %{"operation" => Atom.to_string(operation)}, budget) do
      decode(context, operation, result, output)
    else
      {:ok, _result, _output, %Error{} = error} -> {:error, %{error | operation: operation}}
      {:error, %Error{} = error} -> {:error, %{error | operation: operation}}
      _invalid -> invalid(operation)
    end
  end

  defp decode(context, :health, %{"result" => "health", "snapshot" => snapshot}, empty)
       when empty == %{stdout: <<>>, stderr: <<>>, file: <<>>},
       do:
         Health.from_wire(%{
           "status" => "ok",
           "version" => Config.sdk_version(context.config),
           "machines" => Map.take(snapshot, ~w(total running)),
           "uptime_seconds" => snapshot["uptime_seconds"]
         })

  defp decode(_context, :capacity, %{"result" => "capacity", "snapshot" => snapshot}, empty)
       when empty == %{stdout: <<>>, stderr: <<>>, file: <<>>},
       do:
         snapshot
         |> Map.delete("used_cpu_millis")
         |> Map.put("used_cpus", snapshot["used_cpu_millis"] / 1000)
         |> WorkerCapacity.from_wire()

  defp decode(_context, :readiness, %{"result" => "ready"}, empty)
       when empty == %{stdout: <<>>, stderr: <<>>, file: <<>>}, do: :ok

  defp decode(_context, :metrics, %{"result" => "metrics", "text" => text}, empty)
       when empty == %{stdout: <<>>, stderr: <<>>, file: <<>>}, do: {:ok, text}

  defp decode(_context, :list, %{"result" => "inventory", "bytes" => size, "count" => count}, %{
         file: bytes,
         stdout: <<>>,
         stderr: <<>>
       })
       when byte_size(bytes) == size do
    with {:ok, values} <- Jason.decode(bytes),
         true <- Validation.list?(values, 1024),
         true <- length(values) == count do
      Machine.list_from_embedded_inventory(values)
    else
      _invalid -> invalid(:list)
    end
  end

  defp decode(
         _context,
         operation,
         %{"result" => "error", "code" => code, "dispatch" => dispatch},
         _output
       ),
       do:
         {:error,
          %Error{
            category: category(code),
            operation: operation,
            evidence:
              if(dispatch == "not_dispatched", do: :not_dispatched, else: :dispatch_uncertain)
          }}

  defp decode(_context, operation, _result, _output), do: invalid(operation)

  defp invalid(operation),
    do: {:error, %Error{category: :protocol, operation: operation, evidence: :dispatch_uncertain}}

  defp category("output_limit"), do: :output_limit
  defp category("database"), do: :store
  defp category("unsupported"), do: :unsupported_capability
  defp category("overload"), do: :admission_exhausted
  defp category("deadline"), do: :expired
  defp category(code) when code in ~w(ownership conflict), do: :identity_conflict
  defp category(_code), do: :unknown
end
