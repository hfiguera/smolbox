defmodule SmolBox.CI.ChildTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{Bounded, Child, Util}

  @tag :ordinary_retention
  test "native execute leaves its detached collector alive through normal child exit" do
    root = Util.temporary("native-retained-runner")
    marker = Path.join(root, "release")

    on_exit(fn ->
      File.write(marker, "release")
      File.rm_rf!(root)
    end)

    script =
      "i=0; while [ ! -f \"$1\" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.01; done; test -f \"$1\""

    {_bytes, report} =
      Child.execute(["sh", "-c", script, "fixture", marker], timeout: 100, termination: :retain)

    assert report.retained and report.running
    assert report.failure == "deadline"
    File.write!(marker, "release")
    assert_gone(to_string(report.diagnostic_os_pid))
  end

  @tag :ordinary_retention
  test "native deadline retains its collector until normal pipe release and collection" do
    {:ok, child} =
      Child.start_link(["sh", "-c", "read line; printf released"],
        timeout: 100,
        termination: :retain
      )

    {_bytes, report} = Child.await(child)
    assert report.failure == "deadline"
    assert report.retained and report.running
    assert report.exit_code == nil
    assert true = Child.send_line(child, "done")
    assert_collected(child)
    {bytes, collected} = Child.snapshot(child)
    assert bytes == "released"
    assert collected.exit_code == 0
    # Timeout remains a failed qualification.
    assert collected.status == "failed"
    refute collected.retained or collected.running
    GenServer.stop(child)
  end

  @tag :ordinary_retention
  test "native output overflow stays bounded while normal release remains possible" do
    {:ok, child} =
      Child.start_link(["sh", "-c", "printf 123456789012345678901234567890; read line"],
        timeout: 3_000,
        output_limit: 16,
        termination: :retain
      )

    {bytes, report} = Child.await(child)
    assert byte_size(bytes) == 17
    assert report.failure == "output_limit"
    assert report.retained and report.running
    assert true = Child.send_line(child, "done")
    assert_collected(child)
    assert {^bytes, %{exit_code: 0, retained: false, running: false}} = Child.snapshot(child)
    GenServer.stop(child)
  end

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

  defp assert_collected(child, attempts \\ 100)
  defp assert_collected(_child, 0), do: flunk("normal child exit was not collected")

  defp assert_collected(child, attempts) do
    if elem(Child.snapshot(child), 1).running do
      Process.sleep(10)
      assert_collected(child, attempts - 1)
    end
  end

  defp assert_gone(pid, attempts \\ 100)
  defp assert_gone(_pid, 0), do: flunk("normal child status was not collected")

  defp assert_gone(pid, attempts) do
    {_status, code} = System.cmd("ps", ["-p", pid, "-o", "stat="])

    if code == 0 do
      Process.sleep(10)
      assert_gone(pid, attempts - 1)
    end
  end
end
