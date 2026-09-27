defmodule SmolBox.BranchSpec do
  @moduledoc """
  Immutable request for one child in its source's scope and on its source's worker.
  `id` is the new managed machine ID, never a worker name. `idle: true` attests that
  captured work is safe to duplicate. `hold: true` additionally requires the host
  to prepare the upstream guest branchpoint; it does not pause an arbitrary shell.
  No nested branches, frozen sources, injected environment, ports or secrets.
  """
  alias SmolBox.{BranchPolicy, Error, Validation}
  @enforce_keys [:id, :policy, :idle]
  defstruct @enforce_keys ++ [hold: false, timeout_ms: 120_000]

  @type t :: %__MODULE__{
          id: String.t(),
          policy: BranchPolicy.t(),
          idle: true,
          hold: boolean(),
          timeout_ms: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options),
    do: Validation.construct(__MODULE__, options, @enforce_keys, [:hold, :timeout_ms])

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    with true <- Validation.struct_shape?(spec, __MODULE__) and Validation.identifier?(spec.id),
         true <- spec.idle == true and is_boolean(spec.hold),
         true <- Validation.integer?(spec.timeout_ms, 1000, 86_400_000),
         :ok <- BranchPolicy.validate(spec.policy),
         do: :ok,
         else: (_ -> invalid())
  end

  def validate(_), do: invalid()
  @doc false
  def fingerprint(spec, source, key),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        :erlang.term_to_binary({"smolbox-branch-v1", source, spec})
      )
      |> Base.encode16(case: :lower)

  defp invalid, do: {:error, %Error{category: :validation, operation: :branch}}
end
