defmodule SmolBox.Files do
  @moduledoc """
  Guest workspace paths and byte digests.

  File operations are confined lexically to `/workspace`. This validation does
  not resolve guest symlinks; the file transport and host artifact store must
  enforce their own filesystem boundary. Percent signs, backslashes, traversal,
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
  def encode_path(path) do
    with :ok <- validate_path(path) do
      encoded =
        path
        |> String.trim_leading("/")
        |> String.split("/")
        |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))

      {:ok, encoded}
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
