defmodule SmolBox.Test.Kubernetes do
  @moduledoc false
  alias SmolBox.{Command, Execution, ExecutionSpec, Machine, Profile, Source}
  alias SmolBox.Kubernetes.{Assignment, CleanupProof, Config, Identity, Observation, Receipt}

  defmodule Credentials do
    @moduledoc false
    @behaviour SmolBox.Kubernetes.Credentials
    @impl true
    def resolve(_context, _budget), do: raise("unexpected credential callback")
  end

  defmodule NodeEvidence do
    @moduledoc false
    @behaviour SmolBox.Kubernetes.NodeEvidence
    @impl true
    def check(_binding, _budget, _context), do: raise("unexpected node callback")
    @impl true
    def capture(_binding, _uid, _budget, _context), do: raise("unexpected node callback")
    @impl true
    def cleanup(_binding, _receipt, _budget, _context), do: raise("unexpected node callback")
  end

  def digest, do: String.duplicate("a", 64)

  def config(overrides \\ []) do
    {:ok, source} =
      Source.oci(
        id: "python-v1",
        reference: "registry.example/team/python@sha256:" <> digest(),
        architecture: "x86_64"
      )

    {:ok, profile} =
      Profile.new("kube-v1",
        cpus: 2,
        memory_mb: 1024,
        storage_gb: 20,
        overlay_gb: 10,
        host_overhead_mb: 512
      )

    options = [
      id: "kube-lab",
      api_server: "https://127.0.0.1:16443",
      ca_file: "/private/lab/ca.crt",
      credential_provider: {Credentials, %{secret: "private-credential-context"}},
      cluster_id: "lab-cluster",
      cluster_anchor_uid: "cluster-anchor-uid",
      namespace: "smolbox-preview",
      namespace_uid: "namespace-uid",
      node_name: "smolbox-k3s",
      node_uid: "node-uid",
      node_boot_id: "00000000-0000-0000-0000-000000000001",
      runtime_class: "smolbox-preview",
      runtime_class_uid: "runtime-class-uid",
      runtime_policy_digest: digest(),
      runtime_identity: identity(),
      sources: [source],
      profiles: [profile],
      node_evidence: {NodeEvidence, %{private_node_key: "private-node-context"}}
    ]

    Config.new(Keyword.merge(options, overrides))
  end

  def identity do
    Map.new(
      ~w(archive_sha256 shim_sha256 libkrun_sha256 kernel_sha256 rootfs_sha256 guard_sha256 guard_template_sha256),
      &{&1, digest()}
    )
    |> Map.merge(%{
      "smolvm_version" => "1.34.0",
      "k3s_version" => "v1.35.10+k3s1",
      "containerd_version" => "2.2.10-k3s1"
    })
  end

  def execution(config, overrides \\ [], now \\ 1000) do
    {:ok, command} =
      Command.new(["python3", "-c", "print('private-command-value')"],
        env: [{"PRIVATE", "private-env-value"}]
      )

    {:ok, spec} =
      ExecutionSpec.new(
        Keyword.merge(
          [
            scope: "unit",
            id: "execution-1",
            command: command,
            artifact: config.sources |> hd() |> Source.artifact(),
            profile: hd(config.profiles),
            retention_ms: 0
          ],
          overrides
        )
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = Execution.new(spec, fingerprint, now)
    record
  end

  def assigned(config, overrides \\ [], now \\ 1000) do
    record = execution(config, overrides, now)
    {:ok, assignment} = Assignment.new(config, record, "kube-unit-creation")

    reserved = %{
      record
      | backend_assignment: assignment,
        backend_create_state: :pending,
        worker_id: config.id,
        machine_name: assignment.pod_name,
        worker_generation: 1,
        reservation: Profile.resources(record.spec.profile)
    }

    record = %{
      reserved
      | state: :preparing,
        deadlines:
          Map.put(reserved.deadlines, :preparation, now + reserved.spec.profile.preparation_ms)
    }

    {record, assignment}
  end

  def ready_record(config, overrides \\ [], now \\ 1000) do
    {record, assignment} = assigned(config, overrides, now)
    ready = ready_receipt(assignment)
    {:ok, created} = Receipt.created(assignment, ready.pod_uid)

    {:ok, record} =
      Execution.transition(
        record,
        [backend_create_state: :dispatched, backend_receipt: created],
        now
      )

    machine = %Machine{
      name: assignment.pod_name,
      state: :running,
      created_at: nil,
      cpus: 2,
      memory_mb: 1024,
      storage_gb: 20,
      overlay_gb: 10,
      backend_identity: %Identity{receipt: ready}
    }

    {:ok, record} =
      Execution.transition(
        record,
        [backend_receipt: ready, created_machine: machine, state: :ready],
        now
      )

    {record, assignment}
  end

  def runtime(config, store, artifact_store, {prepared, assignment}, options \\ []) do
    alias SmolBox.Runtime.{Config, Session}
    alias SmolBox.Store.Memory
    now = prepared.accepted_at_ms

    {:ok, runtime} =
      Config.new(
        Keyword.merge(
          [
            name: __MODULE__,
            namespace: "kubefiles",
            mode: :ephemeral,
            store: {Memory, store},
            artifact_store: artifact_store,
            workers: [config],
            fingerprint_key: String.duplicate("k", 32),
            poll_ms: 10
          ],
          options
        )
      )

    {:ok, _} = Memory.bind_backend(store, config.id, SmolBox.Kubernetes.Config.binding(config))
    {:ok, _} = Memory.claim_worker(store, config.id, runtime.owner, now, runtime.lease_ms)
    {:ok, record} = Execution.new(prepared.spec, prepared.fingerprint, now)
    {:ok, _, :inserted} = Memory.accept(store, record, 1)

    {:ok, record} =
      Memory.claim(store, Execution.key(record), runtime.owner, now, runtime.lease_ms)

    {:ok, record} =
      Memory.reserve(
        store,
        Execution.key(record),
        Session.guard(record),
        {config.id, assignment.pod_name, config.capacity, assignment},
        now
      )

    {runtime, record}
  end

  def observation(binding, pod_uid \\ "pod-original") do
    sandbox = String.duplicate("d", 64)

    %Observation{
      binding_generation: binding.generation,
      pod_uid: pod_uid,
      sandbox_ids: [sandbox],
      observer_epoch: "observer-1",
      observed_at_ms: 1000,
      guard_sha256: binding.runtime_identity["guard_sha256"],
      guard_template_sha256: binding.runtime_identity["guard_template_sha256"],
      complete_history: true,
      isolated: true,
      processes: [
        %{
          sandbox_id: sandbox,
          vm_directory: Observation.vm_directory(sandbox),
          pid: 1234,
          start_ticks: 777,
          exe_sha256: binding.runtime_identity["shim_sha256"],
          kvm: ["anon_inode:kvm-vcpu:0", "anon_inode:kvm-vcpu:1", "anon_inode:kvm-vm"]
        }
      ],
      interfaces: [%{sandbox_id: sandbox, name: "vethcafe", ifindex: 9}]
    }
  end

  def ready_receipt(assignment) do
    {:ok, created} = Receipt.created(assignment, "pod-original")

    {:ok, ready} =
      Receipt.ready(
        created,
        "containerd://" <> digest(),
        assignment.source["reference"],
        observation(assignment.binding)
      )

    ready
  end

  def cleanup_proof(receipt) do
    %CleanupProof{
      receipt: receipt,
      observed_at_ms: 1100,
      observer_epoch: receipt.observation.observer_epoch,
      api_absent: true,
      complete_history: true,
      terminated_processes: receipt.observation.processes,
      absent_records: receipt.observation.sandbox_ids,
      absent_vm_directories:
        receipt.observation.sandbox_ids |> Enum.map(&Observation.vm_directory/1) |> Enum.sort(),
      absent_shares: receipt.observation.sandbox_ids
    }
  end
end
