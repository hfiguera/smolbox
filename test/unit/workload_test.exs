defmodule SmolBox.WorkloadTest do
  use ExUnit.Case, async: true
  alias SmolBox.{MachineSpec, ManagedMachine, ManagedMachineSpec, Workload}
  alias SmolBox.Store.{Codec, MachineContract}

  test "startup configuration is opt-in, immutable and redacted" do
    {:ok, inherited} = Workload.new()
    {:ok, spec} = MachineSpec.new("app", "/approved/app.smolmachine", workload: inherited)
    {:ok, wire} = MachineSpec.to_wire(spec)
    assert wire["entrypoint"] == [] and wire["cmd"] == []
    refute Map.has_key?(wire, "workdir")

    {:ok, workload} =
      Workload.new(
        entrypoint: ["python3"],
        cmd: ["-c", "private-code"],
        env: [{"Z", "secret"}, {"A", "value"}],
        workdir: "/app"
      )

    {:ok, wire} = MachineSpec.to_wire(%{spec | workload: workload})
    assert wire["entrypoint"] == ["python3"] and wire["cmd"] == ["-c", "private-code"]

    assert wire["env"] == [
             %{"name" => "A", "value" => "value"},
             %{"name" => "Z", "value" => "secret"}
           ]

    assert wire["workdir"] == "/app" and wire["restart"] == %{"policy" => "never"}
    refute inspect(workload) =~ "secret"
    refute inspect(workload) =~ "private-code"

    assert {:error, _} =
             MachineSpec.new("app", "/approved/app.smolcheckpoint",
               source: :checkpoint,
               workload: workload
             )
  end

  test "unqualified restart policies and malformed configuration fail before dispatch" do
    for policy <- [:always, :on_failure, :unless_stopped, "never", nil] do
      assert {:error, %{category: :unsupported_capability}} = Workload.new(restart: policy)
    end

    for options <- [
          [entrypoint: "sh"],
          [cmd: [""]],
          [cmd: ["a\0"]],
          [cmd: [<<255>>]],
          [cmd: List.duplicate("a", 256)],
          [cmd: [String.duplicate("a", 65_537)]],
          [env: [{"A", "1"}, {"A", "2"}]],
          [env: [{"BAD=KEY", "x"}]],
          [workdir: "relative"],
          [workdir: "/a\0"],
          [workdir: String.duplicate("/", 4097)],
          [restart: :never, restart: :never],
          [unknown: true]
        ] do
      assert {:error, _} = Workload.new(options)
    end

    assert {:error, _} = Workload.validate(%{})
    assert {:error, _} = Workload.validate(Map.put(%Workload{}, :extra, true))
  end

  test "console event and framing bounds apply across incremental chunks" do
    alias SmolBox.Transport.Capture
    state = Capture.new(%{mode: {:logs, 100_000, nil}, max_bytes: 1_000_000})
    {:ok, state} = Capture.feed(state, String.duplicate("data:\n\n", 10_000))
    assert {:error, %{category: :output_limit}} = Capture.feed(state, "data:\n\n")
    fresh = Capture.new(%{mode: {:logs, 1_000_000, nil}, max_bytes: 1_000_000})

    assert {:error, %{category: :output_limit}} =
             Capture.feed(fresh, "data: " <> String.duplicate("x", 140_000))

    assert {:error, %{category: :output_limit}} =
             Capture.feed(fresh, String.duplicate("x", 262_145))
  end

  test "v8 persists workload intent without changing prior no-workload envelopes" do
    original = MachineContract.record()
    {:ok, workload} = Workload.new(cmd: ["server"], env: [{"B", "2"}, {"A", "1"}])
    spec = %{original.spec | workload: workload}
    key = :binary.copy(<<1>>, 32)
    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, key)
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)
    reordered = %{spec | workload: %{workload | env: Enum.reverse(workload.env)}}
    assert ManagedMachineSpec.fingerprint(reordered, key) == {:ok, fingerprint}
    refute ManagedMachineSpec.fingerprint(original.spec, key) == {:ok, fingerprint}
    assert {:ok, <<"smolbox-record-v8\0", payload::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for prefix <- [
          "smolbox-record-v4\0",
          "smolbox-record-v5\0",
          "smolbox-record-v6\0",
          "smolbox-record-v7\0"
        ] do
      assert {:error, _} = Codec.decode(prefix <> payload)
    end

    assert {:error, _} = Codec.decode(bytes <> "extra")

    assert {:error, _} =
             Codec.decode("smolbox-record-v8\0" <> :erlang.term_to_binary(record, compressed: 9))

    assert {:error, _} = Codec.decode("smolbox-record-v8\0" <> :erlang.term_to_binary(original))

    assert {:error, _} =
             Codec.encode(%{record | spec: %{spec | workload: %{workload | restart: :always}}})

    assert {:ok, <<"smolbox-record-v5\0", old_payload::binary>> = old} = Codec.encode(original)
    refute Map.has_key?(:erlang.binary_to_term(old_payload).spec, :workload)
    assert {:ok, ^original} = Codec.decode(old)

    extended = %{
      original
      | spec: %{original.spec | profile: %{original.spec.profile | execution_ms: 600_000}}
    }

    assert {:ok, <<"smolbox-record-v6\0", _::binary>> = old} = Codec.encode(extended)
    assert {:ok, ^extended} = Codec.decode(old)
  end
end
