defmodule SmolBox.ManagedMachineSpec do
  @moduledoc """
  Immutable creation intent for a machine retained until explicit deletion.

  Scope and ID are host-authorized identities, not access tokens. Artifact and
  profile approvals have the same meaning as in `SmolBox.ExecutionSpec`.
  """
  alias SmolBox.{Command, Error, ExecutionSpec, Validation}

  @enforce_keys [:scope, :id, :artifact, :profile]
  @derive {Inspect, only: [:scope, :id]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          scope: String.t(),
          id: String.t(),
          artifact: map(),
          profile: SmolBox.Profile.t()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(options, @enforce_keys) and
         Enum.all?(@enforce_keys, &Keyword.has_key?(options, &1)) do
      spec = struct!(__MODULE__, options)
      with :ok <- validate(spec), do: {:ok, spec}
    else
      invalid()
    end
  end

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    with true <- Validation.struct_shape?(spec, __MODULE__),
         {:ok, _spec} <- execution_spec(spec) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_spec), do: invalid()

  @doc false
  def execution_spec(spec) do
    {:ok, command} = Command.new(["/bin/true"], timeout_secs: 1)
    ExecutionSpec.new(Map.to_list(Map.from_struct(spec)) ++ [command: command])
  end

  @doc false
  def fingerprint(spec, key) do
    with :ok <- validate(spec),
         {:ok, execution} <- execution_spec(spec),
         {:ok, digest} <- ExecutionSpec.fingerprint(execution, key) do
      {:ok,
       :crypto.mac(:hmac, :sha256, key, "smolbox-managed-machine-v1:" <> digest)
       |> Base.encode16(case: :lower)}
    end
  end

  defp invalid, do: {:error, %Error{category: :validation, operation: :machine_spec}}
end
