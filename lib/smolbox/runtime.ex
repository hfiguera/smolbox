defmodule SmolBox.Runtime do
  @moduledoc """
  Explicitly started supervisor for bounded managed execution.

  Starting the library application alone opens no worker connections and starts
  no scheduler or database. A named runtime checks its host store semantics,
  then starts a bounded work subtree and an independent notification dispatcher.
  The work subtree couples its task supervisor and coordinator for recovery;
  a dispatcher restart alone does not interrupt those execution processes.
  Shutdown terminates
  observers; this is not proof of guest cancellation. Persisted due work is the
  restart authority. Durable mode never falls back to memory.
  """
  use Supervisor
  alias SmolBox.Runtime.{Config, Coordinator, WorkSupervisor}
  alias SmolBox.Telemetry.Dispatcher

  @doc """
  Start a linked runtime using the options documented in `SmolBox.child_spec/1`.

  Normal applications add `{SmolBox, options}` to their supervision tree. Startup
  validates adapter contracts and store capabilities before starting observers.
  Returns `{:ok, pid}` or the underlying validation/supervisor startup error.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    with {:ok, config} <- Config.new(options),
         do: Supervisor.start_link(__MODULE__, config, name: config.name)
  end

  @impl Supervisor
  def init(config) do
    config = %{config | telemetry_table: Dispatcher.table()}

    children = [
      {Dispatcher,
       table: config.telemetry_table,
       metadata: %{runtime: config.name, namespace: config.namespace},
       max_pending: config.telemetry_max_pending,
       timeout_ms: config.telemetry_timeout_ms},
      {WorkSupervisor, config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec coordinator(Supervisor.supervisor()) :: pid()
  def coordinator(runtime) do
    {WorkSupervisor, work, :supervisor, _modules} =
      Enum.find(Supervisor.which_children(runtime), &(elem(&1, 0) == WorkSupervisor))

    {Coordinator, pid, :worker, _modules} =
      Enum.find(Supervisor.which_children(work), &(elem(&1, 0) == Coordinator))

    pid
  end
end
