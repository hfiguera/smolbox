defmodule SmolBox.Backend.Embedded do
  @moduledoc false
  @behaviour SmolBox.Backend
  alias SmolBox.Backend.{
    Assignment,
    Budget,
    EmbeddedContext,
    EmbeddedOperation,
    EmbeddedReply,
    Reference
  }

  alias SmolBox.Embedded.{Call, Health}

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
        {:ok, %{status: :ready} = health} -> {:ready, Health.describe(context.config, health)}
        _unavailable -> {:unavailable, nil}
      end
    else
      {:incompatible, nil}
    end
  end

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

  def invoke(context, operation, arguments, budget) do
    with {:ok, request, budget, input, callback} <-
           EmbeddedOperation.build(context, operation, arguments, budget) do
      context
      |> Call.run(request, budget, input, callback)
      |> then(&EmbeddedReply.decode(context, operation, request, &1))
    end
  end

  defp qualification_error({:error, error}), do: {:error, %{error | evidence: :not_dispatched}}

  defp qualification_error(_),
    do: {:error, %SmolBox.Error{category: :unknown, operation: :qualify_creation}}
end
