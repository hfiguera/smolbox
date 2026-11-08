defmodule SmolBox.Backend.Assignment do
  @moduledoc """
  Durable embedded creation intent associated with a target/domain binding.

  Ownership and incarnation tokens are generated before an atomic reservation
  write and retained across helper restarts. Public runtime startup separately
  validates the target and store capabilities. Inspect output omits creation evidence.
  """
  alias SmolBox.Backend.Binding

  alias SmolBox.{Command, Error, ExecutionSpec, ManagedMachineSpec, Profile, Validation}
  alias SmolBox.Embedded.{Config, Identity, Launch, Request}

  @enforce_keys [:binding, :creation]
  @derive {Inspect, only: [:binding]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{binding: Binding.t(), creation: map()}

  # Generate once before the atomic reservation write, never inside dispatch.
  @doc false
  def new(config, spec, name) do
    with :ok <- Config.validate(config),
         :ok <- validate_spec(spec),
         true <- admission_spec?(spec) and spec.profile in config.profiles,
         artifact when not is_nil(artifact) <- approved_artifact(config, spec.artifact) do
      assignment = %__MODULE__{
        binding: struct!(Binding, Config.domain_binding(config)),
        creation: %{
          "name" => name,
          "owner_token" => random(32),
          "incarnation" => random(16),
          "artifact" => Launch.artifact(artifact),
          "resources" => resources(spec.profile),
          "labels" => %{}
        }
      }

      if valid?(assignment), do: {:ok, assignment}, else: failure(:validation)
    else
      _unsupported -> failure(:unsupported_capability)
    end
  end

  @doc false
  def supports?(config, spec),
    do:
      Config.validate(config) == :ok and validate_spec(spec) == :ok and
        admission_spec?(spec) and spec.profile in config.profiles and
        approved_artifact(config, spec.artifact) != nil

  @doc false
  def valid?(%__MODULE__{} = assignment),
    do:
      Validation.struct_shape?(assignment, __MODULE__) and Binding.valid?(assignment.binding) and
        Request.valid?(%{"operation" => "create", "create" => assignment.creation}, 1) and
        assignment.creation["labels"] == %{}

  def valid?(_assignment), do: false

  @doc false
  def approved?(assignment, config, spec) do
    Config.validate(config) == :ok and valid?(assignment) and supported_spec?(spec) and
      spec.profile in config.profiles and
      Map.from_struct(assignment.binding) == Config.domain_binding(config) and
      approved_creation?(assignment.creation, approved_artifact(config, spec.artifact))
  end

  defp approved_creation?(_creation, nil), do: false

  defp approved_creation?(creation, artifact),
    do: creation["artifact"] == Launch.artifact(artifact)

  @doc false
  def record_valid?(%{backend_assignment: nil} = record),
    do:
      Enum.all?(
        [Map.get(record, :created_machine), Map.get(record, :observed_machine)],
        &legacy_identity?/1
      )

  def record_valid?(%{backend_assignment: %__MODULE__{} = assignment} = record) do
    valid?(assignment) and supported_spec?(record.spec) and
      assignment.binding.target_id == record.worker_id and
      assignment.creation["name"] == record.machine_name and
      assignment.creation["resources"] == resources(record.spec.profile) and
      artifact_matches?(assignment.creation["artifact"], record.spec.artifact) and
      optional_histories?(record) and
      Enum.all?(
        [Map.get(record, :created_machine), Map.get(record, :observed_machine)],
        &observation_matches?(&1, assignment)
      )
  end

  def record_valid?(_record), do: false

  @doc false
  def qualification(config, spec) do
    if supports?(config, spec),
      do:
        {:ok,
         %{
           "operation" => "qualify_creation",
           "artifact" => Launch.artifact(approved_artifact(config, spec.artifact)),
           "resources" => resources(spec.profile),
           "user" =>
             case Map.get(spec, :command) do
               nil -> nil
               command -> command.user
             end
         }},
      else: failure(:unsupported_capability)
  end

  # Admission policy is separate from structural historical validation. A new
  # qualification rule must not make existing v16 native records unreadable.
  defp admission_spec?(spec),
    do: supported_spec?(spec) and qualified_user?(Map.get(spec, :command))

  defp qualified_user?(nil), do: true
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

  defp observation_matches?(%{backend_identity: identity}, assignment),
    do: Identity.matches?(identity, assignment)

  defp observation_matches?(_machine, _assignment), do: false

  defp approved_artifact(config, expected),
    do: Enum.find(config.artifacts, &(Map.take(&1, ~w(id sha256 architecture)) == expected))

  defp artifact_matches?(artifact, expected),
    do:
      artifact["sha256"] == expected["sha256"] and
        artifact["guest_platform"] ==
          if(expected["architecture"] == "aarch64", do: "linux/arm64", else: "linux/amd64")

  defp supported_spec?(spec) do
    is_map(spec) and native_profile?(spec.profile) and
      is_map(spec.artifact) and map_size(spec.artifact) == 3 and
      bare_guest?(spec) and
      command_supported?(Map.get(spec, :command), spec.profile) and
      bounded_files?(Map.get(spec, :inputs, []), "size", 0) and
      bounded_files?(Map.get(spec, :outputs, []), "max_bytes", 1)
  end

  defp bounded_files?(entries, field, minimum),
    do: Enum.all?(entries, &Validation.integer?(&1[field], minimum, 16_777_216))

  defp native_profile?(profile),
    do:
      Profile.validate(profile) == :ok and profile.network == :offline and
        profile.max_output_bytes <= 16_777_216 and profile.max_file_bytes <= 16_777_216 and
        profile.cpus <= 16 and profile.execution_ms <= 86_400_000

  defp bare_guest?(spec),
    do:
      Map.get(spec, :ports, []) == [] and Map.get(spec, :volumes, []) == [] and
        Map.get(spec, :workload) == nil and not Map.get(spec, :checkpointable, false)

  defp command_supported?(nil, _profile), do: true

  defp command_supported?(%Command{background: false, stdin: nil} = command, profile),
    do:
      Request.command_valid?(%{
        "argv" => command.argv,
        "env" => Map.new(command.env),
        "workdir" => command.workdir,
        "user" => command.user,
        "max_output_bytes" => profile.max_output_bytes
      })

  defp command_supported?(_command, _profile), do: false

  defp optional_histories?(record),
    do:
      Enum.all?(
        [
          disk_expansions: %{},
          captures: %{},
          exports: %{},
          branch_children: %{},
          disk_sizes: nil,
          active_expansion: nil,
          active_capture: nil,
          active_export: nil,
          branch: nil,
          active_branch: nil,
          preparation: nil,
          mounts: [],
          reserved_ports: []
        ],
        fn {key, empty} -> Map.get(record, key, empty) == empty end
      )

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
