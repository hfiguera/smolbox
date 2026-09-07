defmodule SmolBox.DurableHost.RecoveryRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{Client, Error, Machine}

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.DurableHost.{ControllerProcess, Database, Demo, Store}

  @moduletag :runtime
  @moduletag timeout: 180_000

  @boundaries [
    {"dispatch_intent", "before"},
    {"dispatch_intent", "after"},
    {"first_output_record", "after"},
    {"result_write", "before"},
    {"result_write", "after"},
    {"artifact_put", "before"},
    {"artifact_put", "after"},
    {"artifact_record", "after"},
    {"completion_record", "before"},
    {"completion_record", "after"},
    {"stop", "before"},
    {"stop", "after"},
    {"delete", "before"},
    {"delete", "after"},
    {"absence_record", "before"},
    {"absence_record", "after"},
    {"release", "before"},
    {"release", "after"}
  ]

  setup %{event: event} do
    unique = "case-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    root = Path.join(System.tmp_dir!(), "sbx-recovery-" <> unique)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    objects = Path.join(root, "objects")
    File.mkdir!(objects)
    File.chmod!(objects, 0o700)

    settings = %{
      "url" => System.fetch_env!("SMOLBOX_RUNTIME_URL"),
      "artifact_path" => System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT"),
      "artifact_sha256" => System.fetch_env!("SMOLBOX_PYTHON_SHA256"),
      "artifact_root" => objects,
      "id" => unique,
      "partition" => "runtime-" <> unique,
      "fingerprint_key_file" => key_file(root, "fingerprint.key"),
      "encryption_key_file" => key_file(root, "encryption.key"),
      "ledger" => Path.join(root, "dispatch-attempts"),
      "wait" => event == "first_output_record"
    }

    file = Path.join(root, "settings.json")
    File.write!(file, Jason.encode!(settings))
    File.chmod!(file, 0o600)
    {options, spec, directory, store} = Demo.configure(settings)
    [worker] = options[:workers]
    on_exit(fn -> clean_owned(worker.client, store, {spec.scope, spec.id}, root) end)

    %{
      settings_file: file,
      settings: settings,
      store: store,
      spec: spec,
      objects: directory,
      worker: worker
    }
  end

  for {event, phase} <- @boundaries do
    @tag event: event
    test "fresh BEAM recovers after SIGKILL at #{event}:#{phase}", context do
      event = unquote(event)
      phase = unquote(phase)
      {output, status} = ControllerProcess.run(context.settings_file, "fault", event, phase)
      assert output =~ "boundary:#{event}:#{phase}\n"
      assert status != 0
      key = {context.spec.scope, context.spec.id}
      assert {:ok, before} = Store.fetch(context.store, key)
      assert before.created_machine != nil
      attempts_before = attempts(context.settings["ledger"])
      if before.cleanup != :complete, do: assert(before.reservation != nil)

      {output, status} = ControllerProcess.run(context.settings_file, "recover", event, phase)
      assert status == 0, output
      assert output =~ "result:"
      assert {:ok, recovered} = Store.fetch(context.store, key)
      assert recovered.fingerprint == before.fingerprint
      assert recovered.machine_name == before.machine_name
      assert recovered.cleanup == :complete
      assert recovered.absence_at_ms != nil
      assert recovered.reservation == nil
      assert {:ok, %{slots: 0}} = Store.usage(context.store, context.worker.client.worker.id)

      assert {:error, %Error{category: :not_found}} =
               Client.inspect_machine(context.worker.client, recovered.machine_name)

      verify_outcome(context, event, phase, recovered, attempts_before)
    end
  end

  defp verify_outcome(context, event, phase, record, attempts_before) do
    attempts_after = attempts(context.settings["ledger"])
    assert attempts_after <= 1

    if event == "dispatch_intent" and phase == "before" do
      assert attempts_before == 0
      assert attempts_after == 1
    else
      assert attempts_after == attempts_before
    end

    if {event, phase} in [
         {"dispatch_intent", "after"},
         {"first_output_record", "after"},
         {"result_write", "before"}
       ] do
      assert record.state == :unknown
      assert record.result == nil
      assert record.evidence == :termination_confirmed
    else
      assert record.state == :completed
      assert record.result.exit_code == 0
      key = {record.scope, record.id}
      assert {:ok, "x"} = Directory.read_output(context.objects, key, "count", 32)
      assert {:ok, <<7, 255, 0>>} = Directory.read_output(context.objects, key, "output", 32)
    end
  end

  defp key_file(root, name) do
    file = Path.join(root, name)
    File.write!(file, :crypto.strong_rand_bytes(32))
    File.chmod!(file, 0o600)
    file
  end

  defp attempts(file) do
    case File.read(file) do
      {:ok, bytes} -> length(String.split(bytes, "\n", trim: true))
      {:error, :enoent} -> 0
    end
  end

  defp clean_owned(client, store, key, root) do
    case Store.fetch(store, key) do
      {:ok, %{cleanup: :complete, reservation: nil}} ->
        Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [
          store.partition
        ])

        File.rm_rf!(root)

      {:ok, record} ->
        stop_verified(client, record)

      _unavailable ->
        :ok
    end
  end

  defp stop_verified(client, %{created_machine: creation} = record) when creation != nil do
    case Client.inspect_machine(client, record.machine_name) do
      {:ok, current} ->
        if Machine.same_incarnation?(creation, current),
          do: Client.stop(client, record.machine_name)

      _absent_or_unavailable ->
        :ok
    end
  end

  defp stop_verified(_client, _record), do: :ok
end
