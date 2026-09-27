defmodule SmolBox.CheckpointIO do
  @moduledoc false
  alias SmolBox.{CheckpointCapture, Error}

  def vacant?(capture) do
    root = capture.spec.policy.root

    with {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(root),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:error, :enoent} <- File.lstat(Path.dirname(CheckpointCapture.path(capture))) do
      :ok
    else
      _ -> error(:identity_conflict, :not_dispatched)
    end
  end

  def receive_file(client, path, output, max_bytes) do
    directory = Path.dirname(output)

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, result} <-
           File.open(output <> ".partial", [:write, :exclusive, :binary], fn io ->
             transfer(client, path, output, max_bytes, io)
           end) do
      result
    else
      _ -> error(:identity_conflict, :not_dispatched)
    end
  end

  defp transfer(client, path, output, max_bytes, io) do
    with :ok <- File.chmod(output <> ".partial", 0o600),
         {:ok, receipt} <-
           client.transport.request(client.worker, %{
             method: :post,
             path: path,
             body: "",
             content_type: "application/json",
             accept: "application/vnd.smolmachines.checkpoint",
             max_bytes: max_bytes,
             mode: {:file, io}
           }),
         :ok <- :file.sync(io),
         :ok <- File.ln(output <> ".partial", output),
         :ok <- File.rm(output <> ".partial") do
      {:ok, receipt}
    else
      _ -> error(:unknown, :dispatch_uncertain)
    end
  end

  def absent?(capture) do
    path = CheckpointCapture.path(capture)
    Enum.all?([path, path <> ".partial"], &(File.lstat(&1) == {:error, :enoent}))
  end

  defp error(category, evidence),
    do: {:error, %Error{category: category, operation: :checkpoint, evidence: evidence}}
end
