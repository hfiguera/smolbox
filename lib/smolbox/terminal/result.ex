defmodule SmolBox.Terminal.Result do
  @moduledoc """
  Confirmed interactive program exit, without a persisted terminal transcript.
  Upstream codes -1, 124 and 130 are ambiguous internal/disconnect sentinels and cannot
  produce this result, even though an application could itself exit with 130.
  Exit evidence does not prove all descendants or background services terminated.
  """
  alias SmolBox.Validation
  @enforce_keys [:exit_code]
  defstruct [:exit_code]
  @type t :: %__MODULE__{exit_code: non_neg_integer()}
  @doc false
  def valid?(%__MODULE__{} = result),
    do:
      Validation.struct_shape?(result, __MODULE__) and
        Validation.integer?(result.exit_code, 0, 255) and result.exit_code not in [124, 130]

  def valid?(_result), do: false
end
