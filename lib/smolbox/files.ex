defmodule SmolBox.Files do
  @moduledoc """
  Guest path encoding and byte digests.

  `validate_path/1` retains the legacy lexical `/workspace` contract. Explicit
  directional policies use `SmolBox.GuestPaths` and `encode_path/3`. Neither
  resolves guest symlinks; approved roots are not a filesystem sandbox. Percent signs, backslashes, traversal,
  repeated separators, and non-UTF-8 paths are deliberately unsupported.
  """

  alias SmolBox.Error

  @spec validate_path(term()) :: :ok | {:error, Error.t()}
  def validate_path(path) when is_binary(path) and byte_size(path) <= 1024 do
    parts = String.split(path, "/")

    if String.valid?(path) and workspace?(parts) and
         not String.contains?(path, ["\0", "%", "\\"]) do
      :ok
    else
      invalid()
    end
  end

  def validate_path(_path), do: invalid()

  @doc "Encode a validated guest path for the worker's wildcard file route."
  @spec encode_path(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def encode_path(path), do: encode_path(path, nil, :download)

  @doc "Encode a path after explicit directional policy authorization."
  def encode_path(path, policy, direction) do
    if path != "/" and SmolBox.GuestPaths.allowed?(policy, direction, path) do
      encoded =
        path
        |> String.trim_leading("/")
        |> String.split("/")
        |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))

      {:ok, encoded}
    else
      invalid()
    end
  end

  @doc "Compute a lowercase SHA-256 digest of file bytes."
  @spec sha256(binary()) :: String.t()
  def sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp workspace?(["", "workspace" | rest]) do
    Enum.all?(rest, &(&1 not in ["", ".", ".."]))
  end

  defp workspace?(_parts), do: false
  defp invalid, do: {:error, %Error{category: :validation, operation: :guest_path}}
end
