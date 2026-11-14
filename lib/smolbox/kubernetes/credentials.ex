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

  # Called only in Operation.run's isolated, deadline-bound request worker.
  def resolve(provider, budget) do
    case fetch(provider, budget) do
      {:ok, token} -> if token?(token), do: {:ok, token}, else: invalid()
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  defp fetch({:token_file, path}, _budget) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, 16_385) do
          token when is_binary(token) and byte_size(token) < 16_385 ->
            {:ok, String.trim_trailing(token, "\n")}

          _ ->
            invalid()
        end
      after
        File.close(file)
      end
    end
  end

  defp fetch({module, context}, budget), do: module.resolve(context, budget)
  defp fetch(_, _), do: invalid()

  defp token?(token),
    do:
      is_binary(token) and byte_size(token) in 1..16_384 and
        Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, token)

  defp invalid, do: {:error, %Error{category: :authentication, operation: :client}}
end
