defmodule SmolBox.Embedded.Protocol do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchChildAbsence,
    BranchCompletion,
    BranchDeletionCollection,
    BranchDeletionContinuation,
    BranchDeletionResolution,
    BranchReleaseTransition,
    CaptureAbortSourceQualification,
    CaptureResolutionTransition,
    CaptureStagingCleanupReceipt,
    CaptureStream,
    CaptureTransition,
    CommandPayload,
    CreationFeatures,
    CreationPayload,
    ExportContract,
    ExportPublication,
    ExportStageCleanup,
    GrowthTransition,
    ImageContract,
    JSON,
    LogStream,
    ObservationShape,
    PreparedBranchRetirement,
    RegistryContract,
    ReleasedBranchDeletionContinuation,
    ReleasedBranchDeletionResolution,
    SDKIdentity,
    Shape,
    TerminalContract,
    UnbootedBranchChildAbsence,
    UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate,
    VolumeContract
  }

  alias SmolBox.Validation

  @capabilities ~w(create inspect start stop delete exec read_file write_file qualify_creation inspect_creation)
  @observations ~w(health capacity metrics readiness list measurements)
  @observation_limits %{
    "records" => 1024,
    "record_bytes" => 262_144,
    "snapshot_bytes" => 4_194_304,
    "cpu_sample_ms" => 25,
    "disk_entries" => 65_536,
    "disk_depth" => 32
  }
  @codes ~w(validation unsupported conflict ownership database state native io overload package deadline cancelled)
  @job_limits %{
    "work_slots" => 4,
    "observation_slots" => 2,
    "worker_children" => 4,
    "staging_bytes" => 67_108_864,
    "descriptors" => 32,
    "control_fd_headroom" => 8,
    "agent_request_bytes" => 4_194_304,
    "agent_reply_overhead_bytes" => 65_536
  }
  @dispatch ~w(not_dispatched may_have_dispatched)
  @completions ~w(exited cancelled deadline output_limit consumer_lost native_error unknown)
  @states ~w(missing stopped running paused pausing frozen failed unreachable identity_unknown)
  @volume_limits %{
    "work_ms" => 86_400_000,
    "observation_ms" => 30_000,
    "record_bytes" => 16_384,
    "delete_entries" => 1_000_000,
    "ancestor_bytes" => 4096,
    "control_metadata_bytes" => 262_144,
    "observation_metadata_bytes" => 131_072
  }
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
  def limits(1, minor) when minor in [3, 4], do: limits(minor)

  def limits(2, 0),
    do:
      limits(2, 0, %{
        "feature_versions" => %{
          "observability" => 1,
          "compact_creation" => 1,
          "job_resources" => 1,
          "buffered_exec" => 1,
          "logs" => 1,
          "terminals" => 1
        }
      })

  def limits(_major, _minor), do: nil

  def limits(2, 0, sdk) do
    compact = match?(%{"feature_versions" => %{"compact_creation" => 1}}, sdk)

    observations =
      if compact,
        do: %{@observation_limits | "record_bytes" => 8_388_608, "snapshot_bytes" => 33_554_432},
        else: @observation_limits

    values =
      if observers?(sdk), do: Map.put(limits(4), "observations", observations), else: limits(4)

    values =
      if compact,
        do: Map.put(values, "creation", CreationPayload.limits()),
        else: values

    buffered = match?(%{"feature_versions" => %{"buffered_exec" => 1}}, sdk)
    jobs = if buffered, do: Map.put(@job_limits, "metadata_bytes", 33_554_432), else: @job_limits
    values = if buffered, do: Map.put(values, "buffered", CommandPayload.limits()), else: values

    values
    |> feature_limits(sdk, "logs", "logs", LogStream.limits())
    |> feature_limits(sdk, "terminals", "terminals", TerminalContract.limits())
    |> feature_limits(sdk, "exports", "exports", ExportContract.limits())
    |> volume_limits(sdk)
    |> feature_limits(sdk, "job_resources", "jobs", jobs)
  end

  def limits(major, minor, _sdk), do: limits(major, minor)

  defp feature_limits(values, %{"feature_versions" => versions}, feature, key, limits)
       when is_map_key(versions, feature) and :erlang.map_get(feature, versions) === 1,
       do: Map.put(values, key, limits)

  defp feature_limits(values, _sdk, _feature, _key, _limits), do: values

  def capabilities, do: @capabilities

  def capabilities(sdk) do
    images =
      if match?(%{"feature_versions" => %{"images" => 1}}, sdk),
        do: ~w(list_images pull_image),
        else: []

    growth =
      if match?(%{"feature_versions" => %{"disk_growth" => 1}}, sdk),
        do: ~w(expand_disks inspect_growth qualify_growth),
        else: []

    terminals =
      if match?(%{"feature_versions" => %{"terminals" => 1}}, sdk),
        do: ["terminal_open"],
        else: []

    stream =
      if match?(%{"feature_versions" => %{"streaming_exec" => 1}}, sdk),
        do: ["exec_stream"],
        else: []

    values =
      if observers?(sdk),
        do: preparation(sdk) ++ volume_capabilities(sdk) ++ @observations ++ @capabilities,
        else: preparation(sdk) ++ volume_capabilities(sdk) ++ @capabilities

    values =
      if match?(%{"feature_versions" => %{"logs" => 1}}, sdk), do: ["logs" | values], else: values

    values =
      if match?(%{"feature_versions" => %{"background_exec" => 1}}, sdk),
        do: ["exec_background" | values],
        else: values

    if match?(%{"feature_versions" => %{"buffered_exec" => 1}}, sdk),
      do: images ++ growth ++ terminals ++ stream ++ ["exec_buffered" | values],
      else: images ++ growth ++ terminals ++ stream ++ values
  end

  defp preparation(%{"feature_versions" => %{"remote_sources" => 1}}), do: ["prepare_artifact"]
  defp preparation(_sdk), do: []

  defp volume_feature?(sdk), do: match?(%{"feature_versions" => %{"volumes" => 1}}, sdk)
  defp volume_capabilities(sdk), do: if(volume_feature?(sdk), do: ["volumes"], else: [])

  defp volume_limits(values, %{"feature_versions" => %{"volumes" => 1}}),
    do: Map.put(values, "volumes", @volume_limits)

  defp volume_limits(values, _sdk), do: values

  defp volume_platform?(hello),
    do: not volume_feature?(hello["sdk"]) or hello["package"]["platform"] == "linux"

  defp observers?(%{"feature_versions" => %{"observability" => 1}}), do: true
  defp observers?(_sdk), do: false

  def version, do: %{major: 1, minor: 4}
  def valid_outcome?(outcome, major \\ 1), do: major in [1, 2] and outcome?(outcome, major)

  def decode(body, major \\ 1) do
    with true <- major in [1, 2],
         {:ok, message} <- JSON.decode(body),
         true <- server?(message, major) do
      {:ok, message}
    else
      _invalid -> :error
    end
  end

  def approve(hello, config, expected_sdk \\ nil) do
    major = if expected_sdk == nil, do: 1, else: 2

    hello?(hello, major) and hello["preflight"] == %{"status" => "ready"} and
      cancellation_approved?(hello, config, major) and
      hello["domain"] == %{"target_id" => config.id, "generation" => config.domain_generation} and
      hello["package"] == config.package_identity and
      hello["capabilities"] == capabilities(expected_sdk) and
      sdk_approved?(hello, expected_sdk, major)
  end

  defp cancellation_approved?(%{"minor" => 3}, _config, 1), do: true
  defp cancellation_approved?(_hello, config, _major), do: config.limits.cancel_grace_ms >= 4000
  defp sdk_approved?(_hello, nil, 1), do: true

  defp sdk_approved?(hello, expected, 2),
    do: SDKIdentity.valid?(expected) and hello["sdk"] == expected

  defp server?(%{"type" => "hello", "hello" => hello} = message, major),
    do: Shape.keys?(message, ~w(type hello)) and hello?(hello, major)

  defp server?(%{"type" => "unavailable", "epoch" => epoch} = message, _major),
    do: Shape.keys?(message, ~w(type epoch)) and Shape.hex?(epoch, 32)

  defp server?(%{"type" => "accepted", "sequence" => 0} = message, _major),
    do: Shape.keys?(message, ~w(type epoch id sequence)) and correlation?(message)

  defp server?(%{"type" => "terminal_opened", "sequence" => sequence} = message, 2),
    do:
      Shape.keys?(message, ~w(type epoch id sequence)) and correlation?(message) and
        Validation.integer?(sequence, 1, TerminalContract.max_sequence())

  defp server?(%{"type" => "event", "sequence" => sequence, "event" => event} = message, major),
    do:
      Shape.keys?(message, ~w(type epoch id sequence event)) and correlation?(message) and
        Validation.integer?(
          sequence,
          1,
          cond do
            event["stream"] == "checkpoint" -> CaptureStream.max_events()
            event["stream"] == "terminal" -> TerminalContract.max_sequence() - 1
            true -> 65_536
          end
        ) and event?(event, major)

  defp server?(
         %{"type" => "terminal", "sequence" => sequence, "outcome" => outcome} = message,
         major
       ),
       do:
         Shape.keys?(message, ~w(type epoch id sequence outcome)) and correlation?(message) and
           Validation.integer?(
             sequence,
             0,
             terminal_limit(outcome, major)
           ) and outcome?(outcome, major) and
           terminal_sequence?(sequence, outcome)

  defp server?(_message, _major), do: false

  defp terminal_limit(%{"result" => "terminal"}, _major), do: TerminalContract.max_sequence()
  defp terminal_limit(%{"result" => "captured"}, 2), do: CaptureStream.max_events() + 1

  defp terminal_limit(%{"result" => "error", "dispatch" => "may_have_dispatched"}, 2),
    do: CaptureStream.max_events() + 1

  defp terminal_limit(_outcome, _major), do: 65_537

  defp terminal_sequence?(0, %{"result" => "error", "dispatch" => "not_dispatched"}), do: true
  defp terminal_sequence?(sequence, _outcome), do: sequence > 0

  defp correlation?(message),
    do:
      Shape.hex?(message["epoch"], 32) and
        Validation.integer?(message["id"], 1, 9_007_199_254_740_991)

  defp hello?(hello, major),
    do:
      hello_version?(hello, major) and Shape.hex?(hello["epoch"], 32) and
        domain?(hello["domain"]) and package?(hello["package"]) and sdk_matches?(hello, major) and
        volume_platform?(hello) and
        capabilities?(hello["capabilities"], major, hello["sdk"]) and
        hello["limits"] == limits(major, hello["minor"], hello["sdk"]) and
        preflight?(hello["preflight"])

  defp hello_version?(hello, 1),
    do:
      Shape.keys?(hello, ~w(major minor epoch domain package capabilities limits preflight)) and
        hello["major"] == 1 and hello["minor"] in [3, 4]

  defp hello_version?(hello, 2),
    do:
      Shape.keys?(hello, ~w(major minor epoch domain package capabilities limits preflight sdk)) and
        hello["major"] == 2 and hello["minor"] == 0 and SDKIdentity.valid?(hello["sdk"])

  defp hello_version?(_hello, _major), do: false

  defp sdk_matches?(_hello, 1), do: true

  defp sdk_matches?(hello, 2),
    do:
      hello["sdk"]["source_revision"] == hello["package"]["smolvm_revision"] and
        hello["package"]["engine_version"] == "0.2.0"

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

  defp capabilities?(capabilities, major, sdk),
    do:
      Validation.list?(capabilities, if(major == 1, do: 10, else: 32)) and
        Enum.all?(capabilities, &(&1 in capabilities(sdk))) and
        MapSet.size(MapSet.new(capabilities)) == length(capabilities)

  defp preflight?(%{"status" => "ready"} = preflight), do: map_size(preflight) == 1

  defp preflight?(%{"status" => "rejected", "code" => code} = preflight),
    do: map_size(preflight) == 2 and code in @codes

  defp preflight?(_preflight), do: false

  defp event?(event, major),
    do:
      Shape.keys?(event, ~w(stream data_base64)) and
        (event["stream"] in ~w(stdout stderr file) or
           (major == 2 and event["stream"] in ~w(log terminal checkpoint))) and
        match?({:ok, _bytes}, Shape.chunk(event["data_base64"]))

  defp outcome?(%{"result" => "unbooted_branch_child_absent", "proof" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result proof)) and UnbootedBranchChildAbsence.valid?(proof)

  defp outcome?(
         %{"result" => "unbooted_branch_disposal_candidate", "candidate" => candidate} = outcome,
         2
       ),
       do:
         Shape.keys?(outcome, ~w(result candidate)) and
           UnbootedBranchDisposalCandidate.valid?(candidate)

  defp outcome?(%{"result" => "unbooted_branch_disposed", "proof" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result proof)) and UnbootedBranchDisposal.valid?(proof)

  defp outcome?(%{"result" => "prepared_branch_retired", "proof" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result proof)) and PreparedBranchRetirement.valid?(proof)

  defp outcome?(%{"result" => "terminal"} = outcome, 2), do: TerminalContract.outcome?(outcome)

  defp outcome?(%{"result" => "branch_created", "completion" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result completion)) and BranchCompletion.wire?(proof)

  defp outcome?(%{"result" => "held_branch_deletion_continued", "proof" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result proof)) and BranchDeletionContinuation.valid?(proof)

  defp outcome?(%{"result" => "held_branch_deletion_cleaned", "proof" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result proof)) and BranchDeletionResolution.valid?(proof)

  defp outcome?(
         %{"result" => "released_branch_deletion_continued", "proof" => proof} = outcome,
         2
       ),
       do:
         Shape.keys?(outcome, ~w(result proof)) and
           ReleasedBranchDeletionContinuation.valid?(proof)

  defp outcome?(
         %{"result" => "released_branch_deletion_cleaned", "proof" => proof} = outcome,
         2
       ),
       do:
         Shape.keys?(outcome, ~w(result proof)) and ReleasedBranchDeletionResolution.valid?(proof)

  defp outcome?(
         %{"result" => "branch_deletion_collected", "proof" => proof} = outcome,
         2
       ),
       do: Shape.keys?(outcome, ~w(result proof)) and BranchDeletionCollection.valid?(proof)

  defp outcome?(
         %{"result" => "released_branch_deletion_resolved", "proof" => proof} = outcome,
         2
       ),
       do:
         Shape.keys?(outcome, ~w(result proof)) and ReleasedBranchDeletionResolution.valid?(proof)

  defp outcome?(%{"result" => "held_branch_deletion_resolved", "proof" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result proof)) and BranchDeletionResolution.valid?(proof)

  defp outcome?(%{"result" => "branch_backing_released", "proof" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result proof)) and BranchBackingRelease.valid?(proof)

  defp outcome?(%{"result" => "branch_child_absent", "proof" => proof} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result proof)) and BranchChildAbsence.valid?(proof)

  defp outcome?(%{"result" => kind, "transition" => proof} = outcome, 2)
       when kind in ~w(held_branch_released held_branch_release_presence),
       do:
         Shape.keys?(outcome, ~w(result transition)) and
           ((kind == "held_branch_release_presence" and proof == nil) or
              (BranchReleaseTransition.valid?(proof) and
                 proof["change"]["mode"] == "explicit"))

  defp outcome?(%{"result" => "branch_completion_presence", "completion" => proof} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result completion)) and
        (proof == nil or BranchCompletion.wire?(proof))

  defp outcome?(
         %{"result" => kind, "transition" => transition, "observation" => observation} =
           outcome,
         2
       )
       when kind in ~w(grown growth_qualified) do
    with true <- Shape.keys?(outcome, ~w(result transition observation)),
         {:ok, proof} <- GrowthTransition.from_wire(transition),
         true <-
           observation?(observation, 2) and observation["state"] == "stopped" and
             observation["pid_identity"] == nil do
      observation["resources"]["storage_gib"] == proof.change["storage_gib"] and
        observation["resources"]["overlay_gib"] == proof.change["overlay_gib"]
    else
      _ -> false
    end
  end

  defp outcome?(%{"result" => "growth_presence", "transition" => transition} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result transition)) and
        (transition == nil or match?({:ok, _}, GrowthTransition.from_wire(transition)))

  defp outcome?(%{"result" => "exported", "publication" => proof} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result publication)) and
        match?({:ok, _}, ExportPublication.from_wire(proof))

  defp outcome?(%{"result" => "export_presence", "publication" => proof} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result publication)) and
        (proof == nil or match?({:ok, _}, ExportPublication.from_wire(proof)))

  defp outcome?(%{"result" => "export_staging_cleaned", "cleanup" => proof} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result cleanup)) and
        match?({:ok, _}, ExportStageCleanup.from_wire(proof))

  defp outcome?(%{"result" => "capture_presence", "transition" => transition} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result transition)) and
        (transition == nil or match?({:ok, _}, CaptureTransition.from_wire(transition)))

  defp outcome?(
         %{"result" => "aborted_capture_source_qualified", "qualification" => proof} = outcome,
         2
       ),
       do:
         Shape.keys?(outcome, ~w(result qualification)) and
           match?({:ok, _}, CaptureAbortSourceQualification.from_wire(proof))

  defp outcome?(%{"result" => "capture_staging_aborted", "cleanup" => cleanup} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result cleanup)) and
        match?({:ok, _}, CaptureStagingCleanupReceipt.from_wire(cleanup))

  defp outcome?(%{"result" => "capture_staging_cleaned", "cleanup" => cleanup} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result cleanup)) and
        match?({:ok, _}, CaptureStagingCleanupReceipt.from_wire(cleanup))

  defp outcome?(%{"result" => "capture_resolved", "transition" => transition} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result transition)) and
        match?({:ok, _}, CaptureResolutionTransition.from_wire(transition))

  defp outcome?(
         %{"result" => "capture_resolution_presence", "transition" => transition} = outcome,
         2
       ),
       do:
         Shape.keys?(outcome, ~w(result transition)) and
           (transition == nil or
              match?({:ok, _}, CaptureResolutionTransition.from_wire(transition)))

  defp outcome?(%{"result" => "captured", "transition" => transition} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result transition)) and
        match?({:ok, _}, CaptureTransition.from_wire(transition))

  defp outcome?(%{"result" => "created", "receipt" => receipt} = outcome, major),
    do: Shape.keys?(outcome, ~w(result receipt)) and Shape.receipt?(receipt, major)

  defp outcome?(%{"result" => "health", "snapshot" => snapshot} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result snapshot)) and ObservationShape.health?(snapshot)

  defp outcome?(%{"result" => "capacity", "snapshot" => snapshot} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result snapshot)) and ObservationShape.capacity?(snapshot)

  defp outcome?(%{"result" => "metrics", "text" => text} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result text)) and Shape.text?(text, 65_536, true)

  defp outcome?(%{"result" => "ready"} = outcome, 2), do: map_size(outcome) == 1

  defp outcome?(%{"result" => "volume"} = outcome, 2), do: VolumeContract.result?(outcome)

  defp outcome?(%{"result" => "prepared_artifact"} = outcome, 2),
    do: RegistryContract.result?(outcome)

  defp outcome?(%{"result" => "pulled", "image" => image} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result image)) and ImageContract.image?(image)

  defp outcome?(%{"result" => "images", "count" => count, "bytes" => bytes} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result count bytes)) and Validation.integer?(count, 0, 1024) and
        Validation.integer?(bytes, 2, 8_388_608)

  defp outcome?(%{"result" => "inventory", "count" => count, "bytes" => bytes} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result count bytes)) and Validation.integer?(count, 0, 1024) and
        Validation.integer?(bytes, 0, 4_194_304)

  defp outcome?(
         %{"result" => "measurements", "observation" => observation, "counters" => counters} =
           outcome,
         2
       ),
       do:
         Shape.keys?(outcome, ~w(result observation counters)) and observation?(observation, 2) and
           ObservationShape.counters?(counters)

  defp outcome?(%{"result" => "qualified"} = outcome, _major), do: map_size(outcome) == 1

  defp outcome?(%{"result" => "creation_presence", "presence" => presence} = outcome, _major),
    do: Shape.keys?(outcome, ~w(result presence)) and presence in ~w(absent unverified)

  defp outcome?(%{"result" => "observed", "observation" => observation} = outcome, major),
    do: Shape.keys?(outcome, ~w(result observation)) and observation?(observation, major)

  defp outcome?(%{"result" => "command"} = outcome, _major), do: command?(outcome)

  defp outcome?(%{"result" => "launched", "pid" => pid} = outcome, 2),
    do: Shape.keys?(outcome, ~w(result pid)) and Validation.integer?(pid, 1, 4_294_967_295)

  defp outcome?(%{"result" => "file"} = outcome, _major), do: file?(outcome)

  defp outcome?(%{"result" => "logs"} = outcome, 2),
    do:
      Shape.keys?(outcome, ~w(result completion lines bytes wire_bytes)) and
        outcome["completion"] in ~w(completed cancelled deadline output_limit consumer_lost native_error) and
        Validation.integer?(outcome["lines"], 0, 10_000) and
        Validation.integer?(outcome["bytes"], outcome["lines"], 8_388_608) and
        Validation.integer?(
          outcome["wire_bytes"],
          outcome["bytes"] + 3 * outcome["lines"],
          8_418_608
        ) and
        (outcome["completion"] != "completed" or
           outcome["wire_bytes"] == outcome["bytes"] + 3 * outcome["lines"])

  defp outcome?(%{"result" => "error", "code" => code, "dispatch" => dispatch} = outcome, major),
    do:
      Shape.keys?(outcome, ~w(result code dispatch)) and
        (code in @codes or (major == 2 and code in ~w(output_limit port_conflict not_found))) and
        dispatch in @dispatch

  defp outcome?(_outcome, _major), do: false

  defp observation?(observation, major),
    do:
      (Shape.keys?(observation, ~w(state resources pid_identity)) or
         (major == 2 and Shape.keys?(observation, ~w(state resources pid_identity configuration)) and
            CreationFeatures.configuration?(observation["configuration"]))) and
        observation["state"] in @states and
        Shape.optional?(observation["resources"], &Shape.resources?/1) and
        Shape.optional?(observation["pid_identity"], &pid?/1) and missing?(observation)

  defp missing?(%{"state" => "missing"} = observation),
    do:
      observation["resources"] == nil and observation["pid_identity"] == nil and
        observation["configuration"] == nil

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
