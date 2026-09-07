defmodule SmolBox.CI.GateTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{Child, Gate}

  test "ordinary CI succeeds without any runtime job dependencies" do
    for event <- ~w(push pull_request workflow_dispatch) do
      assert Gate.failures(baseline(:ci), event) == %{}

      for job <- ~w(smolbox-linux-runtime smolbox-macos-runtime) do
        results = Map.put(baseline(:ci), job, %{"result" => "skipped"})
        assert Gate.failures(results, event) != %{}
      end
    end

    assert Gate.failures(baseline(:runtime), "workflow_dispatch", :runtime) == %{}
  end

  test "each workflow requires its exact dependencies to succeed with no allowed skips" do
    for scope <- [:ci, :runtime] do
      for job <- Gate.jobs(scope) do
        for status <- [nil, "failure", "cancelled", "skipped", "neutral", "unknown"] do
          results = put_in(baseline(scope), [job, "result"], status)
          assert Gate.failures(results, "workflow_dispatch", scope) != %{}
        end

        assert Gate.failures(Map.delete(baseline(scope), job), "workflow_dispatch", scope) != %{}

        assert Gate.failures(Map.put(baseline(scope), job, false), "workflow_dispatch", scope) !=
                 %{}
      end

      for results <- [%{}, nil, Map.put(baseline(scope), "unexpected", %{})] do
        assert Gate.failures(results, "workflow_dispatch", scope) != %{}
      end
    end
  end

  test "qualification requires manual dispatch and invalid workflow selections fail closed" do
    for {event, scope} <- [
          {"push", :runtime},
          {"pull_request", :runtime},
          {"pull_request_target", :ci},
          {"pull_request_target", :runtime},
          {nil, :ci},
          {"workflow_dispatch", nil},
          {"workflow_dispatch", "runtime"},
          {"workflow_dispatch", :unknown}
        ] do
      results = if scope == :runtime, do: baseline(:runtime), else: baseline(:ci)
      assert Gate.failures(results, event, scope) != %{}
    end
  end

  test "actual CLI gates pass complete workflows and reject a skipped required dependency" do
    root = Path.expand("../..", __DIR__)

    for {scope, command, job} <- [
          {:ci, "required", "smolbox-tests"},
          {:runtime, "runtime-required", "smolbox-linux-runtime"}
        ],
        {status, expected} <- [{"success", 0}, {"skipped", 1}] do
      results = put_in(baseline(scope), [job, "result"], status)

      {data, report} =
        Child.execute(["elixir", "scripts/ci.exs", command],
          cd: root,
          env: [
            {"NEEDS_JSON", JSON.encode!(results)},
            {"GITHUB_EVENT_NAME", "workflow_dispatch"}
          ],
          timeout: 20_000
        )

      assert report.exit_code == expected
      failed = JSON.decode!(data)["failed_dependencies"]
      assert failed == if(expected == 0, do: %{}, else: %{job => "skipped"})
    end
  end

  defp baseline(scope), do: Map.new(Gate.jobs(scope), &{&1, %{"result" => "success"}})
end
