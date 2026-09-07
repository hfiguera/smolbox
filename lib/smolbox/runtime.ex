defmodule SmolBox.Runtime do
  @moduledoc """
  Explicitly started supervisor for bounded managed execution.

  Starting the library application alone opens no worker connections and starts
  no scheduler or database. A named runtime checks its host store semantics,
  then starts a bounded task supervisor and a coordinator. Shutdown terminates
  observers; this is not proof of guest cancellation. Persisted due work is the
  restart authority. Durable mode never falls back to memory.
  """
  use Supervisor
  alias SmolBox.Runtime.{Config, Coordinator}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    with {:ok, config} <- Config.new(options),
         do: Supervisor.start_link(__MODULE__, config, name: config.name)
  end

  @impl Supervisor
  def init(config) do
    children = [
      {Task.Supervisor, max_children: config.max_active + 1},
      {Coordinator, {config, self()}}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc false
  @spec coordinator(Supervisor.supervisor()) :: pid()
  def coordinator(runtime) do
    {Coordinator, pid, :worker, _modules} =
      Enum.find(Supervisor.which_children(runtime), &(elem(&1, 0) == Coordinator))

    pid
  end
end
