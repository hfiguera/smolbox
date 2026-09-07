defmodule SmolBox.CI.Gate do
  @moduledoc false

  @runtime ~w(smolbox-runtime-candidate smolbox-linux-runtime smolbox-macos-runtime)
  @ordinary ~w(smolbox-ci-tools smolbox-format-compile smolbox-credo-ex-slop
    smolbox-ex-dna smolbox-credence smolbox-dialyzer smolbox-tests
    smolbox-coverage smolbox-quality-canaries smolbox-security smolbox-docs-package
    smolbox-compatibility smolbox-minimum-dependencies smolbox-minimal-host smolbox-store-contract)

  def jobs(scope \\ :ci)
  def jobs(:ci), do: @ordinary
  def jobs(:runtime), do: @runtime

  def failures(results, event, scope \\ :ci) do
    with :ok <- selection(event, scope),
         :ok <- job_set(results, scope) do
      Enum.reduce(results, %{}, &check_job/2)
    end
  end

  defp selection(event, scope) do
    cond do
      event not in ~w(push pull_request workflow_dispatch) or scope not in [:ci, :runtime] ->
        %{"selection" => "invalid workflow selection"}

      scope == :runtime and event != "workflow_dispatch" ->
        %{"selection" => "qualification requires manual dispatch"}

      true ->
        :ok
    end
  end

  defp job_set(results, scope) do
    if is_map(results) and Enum.sort(Map.keys(results)) == Enum.sort(jobs(scope)),
      do: :ok,
      else: %{"job_set" => "missing or unexpected required dependency"}
  end

  defp check_job({job, value}, failed) do
    status = if is_map(value), do: Map.get(value, "result")

    if status == "success",
      do: failed,
      else: Map.put(failed, job, status || "missing result")
  end
end
