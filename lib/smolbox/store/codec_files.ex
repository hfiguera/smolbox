defmodule SmolBox.Store.CodecFiles do
  @moduledoc false
  alias SmolBox.{Command, Error, Files, Profile, Validation}

  def upgrade(%{spec: %{profile: %Profile{} = profile} = spec} = record) do
    with false <- Map.has_key?(profile, :guest_paths),
         true <- Validation.integer?(profile.max_file_bytes, 1, 1_048_576),
         true <- Validation.integer?(profile.max_total_file_bytes, 1, 16_777_216),
         true <- old_workdir?(spec) do
      {:ok, %{record | spec: %{spec | profile: Map.put(profile, :guest_paths, nil)}}}
    else
      _invalid -> invalid()
    end
  end

  def upgrade(_record), do: invalid()

  def strip(%{spec: %{profile: %{guest_paths: nil} = profile} = spec} = record),
    do: %{record | spec: %{spec | profile: Map.delete(profile, :guest_paths)}}

  def strip(record), do: record

  defp old_workdir?(%{command: %Command{workdir: dir}}), do: Files.validate_path(dir) == :ok
  defp old_workdir?(_spec), do: true
  defp invalid, do: {:error, %Error{category: :store, operation: :codec}}
end
