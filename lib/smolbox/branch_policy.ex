defmodule SmolBox.BranchPolicy do
  @moduledoc """
  Worker-approved extra capacity for a live branch's preparation and backing state.
  The child's ordinary allocation is charged separately. Extra capacity remains
  after dependency retirement, until source deletion and host-confirmed backing
  cleanup through `SmolBox.Branches.release_storage/3`.
  These are conservative declarations, not host quotas or measured CoW savings.
  """
  alias SmolBox.{Error, Validation}
  @enforce_keys [:id, :resources]
  defstruct @enforce_keys
  @type t :: %__MODULE__{id: String.t(), resources: SmolBox.Store.resources()}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options), do: Validation.construct(__MODULE__, options, @enforce_keys, [])

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    if Validation.struct_shape?(policy, __MODULE__) and Validation.identifier?(policy.id) and
         is_map(policy.resources) and
         Enum.sort(Map.keys(policy.resources)) == [:cpus, :disk_gb, :memory_mb, :slots] and
         Enum.all?(policy.resources, fn {_, v} -> Validation.integer?(v, 1, 1_048_576) end),
       do: :ok,
       else: invalid()
  end

  def validate(_), do: invalid()
  defp invalid, do: {:error, %Error{category: :validation, operation: :branch}}
end
