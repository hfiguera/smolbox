defmodule SmolBox.Runtime.NativeResolution do
  @moduledoc false
  alias SmolBox.Backend.EmbeddedContext
  alias SmolBox.Runtime.{NativeAuthority, Session, Target}

  # A lost receipt can prove only absence. Stopped resolution cannot recover
  # material identity or substitute matching SDK labels for creation authority.
  def run(
        _config,
        _coordinator,
        %{created_machine: nil},
        %{kind: :embedded},
        :stopped,
        _function
      ),
      do: Session.error(:unsupported_capability, :reconcile)

  def run(config, coordinator, _record, %{kind: :embedded} = target, _disposition, function) do
    Session.safe(fn ->
      target = Target.pin(target)

      NativeAuthority.run(coordinator, target.id, fn -> resolve(config, target, function) end)
    end)
  end

  def run(_config, _coordinator, _record, worker, _disposition, function), do: function.(worker)

  defp resolve(config, target, function) do
    context = target.connection.context
    bridge = EmbeddedContext.bridge(context)

    with :ok <- bridge.quiesce(context.server, context.epoch),
         {:ok, _lease} <-
           Session.store(config, :claim_worker, [
             target.id,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         do: function.(quiesced(target))
  end

  defp quiesced(%{connection: %{context: %EmbeddedContext{} = context} = reference} = target),
    do: %{target | connection: %{reference | context: %{context | quiesced: true}}}

  defp quiesced(target), do: target
end
