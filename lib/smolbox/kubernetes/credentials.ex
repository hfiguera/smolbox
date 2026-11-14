defmodule SmolBox.Kubernetes.Credentials do
  @moduledoc """
  Host-owned Kubernetes API credential provider.

  Configure a token file or `{module, context}` in `SmolBox.Kubernetes.Config`.
  A callback receives the remaining operation budget. Token resolution belongs
  inside that budget, never in target construction or durable assignment data.
  Implementations must not log credentials or include them in error details.
  """
  alias SmolBox.Backend.Budget
  alias SmolBox.Error
  alias SmolBox.Kubernetes.Shape

  @callback resolve(context :: term(), Budget.t()) :: {:ok, binary()} | {:error, Error.t()}

  @doc false
  def valid?({:token_file, path}), do: Shape.absolute_path?(path)
  def valid?(provider), do: Shape.callback?(provider, resolve: 2)
end
