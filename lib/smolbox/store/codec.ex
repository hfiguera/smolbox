defmodule SmolBox.Store.Codec do
  @moduledoc """
  Versioned data-only record encoding for trusted host store adapters.

  This is an internal persistence format, never an endpoint for guest or public
  input. Records are validated before encoding and after safe decoding. Compressed
  terms, trailing bytes, unknown schemas, unexpected structs/keys, PIDs, refs,
  ports, and closures are rejected. Payloads have a fixed 16 MiB cap.

  Encoding does not encrypt secrets. Durable adapters must authenticate and encrypt
  these bytes or use an explicitly approved equivalent secure storage policy.
  Schema v2 adds network policy. Exact v1 records are upgraded to offline defaults
  on read; offline fingerprints are unchanged. Old readers cannot read v2 writes.
  Image writes use v2, including offline executions. Checkpoint records use v3;
  v1/v2 envelopes cannot contain checkpoint references. Upgrade all controllers
  sharing a store before accepting checkpoints; older readers cannot read v3.
  See [Checkpoint upgrades](checkpoints.html#persistence-and-upgrades). Follow
  [Upgrading to 0.1.3](recovery.html#upgrading-to-0-1-3) across all controllers.
  Managed machines and associated commands now use v5, including no-port records.
  Exact v4 records gain empty port specifications and reservations on read.
  Older readers cannot read v5; coordinate upgrades before any managed writes.
  See [Port persistence](port-mappings.html#persistence-and-upgrades). Disposable writes retain their
  v2/v3 shape, omitting the empty managed-machine reference; old payloads gain that
  field on read. Upgrade every controller sharing workers before enabling retained
  reservations. See [Persistent-machine upgrades](persistent-machines.html#store-contract-and-upgrades).
  Background and extended-budget records use v6. Exact older commands gain
  `background: false`; ordinary writes omit that field to preserve prior formats.
  Old envelopes cannot contain extended budgets or background semantics. Upgrade
  readers/adapters together; see [Extended execution](long-running-exec.html#persistence-and-upgrades).
  Interactive records selectively use v7 with `Terminal.Spec` and `Terminal.Result`;
  older envelopes cannot contain interactive semantics. See
  [Terminal upgrades](interactive-terminals.html#persistence-and-upgrades).
  Workload machines selectively use v8; older machines gain `workload: nil` on
  read and retain prior encodings. Upgrade readers/adapters before advertising
  `managed_workloads: 1`; see [Workload upgrades](workloads.html#persistence-and-upgrades).
  Expanded guest path/file profiles selectively use v9, including any other
  features of that record. Exact older profiles gain `guest_paths: nil` and
  keep their old byte-budget constraints. Coordinate `guest_files: 1` support;
  see [Guest file upgrades](guest-files.html#recovery-and-upgrades).
  Remote registry/OCI sources selectively use v10, preserving manifest identity,
  safe credential references and preparation results. Managed OCI image pulls also
  use v10, with typed pull intent and image results. Older machine records gain
  `preparation: nil`; their encodings and fingerprints remain unchanged. Old
  envelopes reject remote sources. Upgrade all readers and the atomic source
  reservation contract before advertising `registry_sources: 1`. Rolling back
  to an older reader with v10 records, including deleted tombstones, is unsupported.
  Machines with export history selectively use v11, including completed and
  cancelled export records in deleted tombstones. Older machines gain empty
  `exports` and nil `active_export` fields while keeping their old encodings.
  Upgrade every reader and resource projection writer before advertising
  `managed_exports: 1`; see [Export upgrades](machine-exports.html#durable-restart-and-compatibility).
  Opted-in checkpointable machines and capture histories selectively use v12.
  Earlier machines gain `checkpointable: false`, empty captures and nil active
  capture. Preserve retained artifact projections even after source deletion;
  coordinate all readers/writers before enabling `managed_checkpoints: 1`.
  See [Managed checkpoint upgrades](managed-checkpoints.html#persistence-and-upgrades).
  Branch children and sources with branch history selectively use v13. Earlier
  machines gain nil branch/active-branch fields and an empty child map without
  changing their prior encodings. Upgrade shared readers and projections before
  `managed_branches: 1`; retained backing is accounted for after child deletion.
  See [Managed branch upgrades](managed-branches.html#durable-adapters-and-compatibility).
  Disk expansion histories and commands on expanded machines selectively use v14.
  Earlier machines gain empty expansion history and no effective disk override.
  Upgrade every reader and resource projection writer before advertising
  `managed_disk_expansion: 1`; old readers cannot decode v14, even tombstones.
  Local volumes, mounted managed machines and their command observations use v15.
  Earlier records gain empty mounts and volume references without changing their
  encodings. Coordinate all readers, attachment transactions and reservation
  projections before advertising `local_volumes: 1`. See [Local volumes](local-volumes.html).
  Embedded assignments selectively use v16, including native creation intent and
  receipt evidence in retained commands and deleted tombstones. Earlier records
  gain nil backend fields on read and omit them on write. Native fields are
  rejected in older envelopes. Coordinate every reader and atomic reservation
  writer before enabling embedded admission; rollback to older readers with
  native records is unsupported. The schema alone does not enable that backend.
  Versioned native material assignments selectively use v17. Legacy v16
  assignments gain `version: 1` on read and omit it on write, preserving their
  original bytes. Version-2 creation authority and material proofs cannot be
  encoded as v16 or older records. Upgrade every reader and reservation/resource
  projection writer before advertising `native_material_proofs: 2` or activating
  protocol-2 targets; unknown v17 bytes must never be treated as absent.
  Native background launch intent/results retain v17 and the existing Command/
  LaunchResult shapes. Older native validators reject these combinations.
  Coordinate every reader before advertising `native_background_launches: 1`;
  material-reader version 2 alone does not authorize this additional feature.
  Native retained terminal intent/results also retain v17, reusing Terminal.Spec/
  Terminal.Result. Older native validators reject this combination. Coordinate
  every reader and command-slot transaction before advertising
  `native_terminal_sessions: 1`; HTTP terminals keep v7 and legacy v16 rejects
  native terminal authority. A reader marker does not enable a helper capability.
  Silently treating undecodable records as absent
  would permit replay and is forbidden.
  Native expansion histories and commands carrying grown native authority use
  v18. Earlier HTTP/v16/v17 envelopes omit the new nil proof defaults exactly.
  Install every reader and resource writer before advertising native_disk_growth:
  1 alongside managed_disk_expansion: 1. This marker enables neither an SDK feature
  nor growth dispatch; public helper feature approval remains separate.
  Typed native OCI creation intent and retained image-pull records selectively
  use v19. Their source identity remains distinct from a local pack's content
  digest. Earlier native and HTTP envelopes retain their exact encodings and
  reject these new native shapes. Upgrade every reader and reservation writer
  before advertising native_sources: 1 alongside registry_sources: 1 (and
  managed_images: 1 for image operations). Reader support alone enables neither
  a source catalog assignment nor preparation, creation or startup dispatch.
  Native volumes selectively use v20, retaining an enrolled owner binding and
  exact provision/deletion/abort authority. HTTP volumes retain identical v15
  bytes and acquire nil native_authority on read. Earlier envelopes reject even
  an explicitly nil new field. Bare readiness/deletion acknowledgments cannot
  complete native records. Install every reader, projection writer, native
  recovery and attachment transaction before enabling native volume admission;
  this codec foundation does not advertise a native volume reader capability.
  Machines holding native volume attachments selectively use v21, including
  pre-allocation records and retirement tombstones. Each attachment retains its
  volume key, enrolled binding, exact provision proof, guest target and read-only
  mode. Earlier HTTP/native envelopes omit the empty native_mounts default and
  reject even explicit empty new fields. Install every reader and atomic attachment/
  release writer before activation; v21 alone enables no mount or SDK feature.
  Native checkpoint restore-source assignments selectively use v22, retaining
  immutable source identity and captured allocations separately from operator
  paths. Earlier native envelopes reject these shapes; HTTP checkpoint records
  retain their exact envelopes. Upgrade every reader and atomic reservation
  writer before advertising native_checkpoint_sources: 1. This marker enables
  neither capture histories nor public checkpoint feature admission.
  Explicit native checkpointable creation opt-in selectively uses v23. The true
  marker is immutable and retained by attached commands; earlier native envelopes
  reject its presence. Omission keeps ordinary native and HTTP bytes unchanged.
  Upgrade every reader and reservation writer before advertising
  native_checkpointable: 1; this marker does not activate capture or its histories.
  Native capture histories and attached mixed material evidence selectively use
  v24. Original creation receipts remain immutable; ordered growth/capture links
  prove current material separately. Earlier envelopes omit new nil defaults and
  reject their presence. Upgrade every reader and atomic history/identity writer
  before advertising native_capture_histories: 1. HTTP and native records without
  capture histories keep their earlier bytes. This marker does not enable public
  capture admission or establish native platform qualification.
  Source-only entered-capture resolution histories selectively use v25. The typed
  resolution proof cannot be decoded as capture completion or carried in older
  envelopes. Upgrade every reader and atomic source/history/resource writer
  before advertising native_capture_resolutions: 1. V24 captured histories and
  all earlier supported HTTP/native records preserve their encodings. The reader
  marker activates neither checkpoint dispatch nor staging cleanup.
  Native captures accepted with a frozen source receipt, and records containing
  native cleanup authority, selectively use v26. Upgrade every reader and guarded
  cleanup/accounting writer before advertising native_capture_cleanup: 1. Older
  envelopes strip new nil defaults and reject their presence. HTTP, v24 capture
  histories and v25 resolution histories without these fields keep their bytes.
  Pre-entry aborted-source qualifications selectively use v27, preserving material
  history and artifact accounting. Upgrade every reader and atomic resolution
  writer before advertising native_capture_abort_sources: 1; older envelopes
  reject the new field even when nil. Records without qualification retain v26
  or their earlier compatible envelopes.

  V28 stores native export histories with frozen source authority, immutable
  bounded dispatch requests, correlated publication acknowledgements and distinct
  explicit cleanup evidence. Deploy the reader and guarded export transactions
  before advertising native_export_histories: 1. Older envelopes reject the new
  fields even when nil. HTTP export histories preserve v11 bytes; native records
  without exports retain their earlier selected envelope. Registry verification
  and staging cleanup remain separate from native publication acknowledgement.

  Typed native branch source-publication and child-release material histories
  selectively use v29, including attached commands carrying those links. Every
  link retains its prior receipt and canonical proof; the immutable creation
  receipt stays separate. V24-v28 and earlier readers reject these typed histories.
  Records without branch links preserve their earlier bytes. Coordinate every
  reader and atomic source/child history/resource writer before advertising
  native_branch_histories: 1. This codec foundation advertises no store capability
  and enables neither branch admission nor child creation/release transactions.

  Frozen native branch child assignments and source dependency/history records
  selectively use v30. Each child retains a distinct owner/incarnation and exact
  source/public request binding. Branch assignment data cannot become fresh SDK
  creation authority. Earlier records gain empty native_branch_history and nil
  Branch.native_authority defaults without changing their encoded bytes. Older
  envelopes reject native branch semantics even with those defaults stripped.
  Coordinate every reader and atomic source/child resource writer before native
  branch admission. The reader alone advertises no store or helper capability;
  public lifecycle/qualification remains a separate gate. Completed child records
  retain the original completion, immutable root and exact optional initial-release
  chain. Commands retaining a native child assignment also use v30; source
  commands carrying only branch material links retain v29.

  Explicit native held-release intent, results and attached commands selectively
  use v31. Release authority binds its original public version, current source
  material, child root, both process identities and exact request. Earlier native
  branch authority gains release: nil on read and keeps its v30 bytes. Older
  envelopes reject explicit release semantics, including attached material proof.
  Upgrade every reader and paired source/child release writer before activation;
  this codec advertises no native feature or store capability by itself.
  """

  alias SmolBox.{Error, Execution, ExecutionFeatures}

  alias SmolBox.Store.{
    CodecBranches,
    CodecCaptures,
    CodecCheckpointable,
    CodecExecution,
    CodecExpansion,
    CodecExports,
    CodecFiles,
    CodecGrowth,
    CodecMaterial,
    CodecNative,
    CodecNativeBranchAuthority,
    CodecNativeBranches,
    CodecNativeBranchReleases,
    CodecNativeCaptureAbortSources,
    CodecNativeCaptureCleanup,
    CodecNativeCaptureResolutions,
    CodecNativeCaptures,
    CodecNativeCheckpoints,
    CodecNativeExports,
    CodecNativeMounts,
    CodecNativeSources,
    CodecNativeVolumes,
    CodecPorts,
    CodecSources,
    CodecVolumes,
    CodecWorkload
  }

  @max_bytes 16_777_216
  @native_branch_releases_prefix "smolbox-record-v31\0"
  @native_branch_authority_prefix "smolbox-record-v30\0"
  @native_branches_prefix "smolbox-record-v29\0"
  @native_exports_prefix "smolbox-record-v28\0"
  @native_prefix "smolbox-record-v16\0"
  @material_prefix "smolbox-record-v17\0"
  @growth_prefix "smolbox-record-v18\0"
  @native_sources_prefix "smolbox-record-v19\0"
  @native_volumes_prefix "smolbox-record-v20\0"
  @native_mounts_prefix "smolbox-record-v21\0"
  @native_checkpoints_prefix "smolbox-record-v22\0"
  @native_captures_prefix "smolbox-record-v24\0"
  @native_capture_abort_sources_prefix "smolbox-record-v27\0"
  @native_capture_cleanup_prefix "smolbox-record-v26\0"
  @native_capture_resolutions_prefix "smolbox-record-v25\0"
  @checkpointable_prefix "smolbox-record-v23\0"
  @volumes_prefix "smolbox-record-v15\0"
  @expansion_prefix "smolbox-record-v14\0"
  @branches_prefix "smolbox-record-v13\0"
  @captures_prefix "smolbox-record-v12\0"
  @exports_prefix "smolbox-record-v11\0"
  @sources_prefix "smolbox-record-v10\0"
  @prefix "smolbox-record-v2\0"
  @checkpoint_prefix "smolbox-record-v3\0"
  @managed_prefix "smolbox-record-v4\0"
  @files_prefix "smolbox-record-v9\0"
  @workload_prefix "smolbox-record-v8\0"
  @terminal_prefix "smolbox-record-v7\0"
  @execution_prefix "smolbox-record-v6\0"
  @ports_prefix "smolbox-record-v5\0"
  @legacy_prefix "smolbox-record-v1\0"
  @record_modules [
    Execution,
    SmolBox.Backend.Binding,
    SmolBox.Backend.Assignment,
    SmolBox.Embedded.Identity,
    SmolBox.Embedded.BranchPublication,
    SmolBox.Embedded.BranchReleaseTransition,
    SmolBox.Embedded.NativeBranchAuthority,
    SmolBox.Embedded.NativeBranchRelease,
    SmolBox.Embedded.BranchCompletion,
    SmolBox.Embedded.GrowthTransition,
    SmolBox.Embedded.CaptureTransition,
    SmolBox.Embedded.CaptureResolutionTransition,
    SmolBox.Embedded.CaptureStagingCleanupReceipt,
    SmolBox.Embedded.NativeCaptureCleanup,
    SmolBox.Embedded.ExportAuthority,
    SmolBox.Embedded.ExportPublication,
    SmolBox.Embedded.ExportStageCleanup,
    SmolBox.Embedded.CaptureAbortSourceQualification,
    SmolBox.Embedded.VolumeAuthority,
    SmolBox.Embedded.VolumeAttachment,
    SmolBox.ManagedMachine,
    SmolBox.ManagedMachineSpec,
    SmolBox.ExecutionSpec,
    SmolBox.ExecutionValidation,
    SmolBox.Command,
    SmolBox.Profile,
    SmolBox.NetworkPolicy,
    SmolBox.Machine,
    SmolBox.PortMapping,
    SmolBox.Result,
    SmolBox.LaunchResult,
    SmolBox.Workload,
    SmolBox.GuestPaths,
    SmolBox.ArtifactPreparation,
    SmolBox.Source,
    SmolBox.ImagePull,
    SmolBox.Image,
    SmolBox.DiskExpansion,
    SmolBox.Volume,
    SmolBox.VolumePolicy,
    SmolBox.VolumeMount,
    SmolBox.Mount,
    SmolBox.Branch,
    SmolBox.BranchSpec,
    SmolBox.BranchPolicy,
    SmolBox.CheckpointCapture,
    SmolBox.Checkpoint,
    SmolBox.CheckpointCaptureSpec,
    SmolBox.CheckpointPolicy,
    SmolBox.CheckpointResult,
    SmolBox.Export,
    SmolBox.ExportSpec,
    SmolBox.ExportDestination,
    SmolBox.ExportReceipt,
    SmolBox.ExportResult,
    SmolBox.Terminal.Spec,
    SmolBox.Terminal.Result,
    Error
  ]

  @spec encode(Execution.t() | SmolBox.ManagedMachine.t() | SmolBox.Volume.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def encode(%SmolBox.Volume{} = record),
    do:
      if(CodecNativeVolumes.required?(record),
        do: encode_native_volume(record),
        else: encode_volumes(record)
      )

  def encode(%{spec: %{profile: %SmolBox.Profile{} = profile}} = record) do
    cond do
      CodecNativeBranchReleases.required?(record) -> encode_native_branch_releases(record)
      CodecNativeBranchAuthority.required?(record) -> encode_native_branch_authority(record)
      CodecNativeBranches.required?(record) -> encode_native_branches(record)
      true -> encode_profile(record, profile)
    end
  end

  def encode(_record), do: invalid()

  defp encode_profile(record, profile) do
    cond do
      CodecNativeExports.required?(record) ->
        encode_native_exports(record)

      CodecNativeCaptureAbortSources.required?(record) ->
        encode_native_capture_abort_sources(record)

      CodecNativeCaptureCleanup.required?(record) ->
        encode_native_capture_cleanup(record)

      CodecNativeCaptureResolutions.required?(record) ->
        encode_native_capture_resolutions(record)

      CodecNativeCaptures.required?(record) ->
        encode_native_captures(record)

      CodecNativeMounts.required?(record) ->
        encode_native_mounts(record)

      CodecNative.required?(record) ->
        encode_native(record)

      true ->
        encode_compatible(record, profile)
    end
  end

  defp encode_compatible(record, profile) do
    cond do
      CodecVolumes.required?(record) -> encode_volumes(record)
      CodecExpansion.required?(record) -> encode_expansion(record)
      CodecBranches.required?(record) -> encode_branches(record)
      CodecCaptures.required?(record) -> encode_captures(record)
      CodecExports.required?(record) -> encode_exports(record)
      CodecSources.required?(record) -> encode_sources(record)
      SmolBox.FileAccess.extended?(profile) -> encode_files(record)
      true -> encode_existing(record)
    end
  end

  defp encode_existing(%SmolBox.ManagedMachine{spec: %{workload: %SmolBox.Workload{}}} = record),
    do: encode_versioned(record, @workload_prefix)

  defp encode_existing(%{spec: spec} = record) do
    if ExecutionFeatures.interactive?(spec),
      do: encode_terminal(record),
      else: encode_nonterminal(record)
  end

  defp encode_nonterminal(%{spec: spec} = record) do
    if ExecutionFeatures.extended?(spec),
      do: encode_extended(record),
      else: encode_original(record)
  end

  defp encode_original(%SmolBox.ManagedMachine{} = record), do: encode_managed(record)

  defp encode_original(%Execution{managed_machine: key} = record) when not is_nil(key),
    do: encode_managed(record)

  defp encode_original(record) do
    with :ok <- Execution.validate(record) do
      prefix = if checkpoint_record?(record), do: @checkpoint_prefix, else: @prefix

      bytes =
        prefix <>
          legacy_payload(
            Map.delete(
              CodecPorts.strip(CodecExecution.strip(CodecFiles.strip(record))),
              :managed_machine
            )
          )

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  @spec decode(binary()) ::
          {:ok, Execution.t() | SmolBox.ManagedMachine.t() | SmolBox.Volume.t()}
          | {:error, Error.t()}
  def decode(<<@native_branch_releases_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_native_branch_releases(bytes)

  def decode(<<@native_branch_authority_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_native_branch_authority(bytes)

  def decode(<<@native_branches_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_native_branches(bytes)

  def decode(<<@native_exports_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_native_exports(bytes)

  def decode(<<@native_capture_abort_sources_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_native_capture_abort_sources(bytes)

  def decode(<<@native_capture_cleanup_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_native_capture_cleanup(bytes)

  def decode(<<@native_capture_resolutions_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_native_capture_resolutions(bytes)

  def decode(<<@native_captures_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_native_captures(bytes)

  def decode(<<@checkpointable_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_checkpointable(bytes)

  def decode(<<@native_checkpoints_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_native_checkpoints(bytes)

  def decode(<<@native_mounts_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_native_mounts(bytes)

  def decode(<<@native_volumes_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_native_volume(bytes)

  def decode(<<@native_sources_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_native_sources(bytes)

  def decode(<<@growth_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_growth(bytes)

  def decode(<<@material_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_material(bytes)

  def decode(<<@native_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_native(bytes)

  def decode(<<@volumes_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_volumes(bytes)

  def decode(<<@expansion_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_expansion(bytes)

  def decode(<<@branches_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_branches(bytes)

  def decode(<<@captures_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_captures(bytes)

  def decode(<<@exports_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_exports(bytes)

  def decode(<<@sources_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes, do: decode_sources(bytes)

  def decode(<<@prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes do
    decode_version(bytes, false, false)
  end

  def decode(<<@legacy_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_version(bytes, true, false)

  def decode(<<@checkpoint_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_version(bytes, false, true)

  def decode(<<@managed_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_managed(bytes, false)

  def decode(<<@ports_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_managed(bytes, true)

  def decode(<<@execution_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_extended(bytes)

  def decode(<<@terminal_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_terminal(bytes)

  def decode(<<@workload_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_workload(bytes)

  def decode(<<@files_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_files(bytes)

  def decode(_bytes), do: invalid()

  defp old_payload(record), do: record |> CodecNativeCaptures.strip() |> :erlang.term_to_binary()

  defp old_term(payload) do
    {record, used} = :erlang.binary_to_term(payload, [:safe, :used])
    {CodecNativeCaptures.upgrade(record), used}
  end

  defp encode_native_exports(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @native_exports_prefix <> :erlang.term_to_binary(CodecNativeBranchAuthority.strip(record))

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp encode_native_branches(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @native_branches_prefix <>
          :erlang.term_to_binary(CodecNativeBranchAuthority.strip(record))

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp encode_native_branch_authority(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @native_branch_authority_prefix <>
          :erlang.term_to_binary(CodecNativeBranchReleases.strip(record))

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_native_branch_authority(<<@native_branch_authority_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload) and CodecNativeBranchAuthority.required?(record),
         record = CodecNativeBranchReleases.upgrade(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_native_branch_releases(record) do
    with :ok <- validate_extended(record) do
      bytes = @native_branch_releases_prefix <> :erlang.term_to_binary(record)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_native_branch_releases(<<@native_branch_releases_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload) and CodecNativeBranchReleases.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_native_branches(<<@native_branches_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload) and CodecNativeBranches.required?(record),
         record = CodecNativeBranchAuthority.upgrade(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_native_exports(<<@native_exports_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload) and CodecNativeExports.required?(record),
         record = CodecNativeBranchAuthority.upgrade(record),
         false <- CodecNativeBranches.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_native_capture_abort_sources(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @native_capture_abort_sources_prefix <>
          :erlang.term_to_binary(CodecNativeExports.strip(record))

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_native_capture_abort_sources(
         <<@native_capture_abort_sources_prefix, payload::binary>>
       ) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         record = CodecNativeExports.upgrade(record),
         true <- used == byte_size(payload) and CodecNativeCaptureAbortSources.required?(record),
         false <- CodecNativeBranches.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_native_capture_cleanup(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @native_capture_cleanup_prefix <>
          :erlang.term_to_binary(CodecNativeCaptureAbortSources.strip(record))

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_native_capture_cleanup(<<@native_capture_cleanup_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         record = CodecNativeCaptureAbortSources.upgrade(record),
         true <- used == byte_size(payload) and CodecNativeCaptureCleanup.required?(record),
         false <- CodecNativeBranches.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_native_captures(record),
    do: encode_capture_history(record, @native_captures_prefix)

  defp encode_native_capture_resolutions(record),
    do: encode_capture_history(record, @native_capture_resolutions_prefix)

  defp encode_capture_history(record, prefix) do
    with :ok <- validate_extended(record) do
      bytes = prefix <> :erlang.term_to_binary(CodecNativeCaptureCleanup.strip(record))
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_native_capture_resolutions(<<@native_capture_resolutions_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         record = CodecNativeCaptureCleanup.upgrade(record),
         true <- used == byte_size(payload) and CodecNativeCaptureResolutions.required?(record),
         false <- CodecNativeBranches.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_native_captures(<<@native_captures_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         record = CodecNativeCaptureCleanup.upgrade(record),
         true <- used == byte_size(payload) and CodecNativeCaptures.required?(record),
         false <- CodecNativeBranches.required?(record),
         false <- CodecNativeCaptureResolutions.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_native(record) do
    with :ok <- validate_extended(record) do
      bytes =
        cond do
          CodecCheckpointable.required?(record) ->
            @checkpointable_prefix <> old_payload(CodecNativeMounts.strip(record))

          CodecNativeCheckpoints.required?(record) ->
            @native_checkpoints_prefix <> old_payload(CodecNativeMounts.strip(record))

          CodecNativeSources.required?(record) ->
            @native_sources_prefix <> old_payload(CodecNativeMounts.strip(record))

          CodecGrowth.required?(record) ->
            @growth_prefix <> old_payload(CodecNativeMounts.strip(record))

          CodecMaterial.required?(record) ->
            @material_prefix <>
              old_payload(record |> CodecGrowth.strip() |> CodecNativeMounts.strip())

          true ->
            @native_prefix <>
              old_payload(record |> CodecMaterial.strip() |> CodecNativeMounts.strip())
        end

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_native(<<@native_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- old_term(payload),
         record = CodecNativeMounts.upgrade(record),
         false <- CodecCheckpointable.required?(record),
         record = CodecMaterial.upgrade(record),
         true <- used == byte_size(payload) and CodecNative.required?(record),
         false <- CodecNativeSources.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_invalid -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_volumes(record) do
    with :ok <- validate_extended(record) do
      bytes = @volumes_prefix <> CodecNative.payload(record)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp encode_native_mounts(record) do
    with :ok <- validate_extended(record) do
      bytes = @native_mounts_prefix <> old_payload(record)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_native_mounts(<<@native_mounts_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- old_term(payload),
         true <- used == byte_size(payload) and CodecNativeMounts.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_native_volume(record) do
    with :ok <- validate_extended(record) do
      bytes = @native_volumes_prefix <> old_payload(record)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_native_volume(<<@native_volumes_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- old_term(payload),
         true <- used == byte_size(payload) and CodecNativeVolumes.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_material(<<@material_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- old_term(payload),
         record = CodecNativeMounts.upgrade(record),
         false <- CodecCheckpointable.required?(record),
         record = CodecGrowth.upgrade(record),
         true <- used == byte_size(payload) and CodecMaterial.required?(record),
         true <- CodecNative.required?(record),
         false <- CodecNativeSources.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_invalid -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_growth(<<@growth_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- old_term(payload),
         record = CodecNativeMounts.upgrade(record),
         false <- CodecCheckpointable.required?(record),
         true <- used == byte_size(payload) and CodecGrowth.required?(record),
         true <- CodecMaterial.required?(record) and CodecNative.required?(record),
         false <- CodecNativeSources.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_native_sources(<<@native_sources_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- old_term(payload),
         record = CodecNativeMounts.upgrade(record),
         false <- CodecCheckpointable.required?(record),
         false <- CodecNativeCheckpoints.required?(record),
         true <- used == byte_size(payload) and CodecNativeSources.required?(record),
         true <- CodecMaterial.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_native_checkpoints(<<@native_checkpoints_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- old_term(payload),
         record = CodecNativeMounts.upgrade(record),
         false <- CodecCheckpointable.required?(record),
         true <- used == byte_size(payload) and CodecNativeCheckpoints.required?(record),
         true <- CodecMaterial.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_checkpointable(<<@checkpointable_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- old_term(payload),
         record = CodecNativeMounts.upgrade(record),
         true <- used == byte_size(payload) and CodecCheckpointable.required?(record),
         true <- CodecMaterial.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp decode_volumes(<<@volumes_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- CodecNative.legacy_term(payload),
         true <- used == byte_size(payload) and CodecVolumes.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_expansion(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @expansion_prefix <> CodecNative.payload(CodecVolumes.strip(record))

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_expansion(<<@expansion_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- CodecNative.legacy_term(payload),
         true <- used == byte_size(payload) and CodecExpansion.required?(record),
         record = CodecVolumes.upgrade(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_branches(record) do
    with :ok <- validate_extended(record) do
      bytes = @branches_prefix <> CodecNative.payload(CodecExpansion.strip(record))
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_branches(<<@branches_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- CodecNative.legacy_term(payload),
         record = CodecExpansion.upgrade(record),
         true <- used == byte_size(payload) and CodecBranches.required?(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_captures(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @captures_prefix <>
          CodecNative.payload(CodecExpansion.strip(CodecBranches.strip(record)))

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_captures(<<@captures_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- CodecNative.legacy_term(payload),
         record = CodecExpansion.upgrade(record),
         true <- used == byte_size(payload) and CodecCaptures.required?(record),
         record = CodecBranches.upgrade(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_exports(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @exports_prefix <>
          CodecNative.payload(
            CodecExpansion.strip(CodecCaptures.strip(CodecBranches.strip(record)))
          )

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_exports(<<@exports_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- CodecNative.legacy_term(payload),
         record = CodecExpansion.upgrade(record),
         true <- used == byte_size(payload),
         true <- CodecExports.required?(record),
         record = CodecCaptures.upgrade(record),
         record = CodecBranches.upgrade(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_invalid -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp encode_sources(record) do
    with :ok <- validate_extended(record) do
      bytes =
        @sources_prefix <>
          CodecNative.payload(
            CodecExpansion.strip(
              CodecExports.strip(CodecCaptures.strip(CodecBranches.strip(record)))
            )
          )

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_sources(<<@sources_prefix, payload::binary>>) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    with {record, used} <- CodecNative.legacy_term(payload),
         record = CodecExpansion.upgrade(record),
         true <- used == byte_size(payload),
         true <- CodecSources.required?(record),
         record = CodecCaptures.upgrade(CodecExports.upgrade(record)),
         record = CodecBranches.upgrade(record),
         :ok <- validate_extended(record),
         do: {:ok, record},
         else: (_invalid -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  defp legacy_payload(record),
    do:
      CodecNative.payload(
        CodecExpansion.strip(
          CodecExports.strip(CodecSources.strip(CodecCaptures.strip(CodecBranches.strip(record))))
        )
      )

  defp encode_files(record) do
    with :ok <- validate_extended(record) do
      bytes = @files_prefix <> legacy_payload(record)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_files(bytes) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    payload =
      binary_part(bytes, byte_size(@files_prefix), byte_size(bytes) - byte_size(@files_prefix))

    with {record, used} <- CodecSources.legacy_term(payload),
         true <- used == byte_size(payload),
         :ok <- validate_extended(record),
         true <- SmolBox.FileAccess.extended?(record.spec.profile),
         do: {:ok, record},
         else: (_invalid -> invalid())
  rescue
    _invalid -> invalid()
  end

  defp decode_workload(bytes) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    payload =
      binary_part(
        bytes,
        byte_size(@workload_prefix),
        byte_size(bytes) - byte_size(@workload_prefix)
      )

    with {%SmolBox.ManagedMachine{spec: %{workload: %SmolBox.Workload{}}} = record, used} <-
           CodecSources.legacy_term(payload),
         true <- used == byte_size(payload),
         {:ok, record} <- CodecFiles.upgrade(record),
         :ok <- validate_managed(record),
         do: {:ok, record},
         else: (_invalid -> invalid())
  rescue
    _invalid -> invalid()
  end

  defp encode_terminal(record) do
    with :ok <- Execution.validate(record) do
      bytes = @terminal_prefix <> legacy_payload(CodecFiles.strip(record))
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_terminal(bytes) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    payload =
      binary_part(
        bytes,
        byte_size(@terminal_prefix),
        byte_size(bytes) - byte_size(@terminal_prefix)
      )

    with {record, used} <- CodecSources.legacy_term(payload),
         true <- used == byte_size(payload),
         {:ok, record} <- CodecFiles.upgrade(record),
         true <- ExecutionFeatures.interactive?(record.spec),
         :ok <- Execution.validate(record),
         do: {:ok, record},
         else: (_invalid -> invalid())
  rescue
    _invalid -> invalid()
  end

  defp encode_extended(record), do: encode_versioned(record, @execution_prefix)

  defp encode_versioned(record, prefix) do
    with :ok <- validate_extended(record) do
      bytes = prefix <> legacy_payload(CodecFiles.strip(CodecWorkload.strip(record)))
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp decode_extended(bytes) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    payload =
      binary_part(
        bytes,
        byte_size(@execution_prefix),
        byte_size(bytes) - byte_size(@execution_prefix)
      )

    with {record, used} <- CodecSources.legacy_term(payload),
         true <- used == byte_size(payload),
         {:ok, record} <- CodecFiles.upgrade(record),
         {:ok, record} <- CodecWorkload.upgrade(record),
         :ok <- validate_extended(record),
         true <-
           ExecutionFeatures.extended?(record.spec) and
             not ExecutionFeatures.interactive?(record.spec) do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  defp validate_extended(%SmolBox.Volume{} = record), do: SmolBox.Volume.validate(record)
  defp validate_extended(%Execution{} = record), do: Execution.validate(record)
  defp validate_extended(record), do: validate_managed(record)

  defp decode_managed(bytes, ports?) do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    payload =
      binary_part(
        bytes,
        byte_size(@managed_prefix),
        byte_size(bytes) - byte_size(@managed_prefix)
      )

    with {record, used} <- CodecSources.legacy_term(payload),
         true <- used == byte_size(payload),
         {:ok, record} <- CodecFiles.upgrade(record),
         {:ok, record} <- if(ports?, do: {:ok, record}, else: CodecPorts.upgrade(record)),
         {:ok, record} <- CodecExecution.upgrade(record),
         {:ok, record} <- CodecWorkload.upgrade(record),
         :ok <- validate_managed(record) do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  defp encode_managed(record) do
    with :ok <- validate_managed(record) do
      bytes =
        @ports_prefix <>
          legacy_payload(CodecFiles.strip(CodecWorkload.strip(CodecExecution.strip(record))))

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp validate_managed(%SmolBox.ManagedMachine{} = record),
    do: SmolBox.ManagedMachine.validate(record)

  defp validate_managed(%Execution{managed_machine: key} = record) when not is_nil(key),
    do: Execution.validate(record)

  defp validate_managed(_record), do: invalid()

  defp decode_version(bytes, legacy?, checkpoint?) do
    with {:ok, record} <- decode_payload(bytes, legacy?),
         true <- checkpoint_record?(record) == checkpoint? do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  end

  defp checkpoint_record?(%{spec: %{artifact: %{"kind" => "checkpoint"}}}), do: true
  defp checkpoint_record?(_record), do: false

  defp decode_payload(bytes, legacy?) do
    # A fresh BEAM must load the finite schema vocabulary before safe decoding;
    # persisted bytes never get to intern new atoms themselves.
    Enum.each(@record_modules, &Code.ensure_loaded!/1)
    payload = binary_part(bytes, byte_size(@prefix), byte_size(bytes) - byte_size(@prefix))

    with {record, used} <- CodecSources.legacy_term(payload),
         true <- used == byte_size(payload),
         {:ok, record} <- CodecFiles.upgrade(record),
         {:ok, record} <- upgrade(record, legacy?),
         {:ok, record} <- CodecPorts.upgrade(record),
         {:ok, record} <- CodecExecution.upgrade(record),
         :ok <- Execution.validate(record),
         true <- record.managed_machine == nil do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  defp upgrade(%Execution{} = record, false),
    do: {:ok, Map.put_new(record, :managed_machine, nil)}

  defp upgrade(_record, false), do: invalid()

  defp upgrade(%Execution{spec: %SmolBox.ExecutionSpec{profile: profile}} = record, true) do
    with {:ok, profile} <- legacy_field(profile, SmolBox.Profile),
         {:ok, machine} <- legacy_field(record.created_machine, SmolBox.Machine) do
      {:ok,
       Map.put_new(
         %{record | spec: %{record.spec | profile: profile}, created_machine: machine},
         :managed_machine,
         nil
       )}
    end
  end

  defp upgrade(_record, true), do: invalid()
  defp legacy_field(nil, SmolBox.Machine), do: {:ok, nil}

  defp legacy_field(value, module) when is_map(value) do
    expected =
      module |> struct() |> Map.keys() |> Enum.reject(&(&1 in [:network, :ports])) |> Enum.sort()

    if Map.get(value, :__struct__) == module and Enum.sort(Map.keys(value)) == expected,
      do: {:ok, Map.put(value, :network, :offline)},
      else: invalid()
  end

  defp legacy_field(_value, _module), do: invalid()
  defp invalid, do: {:error, %Error{category: :store, operation: :codec}}
end
