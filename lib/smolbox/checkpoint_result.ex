defmodule SmolBox.CheckpointResult do
  @moduledoc """
  Captured bytes hashed and synced on the controller host. The digest identifies
  the complete portable checkpoint, not a registry manifest or upstream cache ID.
  It proves received byte identity, not safe guest contents or CPU compatibility.
  """
  alias SmolBox.{Checkpoint, CheckpointPolicy, Error, Profile, Validation}

  @enforce_keys [
    :path,
    :sha256,
    :size_bytes,
    :profile,
    :platform,
    :architecture,
    :runtime_version
  ]
  @derive {Inspect, only: [:sha256, :size_bytes, :platform, :architecture]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: String.t(),
          sha256: String.t(),
          size_bytes: pos_integer(),
          profile: Profile.t(),
          platform: :linux | :macos,
          architecture: String.t(),
          runtime_version: String.t()
        }
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = result) do
    with true <-
           Validation.struct_shape?(result, __MODULE__) and CheckpointPolicy.path?(result.path),
         true <-
           Validation.digest?(result.sha256) and
             Validation.integer?(result.size_bytes, 1, 68_719_476_736),
         true <- result.runtime_version == "1.19.0",
         {:ok, _} <- build_approval(result, id: "validation", worker_path: result.path) do
      :ok
    else
      _invalid -> {:error, %Error{category: :validation, operation: :checkpoint}}
    end
  end

  def validate(_result), do: {:error, %Error{category: :validation, operation: :checkpoint}}

  @doc """
  Construct an explicit idle checkpoint approval after reviewing captured state.
  Copy to `worker_path` and verify the same SHA-256 there before registering it in
  the worker's checkpoint catalog. This function transfers no bytes or authority.
  """
  @spec approval(t(), keyword()) :: {:ok, Checkpoint.t()} | {:error, Error.t()}
  def approval(result, options) do
    with :ok <- validate(result), do: build_approval(result, options)
  end

  defp build_approval(result, options) do
    if Validation.keys?(options, [:id, :worker_path]) do
      Checkpoint.new(
        id: options[:id],
        path: options[:worker_path],
        sha256: result.sha256,
        architecture: result.architecture,
        platform: result.platform,
        profile: result.profile,
        runtime_version: result.runtime_version
      )
    else
      {:error, %Error{category: :validation, operation: :checkpoint}}
    end
  end
end
