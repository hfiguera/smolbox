defmodule SmolBox.Backend.Embedded do
  @moduledoc false
  @behaviour SmolBox.Backend
  alias SmolBox.Backend.{
    Assignment,
    Budget,
    EmbeddedContext,
    EmbeddedObservation,
    EmbeddedOperation,
    EmbeddedReply,
    Features,
    Reference
  }

  alias SmolBox.Embedded.{Call, Health}
  alias SmolBox.Terminal.Connection.Embedded, as: TerminalConnection
  alias SmolBox.Terminal.Server

  @observations ~w(health capacity metrics readiness list machine_measurements)a

  def reference(config, server) do
    with {:ok, context} <- EmbeddedContext.new(config, server),
         do:
           {:ok,
            %Reference{
              adapter: __MODULE__,
              kind: :embedded,
              id: config.id,
              context: context,
              budget: config.budget
            }}
  end

  @impl true
  def assign(context, record), do: EmbeddedContext.assign(context, record)

  @impl true
  def pin(context, budget), do: {:ok, Call.pin(context, budget)}

  @impl true
  def supports_operation?(nil, operation) when operation in @observations, do: true

  def supports_operation?(%EmbeddedContext{config: config}, operation)
      when operation in @observations,
      do: Features.supports?(config, :observability)

  def supports_operation?(_context, operation) when operation in @observations, do: false

  def supports_operation?(nil, :open_managed_terminal), do: true

  def supports_operation?(%EmbeddedContext{config: config}, :open_managed_terminal),
    do: Features.supports?(config, :terminals)

  def supports_operation?(nil, :logs), do: true

  def supports_operation?(%EmbeddedContext{config: config}, :logs),
    do: Features.supports?(config, :logs)

  def supports_operation?(_context, operation),
    do:
      operation in [
        :observe_health,
        :create,
        :inspect_machine,
        :start,
        :stop,
        :delete,
        :exec,
        :exec_stream,
        :upload,
        :download,
        :qualify_creation,
        :inspect_creation
      ]

  @impl true
  def invoke(context, :observe_health, [expected], budget) do
    if expected == context.config.package_identity["engine_version"] do
      case Call.health(context, budget) do
        {:ok, %{status: :ready} = health} -> observe_dispatch(context, health, budget)
        _unavailable -> {:unavailable, nil}
      end
    else
      {:incompatible, nil}
    end
  end

  def invoke(context, operation, [], budget)
      when operation in ~w(health capacity metrics readiness list)a,
      do: EmbeddedObservation.run(context, operation, budget)

  def invoke(context, :qualify_creation, [spec], budget) do
    with {:ok, request} <- Assignment.qualification(context.config, spec),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384) do
      case Call.run(context, request, budget) do
        {:ok, %{"result" => "qualified"}, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil} ->
          :ok

        result ->
          qualification_error(EmbeddedReply.decode(context, :qualify_creation, request, result))
      end
    end
  end

  def invoke(context, :open_managed_terminal, [name, spec, consumer, observer], budget) do
    with {:ok, source} <- TerminalConnection.source(context, name, spec, budget),
         do: Server.start_connection(source, name, spec, consumer, observer)
  end

  def invoke(context, operation, arguments, budget) do
    with {:ok, request, budget, input, callback} <-
           EmbeddedOperation.build(context, operation, arguments, budget) do
      context
      |> Call.run(request, budget, input, callback)
      |> then(&EmbeddedReply.decode(context, operation, request, &1))
    end
  end

  defp observe_dispatch(context, health, budget) do
    described = Health.describe(context.config, health)

    if Features.supports?(context.config, :observability) do
      context = Call.pin(context, budget)
      deadline = System.monotonic_time(:millisecond) + min(budget.timeout_ms, 1000)

      with {:ok, snapshot} <-
             EmbeddedObservation.run(context, :health, observation_budget(budget, deadline)),
           :ok <-
             EmbeddedObservation.run(context, :readiness, observation_budget(budget, deadline)) do
        {:ready, Map.put(described, :inventory, snapshot)}
      else
        _unavailable -> {:degraded, described}
      end
    else
      {:ready, described}
    end
  end

  defp observation_budget(budget, deadline),
    do: %{budget | timeout_ms: max(1, deadline - System.monotonic_time(:millisecond))}

  defp qualification_error({:error, error}), do: {:error, %{error | evidence: :not_dispatched}}

  defp qualification_error(_),
    do: {:error, %SmolBox.Error{category: :unknown, operation: :qualify_creation}}
end
