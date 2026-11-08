defmodule SmolBox.NativeBranchCompletionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branch, Command, DiskExpansion, Execution, ExecutionSpec, ManagedMachine}
  alias SmolBox.Embedded.{BranchCompletion, Identity, NativeGrowth}
  alias SmolBox.Store.{Codec, MachineOps, Memory, NativeBranchContract}

  for hold <- [true, false] do
    test "native held=#{hold} unknown completion requires explicit resolution with historical proof and current observations" do
      NativeBranchContract.resolve_completed(Memory, start_supervised!(Memory), unquote(hold))
    end

    test "native held=#{hold} completion atomically binds current source and child with retained backing" do
      NativeBranchContract.complete(Memory, start_supervised!(Memory), unquote(hold))
    end

    test "native held=#{hold} records retain immutable root and exact child history across ordinary lifecycle" do
      {source, child, result, _} =
        NativeBranchContract.complete(Memory, start_supervised!(Memory), unquote(hold))

      completion = child.branch.native_authority.completion

      assert {:ok, receipt, %{"storage_gib" => 1, "overlay_gib" => 1}, _} =
               NativeGrowth.head(child)

      assert receipt == completion.child
      expected = DiskExpansion.expected(child)
      assert expected.backend_identity.receipt == completion.child
      assert expected.backend_identity.pid_identity == nil
      assert {:ok, history} = NativeGrowth.transitions(child)
      assert length(history) == if(unquote(hold), do: 0, else: 1)
      assert Identity.valid?(expected.backend_identity)

      for changed <- [
            put_in(child.branch.state, if(unquote(hold), do: :ready, else: :held)),
            %{child | created_machine: source.created_machine},
            put_in(child.branch.native_authority.completion, nil),
            put_in(
              child.observed_machine.backend_identity.receipt,
              source.observed_machine.backend_identity.receipt
            ),
            put_in(child.observed_machine.backend_identity.material_history, nil)
          ] do
        if changed != child, do: assert({:error, _} = Codec.encode(changed))
      end

      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{
                   branch: %{
                     child.branch
                     | native_authority: %{child.branch.native_authority | completion: nil}
                   }
                 },
                 1200
               )

      refute BranchCompletion.valid?(%{completion | schema: 2})
      assert {:error, _} = ManagedMachine.update(child, %{branch: nil}, 1200)

      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{
                   spec: %{child.spec | profile: %{child.spec.profile | id: "replacement-policy"}}
                 },
                 1200
               )

      changed_fingerprint = String.duplicate("0", 64)
      changed_authority = %{child.branch.native_authority | fingerprint: changed_fingerprint}

      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{
                   fingerprint: changed_fingerprint,
                   branch: %{child.branch | native_authority: changed_authority}
                 },
                 1200
               )

      if unquote(hold) do
        replacement = %{completion | identity_sha256: String.duplicate("0", 64)}
        assert BranchCompletion.valid?(replacement)

        assert {:error, _} =
                 ManagedMachine.update(
                   child,
                   %{
                     branch: %{
                       child.branch
                       | native_authority: %{
                           child.branch.native_authority
                           | completion: replacement
                         }
                     }
                   },
                   1200
                 )
      end

      stopped = %{
        result.child
        | state: :stopped,
          backend_identity: %{result.child.backend_identity | pid_identity: nil}
      }

      assert {:ok, stopped_record} =
               ManagedMachine.update(child, %{state: :stopped, observed_machine: stopped}, 1200)

      assert stopped_record.created_machine == child.created_machine
      assert {:ok, encoded} = Codec.encode(stopped_record)
      assert {:ok, ^stopped_record} = Codec.decode(encoded)
      assert Branch.usable?(child) == not unquote(hold)

      assert {:ok, command} = Command.new(["true"])

      assert {:ok, spec} =
               ExecutionSpec.new(
                 scope: child.scope,
                 id: "child-command",
                 profile: child.spec.profile,
                 artifact: child.spec.artifact,
                 command: command
               )

      assert {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
      assert {:ok, execution} = Execution.new(spec, fingerprint, 1201)

      source_spec = %{spec | scope: source.scope, id: "source-command"}

      assert {:ok, source_fingerprint} =
               ExecutionSpec.fingerprint(source_spec, String.duplicate("k", 32))

      assert {:ok, source_execution} = Execution.new(source_spec, source_fingerprint, 1201)

      assert {:ok, _, source_command} = MachineOps.attach(source, source_execution, 1201)

      assert {:error, _} =
               Execution.validate(
                 update_in(
                   source_command.backend_assignment.creation,
                   &Map.delete(&1, "checkpointable")
                 )
               )

      if unquote(hold) do
        assert {:error, _} = MachineOps.attach(child, execution, 1201)
      else
        assert {:ok, _, attached} = MachineOps.attach(child, execution, 1201)
        assert attached.created_machine.backend_identity == expected.backend_identity
        assert {:ok, <<"smolbox-record-v30\0", _::binary>> = bytes} = Codec.encode(attached)
        assert {:ok, ^attached} = Codec.decode(bytes)
      end
    end
  end
end
