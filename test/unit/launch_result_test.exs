defmodule SmolBox.LaunchResultTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Command, Error, ExecutionSpec, LaunchResult, Profile, Result}
  alias SmolBox.Store.{Codec, CodecExecution, Contract}

  test "launch is explicit, does not carry an ignored timeout or stdin, and rejects invalid modes" do
    assert {:ok, command} = Command.new(["server"], background: true)
    assert command.timeout_secs == nil
    assert {:ok, wire} = Command.to_wire(command)
    assert wire["background"] == true
    refute Map.has_key?(wire, "timeoutSecs")

    for options <- [
          [background: true, stdin: ""],
          [background: true, timeout_secs: 5],
          [background: :yes]
        ] do
      assert {:error, _} = Command.new(["server"], options)
    end

    spec = %{Contract.record().spec | command: command, outputs: []}
    assert :ok = ExecutionSpec.validate(spec)

    assert {:error, _} =
             ExecutionSpec.validate(%{
               spec
               | artifact: Map.put(spec.artifact, "kind", "checkpoint")
             })

    assert {:error, _} =
             ExecutionSpec.validate(%{
               spec
               | outputs: [
                   %{"path" => "/workspace/log", "destination" => "log", "max_bytes" => 100}
                 ]
             })
  end

  test "only a canonical positive u32 PID acknowledgment yields launch evidence" do
    assert {:ok, %LaunchResult{pid: 123}} = LaunchResult.from_wire(body("pid=123\n"), 100)

    assert {:ok, %Result{stdout: "pid=123\n", exit_code: 0}} =
             Result.from_wire(body("pid=123\n"), 100)

    for stdout <- [
          "pid=0\n",
          "pid=-1\n",
          "pid=01\n",
          "pid=4294967296\n",
          "pid=123",
          "pid=123\nextra",
          "secret"
        ] do
      assert {:error, %Error{category: :protocol, evidence: :dispatch_uncertain, exit_code: nil}} =
               LaunchResult.from_wire(body(stdout), 100)
    end

    for wire <- [
          Map.put(body("pid=1\n"), "exitCode", 1),
          Map.put(body("pid=1\n"), "stderrB64", Base.encode64("error")),
          %{},
          Map.put(body("x"), "stdoutB64", "!")
        ] do
      assert {:error, %Error{evidence: :dispatch_uncertain, exit_code: nil}} =
               LaunchResult.from_wire(wire, 100)
    end

    assert {:error, %Error{evidence: :dispatch_uncertain, exit_code: nil}} =
             LaunchResult.from_wire(body("pid=123\n"), 1)
  end

  test "long budgets are explicit, bounded, and do not enlarge unrelated stages" do
    assert {:ok, command} = Command.new(["build"], timeout_secs: 86_400)
    assert {:ok, profile} = Profile.new("long", execution_ms: 86_460_000)
    spec = %{Contract.record().spec | command: command, profile: profile}
    assert :ok = ExecutionSpec.validate(spec)

    assert {:error, _} =
             ExecutionSpec.validate(%{spec | profile: %{profile | execution_ms: 300_000}})

    assert {:error, _} = Command.new(["build"], timeout_secs: 86_401)
    assert {:error, _} = Profile.new("long", execution_ms: 86_460_001)

    for stage <- [:preparation_ms, :collection_ms, :cleanup_ms] do
      assert {:error, _} = Profile.new("long", [{stage, 300_001}])
    end

    record = %{Contract.record() | spec: %{spec | profile: %{profile | id: "long"}}}
    assert {:ok, <<"smolbox-record-v6\0", _::binary>> = encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)
    forged = CodecExecution.strip(record) |> Map.delete(:managed_machine)
    assert {:error, _} = Codec.decode("smolbox-record-v2\0" <> :erlang.term_to_binary(forged))
  end

  defp body(stdout),
    do: %{"exitCode" => 0, "stdoutB64" => Base.encode64(stdout), "stderrB64" => ""}
end
