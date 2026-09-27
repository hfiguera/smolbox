defmodule SmolBox.ArtifactPreparation do
  @moduledoc """
  Observation of a registry artifact prepared in the worker host's blob cache.

  The manifest and content SHA-256 digests are distinct. This result verifies
  that the warm response names the expected blob, not that an existing cache
  entry was rehashed. Upstream verifies downloaded bytes but trusts cache hits.
  Operators must protect the cache from modification.

  `already_cached` describes the blob lookup, not offline availability: upstream
  still fetches the registry manifest on a warm cache. `size_bytes` describes
  shared host cache storage, outside per-machine disk reservations.
  This observation neither creates a machine nor proves application readiness.
  """
  alias SmolBox.{Error, Source, Validation}

  @enforce_keys [:reference, :manifest_sha256, :content_sha256, :size_bytes, :already_cached]
  @derive {Inspect, only: [:size_bytes, :already_cached]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          reference: String.t(),
          manifest_sha256: String.t(),
          content_sha256: String.t(),
          size_bytes: non_neg_integer(),
          already_cached: boolean()
        }

  @doc false
  @spec from_wire(Source.t(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(%Source{kind: :registry} = source, %{
        "digest" => "sha256:" <> digest,
        "sizeBytes" => size,
        "alreadyCached" => cached
      }) do
    if Source.validate(source) == :ok and digest == source.content_sha256 and
         Validation.integer?(size, 0, 9_223_372_036_854_775_807) and is_boolean(cached) do
      {:ok,
       %__MODULE__{
         reference: source.reference,
         manifest_sha256: source.sha256,
         content_sha256: digest,
         size_bytes: size,
         already_cached: cached
       }}
    else
      invalid()
    end
  end

  def from_wire(_source, _body), do: invalid()

  @doc false
  def matches?(%__MODULE__{} = prepared, artifact) do
    with true <- Validation.struct_shape?(prepared, __MODULE__),
         {:ok, source} <- Source.from_artifact(artifact),
         true <- source.kind == :registry,
         true <-
           prepared.reference == source.reference and prepared.manifest_sha256 == source.sha256,
         {:ok, expected} <-
           from_wire(source, %{
             "digest" => "sha256:" <> source.content_sha256,
             "sizeBytes" => prepared.size_bytes,
             "alreadyCached" => prepared.already_cached
           }) do
      prepared == expected
    else
      _invalid -> false
    end
  end

  def matches?(_prepared, _artifact), do: false

  defp invalid,
    do:
      {:error,
       %Error{category: :protocol, operation: :prepare_artifact, evidence: :dispatch_uncertain}}
end
