defmodule SmolBox.Test.NodeAuthorityStore do
  @moduledoc false
  @behaviour SmolBox.Store
  alias SmolBox.{Error, Execution}

  # Observe the real adapter's durable boundaries. This wrapper never supplies
  # evidence, alters stored records, or bypasses adapter validation.
  for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks) do
    arguments = Macro.generate_arguments(arity - 1, __MODULE__)
    @impl true
    def unquote(operation)(context, unquote_splicing(arguments)),
      do: invoke(context, unquote(operation), [unquote_splicing(arguments)])
  end

  def new(adapter, store) do
    events =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{leases: [], releases: [], pages: [], deny_lease: false, scan: nil} end},
        id: make_ref()
      )

    %{adapter: adapter, store: store, events: events}
  end

  def events(context), do: Agent.get(context.events, & &1)
  def change(context, callback), do: Agent.update(context.events, callback)

  defp invoke(context, :claim_worker, args) do
    if events(context).deny_lease do
      {:error, %Error{category: :store, operation: :claim_worker}}
    else
      result = forward(context, :claim_worker, args)

      if match?({:ok, _}, result) do
        {:ok, lease} = result
        change(context, &%{&1 | leases: [lease | &1.leases]})
      end

      result
    end
  end

  defp invoke(context, :backend_assignments, [_, cursor, _] = args) do
    hook =
      Agent.get_and_update(context.events, fn events ->
        case events.scan do
          {:after_cursor, callback} when not is_nil(cursor) ->
            {callback, %{events | scan: nil}}

          _ ->
            {nil, events}
        end
      end)

    if hook, do: hook.()
    result = forward(context, :backend_assignments, args)
    change(context, &%{&1 | pages: [{cursor, result} | &1.pages]})
    result
  end

  defp invoke(context, :release, [key | _] = args) do
    {:ok, before} = forward(context, :fetch, [key])
    result = forward(context, :release, args)

    if match?({:ok, %Execution{reservation: nil}}, result),
      do: change(context, &%{&1 | releases: [{before, result} | &1.releases]})

    result
  end

  defp invoke(context, operation, args), do: forward(context, operation, args)

  defp forward(context, operation, args),
    do: apply(context.adapter, operation, [context.store | args])
end
