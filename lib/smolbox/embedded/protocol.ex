defmodule SmolBox.Embedded.Protocol do
  @moduledoc false
  alias SmolBox.Embedded.{JSON, Shape}
  alias SmolBox.Validation

  @capabilities ~w(create inspect start stop delete exec read_file write_file qualify_creation inspect_creation)
  @codes ~w(validation unsupported conflict ownership database state native io overload package deadline cancelled)
  @dispatch ~w(not_dispatched may_have_dispatched)
  @completions ~w(exited cancelled deadline output_limit consumer_lost native_error unknown)
  @states ~w(missing stopped running paused pausing frozen failed unreachable identity_unknown)
  @limits %{
    "frame_bytes" => 1_048_576,
    "chunk_bytes" => 65_536,
    "in_flight" => 32,
    "work_workers" => 4,
    "control_workers" => 2,
    "input_queue_encoded_bytes" => 4_194_304,
    "upload_spool_bytes" => 134_217_728,
    "credit_grace_ms" => 1000,
    "writer_grace_ms" => 5000,
    "events_per_request" => 65_536,
    "initial_credit_bytes" => 262_144,
    "initial_credit_events" => 64,
    "event_queue_decoded_bytes" => 8_388_608,
    "event_queue_encoded_bytes" => 12_582_912,
    "transfer_bytes" => 16_777_216,
    "command_ms" => 86_400_000,
    "file_ms" => 600_000,
    "cpus_min" => 1,
    "cpus_max" => 16,
    "memory_mib_min" => 64,
    "memory_mib_max" => 65_536,
    "disk_gib_min" => 1,
    "disk_gib_max" => 1024
  }

  def limits(minor \\ 4)
  def limits(3), do: @limits
  def limits(4), do: Map.put(@limits, "cancel_grace_ms", 3000)
  def capabilities, do: @capabilities
  def version, do: %{major: 1, minor: 4}
  def valid_outcome?(outcome), do: outcome?(outcome)

  def decode(body) do
    with {:ok, message} <- JSON.decode(body), true <- server?(message) do
      {:ok, message}
    else
      _invalid -> :error
    end
  end

  def approve(hello, config) do
    hello?(hello) and hello["preflight"] == %{"status" => "ready"} and
      (hello["minor"] == 3 or config.limits.cancel_grace_ms >= 4000) and
      hello["domain"] == %{"target_id" => config.id, "generation" => config.domain_generation} and
      hello["package"] == config.package_identity and hello["capabilities"] == @capabilities
  end

  defp server?(%{"type" => "hello", "hello" => hello} = message),
    do: Shape.keys?(message, ~w(type hello)) and hello?(hello)

  defp server?(%{"type" => "unavailable", "epoch" => epoch} = message),
    do: Shape.keys?(message, ~w(type epoch)) and Shape.hex?(epoch, 32)

  defp server?(%{"type" => "accepted", "sequence" => 0} = message),
    do: Shape.keys?(message, ~w(type epoch id sequence)) and correlation?(message)

  defp server?(%{"type" => "event", "sequence" => sequence, "event" => event} = message),
    do:
      Shape.keys?(message, ~w(type epoch id sequence event)) and correlation?(message) and
        Validation.integer?(sequence, 1, 65_536) and event?(event)

  defp server?(%{"type" => "terminal", "sequence" => sequence, "outcome" => outcome} = message),
    do:
      Shape.keys?(message, ~w(type epoch id sequence outcome)) and correlation?(message) and
        Validation.integer?(sequence, 0, 65_537) and outcome?(outcome) and
        terminal_sequence?(sequence, outcome)

  defp server?(_message), do: false

  defp terminal_sequence?(0, %{"result" => "error", "dispatch" => "not_dispatched"}), do: true
  defp terminal_sequence?(sequence, _outcome), do: sequence > 0

  defp correlation?(message),
    do:
      Shape.hex?(message["epoch"], 32) and
        Validation.integer?(message["id"], 1, 9_007_199_254_740_991)

  defp hello?(hello),
    do:
      Shape.keys?(hello, ~w(major minor epoch domain package capabilities limits preflight)) and
        hello["major"] == 1 and hello["minor"] in [3, 4] and Shape.hex?(hello["epoch"], 32) and
        domain?(hello["domain"]) and package?(hello["package"]) and
        capabilities?(hello["capabilities"]) and hello["limits"] == limits(hello["minor"]) and
        preflight?(hello["preflight"])

  defp domain?(domain),
    do:
      Shape.keys?(domain, ~w(target_id generation)) and Shape.id?(domain["target_id"]) and
        Shape.hex?(domain["generation"], 32)

  defp package?(package),
    do:
      Shape.keys?(
        package,
        ~w(engine_version smolvm_revision source_sha256 build_sha256 assets_sha256 platform architecture)
      ) and
        Shape.text?(package["engine_version"], 64, false) and
        Shape.hex?(package["smolvm_revision"], 40) and
        Enum.all?(~w(source_sha256 build_sha256 assets_sha256), &Validation.digest?(package[&1])) and
        package["platform"] in ["linux", "macos"] and
        package["architecture"] in ["x86_64", "aarch64"]

  defp capabilities?(capabilities),
    do:
      Validation.list?(capabilities, 10) and Enum.all?(capabilities, &(&1 in @capabilities)) and
        MapSet.size(MapSet.new(capabilities)) == length(capabilities)

  defp preflight?(%{"status" => "ready"} = preflight), do: map_size(preflight) == 1

  defp preflight?(%{"status" => "rejected", "code" => code} = preflight),
    do: map_size(preflight) == 2 and code in @codes

  defp preflight?(_preflight), do: false

  defp event?(event),
    do:
      Shape.keys?(event, ~w(stream data_base64)) and event["stream"] in ~w(stdout stderr file) and
        match?({:ok, _bytes}, Shape.chunk(event["data_base64"]))

  defp outcome?(%{"result" => "created", "receipt" => receipt} = outcome),
    do: Shape.keys?(outcome, ~w(result receipt)) and Shape.receipt?(receipt)

  defp outcome?(%{"result" => "qualified"} = outcome), do: map_size(outcome) == 1

  defp outcome?(%{"result" => "creation_presence", "presence" => presence} = outcome),
    do: Shape.keys?(outcome, ~w(result presence)) and presence in ~w(absent unverified)

  defp outcome?(%{"result" => "observed", "observation" => observation} = outcome),
    do: Shape.keys?(outcome, ~w(result observation)) and observation?(observation)

  defp outcome?(%{"result" => "command"} = outcome), do: command?(outcome)
  defp outcome?(%{"result" => "file"} = outcome), do: file?(outcome)

  defp outcome?(%{"result" => "error", "code" => code, "dispatch" => dispatch} = outcome),
    do:
      Shape.keys?(outcome, ~w(result code dispatch)) and code in @codes and dispatch in @dispatch

  defp outcome?(_outcome), do: false

  defp observation?(observation),
    do:
      Shape.keys?(observation, ~w(state resources pid_identity)) and
        observation["state"] in @states and
        Shape.optional?(observation["resources"], &Shape.resources?/1) and
        Shape.optional?(observation["pid_identity"], &pid?/1) and missing?(observation)

  defp missing?(%{"state" => "missing"} = observation),
    do: observation["resources"] == nil and observation["pid_identity"] == nil

  defp missing?(_observation), do: true

  defp pid?([pid, start]),
    do:
      Validation.integer?(pid, 1, 2_147_483_647) and
        Validation.integer?(start, 1, 18_446_744_073_709_551_615)

  defp pid?(_pid), do: false

  defp command?(outcome),
    do:
      Shape.keys?(
        outcome,
        ~w(result completion dispatch observed_exit running_observed output_bytes)
      ) and
        outcome["completion"] in @completions and outcome["dispatch"] in @dispatch and
        is_boolean(outcome["running_observed"]) and
        Shape.optional?(
          outcome["observed_exit"],
          &Validation.integer?(&1, -2_147_483_648, 2_147_483_647)
        ) and
        Validation.integer?(outcome["output_bytes"], 0, 16_777_216) and command_evidence?(outcome)

  defp command_evidence?(outcome) do
    exit = outcome["observed_exit"]
    running = outcome["running_observed"]
    bytes = outcome["output_bytes"]

    (outcome["completion"] != "exited" or exit != nil) and
      (exit == nil or running) and (bytes == 0 or running) and
      command_dispatch?(outcome)
  end

  defp command_dispatch?(%{"dispatch" => "not_dispatched"} = outcome),
    do:
      outcome["observed_exit"] == nil and not outcome["running_observed"] and
        outcome["output_bytes"] == 0

  defp command_dispatch?(_outcome), do: true

  defp file?(outcome),
    do:
      Shape.keys?(outcome, ~w(result completion dispatch observed_bytes native_acknowledged)) and
        outcome["completion"] in ~w(completed cancelled deadline native_error consumer_lost) and
        outcome["dispatch"] in @dispatch and is_boolean(outcome["native_acknowledged"]) and
        Validation.integer?(outcome["observed_bytes"], 0, 16_777_216) and file_evidence?(outcome)

  defp file_evidence?(outcome),
    do:
      (outcome["completion"] != "completed" or outcome["native_acknowledged"]) and
        (outcome["dispatch"] != "not_dispatched" or
           (not outcome["native_acknowledged"] and outcome["observed_bytes"] == 0))
end
