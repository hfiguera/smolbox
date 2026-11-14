defmodule SmolBox.Kubernetes.LabNodeEvidence.Projection do
  @moduledoc false
  alias SmolBox.Kubernetes.{CleanupProof, Observation, Shape}

  def observation(value) do
    with {:ok, fields} <-
           fields(value, Observation.__struct__() |> Map.from_struct() |> Map.keys()),
         {:ok, processes} <-
           list(fields.processes, [
             :sandbox_id,
             :vm_directory,
             :pid,
             :start_ticks,
             :exe_sha256,
             :kvm
           ]),
         {:ok, interfaces} <- list(fields.interfaces, [:sandbox_id, :name, :ifindex]),
         do: {:ok, struct!(Observation, %{fields | processes: processes, interfaces: interfaces})}
  end

  def cleanup(value, receipt) do
    keys = CleanupProof.__struct__() |> Map.from_struct() |> Map.keys() |> List.delete(:receipt)

    with {:ok, fields} <- fields(value, keys),
         {:ok, processes} <-
           list(fields.terminated_processes, [
             :sandbox_id,
             :vm_directory,
             :pid,
             :start_ticks,
             :exe_sha256,
             :kvm
           ]),
         do:
           {:ok,
            struct!(
              CleanupProof,
              Map.merge(fields, %{receipt: receipt, terminated_processes: processes})
            )}
  end

  defp fields(value, keys) do
    if Shape.exact_keys?(value, Enum.map(keys, &Atom.to_string/1)),
      do: {:ok, Map.new(keys, &{&1, Map.fetch!(value, Atom.to_string(&1))})},
      else: :error
  end

  defp list(value, keys) do
    if SmolBox.Validation.list?(value, 16),
      do: traverse(value, keys, []),
      else: :error
  end

  defp traverse([], _, result), do: {:ok, Enum.reverse(result)}

  defp traverse([value | rest], keys, result) do
    with {:ok, item} <- fields(value, keys), do: traverse(rest, keys, [item | result])
  end
end
