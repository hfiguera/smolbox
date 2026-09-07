defmodule SmolBox.FaultTransport do
  @moduledoc false
  @behaviour SmolBox.Transport
  alias SmolBox.FaultGate
  alias SmolBox.Transport.Req

  def configure(worker_id, gate, ledger),
    do: :persistent_term.put({__MODULE__, worker_id}, %{gate: gate, ledger: ledger})

  @impl SmolBox.Transport
  def request(worker, request) do
    context = :persistent_term.get({__MODULE__, worker.id})
    event = event(request)
    FaultGate.hit(context.gate, event, :before)
    if event == :exec, do: File.write!(context.ledger, "exec\n", [:append, :sync])
    result = Req.request(worker, request)
    FaultGate.hit(context.gate, event, :after)
    result
  end

  defp event(%{method: :post, path: "/api/v1/machines"}), do: :create
  defp event(%{method: :put}), do: :upload
  defp event(%{method: :delete}), do: :delete

  defp event(%{method: :post, path: path}) do
    cond do
      String.ends_with?(path, "/exec/stream") or String.ends_with?(path, "/exec") -> :exec
      String.ends_with?(path, "/stop") -> :stop
      true -> :lifecycle
    end
  end

  defp event(_request), do: :inspect
end
