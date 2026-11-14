defmodule SmolBox.Kubernetes.Exchange do
  @moduledoc false
  alias SmolBox.Error
  alias SmolBox.Kubernetes.{Guard, Operation, RemoteCommand, WebSocket}

  def run(operation, record, payload, options) do
    capture =
      RemoteCommand.new(
        Keyword.get(options, :max_output_bytes, record.spec.profile.max_output_bytes)
      )

    table = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(table, {:capture, capture})

    callback = options[:on_event]

    try do
      outcome =
        Operation.run(operation, fn sent ->
          with :ok <- Guard.check(operation, record),
               :ok <-
                 WebSocket.run(operation, record.backend_receipt, payload, table, callback, sent),
               {:ok, result} <- RemoteCommand.result(WebSocket.snapshot(table)),
               :ok <- Guard.check(operation, record) do
            if callback, do: callback.({:exit, result.exit_code})
            :ok
          end
        end)

      capture = WebSocket.snapshot(table)
      result = finish(capture, outcome, operation.name)
      helper_evidence(result, capture.exit, options[:helper_exit])
    after
      :ets.delete(table)
    end
  end

  # A utility's rejected request still has an actual helper exit. Application
  # exec deliberately requires its dispatch acknowledgement before qualifying
  # an application exit; callers cannot enable this through public exec options.
  defp helper_evidence({:error, %Error{} = error}, exit, true) when is_integer(exit),
    do: {:error, %{error | evidence: :exited, exit_code: exit}}

  defp helper_evidence(result, _, _), do: result

  defp finish(capture, :ok, name), do: outcome(RemoteCommand.result(capture), name)

  defp finish(capture, {:error, %Error{} = error}, name),
    do: outcome(RemoteCommand.result(capture, error.category), name, error.evidence)

  defp finish(capture, {:error, category}, name) when is_atom(category),
    do: outcome(RemoteCommand.result(capture, category), name)

  defp finish(capture, _, name), do: outcome(RemoteCommand.result(capture, :protocol), name)

  defp outcome(result, name, evidence \\ :dispatch_uncertain)
  defp outcome({:ok, result}, _, _), do: {:ok, result}

  defp outcome({:error, category, result}, name, _),
    do:
      {:error,
       %Error{
         category: category,
         operation: name,
         evidence: :exited,
         exit_code: result.exit_code
       }, result}

  defp outcome({:error, category}, name, evidence), do: Operation.error(category, name, evidence)
end
