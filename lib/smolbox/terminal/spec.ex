defmodule SmolBox.Terminal.Spec do
  @moduledoc """
  Immutable interactive terminal intent. Upstream accepts a single executable,
  not argv, environment, user or working-directory overrides. No shell is inserted.

  Session and idle budgets bound observation, not guest lifetime. Managed sessions
  also fit the host-approved profile execution budget. Terminal bytes are not
  persisted. Output buffering is capped independently of session duration.
  """
  alias SmolBox.{Error, Validation}

  @derive {Inspect, only: [:cols, :rows]}
  defstruct program: "/bin/sh",
            cols: 80,
            rows: 24,
            session_ms: 30_000,
            idle_ms: 30_000,
            close_ms: 1000,
            attach_ms: 5000,
            max_buffer_bytes: 262_144,
            max_input_bytes: 16_384

  @type t :: %__MODULE__{
          program: String.t(),
          cols: pos_integer(),
          rows: pos_integer(),
          session_ms: pos_integer(),
          idle_ms: pos_integer(),
          close_ms: pos_integer(),
          attach_ms: pos_integer(),
          max_buffer_bytes: pos_integer(),
          max_input_bytes: pos_integer()
        }

  @doc "Construct bounded terminal intent; unknown options are rejected."
  def new(options \\ []) do
    allowed = Map.keys(%__MODULE__{}) -- [:__struct__]

    if Validation.keys?(options, allowed) do
      spec = struct!(__MODULE__, options)
      with :ok <- validate(spec), do: {:ok, spec}
    else
      error()
    end
  end

  @doc false
  def validate(%__MODULE__{} = spec) do
    checks = [
      Validation.struct_shape?(spec, __MODULE__),
      Validation.text?(spec.program, 4096),
      spec.program != "",
      dimensions?(spec.cols, spec.rows),
      Validation.integer?(spec.session_ms, 1000, 86_400_000),
      Validation.integer?(spec.idle_ms, 1000, spec.session_ms),
      Validation.integer?(spec.close_ms, 1, 5000),
      Validation.integer?(spec.attach_ms, 100, 30_000),
      Validation.integer?(spec.max_buffer_bytes, 1024, 1_048_576),
      Validation.integer?(spec.max_input_bytes, 1, 65_536)
    ]

    if Enum.all?(checks), do: :ok, else: error()
  end

  def validate(_spec), do: error()

  @doc false
  def dimensions?(cols, rows),
    do: Validation.integer?(cols, 1, 65_535) and Validation.integer?(rows, 1, 65_535)

  defp error, do: {:error, %Error{category: :validation, operation: :terminal}}
end
