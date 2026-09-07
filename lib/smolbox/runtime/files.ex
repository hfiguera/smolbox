defmodule SmolBox.Runtime.Files do
  @moduledoc false
  alias SmolBox.{Client, Files, Machine, Telemetry}
  alias SmolBox.Runtime.Session

  def stage(session, record) do
    Enum.reduce_while(record.spec.inputs, :ok, fn input, :ok ->
      case stage_input(session, record, input) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def collect(session, record) do
    Telemetry.span(session.config.telemetry_table, :collection, session.key, fn ->
      collect_files(session, record)
    end)
  end

  defp collect_files(session, record) do
    pending =
      Enum.reject(record.spec.outputs, fn output ->
        Enum.any?(record.artifacts, &(&1["path"] == output["path"]))
      end)

    result =
      Enum.reduce_while(pending, {:ok, record}, fn output, {:ok, current} ->
        case collect_output(session, current, output) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, _record} -> Session.patch(session, state: :completed, collection: :complete)
      {:error, error} -> collection_failed(session, error)
    end
  end

  defp stage_input(session, record, input) do
    {adapter, context} = session.config.artifact_store

    with {:ok, bytes} <-
           Session.io(session, record, :preparation, fn ->
             adapter.read(
               context,
               record.scope,
               input["source"],
               record.spec.profile.max_file_bytes
             )
           end),
         true <-
           is_binary(bytes) and byte_size(bytes) == input["size"] and
             Files.sha256(bytes) == input["sha256"],
         :ok <-
           Session.io(session, record, :preparation, fn ->
             Client.upload(
               session.worker.client,
               record.machine_name,
               input["path"],
               bytes,
               input["sha256"]
             )
           end),
         {:ok, staged} <-
           Session.io(session, record, :preparation, fn ->
             Client.download(
               session.worker.client,
               record.machine_name,
               input["path"],
               record.spec.profile.max_file_bytes
             )
           end),
         true <- byte_size(staged) == input["size"] and Files.sha256(staged) == input["sha256"] do
      :ok
    else
      false -> Session.error(:validation, :artifact_store)
      error -> error
    end
  end

  defp collect_output(session, record, output) do
    {adapter, context} = session.config.artifact_store

    with :ok <- running(session, record),
         {:ok, bytes} <-
           Session.io(session, record, :collection, fn ->
             Client.download(
               session.worker.client,
               record.machine_name,
               output["path"],
               output["max_bytes"]
             )
           end),
         digest = Files.sha256(bytes),
         :ok <-
           Session.io(session, record, :collection, fn ->
             adapter.put(context, session.key, output["destination"], bytes, digest)
           end) do
      artifact =
        Map.merge(Map.take(output, ["path", "destination"]), %{
          "sha256" => digest,
          "size" => byte_size(bytes)
        })

      Session.patch(session, artifacts: record.artifacts ++ [artifact])
    end
  end

  defp running(session, record) do
    case Session.io(session, record, :collection, fn ->
           Client.inspect_machine(session.worker.client, record.machine_name)
         end) do
      {:ok, %{state: :running} = observed} ->
        if Machine.same_incarnation?(record.created_machine, observed),
          do: :ok,
          else: Session.error(:identity_conflict, :download)

      {:ok, _stopped} ->
        Session.error(:unknown, :download)

      error ->
        error
    end
  end

  defp collection_failed(session, error) do
    with {:ok, record} <- Session.claim(session) do
      status = if record.artifacts == [], do: :failed, else: :partial

      Session.write(session, record,
        state: :collection_failed,
        collection: status,
        last_error: error
      )
    end
  end
end
