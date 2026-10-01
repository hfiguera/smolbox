defmodule SmolBox.Image do
  @moduledoc """
  A machine-local image observation, not a worker-host artifact cache entry.

  smolvm 1.19.0, 1.20.2 or 1.22.0 reports the OCI **configuration** digest in `digest`, not the
  manifest digest supplied for a pull. Imported packed images instead report
  the literal `"packed"` and have no digest evidence. `digest_kind` makes this
  distinction explicit. Neither value attests the machine's mutable files.

  Size and layer count are upstream observations, not reservations or quotas.
  A returned reference is untrusted display data; it is not source approval.
  """
  alias SmolBox.{Error, Validation}

  @enforce_keys [:reference, :digest, :digest_kind, :size_bytes, :architecture, :os, :layer_count]
  @derive {Inspect, only: [:digest_kind, :architecture, :os, :layer_count, :size_bytes]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          reference: String.t(),
          digest: String.t(),
          digest_kind: :configuration | :packed,
          size_bytes: non_neg_integer(),
          architecture: String.t(),
          os: String.t(),
          layer_count: non_neg_integer()
        }

  @doc false
  @spec from_wire(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(%{
        "reference" => reference,
        "digest" => digest,
        "size" => size,
        "architecture" => architecture,
        "os" => os,
        "layerCount" => layers
      }) do
    image = %__MODULE__{
      reference: reference,
      digest: digest,
      digest_kind: digest_kind(digest),
      size_bytes: size,
      architecture: architecture,
      os: os,
      layer_count: layers
    }

    with :ok <- validate(image), do: {:ok, image}
  end

  def from_wire(_body), do: invalid()

  @doc false
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = image) do
    if Validation.struct_shape?(image, __MODULE__) and
         text?(image.reference, 1024) and text?(image.architecture, 64) and text?(image.os, 64) and
         image.digest_kind in [:configuration, :packed] and
         image.digest_kind == digest_kind(image.digest) and
         Validation.integer?(image.size_bytes, 0, 9_223_372_036_854_775_807) and
         Validation.integer?(image.layer_count, 0, 65_536), do: :ok, else: invalid()
  end

  def validate(_image), do: invalid()

  @doc false
  @spec matches?(term(), SmolBox.Source.t()) :: boolean()
  def matches?(%__MODULE__{} = image, %SmolBox.Source{kind: :oci} = source),
    do:
      validate(image) == :ok and image.reference == source.reference and
        image.digest_kind == :configuration and image.os == "linux" and
        image.architecture == String.replace(SmolBox.Source.oci_platform(source), "linux/", "")

  def matches?(_image, _source), do: false

  defp digest_kind("packed"), do: :packed
  defp digest_kind("sha256:" <> digest), do: if(Validation.digest?(digest), do: :configuration)
  defp digest_kind(_digest), do: nil
  defp text?(value, max), do: Validation.text?(value, max) and value != ""

  defp invalid,
    do: {:error, %Error{category: :protocol, operation: :images, evidence: :dispatch_uncertain}}
end
