defmodule SmolBox.CI.ChildTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{Bounded, Child, Util}

  test "an existing report prevents execution before spawning its command" do
    directory = Util.temporary("smolbox-report-test")
    on_exit(fn -> File.rm_rf!(directory) end)
    report = Path.join(directory, "report.json")
    marker = Path.join(directory, "executed")
    File.write!(report, "existing")
    assert_raise ArgumentError, fn -> Bounded.run(["--report", report, "--", "touch", marker]) end
    refute File.exists?(marker)
    assert File.read!(report) == "existing"
  end

  test "nonzero exits preserve bounded binary output without leaking it into reports" do
    {bytes, report} =
      Child.execute(["sh", "-c", "printf 'private-payload\\377'; exit 7"], timeout: 3_000)

    assert bytes == <<"private-payload", 255>>
    assert report.exit_code == 7
    assert report.status == "failed"
    refute inspect(report) =~ "private-payload"
  end

  test "output overflow stops its child and retains only the cap plus one byte" do
    {bytes, report} = Child.execute(["sh", "-c", "yes x"], timeout: 3_000, output_limit: 1024)
    assert byte_size(bytes) == 1025
    assert report.failure == "output_limit"
  end

  test "deadline terminates its process group without touching another child" do
    {:ok, other} = Child.start_link(["sleep", "30"])

    try do
      {bytes, report} = Child.execute(["sh", "-c", "echo $$; exec sleep 30"], timeout: 200)
      assert report.failure == "deadline"
      assert_dead(String.trim(bytes))
      assert elem(Child.snapshot(other), 1).exit_code == nil
    after
      Child.stop(other)
      GenServer.stop(other)
    end
  end

  test "leader exit does not leave a TERM-ignoring descendant alive" do
    {bytes, report} =
      Child.execute(["sh", "-c", "(trap '' TERM; exec sleep 30) & echo $!; exit 0"], timeout: 200)

    assert report.failure in [nil, "deadline"]
    assert_dead(String.trim(bytes))
  end

  test "interactive phase delivery remains bounded" do
    {:ok, child} = Child.start_link(["sh", "-c", "read line; echo phase:$line"], phases: true)
    assert true = Child.send_line(child, "ready")
    assert {"phase:ready\n", %{status: "passed"}} = Child.await(child)
    assert {:ok, "phase:ready"} = Child.next_phase(child)
    GenServer.stop(child)

    {_, report} =
      Child.execute(["sh", "-c", "i=0; while [ $i -lt 200 ]; do echo phase:x; i=$((i+1)); done"],
        phases: true
      )

    assert report.failure == "phase_limit"
  end

  test "zero, skipped, fractional, repeated and incomplete suites fail qualification" do
    valid = "Running ExUnit with seed: 123, max_cases: 16\nResult: 9 passed\n"
    assert Bounded.summary!(valid, 9) == %{passed: 9, seed: 123}
    assert_raise ArgumentError, fn -> Bounded.summary!(valid, 0) end

    for invalid <- [
          String.replace(valid, "9 passed", "0 passed"),
          String.replace(valid, "9 passed", "8/9 passed"),
          valid <> "1 excluded\n",
          valid <> "1 skipped\n",
          valid <> valid,
          "",
          "command succeeded\n"
        ] do
      assert_raise ArgumentError, fn -> Bounded.summary!(invalid, 9) end
    end
  end

  defp assert_dead(pid, attempts \\ 100)
  defp assert_dead(pid, 0), do: flunk("owned child #{pid} survived cleanup")

  defp assert_dead(pid, attempts) do
    {status, code} = System.cmd("ps", ["-p", pid, "-o", "stat="])

    unless code != 0 or String.starts_with?(String.trim(status), "Z") do
      Process.sleep(10)
      assert_dead(pid, attempts - 1)
    end
  end
end
