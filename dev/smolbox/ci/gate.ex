defmodule SmolBox.CI.Gate do
  @moduledoc false

  @live ~w(smolbox-linux-runtime smolbox-macos-runtime)
  @ordinary ~w(smolbox-ci-tools smolbox-format-compile smolbox-credo-ex-slop
    smolbox-ex-dna smolbox-credence smolbox-dialyzer smolbox-tests
    smolbox-coverage smolbox-quality-canaries smolbox-security smolbox-docs-package
    smolbox-compatibility smolbox-minimum-dependencies smolbox-minimal-host smolbox-store-contract)

  def jobs, do: @ordinary ++ @live
  def live, do: @live

  def failures(results, event, requested) do
    with :ok <- selection(event, requested),
         :ok <- job_set(results) do
      Enum.reduce(results, %{}, &check_job(&1, &2, requested))
    end
  end

  defp selection(event, requested) do
    cond do
      event not in ~w(push pull_request workflow_dispatch) or requested not in ~w(true false) ->
        %{"selection" => "invalid qualification selection"}

      requested == "true" and event != "workflow_dispatch" ->
        %{"selection" => "qualification requires manual dispatch"}

      true ->
        :ok
    end
  end

  defp job_set(results) do
    if is_map(results) and Enum.sort(Map.keys(results)) == Enum.sort(jobs()),
      do: :ok,
      else: %{"job_set" => "missing or unexpected required dependency"}
  end

  defp check_job({job, value}, failed, requested) do
    status = if is_map(value), do: Map.get(value, "result")
    allowed_skip = job in @live and requested == "false" and status == "skipped"

    if status == "success" or allowed_skip,
      do: failed,
      else: Map.put(failed, job, status || "missing result")
  end
end
