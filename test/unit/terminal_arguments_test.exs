defmodule SmolBox.TerminalArgumentsTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Execution, ExecutionSpec, Files}
  alias SmolBox.Runtime.ExecutionSupport
  alias SmolBox.Store.{Codec, Contract, Memory}
  alias SmolBox.Terminal.Spec

  defmodule Reader do
    def capabilities(caps), do: {:ok, caps}
  end

  test "older store readers continue serving empty arguments and reject the new envelope" do
    store = start_supervised!(Memory)
    {:ok, caps} = Memory.capabilities(store)
    config = %{store: {Reader, Map.delete(caps, :terminal_arguments)}}
    {legacy, _} = record([])
    assert :ok = ExecutionSupport.check(config, legacy)
    {arguments, _} = record(["/workspace/script"])

    assert {:error, %{category: :unsupported_capability, operation: :terminal}} =
             ExecutionSupport.check(config, arguments)

    assert :ok = ExecutionSupport.check(%{store: {Reader, caps}}, arguments)
  end

  test "arguments preserve empty values and metacharacters within explicit bounds" do
    args = ["", "a b", "$(touch /workspace/unwanted)", "--", "λ"]
    assert {:ok, %Spec{args: ^args}} = Spec.new(program: "python3", args: args)

    for args <- [
          nil,
          "one",
          ["x" | "tail"],
          ["a\0b"],
          [<<255>>],
          [String.duplicate("x", 4097)],
          List.duplicate("", 65),
          List.duplicate(String.duplicate("x", 4096), 5)
        ] do
      assert {:error, %{category: :validation}} = Spec.new(args: args)
    end
  end

  test "empty arguments preserve the pre-upgrade fingerprint and v7 record format" do
    {spec, record} = record([])
    # Captured from commit 41cc4592 using its original Spec, fingerprint and codec.
    assert record.fingerprint ==
             "a96e603666461f77e39e0284d592637833920aefad8e8c1fa861a7d772f30060"

    assert {:ok, encoded} = Codec.encode(record)

    fixture = File.read!("test/fixtures/terminal/record-v7.json") |> Jason.decode!()
    legacy = Base.decode64!(fixture["codec"])
    assert Files.sha256(legacy) == fixture["codec_sha256"]
    assert {:ok, ^record} = Codec.decode(legacy)
    <<"smolbox-record-v7\0", previous_payload::binary>> = legacy
    <<"smolbox-record-v7\0", current_payload::binary>> = encoded
    assert :erlang.binary_to_term(previous_payload) == :erlang.binary_to_term(current_payload)

    assert {:ok, ^record} = Codec.decode(encoded)
    assert spec.command.args == []
  end

  test "ordered arguments get a selective envelope and cannot enter older envelopes" do
    {spec, record} = record(["", "one two", "three"])
    assert {:ok, encoded} = Codec.encode(record)
    assert <<"smolbox-record-v55\0", payload::binary>> = encoded
    assert {:ok, ^record} = Codec.decode(encoded)
    assert {:ok, hash} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))

    assert {:ok, other} =
             ExecutionSpec.fingerprint(
               put_in(spec.command.args, Enum.reverse(spec.command.args)),
               :binary.copy(<<1>>, 32)
             )

    refute hash == other
    assert {:error, %{category: :store}} = Codec.decode("smolbox-record-v7\0" <> payload)
    # A nested extension must not recursively decode arbitrary envelope depth.
    assert {:error, %{category: :store}} =
             Codec.decode("smolbox-record-v55\0" <> :erlang.term_to_binary({encoded, ["nested"]}))

    {_, legacy} = record([])
    {:ok, old} = Codec.encode(legacy)
    <<"smolbox-record-v7\0", body::binary>> = old
    raw = :erlang.binary_to_term(body)
    forged = update_in(raw.spec.command, &Map.put(&1, :args, []))

    assert {:error, %{category: :store}} =
             Codec.decode("smolbox-record-v7\0" <> :erlang.term_to_binary(forged))
  end

  defp record(args) do
    base = Contract.record()
    {:ok, command} = Spec.new(args: args)
    spec = %{base.spec | command: command, inputs: [], outputs: []}
    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, record} = Execution.new(spec, fingerprint, 1000)
    {spec, record}
  end
end
