defmodule SmolBox.ImagePull do
  @moduledoc """
  Immutable machine-local OCI pull intent for a retained, running machine.

  Use as the `:command` of an `SmolBox.ExecutionSpec`, submitted through
  `SmolBox.Machines.submit/3`, or use `SmolBox.Machines.pull_image/5`.
  The machine must originate from OCI, and the source must be an exact worker
  approval with an explicit network profile. Prepared artifacts and checkpoints
  cannot support verified managed pulls on the qualified upstream release.
  The execution profile bounds observation time; it does not cancel a request
  already sent to the worker. No authentication overrides are supported by this
  endpoint. Success returns a `SmolBox.Image` observation, not a process exit.
  """
  alias SmolBox.{Error, Source, Validation}
  @enforce_keys [:source]
  @derive {Inspect, only: []}
  defstruct @enforce_keys
  @type t :: %__MODULE__{source: Source.t()}

  @spec new(Source.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(source) do
    pull = %__MODULE__{source: source}
    with :ok <- validate(pull), do: {:ok, pull}
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{source: %Source{kind: :oci} = source} = pull) do
    if Validation.struct_shape?(pull, __MODULE__) and Source.validate(source) == :ok,
      do: :ok,
      else: invalid()
  end

  def validate(_pull), do: invalid()
  defp invalid, do: {:error, %Error{category: :validation, operation: :pull_image}}
end
