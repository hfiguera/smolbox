defmodule SmolBox.FileAccess do
  @moduledoc false
  alias SmolBox.{Error, GuestPaths, Validation}

  def extended?(%{guest_paths: paths, max_file_bytes: file, max_total_file_bytes: total}),
    do: paths != nil or file > 1_048_576 or total > 16_777_216

  def extended?(_invalid), do: false

  def client_valid?(%{guest_paths: _, max_file_bytes: _} = client),
    do:
      GuestPaths.valid?(client.guest_paths) and
        Validation.integer?(client.max_file_bytes, 1, 16_777_216)

  def client_valid?(_invalid), do: false

  def authorize(client, direction, path) do
    if client_valid?(client) and GuestPaths.allowed?(client.guest_paths, direction, path),
      do: :ok,
      else: {:error, %Error{category: :validation, operation: :guest_path}}
  end

  def supports?(client, profile) do
    client_valid?(client) and GuestPaths.subset?(profile.guest_paths, client.guest_paths) and
      profile.max_file_bytes <= client.max_file_bytes and transfer_budget?(client, profile)
  end

  defp transfer_budget?(client, profile) do
    not extended?(profile) or
      (profile.max_file_bytes <= client.worker.max_request_bytes and
         profile.max_file_bytes <= client.worker.max_response_bytes)
  end
end
