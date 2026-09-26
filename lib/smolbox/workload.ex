defmodule SmolBox.Workload do
  @moduledoc """
  Immutable startup workload for an approved image machine on smolvm 1.17.0 or 1.19.0.

  An empty entrypoint and command inherit the artifact's command. Otherwise their
  concatenation replaces it, without inserting a shell. Environment overrides
  layer over the artifact environment; a nil working directory inherits it.
  Values are persisted and must be protected as potentially sensitive data.

  Only `restart: :never` is qualified. Upstream's restart supervisor observes VM
  liveness, not application health, and does not relaunch this workload. Explicit
  machine stop/start launches it again. Machine running does not mean app ready.
  """
  alias SmolBox.{Command, Error, Validation}

  @fields [:entrypoint, :cmd, :env, :workdir, :restart]
  @derive {Inspect, only: [:restart]}
  defstruct entrypoint: [], cmd: [], env: [], workdir: nil, restart: :never

  @type t :: %__MODULE__{
          entrypoint: [String.t()],
          cmd: [String.t()],
          env: [{String.t(), String.t()}],
          workdir: String.t() | nil,
          restart: :never
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options \\ []) do
    with true <- Validation.keys?(options, @fields),
         workload = struct!(__MODULE__, options),
         :ok <- validate(workload) do
      {:ok, %{workload | env: Enum.sort(workload.env)}}
    else
      {:error, error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = workload) do
    with true <- Validation.struct_shape?(workload, __MODULE__),
         true <- Validation.list?(workload.entrypoint, 255),
         true <- Validation.list?(workload.cmd, 255),
         {:ok, _} <-
           Command.new(["true"] ++ workload.entrypoint ++ workload.cmd, env: workload.env),
         true <- first?(workload.entrypoint) and first?(workload.cmd),
         true <- workdir?(workload.workdir) do
      if workload.restart == :never,
        do: :ok,
        else: {:error, %Error{category: :unsupported_capability, operation: :workload}}
    else
      _invalid -> invalid()
    end
  end

  def validate(_value), do: invalid()

  @doc false
  def optional?(nil), do: true
  def optional?(workload), do: validate(workload) == :ok

  @doc false
  def to_wire(workload) do
    wire = %{
      "entrypoint" => workload.entrypoint,
      "cmd" => workload.cmd,
      "env" =>
        Enum.map(workload.env, fn {name, value} -> %{"name" => name, "value" => value} end),
      "restart" => %{"policy" => "never"}
    }

    if workload.workdir, do: Map.put(wire, "workdir", workload.workdir), else: wire
  end

  defp first?([]), do: true
  defp first?([first | _]), do: first != ""
  defp workdir?(nil), do: true

  defp workdir?(path),
    do: Validation.text?(path, 4096) and String.starts_with?(path, "/")

  defp invalid, do: {:error, %Error{category: :validation, operation: :workload}}
end
