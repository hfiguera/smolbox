defmodule SmolBox.Runtime.NativeSupervisor do
  @moduledoc false
  use Supervisor
  alias SmolBox.Embedded.Supervisor, as: EmbeddedSupervisor
  alias SmolBox.Runtime.NativeSupport

  def start_link(config) do
    with :ok <- NativeSupport.enroll(config),
         do: Supervisor.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    children =
      Enum.map(NativeSupport.targets(config), fn target ->
        # Exhausting this target's owner restart budget leaves it unavailable.
        # Escalation must not exhaust the runtime's budget or interrupt HTTP work.
        Supervisor.child_spec({EmbeddedSupervisor, target.native_config},
          id: target.id,
          restart: :temporary
        )
      end)

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 30)
  end
end
