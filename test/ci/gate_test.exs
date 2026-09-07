defmodule SmolBox.CI.GateTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{Child, Gate}

  test "ordinary runs allow only unrequested live jobs to skip" do
    baseline = baseline()

    for event <- ~w(push pull_request workflow_dispatch) do
      results = Enum.reduce(Gate.live(), baseline, &put_in(&2, [&1, "result"], "skipped"))
      assert Gate.failures(results, event, "false") == %{}

      for job <- Gate.jobs() -- Gate.live() do
        assert Gate.failures(put_in(results, [job, "result"], "skipped"), event, "false") != %{}
      end
    end
  end

  test "requested qualification requires every dependency and both live jobs" do
    assert Gate.failures(baseline(), "workflow_dispatch", "true") == %{}

    for job <- Gate.jobs() do
      for status <- [nil, "failure", "cancelled", "skipped"] do
        assert Gate.failures(
                 put_in(baseline(), [job, "result"], status),
                 "workflow_dispatch",
                 "true"
               ) != %{}
      end

      assert Gate.failures(Map.delete(baseline(), job), "workflow_dispatch", "true") != %{}
    end

    assert Gate.failures(Map.put(baseline(), "unexpected", %{}), "push", "false") != %{}
  end

  test "invalid selections and dependency values fail closed" do
    for {event, requested} <- [
          {"push", "true"},
          {"pull_request", "true"},
          {"pull_request_target", "false"},
          {"workflow_dispatch", nil},
          {"workflow_dispatch", true},
          {"workflow_dispatch", "TRUE"}
        ] do
      assert Gate.failures(baseline(), event, requested) != %{}
    end

    assert Gate.failures(%{}, "push", "false") != %{}
    assert Gate.failures(nil, "push", "false") != %{}
    assert Gate.failures(Map.put(baseline(), "smolbox-tests", false), "push", "false") != %{}
  end

  test "actual CLI returns failure for a requested skipped live suite" do
    results = Enum.reduce(Gate.live(), baseline(), &put_in(&2, [&1, "result"], "skipped"))
    root = Path.expand("../..", __DIR__)

    for {requested, expected} <- [{"false", 0}, {"true", 1}] do
      {data, report} =
        Child.execute(["elixir", "scripts/ci.exs", "required"],
          cd: root,
          env: [
            {"NEEDS_JSON", JSON.encode!(results)},
            {"GITHUB_EVENT_NAME", "workflow_dispatch"},
            {"QUALIFY_RUNTIME", requested}
          ],
          timeout: 20_000
        )

      assert report.exit_code == expected
      failed = JSON.decode!(data)["failed_dependencies"]
      assert map_size(failed) == if(requested == "true", do: 2, else: 0)
    end
  end

  defp baseline, do: Map.new(Gate.jobs(), &{&1, %{"result" => "success"}})
end
