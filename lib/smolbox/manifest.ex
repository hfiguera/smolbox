defmodule SmolBox.Manifest do
  @moduledoc """
  Exact input/output file declarations using opaque host artifact-store references.

  Inputs use string keys `source`, `path`, `size`, `sha256`, and `mode`. The only
  supported mode is `runtime_default`; the pinned HTTP API cannot set permissions.
  Outputs use `destination`, `path`, and `max_bytes`. References are identifiers,
  never URLs or host paths. Each direction allows at most 32 unique paths and
  references. Collection takes a byte snapshot of each file; a multi-file atomic
  snapshot is not promised. Neither archives nor recursive globs are interpreted.
  """

  alias SmolBox.{Error, Files, Profile, Validation}

  @type input :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }
  @type output :: %{required(String.t()) => String.t() | pos_integer()}

  @spec validate(term(), term(), Profile.t()) :: :ok | {:error, Error.t()}
  def validate(inputs, outputs, %Profile{} = profile) do
    if entries?(inputs, &input?(&1, profile.max_file_bytes), "source") and
         entries?(outputs, &output?(&1, profile.max_file_bytes), "destination") and
         total(inputs, "size") <= profile.max_total_file_bytes and
         total(outputs, "max_bytes") <= profile.max_total_file_bytes do
      :ok
    else
      {:error, %Error{category: :validation, operation: :manifest}}
    end
  end

  defp entries?(entries, validator, reference_key) do
    Validation.list?(entries, 32) and Enum.all?(entries, validator) and
      unique?(entries, "path") and unique?(entries, reference_key)
  end

  defp unique?(entries, key), do: length(entries) == MapSet.size(MapSet.new(entries, & &1[key]))
  defp total(entries, key), do: Enum.reduce(entries, 0, &(&1[key] + &2))

  defp input?(
         %{
           "source" => source,
           "path" => path,
           "size" => size,
           "sha256" => digest,
           "mode" => "runtime_default"
         } = entry,
         max
       ) do
    map_size(entry) == 5 and Validation.identifier?(source) and file_path?(path) and
      Validation.integer?(size, 0, max) and Validation.digest?(digest)
  end

  defp input?(_entry, _max), do: false

  defp output?(
         %{"destination" => destination, "path" => path, "max_bytes" => max_bytes} = entry,
         max
       ) do
    map_size(entry) == 3 and Validation.identifier?(destination) and file_path?(path) and
      Validation.integer?(max_bytes, 1, max)
  end

  defp output?(_entry, _max), do: false
  defp file_path?(path), do: path != "/workspace" and Files.validate_path(path) == :ok
end
