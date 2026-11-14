defmodule SmolBox.Kubernetes.NodeEvidence do
  @moduledoc """
  Bounded host extension for read-only evidence from the enrolled Kubernetes node.

  This provider observes node/runtime identity, effective offline isolation,
  original sandbox processes and positive cleanup. It cannot create, stop or
  delete machines. API absence or a successful remote command alone is not a
  cleanup proof. The provider may persist its own evidence ledger; installing or
  resetting runtime audit infrastructure is a separate administrator operation.
  Connection configuration and live handles are never persisted.
  """
  alias SmolBox.Backend.Budget
  alias SmolBox.Error
  alias SmolBox.Kubernetes.{Binding, Shape}

  @callback check(Binding.t(), Budget.t(), context :: term()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback capture(Binding.t(), pod_uid :: String.t(), Budget.t(), context :: term()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback cleanup(Binding.t(), receipt :: term(), Budget.t(), context :: term()) ::
              {:ok, map()} | {:error, Error.t()}

  @doc false
  def valid?(provider), do: Shape.callback?(provider, check: 3, capture: 4, cleanup: 4)
end
