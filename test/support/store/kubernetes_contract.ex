defmodule SmolBox.Store.KubernetesContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Execution, Profile}
  alias SmolBox.Kubernetes.{Assignment, Config, Receipt}
  alias SmolBox.Store.{BackendContract, Codec}
  alias SmolBox.Store.Contract
  alias SmolBox.Test.Kubernetes, as: Fixture

  defmacro __using__(options) do
    scenarios =
      for {title, function} <- [
            {"Kubernetes enrollment rejects aliased capacity and cross backend tombstones",
             :enrollment},
            {"Kubernetes reservation atomically saves exact intent and capacity", :reservation},
            {"Kubernetes stale receipt writes cannot replace original authority", :receipts},
            {"Kubernetes cleanup requires matching physical proof and releases once", :cleanup},
            {"Kubernetes historical component proof cannot release managed capacity",
             :legacy_proof},
            {"Kubernetes historical CRI-only proof cannot release managed capacity",
             :legacy_cri_proof},
            {"Kubernetes undispatched create has a separate durable cleanup path", :undispatched},
            {"Kubernetes recovery scans retain released tombstones and empty pages", :recovery}
          ] do
        quote do
          test(unquote(title), %{adapter: adapter, store: store},
            do: SmolBox.Store.KubernetesContract.unquote(function)(adapter, store)
          )
        end
      end

    quote do
      use ExUnit.Case, unquote(options)
      unquote_splicing(scenarios)
    end
  end

  def pending(adapter, store, config, id \\ "execution-1") do
    record = Fixture.execution(config)
    spec = %{record.spec | id: id}
    {:ok, fp} = SmolBox.ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = Execution.new(spec, fp, 1000)
    assert {:ok, ^record, :inserted} = adapter.accept(store, record, 100)
    assert {:ok, claimed} = adapter.claim(store, Execution.key(record), "owner", 1100, 10_000)
    claimed
  end

  def reserved(adapter, store) do
    {:ok, config} = Fixture.config()
    binding = Config.binding(config)
    assert {:ok, ^binding} = adapter.bind_backend(store, config.id, binding)
    assert {:ok, _} = adapter.claim_worker(store, config.id, "owner", 1000, 10_000)
    record = pending(adapter, store, config)
    assert {:ok, assignment} = Assignment.new(config, record, "kube-contract")
    assert {:ok, record} = reserve(adapter, store, config, record, assignment)
    {config, record, assignment}
  end

  def reserve(adapter, store, config, record, assignment),
    do:
      adapter.reserve(
        store,
        Execution.key(record),
        Contract.guard(record),
        {config.id, assignment.pod_name, config.capacity, assignment},
        1200
      )

  def enrollment(adapter, store) do
    {config, record, _} = reserved(adapter, store)
    binding = Config.binding(config)
    assert {:ok, %{kubernetes_backend: 1}} = adapter.capabilities(store)
    assert {:ok, ^binding} = adapter.bind_backend(store, config.id, binding)
    assert {:error, _} = adapter.bind_backend(store, config.id, :http)

    assert {:error, _} =
             adapter.bind_backend(
               store,
               config.id,
               BackendContract.domain_binding(config.id)
             )

    for overrides <- [[id: "alias"], [id: "alias", namespace_uid: "different"]] do
      {:ok, other} = Fixture.config(overrides)
      assert {:error, _} = adapter.bind_backend(store, other.id, Config.binding(other))
    end

    assert {:ok, ^record} = adapter.fetch(store, Execution.key(record))
  end

  def reservation(adapter, store) do
    {config, record, assignment} = reserved(adapter, store)
    assert record.backend_assignment == assignment
    assert record.backend_create_state == :pending
    assert {:error, _} = write(adapter, store, record, state: :ready)
    assert record.deadlines.preparation == 1200 + record.spec.profile.preparation_ms
    resources = Profile.resources(record.spec.profile)
    assert {:ok, ^resources} = adapter.usage(store, config.id)
    second = pending(adapter, store, config, "second")
    {:ok, intent} = Assignment.new(config, second, "kube-second")
    assert {:error, _} = reserve(adapter, store, config, second, intent)
    assert {:ok, ^second} = adapter.fetch(store, Execution.key(second))
    assert {:ok, ^resources} = adapter.usage(store, config.id)
    # A legacy allocation tuple must not drop the typed intent.
    assert {:error, _} =
             adapter.reserve(
               store,
               Execution.key(second),
               Contract.guard(second),
               {config.id, "legacy-name", config.capacity},
               1200
             )
  end

  def receipts(adapter, store) do
    {_, record, assignment} = reserved(adapter, store)
    {:ok, receipt} = Receipt.created(assignment, "pod-original")
    assert {:error, _} = write(adapter, store, record, backend_receipt: receipt)
    assert {:ok, dispatched} = write(adapter, store, record, backend_create_state: :dispatched)
    assert {:ok, saved} = write(adapter, store, dispatched, backend_receipt: receipt)

    assert {:error, _} =
             write(adapter, store, dispatched,
               backend_receipt: %{receipt | pod_uid: "replacement"}
             )

    assert {:error, _} =
             write(adapter, store, saved, backend_receipt: %{receipt | pod_uid: "replacement"})

    assert {:error, _} = write(adapter, store, saved, backend_create_state: :pending)
    assert {:ok, ^saved} = adapter.fetch(store, Execution.key(record))
    ready = Fixture.ready_receipt(assignment)
    assert {:ok, running} = write(adapter, store, saved, backend_receipt: ready)
    assert {:error, _} = write(adapter, store, running, backend_receipt: receipt)

    assert {:error, _} =
             write(adapter, store, running,
               backend_receipt: %{
                 ready
                 | container_id: "containerd://" <> String.duplicate("f", 64)
               }
             )
  end

  defp cleanup_authority(adapter, store) do
    {config, record, assignment} = reserved(adapter, store)
    {:ok, created} = Receipt.created(assignment, "pod-original")

    assert {:ok, record} =
             write(adapter, store, record,
               backend_create_state: :dispatched,
               backend_receipt: created
             )

    ready = Fixture.ready_receipt(assignment)
    assert {:ok, record} = write(adapter, store, record, backend_receipt: ready, state: :failed)
    {config, record, ready}
  end

  def cleanup(adapter, store) do
    {config, record, ready} = cleanup_authority(adapter, store)
    assert {:error, _} = write(adapter, store, record, cleanup: :complete, absence_at_ms: 1300)
    proof = %{Fixture.cleanup_proof(ready) | observed_at_ms: 1300}

    for bad <- [
          %{proof | api_absent: false},
          %{proof | complete_history: false},
          %{proof | terminated_processes: []}
        ] do
      assert {:error, _} =
               write(adapter, store, record,
                 backend_cleanup: bad,
                 cleanup: :complete,
                 absence_at_ms: 1300
               )
    end

    assert {:error, _} =
             adapter.release(store, Execution.key(record), Contract.guard(record), 1300)

    assert {:ok, cleaned} =
             write(adapter, store, record,
               backend_cleanup: proof,
               cleanup: :complete,
               absence_at_ms: 1300
             )

    assert {:ok, released} =
             adapter.release(store, Execution.key(record), Contract.guard(cleaned), 1300)

    assert released.reservation == nil
    assert {:ok, %{slots: 0, memory_mb: 0}} = adapter.usage(store, config.id)

    assert {:error, _} =
             adapter.release(store, Execution.key(record), Contract.guard(cleaned), 1300)

    assert {:ok, _} =
             adapter.release(store, Execution.key(record), Contract.guard(released), 1300)

    assert {:error, _} = adapter.bind_backend(store, config.id, :http)
  end

  def legacy_proof(adapter, store), do: historical_proof(adapter, store, 1)
  def legacy_cri_proof(adapter, store), do: historical_proof(adapter, store, 2)

  defp historical_proof(adapter, store, version) do
    {config, record, ready} = cleanup_authority(adapter, store)
    proof = %{Fixture.cleanup_proof(ready) | version: version, observed_at_ms: 1300}

    assert {:ok, held} =
             write(adapter, store, record,
               backend_cleanup: proof,
               cleanup: :complete,
               absence_at_ms: 1300
             )

    assert {:ok, bytes} = Codec.encode(held)
    assert {:ok, ^held} = Codec.decode(bytes)
    assert {:error, _} = adapter.release(store, Execution.key(held), Contract.guard(held), 1300)
    assert {:ok, ^held} = adapter.fetch(store, Execution.key(held))
    assert {:ok, %{slots: 1}} = adapter.usage(store, config.id)
  end

  def undispatched(adapter, store) do
    {config, record, _} = reserved(adapter, store)

    assert {:error, _} =
             write(adapter, store, record,
               state: :cancelled,
               cleanup: :complete,
               absence_at_ms: 1300
             )

    assert {:ok, cleaned} =
             write(adapter, store, record,
               state: :cancelled,
               cleanup: :complete,
               backend_cleanup: :not_dispatched,
               absence_at_ms: 1300
             )

    assert {:error, _} = write(adapter, store, cleaned, backend_create_state: :dispatched)
    assert {:ok, _} = adapter.release(store, Execution.key(record), Contract.guard(cleaned), 1300)
    assert {:ok, %{slots: 0}} = adapter.usage(store, config.id)
  end

  def recovery(adapter, store) do
    {config, record, _} = reserved(adapter, store)

    assert {:ok, cleaned} =
             write(adapter, store, record,
               state: :cancelled,
               cleanup: :complete,
               backend_cleanup: :not_dispatched,
               absence_at_ms: 1300
             )

    assert {:ok, released} =
             adapter.release(store, Execution.key(record), Contract.guard(cleaned), 1300)

    assert {:ok, [^released], nil} = adapter.backend_assignments(store, config.id, nil, 1)
    assert {:ok, [], nil} = adapter.backend_assignments(store, "other", nil, 1)
    assert {:error, _} = adapter.backend_assignments(store, config.id, :invalid, 1)
    assert {:error, _} = adapter.bind_backend(store, config.id, :http)
  end

  defp write(adapter, store, record, changes),
    do: adapter.write(store, Execution.key(record), Contract.guard(record), changes, 1300)
end
