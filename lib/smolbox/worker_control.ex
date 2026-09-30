defmodule SmolBox.WorkerControl do
  @moduledoc """
  Store-authoritative admission mode for one stable worker identity.

  Version zero is the implicit active state before the first write. Changes use
  compare-and-set versions; retrying the last identical versioned request returns
  the same record. Unconditional draining is conservative and idempotent while
  already draining. Resuming always requires an observed version.

  This fences new reservations, not worker HTTP requests, existing assignments,
  commands or background processes. It never stops or deletes a machine.
  """
  alias SmolBox.{Error, Validation}
  @enforce_keys [:worker_id]
  defstruct [:worker_id, :updated_at_ms, :request_version, mode: :active, version: 0]
  @type mode :: :active | :draining
  @type t :: %__MODULE__{
          worker_id: String.t(),
          mode: mode(),
          version: non_neg_integer(),
          updated_at_ms: non_neg_integer() | nil,
          request_version: non_neg_integer() | nil
        }

  @doc false
  def initial(worker), do: %__MODULE__{worker_id: worker}

  @doc false
  def validate(%__MODULE__{} = control) do
    valid =
      Validation.struct_shape?(control, __MODULE__) and
        Validation.identifier?(control.worker_id) and control.mode in [:active, :draining] and
        Validation.integer?(control.version, 0, 9_223_372_036_854_775_806) and history?(control)

    if valid, do: :ok, else: error(:validation)
  end

  def validate(_), do: error(:validation)

  defp history?(%{version: 0} = control),
    do:
      control.mode == :active and control.updated_at_ms == nil and control.request_version == nil

  defp history?(control),
    do:
      Validation.timestamp?(control.updated_at_ms) and
        (control.request_version == nil or control.request_version == control.version - 1)

  @doc false
  def change(control, mode, expected, now) do
    with :ok <- validate(control),
         true <- mode in [:active, :draining] and Validation.timestamp?(now),
         true <-
           Validation.integer?(expected, 0, 9_223_372_036_854_775_805) or
             (expected == :any and mode == :draining) do
      transition(control, mode, expected, now)
    else
      _ -> error(:validation)
    end
  end

  defp transition(%{mode: :draining} = control, :draining, :any, _now), do: {:ok, control}

  defp transition(
         %{mode: mode, request_version: expected, version: version} = control,
         mode,
         expected,
         _now
       )
       when version > 0 and is_integer(expected), do: {:ok, control}

  defp transition(control, mode, expected, now)
       when expected == :any or expected == control.version do
    next = %{
      control
      | mode: mode,
        version: control.version + 1,
        request_version: if(expected == :any, do: nil, else: expected),
        updated_at_ms: max(now, control.updated_at_ms || 0)
    }

    with :ok <- validate(next), do: {:ok, next}
  end

  defp transition(_, _, _, _), do: error(:stale_version)

  @doc false
  def admit(control) do
    with :ok <- validate(control) do
      if control.mode == :active, do: :ok, else: error(:admission_exhausted)
    end
  end

  @doc false
  def admit_change(_control, record, record), do: :ok
  def admit_change(control, _before, _after), do: admit(control)

  defp error(category), do: {:error, %Error{category: category, operation: :worker_control}}
end
