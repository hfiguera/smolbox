defmodule SmolBox.Embedded.Channel do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchChildAbsence,
    BranchCompletion,
    BranchDeletionCollection,
    BranchDeletionResolution,
    BranchPublication,
    CaptureAbortSourceQualification,
    CaptureResolutionTransition,
    CaptureStagingCleanupReceipt,
    CaptureTransition,
    ExportPublication,
    ExportStageCleanup,
    GrowthTransition,
    HeldBranchDeletionAction,
    HeldBranchReleaseRequest,
    ImageContract,
    PartialBranchBackingRelease,
    PartialBranchChildAbsence,
    PartialBranchCleanupCandidate,
    PartialBranchCollection,
    PartialBranchCollectionCandidate,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup,
    PartialBranchDisposalCleanupUnneeded,
    PreparedBranchRetirement,
    Protocol,
    RegistryContract,
    ReleasedBranchDeletionCleanup,
    ReleasedBranchDeletionContinuation,
    ReleasedBranchDeletionResolution,
    Request,
    Shape,
    TerminalContract,
    UnbootedBranchBackingRelease,
    UnbootedBranchChildAbsence,
    UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate,
    VolumeContract
  }

  alias SmolBox.Validation

  @derive {Inspect, only: [:last_id, :queued_bytes, :queued_events]}
  defstruct [
    :epoch,
    :domain,
    :minor,
    :export_platform,
    :platform,
    major: 1,
    unavailable: false,
    partial_cleanup_resolution: false,
    partial_collection_preflight: false,
    last_id: 0,
    pending: %{},
    queued_bytes: 0,
    queued_events: 0
  ]

  def new(hello),
    do: %__MODULE__{
      epoch: hello["epoch"],
      domain: hello["domain"],
      minor: hello["minor"],
      major: Map.get(hello, "major", 1),
      partial_cleanup_resolution:
        match?(
          %{"branches" => 1, "partial_cleanup_resolution" => 1},
          get_in(hello, ~w(sdk feature_versions))
        ),
      partial_collection_preflight:
        match?(
          %{"branches" => 1, "partial_collection_preflight" => 1},
          get_in(hello, ~w(sdk feature_versions))
        ),
      platform: get_in(hello, ["package", "platform"]),
      export_platform:
        case get_in(hello, ["package", "architecture"]) do
          "x86_64" -> "linux/amd64"
          "aarch64" -> "linux/arm64"
          _ -> nil
        end
    }

  def register(channel, operation, bytes, events) do
    with true <-
           not channel.unavailable or (channel.major == 2 and Request.control?(operation)),
         true <- map_size(channel.pending) < 32,
         true <- channel.last_id < 9_007_199_254_740_991,
         true <- Request.valid?(operation, 1, channel.major),
         true <-
           operation["operation"] != "resolve_partial_branch_cleanup" or
             channel.partial_cleanup_resolution,
         true <-
           operation["operation"] != "inspect_partial_branch_collection" or
             channel.partial_collection_preflight,
         true <- Validation.integer?(bytes, 0, 262_144),
         true <- Validation.integer?(events, 0, 64),
         true <-
           operation["operation"] != "terminal_open" or
             bytes <= operation["terminal"]["max_buffer_bytes"],
         true <- domain_matches?(channel.domain, Request.receipt(operation)),
         true <- held_platform?(channel.platform, operation),
         true <- branch_request_epoch?(channel.epoch, operation) do
      id = channel.last_id + 1

      pending = %{
        operation: RegistryContract.sanitize(operation),
        export_platform: channel.export_platform,
        sequence: nil,
        done: false,
        credit: bytes,
        event_credit: events,
        output_bytes: 0,
        upload_bytes: 0,
        terminal_opened: false,
        terminal_control: 0,
        terminal_attached: false,
        terminal_closed: false,
        terminal_input: 0,
        outstanding: :queue.new(),
        unacknowledged: 0
      }

      {:ok, id, %{channel | last_id: id, pending: Map.put(channel.pending, id, pending)}}
    else
      _invalid -> :error
    end
  end

  # Only structurally validated Protocol messages reach this correlation layer.
  # IDs remain recorded until a terminal AND consumption retire the subscription.
  def receive_message(
        %{major: major, minor: minor, unavailable: false} = channel,
        %{"type" => "unavailable", "epoch" => epoch}
      )
      when epoch == channel.epoch and ((major == 1 and minor == 4) or (major == 2 and minor == 0)),
      do: {:ok, %{channel | unavailable: true}, :unavailable}

  def receive_message(channel, %{"epoch" => epoch, "id" => id} = message)
      when epoch == channel.epoch do
    with {:ok, pending} <- Map.fetch(channel.pending, id),
         false <- pending.done,
         {:ok, updated, event} <- advance(channel, pending, message) do
      delta_bytes = updated.unacknowledged - pending.unacknowledged
      delta_events = :queue.len(updated.outstanding) - :queue.len(pending.outstanding)

      {:ok,
       %{
         channel
         | pending: Map.put(channel.pending, id, updated),
           queued_bytes: channel.queued_bytes + delta_bytes,
           queued_events: channel.queued_events + delta_events
       }, {id, event}}
    else
      _invalid -> :error
    end
  end

  def receive_message(_channel, _message), do: :error

  def acknowledge(channel, id, bytes) do
    with {:ok, pending} <- Map.fetch(channel.pending, id),
         true <- Validation.integer?(bytes, 1, pending.unacknowledged),
         true <-
           pending.operation["operation"] != "terminal_open" or
             whole_credit?(pending.outstanding, bytes),
         {:ok, outstanding, events} <- consume(pending.outstanding, bytes, 0) do
      updated = %{
        pending
        | outstanding: outstanding,
          unacknowledged: pending.unacknowledged - bytes,
          credit: pending.credit + bytes,
          event_credit: pending.event_credit + events
      }

      {:ok,
       %{
         channel
         | pending: Map.put(channel.pending, id, updated),
           queued_bytes: channel.queued_bytes - bytes,
           queued_events: channel.queued_events - events
       }, %{events: events, native_credit: not pending.done}}
    else
      _invalid -> :error
    end
  end

  def uploaded(channel, id, bytes) do
    with {:ok, pending} <- Map.fetch(channel.pending, id),
         false <- pending.done,
         %{"operation" => "write_file", "total_bytes" => total} <- pending.operation,
         true <- Validation.integer?(bytes, 1, min(65_536, total - pending.upload_bytes)) do
      updated = %{pending | upload_bytes: pending.upload_bytes + bytes}
      {:ok, %{channel | pending: Map.put(channel.pending, id, updated)}}
    else
      _invalid -> :error
    end
  end

  def terminal_control(channel, id, sequence, control) do
    with true <- Validation.integer?(id, 1, channel.last_id),
         true <- Validation.integer?(sequence, 1, TerminalContract.max_sequence()) do
      terminal_control_pending(channel, id, sequence, control, channel.pending[id])
    else
      _ -> :error
    end
  end

  defp terminal_control_pending(channel, _id, _sequence, _control, nil), do: {:ok, channel, false}

  defp terminal_control_pending(channel, _id, _sequence, _control, %{done: true}),
    do: {:ok, channel, false}

  defp terminal_control_pending(
         channel,
         id,
         sequence,
         control,
         %{operation: %{"operation" => "terminal_open"}} = pending
       ) do
    with {:ok, updated} <- TerminalContract.control(pending, sequence, control),
         do: {:ok, %{channel | pending: Map.put(channel.pending, id, updated)}, true}
  end

  defp terminal_control_pending(_channel, _id, _sequence, _control, _pending), do: :error

  def retire(channel, id) do
    case Map.fetch(channel.pending, id) do
      {:ok, %{done: true, unacknowledged: 0}} ->
        {:ok, %{channel | pending: Map.delete(channel.pending, id)}}

      _invalid ->
        :error
    end
  end

  def close(channel),
    do: %{
      channel
      | pending: Map.new(channel.pending, fn {id, pending} -> {id, %{pending | done: true}} end)
    }

  def reject_unsent(channel, id) do
    case Map.fetch(channel.pending, id) do
      {:ok, %{sequence: nil, output_bytes: 0, upload_bytes: 0} = pending} ->
        {:ok, %{channel | pending: Map.put(channel.pending, id, %{pending | done: true})}}

      _invalid ->
        :error
    end
  end

  defp domain_matches?(_domain, nil), do: true

  defp domain_matches?(domain, receipt),
    do:
      receipt["target_id"] == domain["target_id"] and
        receipt["domain_generation"] == domain["generation"]

  defp whole_credit?(_queue, 0), do: true

  defp whole_credit?(queue, bytes) do
    case :queue.out(queue) do
      {{:value, size}, rest} when size <= bytes -> whole_credit?(rest, bytes - size)
      _ -> false
    end
  end

  defp advance(_channel, %{sequence: nil} = pending, %{"type" => "accepted", "sequence" => 0}),
    do: {:ok, %{pending | sequence: 0}, :accepted}

  defp advance(
         _channel,
         %{
           operation: %{"operation" => "terminal_open"},
           terminal_opened: false,
           sequence: sequence
         } = pending,
         %{"type" => "terminal_opened", "sequence" => next}
       )
       when is_integer(sequence) and next == sequence + 1,
       do: {:ok, %{pending | sequence: next, terminal_opened: true}, :terminal_opened}

  defp advance(_channel, %{sequence: sequence} = pending, %{
         "type" => "event",
         "sequence" => next,
         "event" => event
       })
       when is_integer(sequence) and next == sequence + 1 do
    with {:ok, bytes} <- Shape.chunk(event["data_base64"]),
         true <- pending.operation["operation"] != "terminal_open" or pending.terminal_opened,
         {:ok, stream, limit} <- stream(pending.operation, event["stream"]),
         true <- chunk_matches?(pending.operation, bytes),
         true <- byte_size(bytes) <= pending.credit and pending.event_credit > 0,
         true <- pending.output_bytes + byte_size(bytes) <= limit do
      updated = %{
        pending
        | sequence: next,
          credit: pending.credit - byte_size(bytes),
          event_credit: pending.event_credit - 1,
          output_bytes: pending.output_bytes + byte_size(bytes),
          unacknowledged: pending.unacknowledged + byte_size(bytes),
          outstanding: :queue.in(byte_size(bytes), pending.outstanding)
      }

      {:ok, updated, {:output, stream, bytes}}
    else
      _invalid -> :error
    end
  end

  defp advance(channel, pending, %{"type" => "terminal", "sequence" => next, "outcome" => outcome}) do
    if(
      terminal_sequence?(pending.sequence, next) and
        Protocol.valid_outcome?(outcome, channel.major) and
        branch_platform?(channel.platform, outcome) and
        branch_epoch?(channel.epoch, outcome) and
        ready_epoch?(channel.epoch, pending, outcome) and
        terminal_matches?(channel.domain, pending, outcome),
      do: {:ok, %{pending | sequence: next, done: true}, {:terminal, outcome}},
      else: :error
    )
  end

  defp advance(_channel, _pending, _message), do: :error

  defp terminal_sequence?(nil, 0), do: true
  defp terminal_sequence?(previous, next) when is_integer(previous), do: next == previous + 1
  defp terminal_sequence?(_previous, _next), do: false

  defp branch_request_epoch?(epoch, %{
         "operation" => "release_partial_branch_backing",
         "request" => request
       }),
       do: PartialBranchBackingRelease.epoch(request) == epoch

  defp branch_request_epoch?(epoch, %{
         "operation" => "qualify_partial_branch_child_absence",
         "request" => request
       }),
       do: PartialBranchChildAbsence.epoch(request) == epoch

  defp branch_request_epoch?(epoch, %{
         "operation" => "qualify_unbooted_branch_child_absence",
         "request" => request
       }),
       do: UnbootedBranchChildAbsence.epoch(request) == epoch

  defp branch_request_epoch?(_, _), do: true

  defp branch_epoch?(epoch, %{
         "result" => "partial_branch_collection_candidate",
         "candidate" => candidate
       }),
       do: candidate["epoch"] == epoch

  defp branch_epoch?(epoch, %{"result" => "partial_branch_child_absent", "proof" => proof}),
    do: PartialBranchChildAbsence.epoch(proof["request"]) == epoch

  defp branch_epoch?(epoch, %{"result" => "unbooted_branch_child_absent", "proof" => proof}),
    do: UnbootedBranchChildAbsence.epoch(proof["request"]) == epoch

  defp branch_epoch?(epoch, %{
         "result" => "unbooted_branch_disposal_candidate",
         "candidate" => candidate
       }),
       do: get_in(candidate, ~w(publication change child_origin intent epoch)) == epoch

  defp branch_epoch?(epoch, %{"result" => name, "proof" => proof})
       when name in ~w(partial_branch_disposal_cleaned partial_branch_cleanup_unneeded),
       do: get_in(proof, ~w(disposal publication change child_origin intent epoch)) == epoch

  defp branch_epoch?(epoch, %{
         "result" => "partial_branch_cleanup_candidate",
         "candidate" => candidate
       }),
       do: get_in(candidate, ~w(publication change child_origin intent epoch)) == epoch

  defp branch_epoch?(epoch, %{"result" => "partial_branch_disposed", "proof" => proof}),
    do: get_in(proof, ~w(publication change child_origin intent epoch)) == epoch

  defp branch_epoch?(epoch, %{
         "result" => "collected_branch_material_published",
         "publication" => publication
       }),
       do: get_in(publication, ~w(change child_origin intent epoch)) == epoch

  defp branch_epoch?(_, _), do: true

  defp branch_platform?(platform, %{
         "result" => "partial_branch_collection_candidate",
         "candidate" => candidate
       }),
       do: candidate["platform"] == platform

  defp branch_platform?(platform, %{"result" => "partial_branch_child_absent", "proof" => proof}),
    do: PartialBranchChildAbsence.platform(proof["request"]) == platform

  defp branch_platform?(platform, %{"result" => "unbooted_branch_child_absent", "proof" => proof}),
       do: UnbootedBranchChildAbsence.platform(proof["request"]) == platform

  defp branch_platform?(platform, %{
         "result" => "unbooted_branch_disposal_candidate",
         "candidate" => candidate
       }),
       do: get_in(candidate, ~w(publication change platform)) == platform

  defp branch_platform?(platform, %{"result" => kind, "completion" => proof})
       when kind in ~w(branch_created branch_completion_presence) and proof != nil,
       do: proof["publication"]["change"]["platform"] == platform

  defp branch_platform?(platform, %{
         "result" => name,
         "proof" => proof
       })
       when name in ~w(partial_branch_disposal_cleaned partial_branch_cleanup_unneeded),
       do: get_in(proof, ~w(disposal publication change platform)) == platform

  defp branch_platform?(platform, %{
         "result" => "partial_branch_cleanup_candidate",
         "candidate" => candidate
       }),
       do: get_in(candidate, ~w(publication change platform)) == platform

  defp branch_platform?(platform, %{"result" => "partial_branch_disposed", "proof" => proof}),
    do: get_in(proof, ~w(publication change platform)) == platform

  defp branch_platform?(platform, %{"result" => "unbooted_branch_disposed", "proof" => proof}),
    do: get_in(proof, ~w(publication change platform)) == platform

  defp branch_platform?(platform, %{"result" => "partial_branch_collected", "platform" => actual}),
       do: actual == platform

  defp branch_platform?(platform, %{
         "result" => "collected_branch_material_published",
         "publication" => publication
       }),
       do: get_in(publication, ~w(change platform)) == platform

  defp branch_platform?(_platform, _outcome), do: true

  defp held_platform?(platform, %{
         "operation" => "qualify_partial_branch_child_absence",
         "request" => request
       }),
       do: PartialBranchChildAbsence.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "qualify_unbooted_branch_child_absence",
         "request" => request
       }),
       do: UnbootedBranchChildAbsence.platform(request) == platform

  defp held_platform?(platform, %{"operation" => name, "request" => request})
       when name in ~w(release_held_branch qualify_held_branch_release),
       do: HeldBranchReleaseRequest.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "qualify_branch_child_absence",
         "request" => request
       }),
       do: BranchChildAbsence.platform(request) == platform

  defp held_platform?(platform, %{"operation" => "release_branch_backing", "request" => request}),
    do: BranchBackingRelease.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "continue_released_branch_deletion",
         "request" => request
       }),
       do: ReleasedBranchDeletionContinuation.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "cleanup_released_branch_deletion",
         "request" => request
       }),
       do: ReleasedBranchDeletionCleanup.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "collect_branch_deletion",
         "request" => request
       }),
       do: BranchDeletionCollection.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "resolve_released_branch_deletion",
         "request" => request
       }),
       do: ReleasedBranchDeletionResolution.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "resolve_held_branch_deletion",
         "request" => request
       }),
       do: BranchDeletionResolution.platform(request) == platform

  defp held_platform?(platform, %{"operation" => name, "request" => request})
       when name in ~w(continue_held_branch_deletion cleanup_held_branch_deletion),
       do: HeldBranchDeletionAction.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "release_unbooted_branch_backing",
         "request" => request
       }),
       do: UnbootedBranchBackingRelease.platform(request) == platform

  defp held_platform?(platform, %{
         "operation" => "release_partial_branch_backing",
         "request" => request
       }),
       do: PartialBranchBackingRelease.platform(request) == platform

  defp held_platform?(_, _), do: true

  defp stream(%{"operation" => name, "command" => command}, "stdout")
       when name in ~w(exec exec_buffered exec_stream),
       do: {:ok, :stdout, command["max_output_bytes"]}

  defp stream(%{"operation" => "terminal_open"}, "terminal"),
    do: {:ok, :terminal, TerminalContract.max_sequence()}

  defp stream(%{"operation" => name, "command" => command}, "stderr")
       when name in ~w(exec exec_buffered exec_stream),
       do: {:ok, :stderr, command["max_output_bytes"]}

  defp stream(%{"operation" => "read_file", "options" => options}, "file"),
    do: {:ok, :file, options["max_bytes"]}

  defp stream(%{"operation" => "capture_checkpoint", "request" => request}, "checkpoint"),
    do: {:ok, :checkpoint, request["max_bytes"]}

  defp stream(%{"operation" => "list_images"}, "file"), do: {:ok, :file, 8_388_608}

  defp stream(%{"operation" => "list"}, "file"), do: {:ok, :file, 4_194_304}
  defp stream(%{"operation" => "logs", "max_bytes" => max}, "log"), do: {:ok, :log, max + 30_000}

  defp stream(_operation, _stream), do: :error

  defp chunk_matches?(%{"operation" => "capture_checkpoint", "chunk_bytes" => limit}, bytes),
    do: byte_size(bytes) <= limit

  defp chunk_matches?(_operation, _bytes), do: true

  defp ready_epoch?(
         epoch,
         %{operation: %{"operation" => "resolve_ready_branch_completion"}},
         %{"result" => "branch_completion_presence", "completion" => proof}
       )
       when not is_nil(proof),
       do: get_in(proof, ~w(publication change child_origin intent epoch)) == epoch

  defp ready_epoch?(_, _, _), do: true

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "publish_collected_branch_material", "request" => request},
           output_bytes: 0
         },
         %{"result" => "collected_branch_material_published", "publication" => publication}
       ),
       do: BranchPublication.matches?(publication, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{
             "operation" => "qualify_partial_branch_child_absence",
             "request" => request
           },
           output_bytes: 0
         },
         %{"result" => "partial_branch_child_absent", "proof" => proof}
       ),
       do: PartialBranchChildAbsence.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{
             "operation" => "qualify_unbooted_branch_child_absence",
             "request" => request
           },
           output_bytes: 0
         },
         %{"result" => "unbooted_branch_child_absent", "proof" => proof}
       ),
       do: UnbootedBranchChildAbsence.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "inspect_unbooted_branch_disposal", "request" => request},
           output_bytes: 0
         },
         %{"result" => "unbooted_branch_disposal_candidate", "candidate" => candidate}
       ),
       do: UnbootedBranchDisposalCandidate.matches?(candidate, request)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => name}, output_bytes: 0},
         %{"result" => "qualified"}
       )
       when name in ~w(qualify_export admit_export),
       do: true

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "export_machine"} = request,
           output_bytes: 0,
           export_platform: platform
         },
         %{"result" => "exported", "publication" => publication}
       ) do
    case ExportPublication.from_wire(publication) do
      {:ok, proof} ->
        proof.identity["platform"] == platform and
          ExportPublication.bound_request?(
            proof,
            request["receipt"],
            request["operation_id"],
            request["request"]
          )

      :error ->
        false
    end
  end

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "inspect_export"} = request,
           output_bytes: 0,
           export_platform: platform
         },
         %{"result" => "export_presence", "publication" => publication}
       ) do
    publication == nil or
      case ExportPublication.from_wire(publication) do
        {:ok, proof} ->
          proof.identity["platform"] == platform and
            ExportPublication.bound?(
              proof,
              request["receipt"],
              request["operation_id"],
              request["request_sha256"]
            )

        :error ->
          false
      end
  end

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "cleanup_export_staging"} = request, output_bytes: 0},
         %{"result" => "export_staging_cleaned", "cleanup" => cleanup}
       ) do
    case ExportStageCleanup.from_wire(cleanup) do
      {:ok, proof} ->
        ExportStageCleanup.bound?(
          proof,
          request["receipt"],
          request["operation_id"],
          request["request_sha256"]
        )

      :error ->
        false
    end
  end

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "terminal_preflight"}, output_bytes: 0},
         %{"result" => "ready"}
       ),
       do: true

  defp terminal_matches?(_domain, pending, %{"result" => "error", "dispatch" => dispatch}),
    do: dispatch != "not_dispatched" or pending.output_bytes == 0

  defp terminal_matches?(
         domain,
         %{operation: %{"operation" => "volume", "request" => request}, output_bytes: 0},
         %{"result" => "volume"} = outcome
       ),
       do: VolumeContract.matches?(outcome, request, domain)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "prepare_artifact", "source" => source}, output_bytes: 0},
         %{"result" => "prepared_artifact", "source" => source}
       ),
       do: true

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "terminal_open"}} = pending,
         %{"result" => "terminal"} = outcome
       ),
       do:
         outcome["output_bytes"] >= pending.output_bytes and
           (outcome["dispatch"] != "not_dispatched" or pending.output_bytes == 0) and
           (outcome["completion"] != "exited" or
              (pending.terminal_opened and outcome["output_bytes"] == pending.output_bytes))

  defp terminal_matches?(_domain, %{operation: %{"operation" => name}, output_bytes: 0}, %{
         "result" => result
       })
       when name in ~w(health capacity metrics readiness measurements),
       do: result == if(name == "readiness", do: "ready", else: name)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "pull_image", "source" => source}, output_bytes: 0},
         %{"result" => "pulled", "image" => image}
       ),
       do: ImageContract.matches?(image, source)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "list_images"}, output_bytes: bytes},
         %{
           "result" => "images",
           "bytes" => bytes
         }
       ),
       do: true

  defp terminal_matches?(_domain, %{operation: %{"operation" => "list"}, output_bytes: bytes}, %{
         "result" => "inventory",
         "bytes" => bytes
       }),
       do: true

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "logs"} = request, output_bytes: delivered},
         %{
           "result" => "logs",
           "bytes" => bytes,
           "wire_bytes" => delivered,
           "completion" => completion
         }
       ),
       do: bytes <= request["max_bytes"] and (completion != "completed" or not request["follow"])

  defp terminal_matches?(_domain, %{operation: %{"operation" => name}}, %{
         "result" => "qualified"
       })
       when name in ~w(qualify_creation qualify_oci_creation qualify_registry_creation qualify_checkpoint_creation),
       do: true

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "capture_checkpoint"} = request, output_bytes: bytes},
         %{"result" => "captured", "transition" => transition}
       ) do
    case CaptureTransition.from_wire(transition) do
      {:ok, proof} ->
        CaptureTransition.bound?(
          proof,
          request["receipt"],
          request["operation_id"],
          request["request"]
        ) and proof.change["artifact"]["size_bytes"] == bytes

      :error ->
        false
    end
  end

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "qualify_aborted_capture_source"} = request,
           output_bytes: 0
         },
         %{"result" => "aborted_capture_source_qualified", "qualification" => qualification}
       ) do
    case CaptureAbortSourceQualification.from_wire(qualification) do
      {:ok, proof} ->
        CaptureAbortSourceQualification.bound?(
          proof,
          request["receipt"],
          request["operation_id"],
          request["request"]
        )

      :error ->
        false
    end
  end

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "abort_capture_staging"} = request, output_bytes: 0},
         %{"result" => "capture_staging_aborted", "cleanup" => cleanup}
       ) do
    case CaptureStagingCleanupReceipt.from_wire(cleanup) do
      {:ok, proof} ->
        CaptureStagingCleanupReceipt.bound?(
          proof,
          request["receipt"],
          request["operation_id"],
          request["request"]
        )

      :error ->
        false
    end
  end

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "cleanup_capture_staging"} = request, output_bytes: 0},
         %{"result" => "capture_staging_cleaned", "cleanup" => cleanup}
       ) do
    case CaptureStagingCleanupReceipt.from_wire(cleanup) do
      {:ok, proof} ->
        CaptureStagingCleanupReceipt.bound?(
          proof,
          request["receipt"],
          request["operation_id"],
          request["request"]
        )

      :error ->
        false
    end
  end

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "resolve_capture"} = request, output_bytes: 0},
         %{"result" => "capture_resolved", "transition" => transition}
       ) do
    case CaptureResolutionTransition.from_wire(transition) do
      {:ok, proof} ->
        CaptureResolutionTransition.bound?(
          proof,
          request["receipt"],
          request["operation_id"],
          request["request"]
        )

      :error ->
        false
    end
  end

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "inspect_capture_resolution"} = request, output_bytes: 0},
         %{"result" => "capture_resolution_presence", "transition" => transition}
       ) do
    transition == nil or
      case CaptureResolutionTransition.from_wire(transition) do
        {:ok, proof} ->
          CaptureResolutionTransition.bound?(
            proof,
            request["receipt"],
            request["operation_id"],
            request["request"]
          )

        :error ->
          false
      end
  end

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "inspect_capture"} = request, output_bytes: 0},
         %{"result" => "capture_presence", "transition" => transition}
       ) do
    transition == nil or
      case CaptureTransition.from_wire(transition) do
        {:ok, proof} ->
          CaptureTransition.bound?(
            proof,
            request["receipt"],
            request["operation_id"],
            request["request"]
          )

        :error ->
          false
      end
  end

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "expand_disks"} = request, output_bytes: 0},
         %{"result" => "grown", "transition" => transition}
       ),
       do: growth_matches?(request, transition)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "qualify_growth", "quiesced" => true} = request,
           output_bytes: 0
         },
         %{"result" => "growth_qualified", "transition" => transition}
       ),
       do: growth_matches?(request, transition)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "inspect_growth"} = request, output_bytes: 0},
         %{"result" => "growth_presence", "transition" => transition}
       ),
       do: transition == nil or growth_matches?(request, transition)

  defp terminal_matches?(
         domain,
         %{operation: %{"operation" => name, "create" => create}, output_bytes: bytes},
         %{
           "result" => "created",
           "receipt" => receipt
         }
       )
       when name in ~w(create create_oci create_registry_prepared create_checkpoint),
       do:
         (name == "create" or bytes == 0) and domain_matches?(domain, receipt) and
           Enum.all?(~w(name owner_token incarnation), &(receipt[&1] == create[&1]))

  defp terminal_matches?(_domain, %{operation: %{"operation" => name}}, %{
         "result" => "creation_presence"
       })
       when name in ~w(inspect_creation inspect_oci_creation inspect_registry_creation inspect_checkpoint_creation),
       do: true

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => name, "request" => request}, output_bytes: 0},
         %{"result" => "unbooted_branch_disposed", "proof" => proof}
       )
       when name in ~w(dispose_unbooted_branch resolve_unbooted_branch_disposal),
       do: UnbootedBranchDisposal.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "release_unbooted_branch_backing", "request" => request},
           output_bytes: 0
         },
         %{"result" => "branch_backing_released", "proof" => proof}
       ),
       do: UnbootedBranchBackingRelease.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "release_partial_branch_backing", "request" => request},
           output_bytes: 0
         },
         %{"result" => "branch_backing_released", "proof" => proof}
       ),
       do: PartialBranchBackingRelease.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "retire_prepared_branch", "request" => request},
           output_bytes: 0
         },
         %{"result" => "prepared_branch_retired", "proof" => proof}
       ),
       do: PreparedBranchRetirement.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "continue_held_branch_deletion", "request" => request},
           output_bytes: 0
         },
         %{"result" => "held_branch_deletion_continued", "proof" => proof}
       ),
       do: HeldBranchDeletionAction.matches?(proof, request, "continue")

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "cleanup_held_branch_deletion", "request" => request},
           output_bytes: 0
         },
         %{"result" => "held_branch_deletion_cleaned", "proof" => proof}
       ),
       do: HeldBranchDeletionAction.matches?(proof, request, "cleanup")

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "continue_released_branch_deletion", "request" => request},
           output_bytes: 0
         },
         %{"result" => "released_branch_deletion_continued", "proof" => proof}
       ),
       do: ReleasedBranchDeletionContinuation.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "cleanup_released_branch_deletion", "request" => request},
           output_bytes: 0
         },
         %{"result" => "released_branch_deletion_cleaned", "proof" => proof}
       ),
       do: ReleasedBranchDeletionCleanup.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => name, "request" => request}, output_bytes: 0},
         %{"result" => "partial_branch_disposed", "proof" => proof}
       )
       when name in ~w(dispose_partial_branch resolve_partial_branch_disposal qualify_partial_branch_cleanup),
       do: PartialBranchDisposal.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "qualify_partial_branch_cleanup", "request" => request},
           output_bytes: 0
         },
         %{"result" => "partial_branch_cleanup_candidate", "candidate" => candidate}
       ),
       do: PartialBranchCleanupCandidate.matches?(candidate, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "resolve_partial_branch_cleanup", "request" => request},
           output_bytes: 0
         },
         %{"result" => "partial_branch_cleanup_unneeded", "proof" => proof}
       ),
       do: PartialBranchDisposalCleanupUnneeded.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "cleanup_partial_branch_disposal", "request" => request},
           output_bytes: 0
         },
         %{"result" => "partial_branch_disposal_cleaned", "proof" => proof}
       ),
       do: PartialBranchDisposalCleanup.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "inspect_partial_branch_collection", "request" => request},
           output_bytes: 0
         },
         %{"result" => "partial_branch_collection_candidate", "candidate" => candidate}
       ),
       do: PartialBranchCollectionCandidate.matches?(candidate, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "collect_partial_branch", "request" => request},
           output_bytes: 0
         },
         %{"result" => "partial_branch_collected", "proof" => proof}
       ),
       do: PartialBranchCollection.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "collect_branch_deletion", "request" => request},
           output_bytes: 0
         },
         %{"result" => "branch_deletion_collected", "proof" => proof}
       ),
       do: BranchDeletionCollection.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "resolve_released_branch_deletion", "request" => request},
           output_bytes: 0
         },
         %{"result" => "released_branch_deletion_resolved", "proof" => proof}
       ),
       do: ReleasedBranchDeletionResolution.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "resolve_held_branch_deletion", "request" => request},
           output_bytes: 0
         },
         %{"result" => "held_branch_deletion_resolved", "proof" => proof}
       ),
       do: BranchDeletionResolution.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "release_branch_backing", "request" => request},
           output_bytes: 0
         },
         %{"result" => "branch_backing_released", "proof" => proof}
       ),
       do: BranchBackingRelease.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "qualify_branch_child_absence", "request" => request},
           output_bytes: 0
         },
         %{"result" => "branch_child_absent", "proof" => proof}
       ),
       do: BranchChildAbsence.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "release_held_branch", "request" => request},
           output_bytes: 0
         },
         %{"result" => "held_branch_released", "transition" => proof}
       ),
       do: HeldBranchReleaseRequest.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => "qualify_held_branch_release", "request" => request},
           output_bytes: 0
         },
         %{"result" => "held_branch_release_presence", "transition" => proof}
       ),
       do: proof == nil or HeldBranchReleaseRequest.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "create_branch", "request" => request}, output_bytes: 0},
         %{"result" => "branch_created", "completion" => proof}
       ),
       do: BranchCompletion.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{
           operation: %{"operation" => name, "request" => request},
           output_bytes: 0
         },
         %{"result" => "branch_completion_presence", "completion" => proof}
       )
       when name in ~w(inspect_branch_completion resolve_ready_branch_completion),
       do: proof == nil or BranchCompletion.matches?(proof, request)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "checkpoint_preflight"}, output_bytes: 0},
         %{"result" => "observed", "observation" => %{"state" => "running"}}
       ),
       do: true

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "branch_preflight"}, output_bytes: 0},
         %{
           "result" => "observed",
           "observation" => %{
             "state" => "running",
             "resources" => resources,
             "pid_identity" => [_pid, _birth],
             "configuration" => %{"network" => %{"enabled" => false}, "ports" => []} = config
           }
         }
       ),
       do: resources != nil and Map.get(config, "mounts") == nil

  defp terminal_matches?(_domain, %{operation: %{"operation" => name}}, %{"result" => "observed"})
       when name in ~w(inspect start start_oci start_checkpointable stop delete), do: true

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "exec_background", "command" => command}, output_bytes: 0},
         %{"result" => "launched", "pid" => pid}
       ),
       do: byte_size("pid=#{pid}\n") <= command["max_output_bytes"]

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => name, "command" => command}} = pending,
         %{"result" => "command"} = outcome
       )
       when name in ~w(exec exec_buffered exec_stream),
       do:
         outcome["output_bytes"] >= pending.output_bytes and
           outcome["output_bytes"] <= command["max_output_bytes"] and
           (outcome["completion"] != "exited" or outcome["output_bytes"] == pending.output_bytes) and
           (outcome["dispatch"] != "not_dispatched" or pending.output_bytes == 0)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "read_file", "options" => options}} = pending,
         %{"result" => "file"} = outcome
       ),
       do:
         outcome["observed_bytes"] >= pending.output_bytes and
           outcome["observed_bytes"] <= options["max_bytes"] and
           (outcome["completion"] != "completed" or
              outcome["observed_bytes"] == pending.output_bytes)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "write_file", "total_bytes" => total}} = pending,
         %{"result" => "file"} = outcome
       ),
       do:
         outcome["observed_bytes"] <= total and
           (outcome["completion"] != "completed" or
              (outcome["observed_bytes"] == total and pending.upload_bytes == total))

  defp terminal_matches?(_domain, _pending, _outcome), do: false

  defp consume(queue, 0, events), do: {:ok, queue, events}

  defp consume(queue, bytes, events) do
    case :queue.out(queue) do
      {{:value, size}, rest} when bytes >= size -> consume(rest, bytes - size, events + 1)
      {{:value, size}, rest} -> {:ok, :queue.in_r(size - bytes, rest), events}
      {:empty, _queue} -> :error
    end
  end

  defp growth_matches?(request, transition) do
    case GrowthTransition.from_wire(transition) do
      {:ok, proof} ->
        GrowthTransition.bound?(
          proof,
          request["receipt"],
          request["operation_id"],
          request["request"],
          request["previous"],
          Map.take(proof.change, ~w(storage_gib overlay_gib))
        )

      _ ->
        false
    end
  end
end
