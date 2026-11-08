defmodule SmolBox.Embedded.NativeBranchAuthority do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Binding}

  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchCreation,
    BranchReleaseTransition,
    BranchRequest,
    Identity
  }

  alias SmolBox.Embedded.{
    NativeBranchBacking,
    NativeBranchDeletion,
    NativeBranchDeletionAction,
    NativeBranchRelease,
    NativeBranchRetirement,
    NativePreparedBranchRetirement,
    NativeUnbootedBranchDisposal
  }

  alias SmolBox.{Branch, BranchSpec, Profile, Validation}

  @enforce_keys [:source, :request, :fingerprint]
  @derive {Inspect, only: []}
  defstruct @enforce_keys ++
              [
                prepared_retirement: nil,
                disposal: nil,
                completion: nil,
                release: nil,
                retirement: nil,
                backing: nil,
                deletion: nil,
                delete_continuation: nil,
                delete_cleanup: nil,
                delete_collection: nil
              ]

  def new(parent, spec, fingerprint, name, profile) do
    source = parent.observed_machine

    child = %{
      "operation_id" => spec.id,
      "name" => name,
      "owner_token" => random(32),
      "incarnation" => random(16),
      "idle" => true,
      "hold" => spec.hold
    }

    request = %{
      "source" => source.backend_identity.receipt,
      "child" => child,
      "approval" => %{
        "id" => spec.policy.id,
        "host_overhead_mb" => profile.host_overhead_mb,
        "resources" =>
          Map.new(spec.policy.resources, fn {key, value} -> {Atom.to_string(key), value} end)
      }
    }

    request =
      if spec.hold,
        do: request,
        else:
          Map.put(request, "initial_release", %{
            "operation_id" => "activate-" <> random(16),
            "request_sha256" =>
              BranchCanonical.digest([
                "smolbox-initial-native-branch-release-v1",
                fingerprint,
                name
              ])
          })

    authority = %__MODULE__{
      source: {parent.scope, parent.id},
      request: request,
      fingerprint: fingerprint
    }

    if valid?(authority), do: {:ok, authority}, else: :error
  end

  def valid?(%__MODULE__{} = authority),
    do:
      Validation.struct_shape?(authority, __MODULE__) and
        source_key?(authority.source) and Validation.digest?(authority.fingerprint) and
        BranchRequest.valid?(authority.request) and
        completion?(authority) and optional_proofs?(authority) and
        NativeBranchDeletionAction.authority?(authority)

  def valid?(_), do: false

  defp completion?(authority),
    do:
      authority.completion == nil or
        (BranchCompletion.valid?(authority.completion) and
           BranchCompletion.matches?(
             BranchCompletion.to_wire(authority.completion),
             authority.request
           ))

  defp optional_proofs?(authority),
    do:
      Enum.all?(
        [
          {authority.prepared_retirement, NativePreparedBranchRetirement},
          {authority.disposal, NativeUnbootedBranchDisposal},
          {authority.release, NativeBranchRelease},
          {authority.retirement, NativeBranchRetirement},
          {authority.backing, NativeBranchBacking},
          {authority.deletion, NativeBranchDeletion}
        ],
        fn {proof, module} -> proof == nil or module.valid?(proof, authority) end
      )

  def assignment_fields(%__MODULE__{} = authority, artifact, profile),
    do: %{
      version: 2,
      binding: %Binding{
        kind: :embedded,
        target_id: authority.request["source"]["target_id"],
        generation: authority.request["source"]["domain_generation"]
      },
      creation: BranchCreation.from_request(authority.request, artifact, profile)
    }

  def child?(
        %{
          backend_assignment: %{__struct__: Assignment} = assignment,
          branch:
            %{
              __struct__: Branch,
              source_machine: %SmolBox.Machine{},
              native_authority: %__MODULE__{} = authority
            } = branch
        } = child
      ) do
    profile = child.spec.profile
    request = authority.request

    valid?(authority) and branch_spec?(branch.spec, request, profile) and
      authority.source == branch.source and authority.fingerprint == child.fingerprint and
      child.id == request["child"]["operation_id"] and
      Map.from_struct(assignment) == assignment_fields(authority, child.spec.artifact, profile) and
      source?(branch.source_machine, request["source"], profile) and
      proof_records?(child, authority.completion)
  end

  def child?(_), do: false

  def preserved?(%{branch: %{native_authority: %__MODULE__{} = original} = before} = record, next) do
    case next.branch do
      %{native_authority: %__MODULE__{} = saved} = after_branch ->
        {before.source, before.source_machine, before.spec} ==
          {after_branch.source, after_branch.source_machine, after_branch.spec} and
          {record.spec, record.fingerprint, record.backend_assignment} ==
            {next.spec, next.fingerprint, next.backend_assignment} and
          {original.source, original.request, original.fingerprint} ==
            {saved.source, saved.request, saved.fingerprint} and
          (original.completion == nil or original.completion == saved.completion) and
          proofs_preserved?(original, saved, record, next)

      _ ->
        false
    end
  end

  def preserved?(_, _), do: true

  defp proof_records?(child, completion),
    do:
      completion_record?(child, completion) and NativePreparedBranchRetirement.record?(child) and
        NativeUnbootedBranchDisposal.record?(child) and
        NativeBranchRetirement.record?(child) and
        NativeBranchBacking.record?(child) and NativeBranchDeletion.record?(child) and
        NativeBranchDeletionAction.record?(child)

  defp proofs_preserved?(original, saved, record, next),
    do:
      NativePreparedBranchRetirement.preserved?(
        original.prepared_retirement,
        saved.prepared_retirement,
        record.version
      ) and
        NativeUnbootedBranchDisposal.preserved?(original.disposal, saved.disposal, record.version) and
        NativeBranchRelease.preserved?(original.release, saved.release) and
        NativeBranchRetirement.preserved?(original.retirement, saved.retirement, record.version) and
        NativeBranchBacking.preserved?(original.backing, saved.backing, record.version) and
        NativeBranchDeletion.preserved?(original.deletion, saved.deletion, record.version) and
        NativeBranchDeletionAction.preserved?(original, saved, record.version) and
        deletion_authorized?(record, next) and closure_authorized?(record.branch, next.branch)

  defp deletion_authorized?(record, %{state: :deleted} = next),
    do:
      not NativeBranchDeletion.required?(record) or
        NativeBranchDeletion.acknowledged?(next.branch.native_authority) or
        NativeBranchDeletionAction.acknowledged?(next.branch.native_authority)

  defp deletion_authorized?(_, _), do: true

  defp closure_authorized?(%{state: before}, %{state: :closed, native_authority: authority})
       when before != :closed,
       do:
         match?(
           %NativeBranchBacking{proof: %SmolBox.Embedded.BranchBackingRelease{}},
           authority.backing
         ) or match?(%NativePreparedBranchRetirement{}, authority.prepared_retirement)

  defp closure_authorized?(_, _), do: true

  def root(%__MODULE__{completion: %BranchCompletion{} = completion}),
    do: %Identity{receipt: completion.publication["change"]["child"]}

  def transitions(%{
        branch: %{native_authority: %__MODULE__{release: %NativeBranchRelease{transition: proof}}}
      })
      when not is_nil(proof), do: {:ok, [proof]}

  def transitions(%{
        branch: %{native_authority: %__MODULE__{completion: %BranchCompletion{release: release}}}
      })
      when not is_nil(release) do
    with {:ok, proof} <- BranchReleaseTransition.from_wire(release), do: {:ok, [proof]}
  end

  def transitions(_), do: {:ok, []}

  defp completion_record?(child, nil),
    do:
      child.created_machine == nil and child.observed_machine == nil and
        ((child.branch.state in [
            :disposal_pending,
            :disposed,
            :retired,
            :backing_pending,
            :closed
          ] and
            child.branch.native_authority.disposal != nil) or
           child.branch.state in [
             :accepted,
             :dispatching,
             :unknown,
             :failed,
             :cancelled,
             :resolved
           ] or
           (child.branch.state == :closed and
              child.branch.native_authority.prepared_retirement != nil))

  defp completion_record?(child, completion) do
    with %SmolBox.Machine{} = created <- child.created_machine,
         %SmolBox.Machine{} = observed <- child.observed_machine,
         {:ok, history} <- transitions(child) do
      completed_state?(child.branch.state, child.branch.native_authority) and
        release_version?(child) and
        created.backend_identity == root(child.branch.native_authority) and
        observed.backend_identity.receipt == current_receipt(child.branch.native_authority) and
        observed.backend_identity.transition == List.last(history) and
        observed.backend_identity.material_history == if(history == [], do: nil, else: history) and
        child.branch.source_machine.backend_identity.pid_identity ==
          completion.publication["change"]["child_origin"]["intent"]["source_pid"]
    else
      _ -> false
    end
  end

  def current_receipt(%__MODULE__{release: %NativeBranchRelease{transition: proof}})
      when not is_nil(proof), do: proof.receipt

  def current_receipt(%__MODULE__{completion: completion}), do: completion.child

  defp release_version?(%{
         branch: %{native_authority: %{release: nil}, release_version: version}
       }),
       do: version == nil

  defp release_version?(%{
         branch: %{native_authority: %{release: release}, release_version: version}
       }),
       do: release.version == version

  defp completed_state?(state, %{release: %NativeBranchRelease{transition: nil}}),
    do: state in [:release_pending, :release_dispatching, :unknown, :resolved, :retired, :closed]

  defp completed_state?(state, %{release: %NativeBranchRelease{}}),
    do: state in [:released, :unknown, :resolved, :retired, :closed]

  defp completed_state?(state, %{completion: %{held: true}}),
    do:
      state in [
        :held,
        :unknown,
        :resolved,
        :retired,
        :closed
      ]

  defp completed_state?(state, %{completion: %{held: false}}),
    do: state in [:ready, :unknown, :resolved, :retired, :closed]

  defp branch_spec?(spec, request, profile),
    do:
      BranchSpec.validate(spec) == :ok and Profile.validate(profile) == :ok and
        spec.hold == request["child"]["hold"] and spec.idle == request["child"]["idle"] and
        request["approval"] == %{
          "id" => spec.policy.id,
          "host_overhead_mb" => profile.host_overhead_mb,
          "resources" =>
            Map.new(spec.policy.resources, fn {key, value} -> {Atom.to_string(key), value} end)
        }

  defp source?(source, receipt, profile),
    do:
      source.name == receipt["name"] and source.created_at == nil and
        source.state == :running and offline?(source) and
        Identity.valid?(source.backend_identity) and source.backend_identity.receipt == receipt and
        source.backend_identity.pid_identity != nil and
        allocations?(source, profile)

  defp offline?(source),
    do: source.network == :offline and source.ports == [] and source.mounts == []

  defp allocations?(source, profile),
    do:
      source.cpus == profile.cpus and source.memory_mb == profile.memory_mb and
        source.storage_gb == profile.storage_gb and source.overlay_gb == profile.overlay_gb

  defp random(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp source_key?({scope, id}), do: Validation.identifier?(scope) and Validation.identifier?(id)
  defp source_key?(_), do: false
end
