defmodule SmolBox.DurableHost.CheckpointRecoveryRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{Client, Error}
  alias SmolBox.DurableHost.{CheckpointDemo, ControllerProcess, Database, Demo, Store}
  alias SmolBox.Store.Codec

  @moduletag :runtime
  @moduletag timeout: 240_000

  setup do
    unique = "checkpoint-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    root = Path.join(System.tmp_dir!(), unique)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    objects = Path.join(root, "objects")
    File.mkdir!(objects)
    File.chmod!(objects, 0o700)

    settings = %{
      "source" => "checkpoint",
      "checkpoint_path" => System.fetch_env!("SMOLBOX_CHECKPOINT_PATH"),
      "checkpoint_sha256" => System.fetch_env!("SMOLBOX_CHECKPOINT_SHA256"),
      "socket" => System.fetch_env!("SMOLBOX_CHECKPOINT_SOCKET"),
      "artifact_root" => objects,
      "id" => unique,
      "partition" => unique,
      "fingerprint_key_file" => key_file(root, "fingerprint.key"),
      "encryption_key_file" => key_file(root, "encryption.key"),
      "ledger" => Path.join(root, "attempts")
    }

    file = Path.join(root, "settings.json")
    File.write!(file, Jason.encode!(settings))
    File.chmod!(file, 0o600)
    {options, spec, directory, store} = Demo.configure(settings)
    [worker] = options[:workers]

    # Retain the partition, keys and creation evidence on any unfinished cleanup.
    # No forced deletion or stop after an uncertain graceful-stop failure.
    on_exit(fn ->
      settled =
        Enum.all?([spec.id, spec.id <> "-independent"], fn id ->
          case Store.fetch(store, {spec.scope, id}) do
            {:ok, %{cleanup: :complete, reservation: nil}} -> true
            {:error, %Error{category: :not_found}} -> true
            _unfinished -> false
          end
        end)

      if settled do
        Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [
          store.partition
        ])

        File.rm_rf!(root)
      else
        IO.puts("Retained checkpoint recovery evidence at #{root}")
      end
    end)

    %{
      settings: settings,
      settings_file: file,
      store: store,
      spec: spec,
      objects: directory,
      worker: worker
    }
  end

  test "separate BEAMs restore independent baselines and recover completed v3 identities", ctx do
    first = run_and_fetch(ctx)
    assert first.state == :completed
    assert :ok = CheckpointDemo.verify_outputs(ctx.objects, {ctx.spec.scope, ctx.spec.id})
    assert attempts(ctx.settings["ledger"]) == 1

    recovered = run_and_fetch(ctx)
    assert recovered.fingerprint == first.fingerprint
    assert recovered.created_machine == first.created_machine
    assert recovered.result == first.result
    assert recovered.artifacts == first.artifacts
    assert attempts(ctx.settings["ledger"]) == 1

    settings = Map.update!(ctx.settings, "id", &(&1 <> "-independent"))
    File.write!(ctx.settings_file, Jason.encode!(settings))
    {_options, spec, _objects, _store} = Demo.configure(settings)
    second = run_and_fetch(%{ctx | spec: spec})
    assert second.state == :completed
    assert second.machine_name != first.machine_name
    assert :ok = CheckpointDemo.verify_outputs(ctx.objects, {spec.scope, spec.id})
    assert attempts(settings["ledger"]) == 2
  end

  for phase <- ["before", "after"] do
    test "fresh BEAM recovers after SIGKILL #{phase} durable checkpoint result commit", ctx do
      phase = unquote(phase)
      {output, status} = ControllerProcess.run(ctx.settings_file, "fault", "result_write", phase)
      assert output =~ "boundary:result_write:#{phase}\n"
      assert status != 0
      assert attempts(ctx.settings["ledger"]) == 1
      assert {:ok, before} = Store.fetch(ctx.store, {ctx.spec.scope, ctx.spec.id})
      assert before.created_machine != nil
      assert before.reservation != nil

      record = run_and_fetch(ctx)
      assert record.fingerprint == before.fingerprint
      assert record.created_machine == before.created_machine
      assert attempts(ctx.settings["ledger"]) == 1

      if phase == "before" do
        assert record.state == :unknown
        assert record.result == nil
        assert record.evidence == :termination_confirmed
      else
        assert record.state == :completed
        assert record.result == before.result
        assert record.result.exit_code == 0
        assert :ok = CheckpointDemo.verify_outputs(ctx.objects, {ctx.spec.scope, ctx.spec.id})
      end
    end
  end

  defp run_and_fetch(ctx) do
    {output, status} =
      ControllerProcess.run(ctx.settings_file, "recover", "result_write", "after")

    assert status == 0, output
    assert output =~ "result:"
    assert {:ok, record} = Store.fetch(ctx.store, {ctx.spec.scope, ctx.spec.id})
    assert {:ok, <<"smolbox-record-v3", 0, _payload::binary>>} = Codec.encode(record)
    assert record.cleanup == :complete
    assert record.absence_at_ms != nil
    assert record.reservation == nil
    assert {:ok, %{slots: 0}} = Store.usage(ctx.store, ctx.worker.client.worker.id)

    assert {:error, %Error{category: :not_found}} =
             Client.inspect_machine(ctx.worker.client, record.machine_name)

    record
  end

  defp attempts(file), do: file |> File.read!() |> String.split("\n", trim: true) |> length()

  defp key_file(root, name) do
    file = Path.join(root, name)
    File.write!(file, :crypto.strong_rand_bytes(32))
    File.chmod!(file, 0o600)
    file
  end
end
