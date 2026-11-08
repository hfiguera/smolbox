defmodule SmolBox.EmbeddedPortProof do
  @moduledoc false
  alias SmolBox.Backend.Budget
  alias SmolBox.Embedded.{Config, Launch, Port}
  alias SmolBox.Profile

  def run(arguments) do
    {options, [], []} =
      OptionParser.parse(arguments,
        strict: [
          package: :string,
          fixture: :string,
          sha256: :string,
          domain_json: :string,
          output: :string,
          inventory_helper: :string,
          without_rust: :boolean,
          ordinary: :boolean,
          operations: :boolean
        ]
      )

    {ordinary, operations} = proof_scope(options)
    without_rust = prepare_tools(options)

    package = Path.expand(Keyword.fetch!(options, :package))
    fixture = Path.expand(Keyword.fetch!(options, :fixture))
    output = Path.expand(Keyword.fetch!(options, :output))
    :ok = File.mkdir(output)
    :ok = File.chmod(output, 0o700)
    manifest_bytes = File.read!(Path.join(package, "package.json"))
    manifest = Jason.decode!(manifest_bytes)
    identity = manifest["identity"]
    domain = options |> Keyword.fetch!(:domain_json) |> File.read!() |> Jason.decode!()
    %{size: size} = File.stat!(fixture)
    true = size <= 34_359_738_368
    true = file_hash(fixture) == options[:sha256]
    {:ok, profile} = Profile.new("offline-proof", cpus: 1, memory_mb: 512)

    {:ok, config} =
      Config.new(
        id: domain["target_id"],
        package_path: package,
        package_manifest_sha256: hash(manifest_bytes),
        package_identity: identity,
        domain_generation: domain["generation"],
        platform: platform(identity["platform"]),
        architecture: identity["architecture"],
        profiles: [profile],
        artifacts: [
          %{
            "id" => "proof",
            "sha256" => options[:sha256],
            "architecture" => identity["architecture"],
            "path" => fixture,
            "max_bytes" => size
          }
        ],
        capacity: %{slots: 1, cpus: 1, memory_mb: 768, disk_gb: 2},
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256}
      )

    before = inventory()
    save(output, "inventory-before", before)
    preflight_rejections(config)
    ^before = inventory()

    create = %{
      "name" => "smolbox-beam-proof-" <> random(8),
      "owner_token" => random(32),
      "incarnation" => random(16),
      "artifact" => Launch.artifact(hd(config.artifacts)),
      "resources" => %{"cpus" => 1, "memory_mib" => 512, "storage_gib" => 1, "overlay_gib" => 1},
      "labels" => %{"proof" => "owned-beam-port"}
    }

    save(output, "intent", %{"domain" => domain, "create" => create})
    pid = start(config)

    try do
      creation_presence(pid, create, "absent")
      {created, _events, nil} = call(pid, %{"operation" => "create", "create" => create})
      %{"result" => "created", "receipt" => receipt} = created
      save(output, "receipt", receipt)
      Process.put(:proof_receipt, receipt)
      creation_presence(pid, create, "unverified")
      observed(pid, "inspect", receipt, "stopped")
      observed(pid, "start", receipt, "running")

      command = %{
        "argv" => [
          "/bin/sh",
          "-c",
          "printf 'cpu=%s env=%s cwd=%s user=%s\\n' \"$(nproc)\" \"$SMOLBOX_PROOF\" \"$PWD\" \"$(id -u)\"; printf stderr-witness >&2; exit 7"
        ],
        "env" => %{"SMOLBOX_PROOF" => "set"},
        "workdir" => "/workspace",
        "user" => "65534:65534",
        "max_output_bytes" => 65_536
      }

      {result, events, nil} = call(pid, operation("exec", receipt, %{"command" => command}))
      true = result["completion"] == "exited" and result["observed_exit"] == 7
      witness = collect(events, :stdout)
      true = witness == "cpu=1 env=set cwd=/workspace user=65534\n"
      true = collect(events, :stderr) == "stderr-witness"
      data = :binary.copy(<<0, 255>>, 524_296) <> <<42>>

      options = %{
        "guest_path" => "/workspace/beam-retained.bin",
        "max_bytes" => 2_097_152,
        "mode" => 0o600
      }

      {result, [], nil} =
        call(
          pid,
          operation("write_file", receipt, %{
            "options" => options,
            "total_bytes" => byte_size(data)
          }),
          30_000,
          data
        )

      true = result["completion"] == "completed" and result["native_acknowledged"]
      options = %{options | "mode" => nil}
      read = operation("read_file", receipt, %{"options" => options})
      {result, events, nil} = call(pid, read)
      true = result["completion"] == "completed" and collect(events, :file) == data

      operation_evidence =
        if operations,
          do: operation_checks(pid, create, receipt, command, read, data, output),
          else: %{}

      {:ok, %{epoch: epoch}} = Port.health(pid)
      if ordinary, do: observed(pid, "stop", receipt, "stopped")
      :ok = Port.shutdown(pid)
      wait(pid, :stopped)
      GenServer.stop(pid)

      pid = start(config, false)
      {:ok, %{epoch: fresh}} = Port.health(pid)
      true = fresh != epoch
      creation_presence(pid, create, "unverified")
      observed(pid, "inspect", receipt, "stopped")
      :ok = Port.activate(pid, Config.domain_binding(config))
      observed(pid, "start", receipt, "running")
      {result, events, nil} = call(pid, read)
      true = result["completion"] == "completed" and collect(events, :file) == data

      pid =
        if ordinary,
          do: pid,
          else: interrupt_and_recover(pid, config, create, receipt, read, data, command)

      observed(pid, "stop", receipt, "stopped")
      observed(pid, "delete", receipt, "missing")
      creation_presence(pid, create, "absent")
      Process.delete(:proof_receipt)
      :ok = Port.shutdown(pid)
      wait(pid, :stopped)
      GenServer.stop(pid)
      after_inventory = inventory()
      true = before == after_inventory

      evidence = %{
        "bridge" => "beam-os-port",
        "without_rust" => without_rust,
        "elixir_version" => System.version(),
        "otp_version" => System.otp_release(),
        "identity" => identity,
        "package_manifest_sha256" => config.package_manifest_sha256,
        "fixture_sha256" => config.artifacts |> hd() |> Map.fetch!("sha256"),
        "witness" => witness,
        "observed_exit" => 7,
        "file_bytes" => byte_size(data),
        "file_sha256" => hash(data),
        "fresh_epoch" => true,
        "retained_after_shutdown" => true,
        "retained_after_owner_kill" => !ordinary,
        "deadline_without_exit" => !ordinary,
        "deliberate_process_interruption" => !ordinary,
        "crash_handling_qualified" => false,
        "missing_package_rejected" => true,
        "wrong_package_digest_rejected" => true,
        "domain_mismatch_rejected" => true,
        "intent_absence_before_create" => true,
        "present_intent_unverified_across_epochs" => true,
        "intent_absence_after_owned_delete" => true,
        "owned_deleted" => true,
        "inventory_before" => before,
        "inventory_after" => after_inventory
      }

      evidence = Map.put(evidence, "operation_checks", operation_evidence)

      save(output, "evidence", evidence)

      IO.puts(
        Jason.encode!(%{
          proof: "passed",
          bridge: "beam-os-port",
          witness: witness,
          file_bytes: byte_size(data),
          owned_deleted: true
        })
      )
    after
      cleanup(config, output)
    end
  end

  defp proof_scope(options) do
    ordinary = Keyword.get(options, :ordinary, false)
    operations = Keyword.get(options, :operations, false)

    if !ordinary,
      do: raise(ArgumentError, "explicit --ordinary required; crash validation is deferred")

    {ordinary, operations}
  end

  defp operation_checks(pid, create, receipt, command, read, data, output) do
    sibling_create = %{
      create
      | "name" => "sb-sibling-" <> random(8),
        "owner_token" => random(32),
        "incarnation" => random(16)
    }

    save(output, "sibling-intent", sibling_create)

    {%{"result" => "created", "receipt" => sibling}, [], nil} =
      call(pid, %{"operation" => "create", "create" => sibling_create})

    save(output, "sibling-receipt", sibling)

    try do
      observed(pid, "start", sibling, "running")

      budget = %Budget{
        timeout_ms: 30_000,
        max_request_bytes: 1_048_576,
        max_response_bytes: 16_777_216
      }

      long = %{command | "argv" => ["/bin/sh", "-c", "printf cancel-witness; sleep 5; exit 0"]}

      {:ok, handle} =
        Port.submit(pid, operation("exec", receipt, %{"command" => long}), budget, self())

      receive do
        {:smolbox_embedded, ^handle, {:output, :stdout, "cancel-witness"}} ->
          :ok = Port.acknowledge(pid, handle, byte_size("cancel-witness"))
      after
        10_000 -> raise "missing actual command witness before cancellation"
      end

      sibling_command = %{command | "argv" => ["/bin/sh", "-c", "printf sibling-witness; exit 0"]}
      sibling_exec(pid, sibling, sibling_command)
      :ok = Port.cancel(pid, handle)
      monitor = Process.monitor(pid)
      {cancelled, [], _overlay} = receive_result(pid, monitor, handle, [])
      Process.demonitor(monitor, [:flush])
      true = cancelled["completion"] == "cancelled" and cancelled["observed_exit"] == nil
      sibling_exec(pid, sibling, sibling_command)

      capped = %{
        command
        | "argv" => ["/bin/sh", "-c", "head -c 4096 /dev/zero; exit 0"],
          "max_output_bytes" => 1024
      }

      {limited, events, _overlay} = call(pid, operation("exec", receipt, %{"command" => capped}))
      true = limited["completion"] == "output_limit"
      true = byte_size(collect(events, :stdout)) <= 1024

      {small, [], nil} = call(pid, put_in(read["options"]["max_bytes"], 32))
      true = small["completion"] != "completed" and small["native_acknowledged"] == false

      write = %{
        "operation" => "write_file",
        "receipt" => receipt,
        "options" => %{read["options"] | "mode" => 0o600},
        "total_bytes" => 16
      }

      {:ok, upload_handle} = Port.submit(pid, write, budget, self())

      receive do
        {:smolbox_embedded, ^upload_handle, :accepted} -> :ok
      after
        5000 -> raise "partial upload was not accepted"
      end

      :ok = Port.upload(pid, upload_handle, "partial!")
      :ok = Port.cancel(pid, upload_handle)
      monitor = Process.monitor(pid)
      {partial, [], _overlay} = receive_result(pid, monitor, upload_handle, [])
      Process.demonitor(monitor, [:flush])
      save(output, "partial-upload-outcome", partial)
      %{"result" => "error", "code" => "cancelled", "dispatch" => "not_dispatched"} = partial
      {unchanged, chunks, nil} = call(pid, read)
      true = unchanged["completion"] == "completed" and collect(chunks, :file) == data

      slow = %{
        command
        | "argv" => ["/bin/sh", "-c", "head -c 1048576 /dev/zero; exit 0"],
          "max_output_bytes" => 2_097_152
      }

      {:ok, slow_handle} =
        Port.submit(pid, operation("exec", receipt, %{"command" => slow}), budget, self())

      sibling_exec(pid, sibling, sibling_command)
      {slow_result, bytes} = unread_result(slow_handle, 0)
      save(output, "slow-consumer-outcome", %{"outcome" => slow_result, "bytes" => bytes})
      true = slow_result["completion"] != "exited" and bytes > 0 and bytes <= 262_144
      :ok = Port.acknowledge(pid, slow_handle, bytes)
      sibling_exec(pid, sibling, sibling_command)

      {:ok, %{status: :ready, epoch: epoch}} = Port.health(pid)
      :ok = Port.quiesce(pid, epoch)

      {:error, %{evidence: :not_dispatched}} =
        Port.submit(
          pid,
          operation("exec", sibling, %{"command" => sibling_command}),
          budget,
          self()
        )

      observed(pid, "inspect", sibling, "running")
      {:error, %{category: :identity_conflict}} = Port.quiesce(pid, random(16))

      binding = %{
        "kind" => "embedded",
        "target_id" => receipt["target_id"],
        "generation" => receipt["domain_generation"]
      }

      :ok =
        Port.activate(
          pid,
          %{kind: :embedded, target_id: binding["target_id"], generation: binding["generation"]},
          epoch
        )

      sibling_exec(pid, sibling, sibling_command)

      %{
        "caller_cancel_after_witness" => true,
        "cancel_without_exit" => true,
        "sibling_execution_during_and_after_cancel" => true,
        "output_byte_limit" => true,
        "read_file_byte_limit" => true,
        "partial_upload_cancel_preserves_file" => true,
        "slow_consumer_credit_bytes" => bytes,
        "slow_consumer_completion" => slow_result["completion"],
        "slow_consumer_sibling_survived" => true,
        "epoch_fenced_quiescence" => true,
        "guest_termination_on_cancel_claimed" => false
      }
    after
      observed(pid, "stop", sibling, "stopped")
      observed(pid, "delete", sibling, "missing")
    end
  end

  defp sibling_exec(pid, receipt, command) do
    {%{"completion" => "exited", "observed_exit" => 0}, events, nil} =
      call(pid, operation("exec", receipt, %{"command" => command}))

    true = collect(events, :stdout) == "sibling-witness"
  end

  defp unread_result(handle, bytes) do
    receive do
      {:smolbox_embedded, ^handle, :accepted} ->
        unread_result(handle, bytes)

      {:smolbox_embedded, ^handle, {:output, :stdout, chunk}} ->
        unread_result(handle, bytes + byte_size(chunk))

      {:smolbox_embedded, ^handle, {:terminal, result, nil}} ->
        {result, bytes}

      {:smolbox_embedded, ^handle, _failure} ->
        raise "slow consumer lost bridge observation"
    after
      10_000 -> raise "credit grace did not terminate bounded output"
    end
  end

  defp interrupt_and_recover(pid, config, create, receipt, read, data, command) do
    # Explicit fault mode only: ordinary consumer qualification never kills its owner.
    Process.unlink(pid)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, :killed} -> :ok
    after
      5000 -> raise "owner did not exit"
    end

    pid = start(config, false)
    creation_presence(pid, create, "unverified")
    observed(pid, "inspect", receipt, "stopped")
    :ok = Port.activate(pid, Config.domain_binding(config))
    observed(pid, "start", receipt, "running")
    {result, events, nil} = call(pid, read)
    true = result["completion"] == "completed" and collect(events, :file) == data
    sleep = %{command | "argv" => ["/bin/sleep", "5"], "env" => %{}, "user" => nil}
    {result, [], overlay} = call(pid, operation("exec", receipt, %{"command" => sleep}), 500)
    true = result["observed_exit"] == nil and result["completion"] in ["cancelled", "deadline"]
    true = overlay == nil or overlay.category == :expired
    pid
  end

  defp prepare_tools(options) do
    without_rust = Keyword.get(options, :without_rust, false)

    if without_rust do
      nil = System.find_executable("rustc")
      nil = System.find_executable("cargo")
    end

    Process.put(
      :inventory_helper,
      Path.expand(Keyword.get(options, :inventory_helper, "native/smolbox-port/tests"))
    )

    without_rust
  end

  defp preflight_rejections(config) do
    {:ok, directory} = Launch.directory()

    try do
      :error =
        Launch.prepare(%{config | package_path: Path.join(directory, "missing")}, directory)

      :error =
        Launch.prepare(%{config | package_manifest_sha256: String.duplicate("0", 64)}, directory)
    after
      Launch.cleanup(directory)
    end

    {:ok, pid} = Port.start_link(%{config | domain_generation: random(16)})

    try do
      wait_rejected(pid, 130_000)

      request = %{
        "operation" => "qualify_creation",
        "artifact" => Launch.artifact(hd(config.artifacts)),
        "resources" => %{"cpus" => 1, "memory_mib" => 512, "storage_gib" => 1, "overlay_gib" => 1},
        "user" => nil
      }

      budget = %Budget{
        timeout_ms: 30_000,
        max_request_bytes: 1_048_576,
        max_response_bytes: 16_777_216
      }

      {:error, %{evidence: :not_dispatched}} = Port.submit(pid, request, budget, self())
      :ok = Port.shutdown(pid)
      wait(pid, :stopped)
    after
      GenServer.stop(pid)
    end
  end

  defp wait_rejected(pid, remaining) do
    {:ok, health} = Port.health(pid)

    cond do
      health.status in [:unavailable, :quarantined] ->
        :ok

      remaining <= 0 or health.status in [:ready, :reconciling] ->
        raise "domain mismatch admitted"

      true ->
        Process.sleep(20)
        wait_rejected(pid, remaining - 20)
    end
  end

  defp start(config, activate \\ true) do
    {:ok, pid} = Port.start_link(config)
    Process.put(:proof_owner, pid)
    wait(pid, :reconciling, 130_000)
    if activate, do: :ok = Port.activate(pid, Config.domain_binding(config))
    pid
  end

  defp wait(pid, status, remaining \\ 15_000) do
    {:ok, health} = Port.health(pid)

    cond do
      health.status == status ->
        :ok

      remaining <= 0 or health.status == :quarantined ->
        raise "owner did not reach expected status"

      true ->
        Process.sleep(20)
        wait(pid, status, remaining - 20)
    end
  end

  defp call(pid, operation, timeout \\ 30_000, upload \\ nil) do
    budget = %Budget{
      timeout_ms: timeout,
      max_request_bytes: 1_048_576,
      max_response_bytes: 16_777_216
    }

    monitor = Process.monitor(pid)

    try do
      {:ok, handle} = Port.submit(pid, operation, budget, self())
      if upload, do: upload(pid, handle, upload)
      receive_result(pid, monitor, handle, [])
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp receive_result(pid, monitor, handle, events) do
    receive do
      {:smolbox_embedded, ^handle, :accepted} ->
        receive_result(pid, monitor, handle, events)

      {:smolbox_embedded, ^handle, {:output, stream, bytes}} ->
        :ok = Port.acknowledge(pid, handle, byte_size(bytes))
        receive_result(pid, monitor, handle, [{stream, bytes} | events])

      {:smolbox_embedded, ^handle, {:terminal, outcome, overlay}} ->
        {outcome, Enum.reverse(events), overlay}

      {:smolbox_embedded, ^handle, _failure} ->
        raise "bridge operation lost observation"

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        raise "owner died without completion"
    after
      45_000 -> raise "bridge completion deadline"
    end
  end

  defp upload(_pid, _handle, <<>>), do: :ok

  defp upload(pid, handle, bytes) do
    size = min(byte_size(bytes), 65_536)
    <<chunk::binary-size(^size), rest::binary>> = bytes
    :ok = Port.upload(pid, handle, chunk)
    upload(pid, handle, rest)
  end

  defp creation_presence(pid, create, expected) do
    {%{"result" => "creation_presence", "presence" => ^expected}, [], nil} =
      call(pid, %{"operation" => "inspect_creation", "create" => create})
  end

  defp observed(pid, name, receipt, state) do
    {%{"result" => "observed", "observation" => %{"state" => ^state}}, [], nil} =
      call(pid, operation(name, receipt))

    :ok
  end

  defp operation(name, receipt, fields \\ %{}),
    do: Map.merge(%{"operation" => name, "receipt" => receipt}, fields)

  defp collect(events, stream), do: for({^stream, bytes} <- events, into: "", do: bytes)
  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp file_hash(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp random(size), do: Base.encode16(:crypto.strong_rand_bytes(size), case: :lower)
  defp platform("macos"), do: :macos
  defp platform("linux"), do: :linux

  defp save(output, name, value) do
    path = Path.join(output, name <> ".json")
    {:ok, file} = File.open(path, [:write, :binary, :exclusive, :sync])

    try do
      :ok = IO.binwrite(file, Jason.encode!(value))
      :ok = :file.sync(file)
    after
      File.close(file)
    end

    :ok = File.chmod(path, 0o600)

    {_, 0} =
      System.cmd(System.find_executable("python3"), [
        "-c",
        "import os,sys; f=os.open(sys.argv[1],os.O_RDONLY); os.fsync(f); os.close(f)",
        output
      ])
  end

  defp inventory do
    {body, 0} =
      System.cmd(System.find_executable("python3"), [
        "-c",
        "import sys,json; sys.path.insert(0,sys.argv[1]); from native_proof import snapshot; print(json.dumps(snapshot()))",
        Process.get(:inventory_helper)
      ])

    Jason.decode!(body)
  end

  defp cleanup(_config, output) do
    pid = Process.get(:proof_owner)
    receipt = Process.get(:proof_receipt)

    if pid && Process.alive?(pid) do
      if receipt do
        try do
          observed(pid, "stop", receipt, "stopped")
          observed(pid, "delete", receipt, "missing")
          save(output, "failure-cleanup", %{"owned_deleted" => true})
        rescue
          _unknown -> :ok
        end
      end

      Port.shutdown(pid)
      GenServer.stop(pid)
    end
  end
end

SmolBox.EmbeddedPortProof.run(System.argv())
