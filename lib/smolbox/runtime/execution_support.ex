defmodule SmolBox.Runtime.ExecutionSupport do
  @moduledoc false
  alias SmolBox.Runtime.Session

  def extended?(%{command: %{background: true}}), do: true
  def extended?(%{profile: %{execution_ms: ms}}), do: is_integer(ms) and ms > 300_000
  def extended?(_invalid), do: false

  def check(config, spec) do
    if extended?(spec) do
      case Session.store(config, :capabilities, []) do
        {:ok, %{extended_execution: 1}} -> :ok
        {:ok, _unsupported} -> Session.error(:unsupported_capability, :submit)
        error -> error
      end
    else
      :ok
    end
  end

  def worker?(worker, spec),
    do: not extended?(spec) or worker.runtime_version == "1.17.0"
end
