defmodule SmolBox.NativePartialBranchRetirementTest do
  use ExUnit.Case, async: true

  alias SmolBox.Backend.{Budget, EmbeddedBranchRetirement, EmbeddedContext}

  alias SmolBox.Embedded.{
    NativeBranchBacking,
    NativeBranchRetirement,
    PartialBranchChildAbsence,
    PartialBranchDisposal
  }

  alias SmolBox.ManagedMachine
  alias SmolBox.Store.{Codec, Memory, NativePartialBranchRetirementContract}

  alias SmolBox.Store.Contract, as: StoreGuard

  alias NativePartialBranchRetirementContract, as: Contract

  for mode <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ["deleted", "resolved_absent"] do
    test "#{mode} provenance=#{provenance} retires only the dependency with original disposal preserved" do
      Contract.complete(Memory, start_supervised!(Memory), unquote(mode), unquote(provenance))
    end
  end

  test "a changed child version rejects stale proof without freeing backing and fresh observation can retry" do
    store = start_supervised!(Memory)
    {parent, child, proof, usage} = Contract.prepare(Memory, store, :held)

    assert {:ok, current} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1201, 10_000])

    assert {:error, _} = Contract.advance(Memory, store, parent, current, proof, 1202)
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    fresh = Contract.proof(current)
    assert fresh.request != proof.request
    assert {:ok, retired} = Contract.advance(Memory, store, parent, current, fresh, 1202)
    saved = retired.branch.native_authority.retirement

    assert {:ok, claimed} =
             Memory.machine(store, :claim, [ManagedMachine.key(retired), "owner", 1203, 10_000])

    assert claimed.branch.native_authority.retirement == saved
    assert {:ok, request} = NativeBranchRetirement.request(claimed)
    assert request == saved.proof.request
  end

  test "retirement cannot be erased rewritten or downgraded into disposal-only authority" do
    {_, retired, _, _} = Contract.complete(Memory, start_supervised!(Memory), :initial_release)

    for replacement <- [
          nil,
          %{retired.branch.native_authority.retirement | version: retired.version}
        ] do
      assert {:error, _} =
               ManagedMachine.update(
                 retired,
                 %{
                   branch: %{
                     retired.branch
                     | native_authority: %{
                         retired.branch.native_authority
                         | retirement: replacement
                       }
                   }
                 },
                 1300
               )
    end

    stripped = put_in(retired.branch.native_authority.retirement, nil)

    for version <- 1..46 do
      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v#{version}" <> <<0>> <> :erlang.term_to_binary(stripped)
               )
    end

    assert {:error, _} =
             ManagedMachine.update(
               retired,
               %{
                 branch: %{
                   retired.branch
                   | state: :disposed,
                     retired_at_ms: nil,
                     native_authority: %{retired.branch.native_authority | retirement: nil}
                 }
               },
               1300
             )
  end

  test "a valid rebound absence of a different historical disposal cannot retire the saved dependency" do
    store = start_supervised!(Memory)
    {parent, child, proof, usage} = Contract.prepare(Memory, store, :held)
    disposal = proof.request["disposal"]
    disposal = %{disposal | "completion" => "resolved_absent"}

    disposal =
      Map.put(
        disposal,
        "proof_sha256",
        PartialBranchDisposal.proof_digest(disposal)
      )

    request = %{proof.request | "disposal" => disposal}

    request =
      Map.put(request, "request_sha256", PartialBranchChildAbsence.request_digest(request))

    wrong = Contract.proof_from_request(request)
    assert PartialBranchChildAbsence.valid?(wrong)
    assert {:error, _} = Contract.advance(Memory, store, parent, child, wrong, 1201)
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert Contract.fetch(Memory, store, child).branch.state == :disposed
  end

  test "source deletion retains backing until the separate partial backing action is accepted" do
    store = start_supervised!(Memory)
    {parent, child, _, _} = Contract.complete(Memory, store, :held)

    assert {:ok, deleting} =
             Memory.machine(store, :request, [
               ManagedMachine.key(parent),
               :delete,
               parent.version,
               1300
             ])

    assert {:ok, source} =
             Memory.machine(store, :write, [
               ManagedMachine.key(parent),
               StoreGuard.guard(deleting),
               [
                 state: :deleted,
                 operation: nil,
                 phase: nil,
                 operation_deadline_ms: nil,
                 absence_at_ms: 1301
               ],
               1301
             ])

    assert {:ok, usage} = Memory.usage(store, parent.worker_id)
    assert usage == child.branch.spec.policy.resources
    assert NativeBranchBacking.pair?(source, child)

    assert {:ok, pending} =
             Memory.machine(store, :branch_backing_accept, [
               ManagedMachine.key(source),
               StoreGuard.guard(source),
               child.id,
               child.version,
               true,
               1302
             ])

    assert pending.branch.state == :backing_pending
    assert Contract.fetch(Memory, store, child) == pending
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "completed-child observation cannot accept an partial retirement scope" do
    {_, child, proof, _} = Contract.complete(Memory, start_supervised!(Memory), :held)
    assert EmbeddedBranchRetirement.intent(child) == nil

    context = %EmbeddedContext{
      config: nil,
      server: self(),
      pinned: true,
      quiesced: true,
      epoch: PartialBranchChildAbsence.epoch(proof.request),
      branch_retirement: child,
      spec: child.spec,
      assignment: child.backend_assignment,
      name: child.machine_name,
      profile: child.spec.profile,
      identity: nil
    }

    refute EmbeddedBranchRetirement.scope?(context)

    assert {:error, _} =
             EmbeddedBranchRetirement.coordinate(
               context,
               child.machine_name,
               %Budget{timeout_ms: 1000, max_request_bytes: 131_072, max_response_bytes: 131_072},
               fn _, _, _ -> flunk("partial proof reached completed-child observation") end
             )
  end

  test "v46 rejects oversized and disposal-only records and does not relabel old records" do
    {_, child, _, _} = Contract.prepare(Memory, start_supervised!(Memory), :held)
    assert {:ok, <<"smolbox-record-v45", 0, body::binary>> = original} = Codec.encode(child)
    assert {:error, _} = Codec.decode("smolbox-record-v46" <> <<0>> <> body)

    assert {:error, _} =
             Codec.decode("smolbox-record-v46" <> <<0>> <> :binary.copy("x", 16_777_216))

    assert {:ok, ^child} = Codec.decode(original)
  end

  test "a fresh BEAM reader decodes v46 without native assets and earlier disposal bytes stay unchanged" do
    {_, retired, _, _} = Contract.complete(Memory, start_supervised!(Memory), :held)
    bytes = Contract.roundtrip(retired)

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-partial-retirement-#{System.unique_integer([:positive])}"
      )

    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code =
      ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, record} -> if SmolBox.ManagedMachine.validate(record) == :ok, do: IO.puts("fresh-partial-retirement"), else: System.halt(1); _ -> System.halt(1) end/

    assert {"fresh-partial-retirement\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end
end
