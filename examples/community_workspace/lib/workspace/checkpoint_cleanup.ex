defmodule Workspace.CheckpointCleanup do
  @moduledoc "Explicit deletion of this walkthrough's recorded local checkpoint files."
  alias Workspace.Settings

  def delete(capture, policy, machine) do
    root = Path.join(Settings.home(), "captures")
    directory = Path.join(root, capture.fingerprint)
    path = Path.join(directory, "capture.smolcheckpoint")

    with true <- capture.machine == machine and capture.spec.policy == policy,
         true <- policy.root == root and capture.result.path == path,
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, capture.fingerprint),
         :ok <- directory?(Settings.home()),
         :ok <- directory?(root),
         :ok <- capture_directory?(directory),
         :ok <- owned_file?(path, capture.result.sha256),
         :ok <- removable?(path <> ".partial"),
         :ok <- remove(path <> ".partial"),
         :ok <- remove(path) do
      :ok
    else
      _ -> {:error, :checkpoint_cleanup_failed}
    end
  end

  defp directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      _ -> :error
    end
  end

  defp capture_directory?(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> directory?(path)
    end
  end

  defp owned_file?(path, digest) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> if Settings.digest(path) == digest, do: :ok, else: :error
      _ -> :error
    end
  end

  defp removable?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _ -> :error
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> :error
    end
  end
end
