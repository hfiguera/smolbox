defmodule SmolBox.Mount do
  @moduledoc """
  An explicit host directory mount. Low-level callers authorize the source path.
  Managed machines accept volume references instead, never caller-supplied host paths.
  Staged mounts are unsupported. Targets must be below `/mnt/volumes`; system paths
  and overlapping targets are rejected. A mount does not imply a filesystem quota.
  """
  alias SmolBox.{Error, Validation}
  @enforce_keys [:source, :target]
  defstruct @enforce_keys ++ [readonly: false]
  @type t :: %__MODULE__{source: String.t(), target: String.t(), readonly: boolean()}

  @spec new(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(source, target, options \\ []) do
    with true <- Validation.keys?(options, [:readonly]),
         mount = struct!(__MODULE__, [source: source, target: target] ++ options),
         true <- valid?(mount),
         do: {:ok, mount},
         else: (_ -> invalid())
  end

  @doc false
  def path?(path),
    do:
      is_binary(path) and byte_size(path) in 2..4096 and String.valid?(path) and
        String.starts_with?(path, "/") and not String.contains?(path, ["\0", "\\", "//"]) and
        not String.ends_with?(path, "/") and
        Enum.all?(String.split(path, "/", trim: true), &(&1 not in [".", ".."]))

  @doc false
  def target?(path), do: path?(path) and String.starts_with?(path, "/mnt/volumes/")
  @doc false
  def valid?(%__MODULE__{} = m),
    do:
      Validation.struct_shape?(m, __MODULE__) and path?(m.source) and target?(m.target) and
        is_boolean(m.readonly)

  def valid?(_), do: false
  @doc false
  def canonical?(mounts),
    do:
      Validation.list?(mounts, 8) and Enum.all?(mounts, &valid?/1) and targets?(mounts) and
        mounts == Enum.sort_by(mounts, & &1.target)

  @doc false
  def targets?(mounts),
    do:
      Enum.all?(mounts, fn m ->
        Enum.count(mounts, fn n ->
          m.target == n.target or String.starts_with?(n.target, m.target <> "/")
        end) == 1
      end)

  @doc false
  def to_wire(mounts),
    do:
      Enum.map(
        mounts,
        &%{
          "source" => &1.source,
          "target" => &1.target,
          "readonly" => &1.readonly,
          "staged" => false
        }
      )

  @doc false
  def from_wire(mounts) do
    if Validation.list?(mounts, 8), do: decode(mounts), else: invalid()
  end

  defp decode(mounts) do
    result =
      Enum.map(mounts, fn
        %{"source" => s, "target" => t, "readonly" => r, "staged" => false} ->
          %__MODULE__{source: s, target: t, readonly: r}

        _ ->
          nil
      end)

    if Enum.all?(result, &valid?/1) and targets?(result),
      do: {:ok, Enum.sort_by(result, & &1.target)},
      else: invalid()
  end

  defp invalid, do: {:error, %Error{category: :validation, operation: :mount}}
end
