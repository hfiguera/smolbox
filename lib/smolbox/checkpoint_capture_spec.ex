defmodule SmolBox.CheckpointCaptureSpec do
  @moduledoc """
  Explicit capture identity and approval. `idle: true` is the host's assertion
  that preparation has finished and no user processes, secrets or connections
  will be resumed. A free command slot alone does not prove this, particularly
  after background execution. Capture briefly pauses and resumes the source.
  """
  alias SmolBox.{CheckpointPolicy, Error, Validation}
  @enforce_keys [:id, :policy, :idle]
  @derive {Inspect, only: [:id]}
  defstruct @enforce_keys ++ [timeout_ms: 900_000]

  @type t :: %__MODULE__{
          id: String.t(),
          policy: CheckpointPolicy.t(),
          idle: true,
          timeout_ms: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options), do: Validation.construct(__MODULE__, options, @enforce_keys, [:timeout_ms])

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    if Validation.struct_shape?(spec, __MODULE__) and Validation.identifier?(spec.id) and
         spec.idle == true and
         CheckpointPolicy.validate(spec.policy) == :ok and
         Validation.integer?(spec.timeout_ms, 1000, 86_400_000), do: :ok, else: invalid()
  end

  def validate(_spec), do: invalid()

  @doc false
  def fingerprint(spec, machine, key),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        :erlang.term_to_binary({"smolbox-checkpoint-capture-v1", machine, spec})
      )
      |> Base.encode16(case: :lower)

  defp invalid, do: {:error, %Error{category: :validation, operation: :checkpoint}}
end
