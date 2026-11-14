defmodule SmolBox.Backend.Assignment do
  @moduledoc """
  Durable embedded creation intent associated with a target/domain binding.

  Ownership and incarnation tokens are generated before an atomic reservation
  write and retained across helper restarts. Public runtime startup separately
  validates the target and store capabilities. Inspect output omits creation evidence.
  """
  alias SmolBox.Backend.{Binding, Features}

  alias SmolBox.{
    ArtifactPreparation,
    Checkpoint,
    Command,
    Error,
    ExecutionSpec,
    Export,
    ImagePull,
    ManagedMachine,
    ManagedMachineSpec,
    Profile,
    Source,
    Validation
  }

  alias SmolBox.Embedded.{
    BranchCreation,
    BranchPublication,
    BranchRequest,
    CheckpointContract,
    Config,
    CreationFeatures,
    Identity,
    Launch,
    MaterialHistory,
    MountContract,
    NativeBranchAuthority,
    NativeGrowth,
    NativeSource,
    Request
  }

  alias SmolBox.Terminal.Spec, as: TerminalSpec

  @enforce_keys [:binding, :creation]
  @derive {Inspect, only: [:binding]}
  defstruct @enforce_keys ++ [version: 1]
  @type t :: %__MODULE__{binding: Binding.t(), creation: map(), version: 1 | 2}

  # Generate once before the atomic reservation write, never inside dispatch.
  @doc false
  def new(config, spec, name, attachments \\ []) do
    with :ok <- Config.validate(config),
         :ok <- validate_spec(spec),
         true <- MountContract.attachments_match?(attachments, spec),
         true <-
           admission_spec?(spec, Config.protocol_major(config)) and
             profile_approved?(config, spec),
         true <-
           CreationFeatures.approved?(CreationFeatures.from_spec(spec), config) and
             command_approved?(config, spec) and volume_spec_approved?(config, spec),
         artifact when not is_nil(artifact) <- approved_artifact(config, spec.artifact) do
      assignment = %__MODULE__{
        version: Config.protocol_major(config),
        binding: struct!(Binding, Config.domain_binding(config)),
        creation:
          CreationFeatures.attach(
            %{
              "name" => name,
              "owner_token" => random(32),
              "incarnation" => random(16),
              provision_key(artifact) => provision_value(artifact),
              "resources" => resources(spec.profile),
              "labels" => %{}
            },
            CreationFeatures.from_spec(spec)
          )
          |> MountContract.attach(attachments)
          |> CheckpointContract.attach(spec)
      }

      if valid?(assignment) and MountContract.matches_spec?(assignment.creation, spec, nil) and
           MountContract.approved?(assignment.creation, config),
         do: {:ok, assignment},
         else: failure(:validation)
    else
      _unsupported -> failure(:unsupported_capability)
    end
  end

  @doc false
  def supports?(config, spec),
    do:
      Config.validate(config) == :ok and validate_spec(spec) == :ok and
        admission_spec?(spec, Config.protocol_major(config)) and profile_approved?(config, spec) and
        CreationFeatures.approved?(CreationFeatures.from_spec(spec), config) and
        command_approved?(config, spec) and volume_spec_approved?(config, spec) and
        approved_artifact(config, spec.artifact) != nil

  @doc false
  def valid?(%__MODULE__{} = assignment),
    do:
      Validation.struct_shape?(assignment, __MODULE__) and Binding.valid?(assignment.binding) and
        assignment.version in [1, 2] and
        creation_valid?(assignment) and mount_binding?(assignment)

  def valid?(_assignment), do: false

  defp creation_valid?(assignment),
    do:
      (Request.valid?(
         %{"operation" => "create", "create" => assignment.creation},
         1,
         assignment.version
       ) or
         (assignment.version == 2 and
            (NativeSource.creation?(assignment.creation) or
               NativeSource.registry_creation?(assignment.creation) or
               CheckpointContract.creation?(assignment.creation) or
               BranchCreation.valid?(assignment.creation)))) and
        assignment.creation["labels"] == %{}

  defp mount_binding?(assignment),
    do:
      not Map.has_key?(assignment.creation, "volume_mounts") or
        MountContract.bound?(assignment.creation["volume_mounts"], assignment.binding)

  @doc false
  def approved?(assignment, config, spec, retained \\ nil) do
    Config.validate(config) == :ok and valid?(assignment) and
      assignment.version == Config.protocol_major(config) and
      supported_spec?(spec, assignment.version) and
      features_approved?(assignment, config, spec) and
      specification_matches?(assignment.creation, spec, retained) and
      profile_approved?(config, spec) and
      Map.from_struct(assignment.binding) == Config.domain_binding(config) and
      approved_creation?(assignment.creation, approved_artifact(config, spec.artifact))
  end

  defp specification_matches?(%{"branch" => _} = create, spec, _retained),
    do: BranchCreation.matches?(create, spec)

  defp specification_matches?(create, spec, retained),
    do:
      CreationFeatures.matches?(create, spec, retained) and
        CheckpointContract.matches?(create, spec, retained) and
        MountContract.matches_spec?(create, spec, retained)

  defp features_approved?(%{creation: %{"branch" => request} = creation}, config, spec),
    do:
      Features.supports?(config, :branches) and
        (not Map.has_key?(creation, "features") or branch_network_approved?(config, creation)) and
        request["approval"] in BranchRequest.approvals(config) and command_approved?(config, spec)

  defp features_approved?(assignment, config, spec),
    do:
      CheckpointContract.opt_in_approved?(config, assignment.creation) and
        CreationFeatures.approved?(Map.get(assignment.creation, "features"), config) and
        command_approved?(config, spec) and MountContract.approved?(assignment.creation, config)

  defp branch_network_approved?(config, %{"features" => %{"branch_https" => true}}),
    do: CheckpointContract.https_approved?(config)

  defp branch_network_approved?(config, _creation),
    do: CheckpointContract.static_egress_approved?(config)

  defp approved_creation?(_creation, nil), do: false

  defp approved_creation?(%{"branch" => _} = creation, %Checkpoint{} = checkpoint),
    do:
      BranchCreation.valid?(creation) and
        creation["artifact_identity"] == Checkpoint.artifact(checkpoint)

  defp approved_creation?(%{"branch" => _}, %Source{}), do: false

  defp approved_creation?(%{"branch" => _} = creation, artifact),
    do:
      BranchCreation.valid?(creation) and
        creation["artifact_identity"] == Map.take(artifact, ~w(id sha256 architecture))

  defp approved_creation?(creation, %Checkpoint{} = checkpoint),
    do:
      CheckpointContract.creation?(creation) and
        creation["source"] == Checkpoint.artifact(checkpoint)

  defp approved_creation?(creation, %Source{kind: kind} = source) when kind in [:oci, :registry],
    do: NativeSource.matches?(creation, Source.artifact(source))

  defp approved_creation?(creation, artifact),
    do: creation["artifact"] == Launch.artifact(artifact)

  @doc false
  def record_valid?(%{backend_assignment: nil} = record),
    do:
      Enum.all?(
        [Map.get(record, :created_machine), Map.get(record, :observed_machine)],
        &legacy_identity?/1
      )

  # The new authority types have no persisted envelope until Phase 2. In
  # particular, they must never pass through an Embedded/HTTP codec version.
  def record_valid?(%{
        __struct__: SmolBox.Execution,
        backend_assignment: %SmolBox.Kubernetes.Assignment{}
      }),
      do: false

  def record_valid?(%{backend_assignment: %__MODULE__{} = assignment} = record) do
    valid?(assignment) and supported_record?(record, assignment.version) and
      specification_matches?(assignment.creation, record.spec, Map.get(record, :managed_machine)) and
      MountContract.record_matches?(record) and
      record_identity_matches?(record, assignment) and
      creation_artifact_matches?(assignment.creation, record.spec.artifact) and
      optional_histories?(record, assignment.version) and
      Enum.all?(
        [Map.get(record, :created_machine), Map.get(record, :observed_machine)],
        &observation_matches?(&1, assignment)
      )
  end

  def record_valid?(_record), do: false

  defp record_identity_matches?(record, assignment),
    do:
      assignment.binding.target_id == record.worker_id and
        assignment.creation["name"] == record.machine_name and
        assignment.creation["resources"] == resources(record.spec.profile)

  @doc false
  def qualification(config, %{artifact: %{"kind" => "checkpoint"}} = spec) do
    if supports?(config, spec),
      do:
        {:ok,
         %{
           "operation" => "qualify_checkpoint_creation",
           "source" => spec.artifact,
           "resources" => resources(spec.profile)
         }
         |> CheckpointContract.attach(spec)},
      else: failure(:unsupported_capability)
  end

  @doc false
  def qualification(config, spec) do
    if supports?(config, spec),
      do:
        {:ok,
         CreationFeatures.attach(
           %{
             "operation" => qualification_operation(spec.artifact),
             provision_key(approved_artifact(config, spec.artifact)) =>
               provision_value(approved_artifact(config, spec.artifact)),
             "resources" => resources(spec.profile),
             "user" =>
               case Map.get(spec, :command) do
                 nil -> nil
                 command -> Map.get(command, :user)
               end
           },
           CreationFeatures.from_spec(spec)
         )
         |> CheckpointContract.attach(spec)},
      else: failure(:unsupported_capability)
  end

  # Admission policy is separate from structural historical validation. A new
  # qualification rule must not make existing v16 native records unreadable.
  defp admission_spec?(spec, version),
    do:
      supported_spec?(spec, version) and qualified_user?(Map.get(spec, :command)) and
        (spec.artifact["kind"] != "oci" or spec.profile.network != :offline)

  defp volume_spec_approved?(config, spec),
    do:
      Map.get(spec, :volumes, []) == [] or
        (config.platform == :linux and Features.supports?(config, :volumes))

  defp profile_approved?(config, spec),
    do:
      spec.profile in config.profiles and checkpoint_profile_approved?(config, spec) and
        (not Map.get(spec, :branch_static_egress, false) or
           CheckpointContract.static_egress_approved?(config)) and
        (not SmolBox.BranchHTTPSCredentials.source?(spec) or
           CheckpointContract.https_approved?(config)) and
        (not Map.get(spec, :checkpointable, false) or Features.supports?(config, :checkpoints))

  defp checkpoint_profile_approved?(config, %{artifact: %{"kind" => "checkpoint"}} = spec),
    do:
      Enum.any?(config.checkpoints, fn checkpoint ->
        Checkpoint.artifact(checkpoint) == spec.artifact and checkpoint.profile == spec.profile
      end)

  defp checkpoint_profile_approved?(_config, _spec), do: true

  defp qualified_user?(nil), do: true
  defp qualified_user?(%ImagePull{}), do: true
  defp qualified_user?(%TerminalSpec{}), do: true
  defp qualified_user?(%{user: nil}), do: true

  defp qualified_user?(%{user: user}) when is_binary(user) do
    parts = String.split(user, ":")

    length(parts) in 1..2 and
      Enum.all?(parts, fn part ->
        Regex.match?(~r/\A[0-9]+\z/, part) and
          case Integer.parse(part) do
            {id, ""} -> id < 4_294_967_295
            _ -> false
          end
      end)
  end

  defp qualified_user?(_command), do: false

  defp legacy_identity?(nil), do: true
  defp legacy_identity?(%SmolBox.Machine{backend_identity: nil}), do: true
  defp legacy_identity?(_machine), do: false

  defp observation_matches?(nil, _assignment), do: true

  defp observation_matches?(%{backend_identity: identity} = machine, assignment),
    do:
      Identity.matches?(identity, assignment) and
        CreationFeatures.observation_matches?(assignment.creation, machine) and
        machine.mounts == MountContract.paths(assignment.creation)

  defp observation_matches?(_machine, _assignment), do: false

  defp provision_key(%Source{kind: kind}) when kind in [:oci, :registry], do: "source"
  defp provision_key(%Checkpoint{}), do: "source"
  defp provision_key(_local), do: "artifact"
  defp provision_value(%Source{} = source), do: Source.artifact(source)
  defp provision_value(%Checkpoint{} = checkpoint), do: Checkpoint.artifact(checkpoint)
  defp provision_value(local), do: Launch.artifact(local)
  defp qualification_operation(%{"kind" => "oci"}), do: "qualify_oci_creation"
  defp qualification_operation(%{"kind" => "registry"}), do: "qualify_registry_creation"
  defp qualification_operation(_local), do: "qualify_creation"

  defp approved_artifact(config, %{"kind" => kind} = expected) when kind in ["oci", "registry"] do
    if Features.supports?(config, :remote_sources),
      do: Enum.find(config.sources, &(Source.artifact(&1) == expected)),
      else: nil
  end

  defp approved_artifact(config, %{"kind" => "checkpoint"} = expected) do
    if Features.supports?(config, :checkpoints),
      do: Enum.find(config.checkpoints, &(Checkpoint.artifact(&1) == expected)),
      else: nil
  end

  defp approved_artifact(config, expected),
    do: Enum.find(config.artifacts, &(Map.take(&1, ~w(id sha256 architecture)) == expected))

  defp artifact_matches?(artifact, expected),
    do:
      artifact["sha256"] == expected["sha256"] and
        artifact["guest_platform"] ==
          if(expected["architecture"] == "aarch64", do: "linux/arm64", else: "linux/amd64")

  defp creation_artifact_matches?(%{"branch" => _} = creation, expected),
    do: BranchCreation.valid?(creation) and creation["artifact_identity"] == expected

  defp creation_artifact_matches?(%{"source" => %{"kind" => "checkpoint"}} = creation, expected),
    do: CheckpointContract.creation?(creation) and creation["source"] == expected

  defp creation_artifact_matches?(%{"source" => _source} = creation, expected),
    do: NativeSource.matches?(creation, expected)

  defp creation_artifact_matches?(creation, expected),
    do:
      is_map(expected) and map_size(expected) == 3 and
        artifact_matches?(creation["artifact"], expected)

  defp supported_spec?(spec, version) do
    is_map(spec) and native_profile?(spec.profile, version) and
      supported_artifact?(spec.artifact, version) and
      bare_guest?(spec, version) and
      command_supported?(Map.get(spec, :command), spec.profile, version) and
      bounded_files?(Map.get(spec, :inputs, []), "size", 0) and
      bounded_files?(Map.get(spec, :outputs, []), "max_bytes", 1)
  end

  defp supported_artifact?(artifact, version),
    do:
      (is_map(artifact) and map_size(artifact) == 3) or
        (version == 2 and
           (NativeSource.artifact?(artifact) or NativeSource.registry_artifact?(artifact) or
              CheckpointContract.source?(artifact)))

  defp bounded_files?(entries, field, minimum),
    do: Enum.all?(entries, &Validation.integer?(&1[field], minimum, 16_777_216))

  defp native_profile?(profile, version),
    do:
      Profile.validate(profile) == :ok and (profile.network == :offline or version == 2) and
        profile.max_output_bytes <= 16_777_216 and profile.max_file_bytes <= 16_777_216 and
        profile.cpus <= 16 and profile.execution_ms <= 86_400_000

  defp bare_guest?(%{artifact: %{"kind" => "checkpoint"}} = spec, version),
    do:
      version == 2 and spec.profile.network == :offline and
        not SmolBox.FileAccess.extended?(spec.profile) and Map.get(spec, :volumes, []) == [] and
        Map.get(spec, :ports, []) == [] and Map.get(spec, :workload) == nil

  defp bare_guest?(%{checkpointable: true} = spec, version),
    do:
      version == 2 and spec.artifact["kind"] != "oci" and
        (spec.profile.network == :offline or SmolBox.BranchHTTPSCredentials.source?(spec)) and
        not SmolBox.FileAccess.extended?(spec.profile) and Map.get(spec, :volumes, []) == [] and
        Map.get(spec, :ports, []) == [] and Map.get(spec, :workload) == nil

  defp bare_guest?(spec, version),
    do:
      (version == 2 or Map.get(spec, :volumes, []) == []) and
        not Map.get(spec, :checkpointable, false) and
        (version == 2 or (Map.get(spec, :ports, []) == [] and Map.get(spec, :workload) == nil))

  defp command_supported?(nil, _profile, _version), do: true

  defp command_supported?(%ImagePull{} = pull, profile, 2),
    do: ImagePull.validate(pull) == :ok and profile.network != :offline

  defp command_supported?(%TerminalSpec{} = terminal, profile, 2),
    do: TerminalSpec.validate(terminal) == :ok and terminal.session_ms <= profile.execution_ms

  defp command_supported?(%Command{background: false, stdin: nil} = command, profile, 1),
    do:
      Request.command_valid?(%{
        "argv" => command.argv,
        "env" => Map.new(command.env),
        "workdir" => command.workdir,
        "user" => command.user,
        "max_output_bytes" => profile.max_output_bytes
      })

  defp command_supported?(%Command{background: false} = command, profile, 2),
    do:
      Request.buffered_command_valid?(%{
        "argv" => command.argv,
        "env" => Map.new(command.env),
        "workdir" => command.workdir,
        "user" => command.user,
        "stdin" => command.stdin,
        "max_output_bytes" => profile.max_output_bytes
      })

  defp command_supported?(%Command{background: true, stdin: nil} = command, profile, 2),
    do:
      Request.buffered_command_valid?(%{
        "argv" => command.argv,
        "env" => Map.new(command.env),
        "workdir" => command.workdir,
        "user" => command.user,
        "stdin" => nil,
        "max_output_bytes" => profile.max_output_bytes
      })

  defp command_supported?(_command, _profile, _version), do: false

  defp command_approved?(config, %{command: %ImagePull{source: source}}),
    do:
      source in config.sources and
        match?(
          %{"feature_versions" => %{"images" => 1, "remote_sources" => 1}},
          Config.sdk_identity(config)
        )

  defp command_approved?(config, spec) do
    sdk = Config.sdk_identity(config)

    case Map.get(spec, :command) do
      nil ->
        true

      %Command{} = command ->
        (command.stdin == nil or match?(%{"feature_versions" => %{"buffered_exec" => 1}}, sdk)) and
          (not command.background or
             match?(%{"feature_versions" => %{"background_exec" => 1}}, sdk)) and
          streaming_approved?(sdk, command, spec.profile)

      %TerminalSpec{} ->
        match?(%{"feature_versions" => %{"terminals" => 1}}, sdk)

      _ ->
        false
    end
  end

  defp streaming_approved?(sdk, %Command{background: false, stdin: nil} = command, profile),
    do:
      match?(%{"feature_versions" => %{"streaming_exec" => 1}}, sdk) or
        command_supported?(command, profile, 1)

  defp streaming_approved?(_sdk, _command, _profile), do: true

  defp retained_terminal?(%{spec: %{command: %TerminalSpec{}}, managed_machine: key}, 2),
    do: key != nil

  defp retained_terminal?(%{spec: %{command: %TerminalSpec{}}}, _version), do: false
  defp retained_terminal?(_record, _version), do: true

  defp supported_record?(record, version),
    do:
      supported_spec?(record.spec, version) and retained_terminal?(record, version) and
        retained_pull?(record)

  defp retained_pull?(%{spec: %{command: %ImagePull{}, artifact: artifact}} = record),
    do: Map.get(record, :managed_machine) != nil and NativeSource.artifact?(artifact)

  defp retained_pull?(_record), do: true

  defp optional_histories?(record, version),
    do:
      preparation_history?(record, version) and NativeBranchAuthority.history_valid?(record) and
        export_histories?(record, version) and
        (Map.get(record, :mounts, []) == [] or version == 2) and
        growth_histories?(record, version) and
        checkpointable_origin?(record) and capture_histories?(record, version)

  defp preparation_history?(record, version) do
    case Map.get(record, :preparation) do
      nil ->
        true

      prepared ->
        version == 2 and NativeSource.registry_artifact?(record.spec.artifact) and
          ArtifactPreparation.matches?(prepared, record.spec.artifact)
    end
  end

  defp capture_histories?(_record, 2), do: true

  defp capture_histories?(record, _version),
    do:
      Map.get(record, :reserved_ports, []) == [] and
        Map.get(record, :captures, %{}) == %{} and Map.get(record, :active_capture) == nil

  defp export_histories?(%{__struct__: ManagedMachine} = record, 2),
    do: Export.history_valid?(record)

  defp export_histories?(record, _),
    do: Map.get(record, :exports, %{}) == %{} and Map.get(record, :active_export) == nil

  defp growth_histories?(record, 2), do: NativeGrowth.record_valid?(record)

  defp growth_histories?(record, 1),
    do:
      Enum.all?([disk_expansions: %{}, disk_sizes: nil, active_expansion: nil], fn {key, empty} ->
        Map.get(record, key, empty) == empty
      end) and NativeGrowth.record_valid?(record)

  defp checkpointable_origin?(record) do
    required =
      Map.get(record, :captures, %{}) != %{} or
        checkpointable_links?(Map.get(record, :created_machine))

    not required or record.backend_assignment.creation["checkpointable"] == true
  end

  defp checkpointable_links?(%{backend_identity: %{material_history: history}})
       when is_list(history),
       do: Enum.any?(history, &(MaterialHistory.capture?(&1) or is_struct(&1, BranchPublication)))

  defp checkpointable_links?(_), do: false

  defp validate_spec(%ManagedMachineSpec{} = spec), do: ManagedMachineSpec.validate(spec)
  defp validate_spec(spec), do: ExecutionSpec.validate(spec)

  defp resources(profile),
    do: %{
      "cpus" => profile.cpus,
      "memory_mib" => profile.memory_mb,
      "storage_gib" => profile.storage_gb,
      "overlay_gib" => profile.overlay_gb
    }

  defp random(size), do: Base.encode16(:crypto.strong_rand_bytes(size), case: :lower)
  defp failure(category), do: {:error, %Error{category: category, operation: :reservation}}
end
