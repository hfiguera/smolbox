defmodule SmolBox.ExportResult do
  @moduledoc """
  Verified published artifact identity, without captured workload metadata.

  Manifest, config and content digests name different registry objects. Reuse is
  pinned to the per-platform manifest and artifact blob, never a mutable tag.
  Verification trusts the approved registry and worker's protected artifact cache.
  It does not certify guest contents, portability, or application consistency.
  """
  alias SmolBox.{Error, Source, Validation}

  @enforce_keys [
    :reference,
    :manifest_sha256,
    :config_sha256,
    :content_sha256,
    :size_bytes,
    :architecture,
    :platform,
    :verified_at_ms
  ]
  # Preserve legacy receipt construction; new exports supply the actual worker version.
  defstruct @enforce_keys ++ [runtime_version: "1.19.0"]

  @type t :: %__MODULE__{
          reference: String.t(),
          manifest_sha256: String.t(),
          config_sha256: String.t(),
          content_sha256: String.t(),
          size_bytes: pos_integer(),
          architecture: String.t(),
          platform: String.t(),
          verified_at_ms: non_neg_integer(),
          runtime_version: String.t()
        }

  @doc "Build a pinned source for explicit host approval in a worker's source catalog."
  @spec source(t(), keyword()) :: {:ok, Source.t()} | {:error, Error.t()}
  def source(result, options) do
    with :ok <- validate(result),
         true <- Validation.keys?(options, [:id, :credential_ref]) do
      Source.registry(
        options ++
          [
            reference: result.reference,
            content_sha256: result.content_sha256,
            architecture: result.architecture
          ]
      )
    else
      _invalid -> invalid()
    end
  end

  @doc false
  def validate(%__MODULE__{} = result) do
    with true <- Validation.struct_shape?(result, __MODULE__),
         true <-
           Enum.all?(
             [result.manifest_sha256, result.config_sha256, result.content_sha256],
             &Validation.digest?/1
           ),
         true <- Validation.integer?(result.size_bytes, 1, 9_223_372_036_854_775_807),
         true <- Validation.timestamp?(result.verified_at_ms),
         true <- result.runtime_version in ["1.19.0", "1.20.2", "1.22.0"],
         true <-
           {result.architecture, result.platform} in [
             {"x86_64", "linux/amd64"},
             {"aarch64", "linux/arm64"}
           ],
         {:ok, source} <-
           Source.registry(
             id: "export-result",
             reference: result.reference,
             content_sha256: result.content_sha256,
             architecture: result.architecture
           ),
         true <- source.sha256 == result.manifest_sha256 do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_result), do: invalid()
  defp invalid, do: {:error, %Error{category: :validation, operation: :export}}
end
