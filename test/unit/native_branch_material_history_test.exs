defmodule SmolBox.NativeBranchMaterialHistoryTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchPublication,
    BranchReleaseTransition,
    CaptureResolutionTransition,
    CaptureTransition,
    GrowthTransition,
    Identity,
    MaterialHistory
  }

  alias SmolBox.{Command, Execution, ExecutionSpec, ManagedMachine}
  alias SmolBox.Store.{Codec, MachineOps, NativeCaptureContract}

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "branch-material-history-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))

  defp proof(%{"kind" => kind, "transition" => wire}) do
    type =
      case kind do
        "growth" -> GrowthTransition
        "capture" -> CaptureTransition
        "resolution" -> CaptureResolutionTransition
        "branch" -> BranchPublication
      end

    assert {:ok, value} = type.from_wire(wire)
    value
  end

  defp proofs(row), do: Enum.map(row["events"], &proof/1)

  test "every synthetic platform prefix retains exact material authority and disk accounting" do
    for row <- @rows do
      history = proofs(row)

      for count <- 1..7 do
        prefix = Enum.take(history, count)
        expected = List.last(prefix).receipt

        assert {:ok, ^expected, _} =
                 MaterialHistory.chain(prefix, row["origin"], row["initial_sizes"])
      end

      assert {:ok, receipt, sizes} =
               MaterialHistory.chain(history, row["origin"], row["initial_sizes"])

      assert receipt == row["receipt"] and sizes == row["sizes"]
      last = List.last(history)
      identity = %Identity{receipt: receipt, transition: last, material_history: history}
      assert Identity.valid?(identity)
      refute Identity.valid?(%{identity | material_history: nil})
      refute Identity.valid?(%{identity | material_history: Enum.drop(history, 1)})
      refute Identity.valid?(%{identity | receipt: last.previous})
      refute inspect(last) =~ row["origin"]["owner_token"]
      assert BranchPublication.to_wire(last) == List.last(row["events"])["transition"]
      assert :error = BranchPublication.from_wire(last)
    end
  end

  test "individually valid branch links cannot replace known immutable checkpoint lineage or platform state" do
    for row <- @rows do
      history = proofs(row)
      previous = Enum.drop(history, -1)
      original = List.last(history)

      for field <- ~w(growth capture checkpoint lineage platform) do
        changed = crossed(original, field)
        assert BranchPublication.valid?(changed)

        assert :error =
                 MaterialHistory.chain(previous ++ [changed], row["origin"], row["initial_sizes"])
      end

      assert :error =
               MaterialHistory.chain(Enum.reverse(history), row["origin"], row["initial_sizes"])

      assert :error =
               MaterialHistory.chain(history ++ [original], row["origin"], row["initial_sizes"])

      assert :error =
               MaterialHistory.chain(
                 List.delete_at(history, 2),
                 row["origin"],
                 row["initial_sizes"]
               )

      assert :error =
               MaterialHistory.chain(history, row["origin"], %{
                 "storage_gib" => 2,
                 "overlay_gib" => 1
               })
    end
  end

  test "a new valid branch proof cannot reuse an earlier growth operation id" do
    for row <- @rows do
      history = proofs(row)
      original = List.last(history)

      changed = %{
        original
        | change: put_in(original.change, ~w(child_origin intent child operation_id), "grow.1")
      }

      changed = rebind(changed)
      assert BranchPublication.valid?(changed)

      assert :error =
               MaterialHistory.chain(
                 Enum.drop(history, -1) ++ [changed],
                 row["origin"],
                 row["initial_sizes"]
               )
    end
  end

  test "child release is its own root-linked sealed history and cannot grant later source mutation" do
    rows = @fixtures |> Path.join("branch-creation-v1.json") |> File.read!() |> Jason.decode!()
    release = Enum.find_value(rows, & &1["completion"]["release"])
    assert {:ok, proof} = BranchReleaseTransition.from_wire(release)
    sizes = %{"storage_gib" => 1, "overlay_gib" => 1}
    assert {:ok, receipt, ^sizes} = MaterialHistory.chain([proof], proof.previous, sizes)
    assert receipt == proof.receipt

    assert Identity.valid?(%Identity{
             receipt: receipt,
             transition: proof,
             material_history: [proof]
           })

    refute Identity.valid?(%Identity{receipt: receipt, transition: proof})
    assert BranchReleaseTransition.to_wire(proof) == release

    [row | _] = @rows
    [growth | _] = row["events"]
    wire = %{growth["transition"] | "previous" => receipt, "receipt" => receipt}
    wire = put_in(wire, ~w(change previous), receipt["material"])
    change = wire["change"]
    request = ordered(change["request"], ~w(storage_gib overlay_gib))

    payload =
      change
      |> Map.put("request", request)
      |> Map.put("previous", BranchCanonical.ordered(receipt["material"], :material))

    payload =
      ordered(
        payload,
        ~w(operation_id request previous immutable_sha256 previous_storage_gib previous_overlay_gib storage_gib overlay_gib)
      )

    next = %{
      receipt["material"]
      | "revision" => 2,
        "operation_id" => change["operation_id"],
        "request_sha256" => BranchCanonical.digest(request),
        "record_sha256" => String.duplicate("0", 64)
    }

    next = %{
      next
      | "chain_sha256" =>
          BranchCanonical.digest([
            "smolbox-material-transition-v2",
            payload,
            next["record_sha256"]
          ])
    }

    assert {:ok, growth} = GrowthTransition.from_wire(put_in(wire, ~w(receipt material), next))
    assert :error = MaterialHistory.chain([proof, growth], proof.previous, sizes)

    assert :error =
             MaterialHistory.chain([proof], proof.previous, %{
               "storage_gib" => 2,
               "overlay_gib" => 1
             })
  end

  test "attached native command evidence selects v29 and rejects every older or unsafe envelope" do
    for row <- @rows do
      execution = attached()
      assert execution.created_machine.backend_identity.receipt == row["origin"]
      assert {:ok, original_bytes} = Codec.encode(execution)
      history = proofs(row)
      last = List.last(history)

      identity = %Identity{
        receipt: last.receipt,
        transition: last,
        material_history: history
      }

      machine = %{
        execution.created_machine
        | backend_identity: identity,
          storage_gb: row["sizes"]["storage_gib"],
          overlay_gb: row["sizes"]["overlay_gib"]
      }

      evolved = %{execution | created_machine: machine}
      assert :ok = Execution.validate(evolved)
      assert {:ok, <<"smolbox-record-v29\0", body::binary>> = bytes} = Codec.encode(evolved)
      assert {:ok, ^evolved} = Codec.decode(bytes)

      for version <- 1..28,
          do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

      assert {:error, _} = Codec.decode(bytes <> "trailing")

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v29\0" <> :erlang.term_to_binary(evolved, compressed: 9)
               )

      assert {:error, _} =
               Codec.encode(
                 put_in(evolved.created_machine.backend_identity.material_history, nil)
               )

      assert {:ok, ^original_bytes} = Codec.encode(execution)
      [_prefix, old_body] = :binary.split(original_bytes, <<0>>)
      assert {:error, _} = Codec.decode("smolbox-record-v29\0" <> old_body)
    end
  end

  defp attached do
    record = NativeCaptureContract.fixture()

    observed = %{
      record.observed_machine
      | state: :running,
        backend_identity: %{record.observed_machine.backend_identity | pid_identity: [123, 456]}
    }

    {:ok, running} =
      ManagedMachine.update(record, %{state: :running, observed_machine: observed}, 1100)

    {:ok, command} = Command.new(["true"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: record.scope,
        id: "branch-history",
        profile: record.spec.profile,
        artifact: record.spec.artifact,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, execution} = Execution.new(spec, fingerprint, 1101)
    assert {:ok, _, attached} = MachineOps.attach(running, execution, 1101)
    attached
  end

  defp crossed(proof, field) do
    change = proof.change

    change =
      case field do
        "growth" ->
          Map.merge(change, %{
            "previous_growth_sha256" => String.duplicate("0", 64),
            "growth_sha256" => String.duplicate("0", 64)
          })

        "capture" ->
          Map.merge(change, %{
            "previous_capture_sha256" => String.duplicate("0", 64),
            "capture_sha256" => String.duplicate("0", 64)
          })

        "checkpoint" ->
          Map.put(change, "checkpoint_head", String.duplicate("0", 32))

        "lineage" ->
          Map.merge(change, %{
            "previous_lineage" => 789,
            "lineage" => if(change["platform"] == "macos", do: 789, else: 456)
          })

        "platform" ->
          Map.merge(change, %{
            "platform" => if(change["platform"] == "macos", do: "linux", else: "macos"),
            "lineage" => 456,
            "previous_lineage" => 456
          })
      end

    rehash(%{proof | change: change})
  end

  defp rebind(proof) do
    intent = proof.change["child_origin"]["intent"]

    digest =
      BranchCanonical.digest([
        "smolbox-initial-branch-admission-v1",
        "9f446ae00219148ca4a703914f44a8e2fab11655",
        "shared-materialized-ram",
        BranchCanonical.ordered(intent["source"], :receipt),
        BranchCanonical.ordered(intent["child"], :child),
        BranchCanonical.ordered(intent["approval"], :approval),
        BranchCanonical.ordered(intent["plan"], :plan),
        intent["source_pid"],
        intent["epoch"]
      ])

    rehash(%{
      proof
      | change: put_in(proof.change, ~w(child_origin intent request_sha256), digest)
    })
  end

  defp rehash(proof) do
    intent = proof.change["child_origin"]["intent"]

    material = %{
      proof.receipt["material"]
      | "operation_id" => intent["child"]["operation_id"],
        "request_sha256" => intent["request_sha256"],
        "chain_sha256" =>
          BranchCanonical.digest([
            "smolbox-branch-source-transition-v1",
            BranchCanonical.ordered(proof.change, :source_change),
            proof.receipt["material"]["record_sha256"]
          ])
    }

    %{proof | receipt: Map.put(proof.receipt, "material", material)}
  end

  defp ordered(value, fields),
    do: %Jason.OrderedObject{values: Enum.map(fields, &{&1, Map.fetch!(value, &1)})}
end
