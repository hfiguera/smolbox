defmodule SmolBox.Kubernetes.Files do
  @moduledoc false
  alias SmolBox.{Error, Execution, Result, Validation}
  alias SmolBox.Files, as: GuestFiles
  alias SmolBox.Kubernetes.{Exchange, FileReply, GuestHelper, Operation, Receipt}

  def upload(operation, record, path, bytes, digest) do
    with true <- preparing?(record) and GuestHelper.file_path?(path),
         input when is_map(input) <- Enum.find(record.spec.inputs, &(&1["path"] == path)),
         true <-
           is_binary(bytes) and byte_size(bytes) == input["size"] and
             digest == input["sha256"] and GuestFiles.sha256(bytes) == digest,
         {:ok, payload} <- GuestHelper.upload(path, bytes, digest, timeout(operation)),
         {:ok, result} <- transfer(operation, record, payload, FileReply.overhead()),
         do: uploaded(operation, result, path, byte_size(bytes), digest),
         else: (error -> failure(error, operation))
  end

  def download(operation, record, path, max) do
    with true <- downloadable?(record, path, max) and GuestHelper.file_path?(path),
         {:ok, payload} <- GuestHelper.download(path, max, timeout(operation)),
         {:ok, result} <- transfer(operation, record, payload, max + FileReply.overhead()),
         do: downloaded(operation, result, path, max),
         else: (error -> failure(error, operation))
  end

  defp uploaded(operation, result, path, size, digest) do
    with {:ok, header, <<>>} <- FileReply.decode(result.stdout, :upload, path, size),
         true <- header["size"] == size and header["sha256"] == digest,
         do: :ok,
         else: (_ -> invalid_reply(operation, result.exit_code))
  end

  defp downloaded(operation, result, path, max) do
    case FileReply.decode(result.stdout, :download, path, max) do
      {:ok, _header, data} -> {:ok, data}
      _ -> invalid_reply(operation, result.exit_code)
    end
  end

  defp invalid_reply(operation, exit),
    do:
      {:error,
       %Error{category: :protocol, operation: operation.name, evidence: :exited, exit_code: exit}}

  defp owned?(record),
    do:
      Execution.validate(record) == :ok and Receipt.valid?(record.backend_receipt) and
        record.backend_receipt.phase == :ready and record.cleanup == :pending and
        record.cancel_requested_at_ms == nil

  defp preparing?(record),
    do:
      owned?(record) and record.state in [:preparing, :ready] and
        record.evidence == :not_dispatched

  defp downloadable?(record, path, max) do
    owned?(record) and Validation.integer?(max, 1, record.spec.profile.max_file_bytes) and
      (preparation_path?(record, path) or collection_path?(record, path, max))
  end

  defp preparation_path?(record, path),
    do: preparing?(record) and Enum.any?(record.spec.inputs, &(&1["path"] == path))

  defp collection_path?(record, path, max),
    do:
      record.state == :collecting and record.evidence == :exited and
        match?(%Result{}, record.result) and
        Enum.any?(record.spec.outputs, &(&1["path"] == path and max <= &1["max_bytes"]))

  defp timeout(operation), do: max(1, min(300_000, Operation.remaining(operation)))

  defp transfer(operation, record, payload, max_output) do
    if Operation.account(operation, 1, byte_size(payload)) <= operation.budget.max_request_bytes do
      operation
      |> Exchange.run(record, payload, max_output_bytes: max_output, helper_exit: true)
      |> complete(operation)
    else
      Operation.error(:output_limit, operation.name, :not_dispatched)
    end
  end

  defp complete(
         {:ok, %Result{exit_code: 0, encoding: :bytes, truncated: false, stderr: <<>>} = result},
         _
       ),
       do: {:ok, result}

  defp complete({:ok, %Result{exit_code: exit}}, operation),
    do:
      {:error,
       %Error{category: :protocol, operation: operation.name, evidence: :exited, exit_code: exit}}

  defp complete({:error, error, _partial}, _), do: {:error, error}
  defp complete(error, _), do: error

  defp failure({:error, %Error{}} = error, _), do: error
  defp failure(_, operation), do: Operation.error(:validation, operation.name, :not_dispatched)
end
