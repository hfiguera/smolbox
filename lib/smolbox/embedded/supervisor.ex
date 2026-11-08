defmodule SmolBox.Embedded.Supervisor do
  @moduledoc """
  Explicit supervision for an approved embedded Port owner.

  Starting this supervisor verifies and launches the configured helper. Merely
  loading SmolBox never launches a native process. A fresh owner permits only
  inspection until the controller binds its durable store, reconciles retained
  assignments, and calls the owner's activation callback.

  Helper failures are handled inside the owner with finite grace periods and
  bounded restart backoff. An unconfirmed helper exit quarantines the owner.
  Unexpected owner death restarts the owner without replaying requests; callers
  must monitor the owner to resolve interrupted calls conservatively.
  """
  use Supervisor
  alias SmolBox.Embedded.{Config, Port}

  def start_link(config, options \\ []) do
    with :ok <- Config.validate(config) do
      Supervisor.start_link(__MODULE__, config, options)
    end
  end

  @impl true
  def init(config),
    do:
      Supervisor.init([{Port, config}], strategy: :one_for_one, max_restarts: 3, max_seconds: 30)
end
