defmodule SmolBox.LaunchResult do
  @moduledoc """
  Confirmation that upstream launched a background process, not its exit result.

  `pid` is the upstream guest PID. It is neither a durable process identity nor
  proof of readiness or continued life. PIDs can be reused. The enclosing managed
  execution supplies the machine and launch identity; no automatic replay, status
  lookup or PID-based termination is authorized by this evidence.
  """
  alias SmolBox.{Error, Result, Validation}

  @enforce_keys [:pid]
  defstruct [:pid]
  @type t :: %__MODULE__{pid: pos_integer()}

  @doc "Decode only the qualified background launch acknowledgment."
  @spec from_wire(term(), pos_integer()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(body, max) do
    with {:ok, %Result{exit_code: 0, stdout: stdout, stderr: ""}} <- Result.from_wire(body, max),
         [_, digits] <- Regex.run(~r/\Apid=([1-9][0-9]{0,9})\n\z/, stdout),
         result = %__MODULE__{pid: String.to_integer(digits)},
         true <- valid?(result) do
      {:ok, result}
    else
      _invalid ->
        {:error, %Error{category: :protocol, operation: :exec, evidence: :dispatch_uncertain}}
    end
  end

  @doc false
  def valid?(%__MODULE__{} = result),
    do:
      Validation.struct_shape?(result, __MODULE__) and
        Validation.integer?(result.pid, 1, 4_294_967_295)

  def valid?(_result), do: false
end
