defmodule SmolBox.TerminalUnitTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Error, ExecutionSpec}
  alias SmolBox.Store.Contract
  alias SmolBox.Terminal.{Result, Server, Spec, Wire}

  test "terminal intent rejects unsupported exec options, dimensions and unbounded budgets" do
    assert {:ok, %Spec{program: "/bin/sh"}} = Spec.new()

    for options <- [
          [argv: ["sh"]],
          [env: %{}],
          [user: "root"],
          [workdir: "/"],
          [background: true],
          [stdin: "secret"],
          [program: ""],
          [program: "a\0b"],
          [cols: 0],
          [rows: 65_536],
          [session_ms: :infinity],
          [session_ms: 86_400_001],
          [idle_ms: 60_000],
          [max_buffer_bytes: 1_048_577],
          [max_input_bytes: 65_537]
        ] do
      assert {:error, %Error{category: :validation}} = Spec.new(options)
    end

    assert {:ok, max} = Spec.new(session_ms: 86_400_000, idle_ms: 86_400_000, rows: 65_535)
    assert Spec.validate(max) == :ok
  end

  test "interactive intent forbids file manifests and uses a distinct stable identity" do
    ordinary = Contract.record().spec
    {:ok, terminal} = Spec.new(session_ms: 1000, idle_ms: 1000, max_buffer_bytes: 1024)
    spec = %{ordinary | command: terminal, inputs: [], outputs: []}
    assert :ok = ExecutionSpec.validate(spec)

    assert {:error, _} =
             ExecutionSpec.validate(%{
               spec
               | inputs: [
                   %{
                     "path" => "/workspace/in",
                     "source" => "input",
                     "sha256" => String.duplicate("a", 64),
                     "max_bytes" => 1024
                   }
                 ]
             })

    assert {:error, _} =
             ExecutionSpec.validate(%{
               spec
               | outputs: [
                   %{"path" => "/workspace/out", "destination" => "output", "max_bytes" => 1024}
                 ]
             })

    assert {:error, _} =
             ExecutionSpec.validate(%{
               spec
               | artifact: Map.put(spec.artifact, "kind", "checkpoint")
             })

    key = :binary.copy("k", 32)
    assert {:ok, hash} = ExecutionSpec.fingerprint(spec, key)
    assert {:ok, ^hash} = ExecutionSpec.fingerprint(spec, key)

    assert {:ok, other} =
             ExecutionSpec.fingerprint(%{spec | command: %{terminal | cols: 81}}, key)

    refute hash == other
  end

  test "fragmented binary output survives arbitrary network boundaries and interleaved ping" do
    bytes = <<2, 2, 0, 255, 137, 1, 42, 128, 1, 128>>

    {wire, frames} =
      Enum.reduce(:binary.bin_to_list(bytes), {Wire.new(%Mint.WebSocket{}, 1024), []}, fn byte,
                                                                                          {wire,
                                                                                           frames} ->
        assert {:ok, wire, new} = Wire.feed(wire, <<byte>>)
        {wire, frames ++ new}
      end)

    assert frames == [{:ping, "*"}, {:binary, <<0, 255, 128>>}]
    assert wire.buffer == "" and wire.message_bytes == 0
    assert Wire.event({:binary, <<255>>}) == {:ok, {:output, <<255>>}}
  end

  test "wire guards incomplete huge frames, compressed/masked frames and fragmented message totals" do
    wire = Wire.new(%Mint.WebSocket{}, 1024)
    assert {:error, :output_limit} = Wire.feed(wire, <<130, 127, 1_000_000::64>>)
    assert {:error, :protocol} = Wire.feed(wire, <<194, 0>>)
    assert {:error, :protocol} = Wire.feed(wire, <<130, 128>>)
    assert {:error, :protocol} = Wire.feed(wire, <<130, 126, 1::16>>)

    assert {:ok, wire, []} =
             Wire.feed(wire, <<2, 126, 1024::16, :binary.copy("a", 1024)::binary>>)

    assert {:error, :output_limit} = Wire.feed(wire, <<128, 1, 42>>)
  end

  test "exit notification is strict and ambiguous upstream codes remain unknown" do
    for code <- [-1, 124, 130, 256, "0", nil] do
      refute Result.valid?(%Result{exit_code: code})
      assert {:error, :unknown} = Wire.event({:text, Jason.encode!(%{type: "exit", code: code})})
    end

    assert {:ok, {:exit, %Result{exit_code: 7}}} =
             Wire.event({:text, ~s({"type":"exit","code":7})})

    for bytes <- [~s({"type":"exit","code":0,"extra":true}), "not json", <<255>>] do
      assert {:error, :protocol} = Wire.event({:text, bytes})
    end

    assert {:error, :unknown} = Wire.event({:close, 1000, ""})
  end

  test "a fresh BEAM safely decodes terminal uncertainty without preloaded operation atoms" do
    alias SmolBox.Store.{Codec, MachineContract, Memory}
    store = start_supervised!(Memory)
    MachineContract.terminal(Memory, store)
    {:ok, record} = Memory.fetch(store, {"contract", "uncertain-terminal"})

    path =
      Path.join(System.tmp_dir!(), "sbx-terminal-codec-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)

    payloads =
      for operation <- [
            :terminal,
            :terminal_close,
            :terminal_idle,
            :terminal_session,
            :terminal_consumer
          ] do
        {:ok, bytes} =
          Codec.encode(%{record | last_error: %{record.last_error | operation: operation}})

        Base.encode64(bytes)
      end

    File.write!(path, Enum.join(payloads, "\n"))

    code = """
    for line <- File.read!(hd(System.argv())) |> String.split("\\n") do
      {:ok, record} = SmolBox.Store.Codec.decode(Base.decode64!(line))
      IO.puts(Atom.to_string(record.last_error.operation))
    end
    """

    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path]

    assert {output, 0} =
             System.cmd(System.find_executable("elixir"), args,
               env: [{"ERL_FLAGS", "+S 2:2"}],
               stderr_to_stdout: true
             )

    assert String.split(String.trim(output), "\n") ==
             ~w(terminal terminal_close terminal_idle terminal_session terminal_consumer)
  end

  test "dead session handles cannot accumulate when terminate cleanup was bypassed" do
    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :never -> :ok
        end
      end)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    table = :ets.new(:dead_terminals, [:set])
    handle = %SmolBox.Terminal.Handle{pid: pid, token: make_ref()}
    :ets.insert(table, {{"scope", "dead"}, handle})
    Server.retire_closed(table, 1)
    assert :ets.tab2list(table) == []
  end
end
