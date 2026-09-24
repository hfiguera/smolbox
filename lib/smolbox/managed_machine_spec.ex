defmodule SmolBox.ManagedMachineSpec do
  @moduledoc """
  Immutable creation intent for a machine retained until explicit deletion.

  Scope and ID are host-authorized identities, not access tokens. Artifact and
  profile approvals have the same meaning as in `SmolBox.ExecutionSpec`.
  Optional `ports: [SmolBox.PortMapping.t()]` adds fixed TCP forwarding on image
  sources and smolvm 1.17.0. The constructor canonicalizes mappings; they are part
  of immutable identity, independent of commands and outbound profile policy.
  Changing a mapping requires a new machine identity. See [Port mappings](port-mappings.html).

  Optional `workload: SmolBox.Workload.t()` starts an immutable application on
  image machines with smolvm 1.17.0. Omitting it preserves `/bin/true` startup.
  Changes require a new identity. Values are persisted, including environment;
  the store must protect them. See [Workloads and diagnostics](workloads.html).
  """
  alias SmolBox.{Command, Error, ExecutionSpec, Validation}

  @enforce_keys [:scope, :id, :artifact, :profile]
  @derive {Inspect, only: [:scope, :id]}
  defstruct @enforce_keys ++ [ports: [], workload: nil]

  @type t :: %__MODULE__{
          scope: String.t(),
          id: String.t(),
          artifact: map(),
          profile: SmolBox.Profile.t(),
          ports: [SmolBox.PortMapping.t()],
          workload: SmolBox.Workload.t() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(options, @enforce_keys ++ [:ports, :workload]) and
         Enum.all?(@enforce_keys, &Keyword.has_key?(options, &1)) do
      with {:ok, ports} <- SmolBox.PortMapping.normalize(Keyword.get(options, :ports, [])),
           spec = struct!(__MODULE__, Keyword.put(options, :ports, ports)),
           :ok <- validate(spec),
           do: {:ok, spec}
    else
      invalid()
    end
  end

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    with true <- Validation.struct_shape?(spec, __MODULE__),
         true <- SmolBox.PortMapping.canonical?(spec.ports),
         true <- is_map(spec.artifact),
         true <- SmolBox.Workload.optional?(spec.workload),
         true <- spec.workload == nil or spec.artifact["kind"] != "checkpoint",
         true <- spec.ports == [] or spec.artifact["kind"] != "checkpoint",
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
    options = spec |> Map.from_struct() |> Map.take(@enforce_keys) |> Map.to_list()
    ExecutionSpec.new(options ++ [command: command])
  end

  @doc false
  def fingerprint(spec, key) do
    with :ok <- validate(spec),
         {:ok, execution} <- execution_spec(spec),
         {:ok, digest} <- ExecutionSpec.fingerprint(execution, key) do
      payload =
        if spec.ports == [],
          do: "smolbox-managed-machine-v1:" <> digest,
          else: :erlang.term_to_binary({"smolbox-managed-machine-ports-v1", digest, spec.ports})

      payload =
        if spec.workload == nil,
          do: payload,
          else:
            :erlang.term_to_binary(
              {"smolbox-managed-workload-v1", payload,
               %{spec.workload | env: Enum.sort(spec.workload.env)}}
            )

      {:ok,
       :crypto.mac(:hmac, :sha256, key, payload)
       |> Base.encode16(case: :lower)}
    end
  end

  defp invalid, do: {:error, %Error{category: :validation, operation: :machine_spec}}
end
