defmodule SmolBox.Backend.Kubernetes do
  @moduledoc false
  @behaviour SmolBox.Backend
  alias SmolBox.Backend.Reference
  alias SmolBox.Error
  alias SmolBox.Kubernetes.Config

  def reference(config) do
    with :ok <- Config.validate(config),
         do:
           {:ok,
            %Reference{
              adapter: __MODULE__,
              kind: :kubernetes,
              id: config.id,
              context: config,
              budget: config.budget
            }}
  end

  # Types and authority can be inspected offline. No operation is advertised
  # before its implementation and the remaining preview gates are available.
  @impl true
  def supports_operation?(_context, _operation), do: false

  @impl true
  def invoke(_context, operation, _arguments, _budget),
    do:
      {:error,
       %Error{
         category: :unsupported_capability,
         operation: operation,
         evidence: :not_dispatched
       }}
end
