defmodule SmolBox.Checkpoint do
  @moduledoc """
  Operator approval for an idle, offline checkpoint on one worker platform.

  Preparing and inspecting the checkpoint is an operator responsibility. Approval
  asserts that its digest is immutable, its captured allocations match `profile`,
  and it contains no workload waiting to resume, credentials, external connections,
  mounts, ports, device forwarding or automatic workload restart. Restoring RAM
  resumes processes; setting an entrypoint cannot neutralize captured work.

  smolvm 1.16.1, 1.17.0 and 1.19.0 are admitted; the default is 1.19.0.
  Explicitly pin existing approvals to their original capture runtime. CPU compatibility is additionally
  checked by smolvm. Approval does not make a checkpoint portable across operating
  systems, architectures, CPU models or runtime versions. The file stays on the
  worker and is never uploaded through the Elixir process.
  """
  alias SmolBox.{Error, MachineSpec, Profile, Validation}

  @enforce_keys [:id, :sha256, :architecture, :platform, :path, :profile]
  @derive {Inspect, only: [:id, :architecture, :platform]}
  defstruct @enforce_keys ++ [runtime_version: "1.19.0", resume: :idle]

  @type t :: %__MODULE__{
          id: String.t(),
          sha256: String.t(),
          architecture: String.t(),
          platform: :linux | :macos,
          path: String.t(),
          profile: Profile.t(),
          runtime_version: String.t(),
          resume: :idle
        }

  @doc "Register an operator-verified idle checkpoint and its exact offline execution profile."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(options, @enforce_keys ++ [:runtime_version, :resume]) and
         Enum.all?(@enforce_keys, &Keyword.has_key?(options, &1)) do
      checkpoint = struct!(__MODULE__, options)
      with :ok <- validate(checkpoint), do: {:ok, checkpoint}
    else
      invalid()
    end
  end

  @doc "Validate approval shape; does not read files or attest captured processes or secrets."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = checkpoint) do
    with true <- Validation.struct_shape?(checkpoint, __MODULE__),
         true <- Validation.identifier?(checkpoint.id) and Validation.digest?(checkpoint.sha256),
         true <-
           {checkpoint.platform, checkpoint.architecture} in [
             {:linux, "x86_64"},
             {:macos, "aarch64"}
           ],
         true <-
           checkpoint.runtime_version in ["1.16.1", "1.17.0", "1.19.0"] and
             checkpoint.resume == :idle,
         :ok <- Profile.validate(checkpoint.profile),
         true <- checkpoint.profile.network == :offline,
         {:ok, _spec} <- machine(checkpoint, "approved-checkpoint") do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_checkpoint), do: invalid()

  @doc "Immutable reference used as the `:artifact` in `SmolBox.ExecutionSpec.new/1`."
  @spec artifact(t()) :: map()
  def artifact(checkpoint) do
    %{
      "id" => checkpoint.id,
      "sha256" => checkpoint.sha256,
      "architecture" => checkpoint.architecture,
      "kind" => "checkpoint"
    }
  end

  @doc false
  @spec machine(t(), String.t()) :: {:ok, MachineSpec.t()} | {:error, Error.t()}
  def machine(checkpoint, name) do
    options =
      checkpoint.profile
      |> Map.from_struct()
      |> Map.take([:cpus, :memory_mb, :storage_gb, :overlay_gb])
      |> Map.to_list()

    MachineSpec.new(name, checkpoint.path, [{:source, :checkpoint} | options])
  end

  defp invalid, do: {:error, %Error{category: :validation, operation: :checkpoint}}
end
