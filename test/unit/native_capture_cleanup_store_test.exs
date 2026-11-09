defmodule SmolBox.NativeCaptureCleanupStoreTest do
  use ExUnit.Case, async: true
  alias SmolBox.{CheckpointCapture, ManagedMachine}
  alias SmolBox.Embedded.NativeCaptureCleanup
  alias SmolBox.Store.{Codec, CodecNativeCaptureCleanup, Contract, Memory, NativeCaptureContract}

  for disposition <- [:completed, :resolved, :deleted, :aborted] do
    test "Memory releases #{disposition} native capture only with exact immutable cleanup authority" do
      NativeCaptureContract.cleanup_release(
        Memory,
        start_supervised!(Memory),
        unquote(disposition)
      )
    end
  end

  test "v26 rejects old envelopes, proof substitution and smuggled default fields" do
    record = NativeCaptureContract.cleanup_release(Memory, start_supervised!(Memory), :resolved)
    assert {:ok, <<"smolbox-record-v26\0", body::binary>> = bytes} = Codec.encode(record)

    for version <- 1..25,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "trailing")
    capture = record.captures["resolve-1"]
    refute NativeCaptureCleanup.valid?(nil)
    assert {:error, _} = CheckpointCapture.validate(%{capture | released_at_ms: nil})

    assert {:error, _} =
             CheckpointCapture.validate(%{
               capture
               | native_source_receipt:
                   Map.put(
                     capture.native_source_receipt,
                     "owner_token",
                     String.duplicate("f", 64)
                   )
             })

    for changed <- [
          %{capture | native_cleanup: %{capture.native_cleanup | kind: :aborted}},
          %{
            capture
            | native_cleanup: %{
                capture.native_cleanup
                | receipt: %{capture.native_cleanup.receipt | operation_id: "other"}
              }
          }
        ],
        do:
          assert(
            {:error, _} =
              Codec.encode(%{record | captures: Map.put(record.captures, "resolve-1", changed)})
          )

    assert CodecNativeCaptureCleanup.required?(record)
    assert :ok = ManagedMachine.validate(record)
  end

  test "legacy native histories preserve their envelope and reject new fields even when nil" do
    record = NativeCaptureContract.entered_resolution(Memory, start_supervised!(Memory), false)

    legacy = %{
      record
      | captures:
          Map.new(record.captures, fn {id, capture} ->
            {id, %{capture | native_source_receipt: nil}}
          end)
    }

    assert {:ok, <<"smolbox-record-v25\0", body::binary>> = bytes} = Codec.encode(legacy)
    assert {:ok, ^legacy} = Codec.decode(bytes)
    raw = :erlang.binary_to_term(body)

    for field <- [:native_source_receipt, :native_cleanup] do
      poisoned =
        put_in(raw, [Access.key!(:captures), Access.key!("resolve-1"), Access.key(field)], nil)

      assert {:error, _} =
               Codec.decode("smolbox-record-v25\0" <> :erlang.term_to_binary(poisoned))
    end
  end

  test "fresh BEAM loads v26 cleanup vocabulary before safe decoding" do
    record = NativeCaptureContract.cleanup_release(Memory, start_supervised!(Memory), :aborted)
    assert {:ok, bytes} = Codec.encode(record)

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-cleanup-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code = ~S"""
    [path] = System.argv()
    case path |> File.read!() |> SmolBox.Store.Codec.decode() do
      {:ok, %{captures: captures}} ->
        case Enum.any?(captures, fn {_id, capture} ->
          match?(%SmolBox.Embedded.NativeCaptureCleanup{kind: :aborted,
            receipt: %SmolBox.Embedded.CaptureStagingCleanupReceipt{}}, capture.native_cleanup)
        end) do
          true -> IO.puts("fresh-cleanup")
          false -> System.halt(1)
        end
      _ -> System.halt(1)
    end
    """

    assert {"fresh-cleanup\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end

  test "source authority is frozen at acceptance and cannot be imported through generic changes" do
    store = start_supervised!(Memory)
    {_, running, sent, spec, _, _, _} = NativeCaptureContract.prepare(Memory, store)
    capture = sent.captures[spec.id]
    assert capture.native_source_receipt == running.observed_machine.backend_identity.receipt
    foreign = Map.put(capture.native_source_receipt, "owner_token", String.duplicate("f", 64))

    changed = %{
      sent
      | captures: Map.put(sent.captures, spec.id, %{capture | native_source_receipt: foreign})
    }

    assert {:error, _} = ManagedMachine.validate(changed)
    assert {:error, _} = Codec.encode(changed)

    assert {:error, _} =
             Memory.machine(store, :capture_advance, [
               ManagedMachine.key(sent),
               Contract.guard(sent),
               spec.id,
               :dispatching,
               [state: :unknown, native_source_receipt: foreign],
               1102
             ])

    assert {:ok, ^sent} = Memory.machine(store, :fetch, [ManagedMachine.key(sent)])
  end
end
