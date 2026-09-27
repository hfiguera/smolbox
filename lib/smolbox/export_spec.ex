defmodule SmolBox.ExportSpec do
  @moduledoc """
  Immutable export request, identified within a managed machine's scope and ID.

  Supply an exact approved destination and a new tag. The tag and its platform
  variant remain claimed in durable history even after failure or deletion.
  Retrying the same identity and specification returns its original record;
  changing either destination, tag or deadline under that identity conflicts.
  """
  alias SmolBox.{Error, ExportDestination, Validation}
  @enforce_keys [:id, :destination, :tag]
  @derive {Inspect, only: [:id, :tag, :timeout_ms]}
  defstruct @enforce_keys ++ [timeout_ms: 900_000]

  @type t :: %__MODULE__{
          id: String.t(),
          destination: ExportDestination.t(),
          tag: String.t(),
          timeout_ms: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options), do: Validation.construct(__MODULE__, options, @enforce_keys, [:timeout_ms])

  @doc false
  def validate(%__MODULE__{} = spec) do
    with true <- Validation.struct_shape?(spec, __MODULE__),
         true <- Validation.identifier?(spec.id),
         true <-
           Validation.text?(spec.tag, 100) and
             Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/, spec.tag),
         true <- Validation.integer?(spec.timeout_ms, 1000, 86_400_000),
         :ok <- ExportDestination.validate(spec.destination) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_spec), do: invalid()

  @doc false
  def tags(spec, architecture),
    do: [
      spec.tag,
      spec.tag <> "-linux-" <> if(architecture == "x86_64", do: "amd64", else: "arm64")
    ]

  @doc false
  def fingerprint(spec, machine, key) do
    with :ok <- validate(spec),
         true <- is_binary(key) and byte_size(key) >= 32 do
      bytes = :erlang.term_to_binary({"smolbox-export-v1", machine, spec}, [:deterministic])
      {:ok, Base.encode16(:crypto.mac(:hmac, :sha256, key, bytes), case: :lower)}
    else
      _invalid -> invalid()
    end
  end

  defp invalid, do: {:error, %Error{category: :validation, operation: :export}}
end
