defmodule SmolBox.CheckpointPolicy do
  @moduledoc """
  Host approval for idle, offline capture on smolvm 1.19.0.

  `root` is a private existing directory on the controller host, shared at the
  same path by controllers using the store. The host protects it from replacement
  and symlink races. `max_bytes` bounds streamed bytes, not worker staging.
  Additional resources cover capture staging and retained output; they are
  accounting declarations, not enforced host quotas. No worker cache is requested.
  """
  alias SmolBox.{Error, Validation}
  @enforce_keys [:id, :root, :max_bytes, :resources]
  @derive {Inspect, only: [:id, :max_bytes]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          root: String.t(),
          max_bytes: pos_integer(),
          resources: SmolBox.Store.resources()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(options, @enforce_keys) and
         Enum.all?(@enforce_keys, &Keyword.has_key?(options, &1)) do
      policy = struct!(__MODULE__, options)
      with :ok <- validate(policy), do: {:ok, policy}
    else
      invalid()
    end
  end

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    if Validation.struct_shape?(policy, __MODULE__) and Validation.identifier?(policy.id) and
         path?(policy.root) and Validation.integer?(policy.max_bytes, 1, 68_719_476_736) and
         resources?(policy.resources), do: :ok, else: invalid()
  end

  def validate(_policy), do: invalid()

  @doc false
  def path?(path),
    do:
      is_binary(path) and byte_size(path) <= 4096 and String.valid?(path) and
        Path.type(path) == :absolute and Path.expand(path) == path and
        not String.contains?(path, <<0>>)

  defp resources?(resources),
    do:
      is_map(resources) and
        Enum.sort(Map.keys(resources)) == [:cpus, :disk_gb, :memory_mb, :slots] and
        Enum.all?(resources, fn {_key, value} -> Validation.integer?(value, 1, 1_048_576) end)

  defp invalid, do: {:error, %Error{category: :validation, operation: :checkpoint}}
end
