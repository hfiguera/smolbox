defmodule SmolBox.ExportReceipt do
  @moduledoc """
  Worker acknowledgement of publication, before independent registry verification.

  The manifest digest identifies a per-platform OCI manifest, not the artifact
  blob or the tag's index. The returned pack metadata may contain environment
  values; it is discarded rather than retained in this receipt.
  """
  alias SmolBox.{Error, Validation}
  @enforce_keys [:manifest_sha256, :size_bytes, :platform]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          manifest_sha256: String.t(),
          size_bytes: pos_integer(),
          platform: String.t()
        }

  @doc false
  def from_wire(%{"digest" => "sha256:" <> digest, "sizeBytes" => size, "platform" => platform}) do
    receipt = %__MODULE__{manifest_sha256: digest, size_bytes: size, platform: platform}
    with :ok <- validate(receipt), do: {:ok, receipt}
  end

  def from_wire(_body), do: invalid()

  @doc false
  def validate(%__MODULE__{} = receipt) do
    if Validation.struct_shape?(receipt, __MODULE__) and
         Validation.digest?(receipt.manifest_sha256) and
         Validation.integer?(receipt.size_bytes, 1, 9_223_372_036_854_775_807) and
         receipt.platform in ["linux/amd64", "linux/arm64"],
       do: :ok,
       else: invalid()
  end

  def validate(_receipt), do: invalid()
  defp invalid, do: {:error, %Error{category: :protocol, operation: :export, evidence: :unknown}}
end
