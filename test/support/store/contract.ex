defmodule SmolBox.Store.Contract do
  @moduledoc false

  import ExUnit.Assertions

  alias SmolBox.{Command, Error, Execution, ExecutionSpec, Files, Profile}

  def record(id \\ "one", argv \\ ["true"]) do
    {:ok, command} = Command.new(argv)
    {:ok, profile} = Profile.new("offline-v1")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "contract",
        id: id,
        command: command,
        profile: profile,
        artifact: %{
          "id" => "python",
          "architecture" => "x86_64",
          "sha256" => Files.sha256("approved")
        }
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, record} = Execution.new(spec, fingerprint, 1000)
    record
  end

  def guard(record),
    do: %{owner: record.claim_owner, generation: record.generation, version: record.version}

  def capacity(slots \\ 1),
    do: %{slots: slots, cpus: slots, memory_mb: 512 * slots, disk_gb: 2 * slots}

  @scenarios [
    {"atomic identical acceptance returns one original record under concurrency", :acceptance},
    {"conflicts fail and full queues still recognize the existing identity", :conflicts},
    {"execution claims and CAS writes fence concurrent owners", :claims},
    {"atomic reservations cannot overbook and release waits for confirmed cleanup",
     :reservations},
    {"worker takeover preserves dispatch uncertainty and existing reservations", :takeover},
    {"queue expiry cannot reserve or reset its original deadline", :expiry},
    {"due work is bounded and cancellation intent survives subsequent reads", :pagination}
  ]

  defmacro __using__(options) do
    cases =
      for {title, function} <- @scenarios do
        quote do
          test unquote(title), %{adapter: adapter, store: store} do
            SmolBox.Store.Contract.unquote(function)(adapter, store)
          end
        end
      end

    quote do
      use ExUnit.Case, unquote(options)
      unquote_splicing(cases)
    end
  end

  def acceptance(adapter, store) do
    record = record()

    results =
      1..24
      |> Task.async_stream(fn _n -> adapter.accept(store, record, 10) end,
        max_concurrency: 24,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, ^record, :inserted}, &1)) == 1
    assert Enum.count(results, &match?({:ok, ^record, :existing}, &1)) == 23
    assert {:ok, ^record} = adapter.fetch(store, Execution.key(record))
  end

  def conflicts(adapter, store) do
    record = record()
    assert {:ok, ^record, :inserted} = adapter.accept(store, record, 1)

    assert {:error, %Error{category: :identity_conflict}} =
             adapter.accept(store, record("one", ["false"]), 1)

    assert {:error, %Error{category: :admission_exhausted}} =
             adapter.accept(store, record("two"), 1)

    assert {:ok, ^record, :existing} = adapter.accept(store, record, 1)
    assert {:error, %Error{category: :not_found}} = adapter.fetch(store, {"foreign", "one"})
  end

  def claims(adapter, store) do
    record = record()
    key = Execution.key(record)
    {:ok, _, :inserted} = adapter.accept(store, record, 1)

    claims =
      1..16
      |> Task.async_stream(fn n -> adapter.claim(store, key, "owner#{n}", 1100, 1000) end,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, claim}] = Enum.filter(claims, &match?({:ok, _}, &1))
    assert Enum.count(claims, &match?({:error, %Error{category: :stale_claim}}, &1)) == 15

    assert {:ok, cancelled} =
             adapter.write(
               store,
               key,
               guard(claim),
               [state: :cancelled, cleanup: :complete],
               1200
             )

    assert {:error, %Error{category: :stale_version}} =
             adapter.write(store, key, guard(claim), [], 1300)

    assert {:ok, takeover} = adapter.claim(store, key, "new-owner", 2100, 1000)
    assert takeover.generation == cancelled.generation + 1

    assert {:error, %Error{category: :stale_version}} =
             adapter.write(store, key, guard(cancelled), [], 2200)

    assert {:error, %Error{category: :stale_claim}} =
             adapter.write(store, key, guard(takeover), [], 3100)
  end

  def reservations(adapter, store) do
    assert {:ok, _lease} = adapter.claim_worker(store, "worker", "owner", 1000, 10_000)

    records =
      for id <- ["one", "two"] do
        record = record(id)
        {:ok, _, :inserted} = adapter.accept(store, record, 2)
        {:ok, claim} = adapter.claim(store, Execution.key(record), "owner", 1100, 10_000)
        claim
      end

    outcomes =
      records
      |> Task.async_stream(fn record ->
        adapter.reserve(
          store,
          Execution.key(record),
          guard(record),
          {"worker", "sbx-" <> record.id, capacity()},
          1200
        )
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, reserved}] = Enum.filter(outcomes, &match?({:ok, _}, &1))

    assert Enum.count(outcomes, &match?({:error, %Error{category: :admission_exhausted}}, &1)) ==
             1

    assert {:ok, %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2}} =
             adapter.usage(store, "worker")

    key = Execution.key(reserved)

    assert {:error, %Error{category: :cleanup}} =
             adapter.release(store, key, guard(reserved), 1300)

    assert {:error, _} =
             adapter.write(
               store,
               key,
               guard(reserved),
               [state: :cancelled, cleanup: :complete],
               1300
             )

    assert {:ok, cleaned} =
             adapter.write(
               store,
               key,
               guard(reserved),
               [state: :cancelled, cleanup: :complete, absence_at_ms: 1300],
               1300
             )

    assert {:ok, released} = adapter.release(store, key, guard(cleaned), 1400)
    assert released.reservation == nil

    assert {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} =
             adapter.usage(store, "worker")

    assert {:ok, ^released, :existing} =
             adapter.accept(store, record(released.id), 2)
  end

  def takeover(adapter, store) do
    record = record()
    key = Execution.key(record)
    {:ok, _, :inserted} = adapter.accept(store, record, 1)
    {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 1000)

    assert {:error, %Error{category: :stale_claim}} =
             adapter.claim_worker(store, "worker", "foreign", 1500, 1000)

    {:ok, claimed} = adapter.claim(store, key, "owner", 1100, 1000)

    {:ok, preparing} =
      adapter.reserve(
        store,
        key,
        guard(claimed),
        {"worker", "sbx-one", capacity()},
        1200
      )

    {:ok, ready} = adapter.write(store, key, guard(preparing), [state: :ready], 1300)

    {:ok, sent} =
      adapter.write(
        store,
        key,
        guard(ready),
        [state: :dispatching, evidence: :dispatch_uncertain],
        1400
      )

    {:ok, lease} = adapter.claim_worker(store, "worker", "new-owner", 2200, 1000)
    {:ok, takeover} = adapter.claim(store, key, "new-owner", 2200, 1000)
    assert takeover.worker_generation == lease.generation
    assert takeover.state == :dispatching
    assert takeover.deadlines == sent.deadlines
    assert {:error, _} = adapter.write(store, key, guard(sent), [], 2300)

    assert {:error, _} =
             adapter.write(store, key, guard(takeover), [state: :ready], 2300)

    assert {:ok, unknown} =
             adapter.write(
               store,
               key,
               guard(takeover),
               [state: :unknown, evidence: :unknown],
               2300
             )

    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
    assert {:ok, ^unknown, :existing} = adapter.accept(store, record, 1)
  end

  def expiry(adapter, store) do
    record = record()
    key = Execution.key(record)
    {:ok, _, :inserted} = adapter.accept(store, record, 1)
    now = record.deadlines.queue
    {:ok, _} = adapter.claim_worker(store, "worker", "owner", now, 1000)
    {:ok, claim} = adapter.claim(store, key, "owner", now, 1000)

    assert {:error, %Error{category: :expired}} =
             adapter.reserve(
               store,
               key,
               guard(claim),
               {"worker", "sbx-one", capacity()},
               now
             )

    assert {:ok, expired} =
             adapter.write(
               store,
               key,
               guard(claim),
               [state: :expired, cleanup: :complete],
               now
             )

    assert {:ok, ^expired, :existing} = adapter.accept(store, record, 1)
    assert {:ok, [], nil} = adapter.due(store, now, nil, 10)
  end

  def pagination(adapter, store) do
    for id <- ["a", "b", "c", "d", "e"],
        do: assert({:ok, _, :inserted} = adapter.accept(store, record(id), 10))

    assert {:ok, first, cursor} = adapter.due(store, 1100, nil, 2)
    assert Enum.map(first, & &1.id) == ["a", "b"]
    assert {:ok, second, next} = adapter.due(store, 1100, cursor, 2)
    assert Enum.map(second, & &1.id) == ["c", "d"]
    assert {:ok, [last], nil} = adapter.due(store, 1100, next, 2)
    assert last.id == "e"
    assert {:ok, [], nil} = adapter.due(store, 999, nil, 2)
    assert {:error, _} = adapter.due(store, 1100, nil, 0)
    assert {:ok, cancelled} = adapter.cancel(store, {"contract", "a"}, 1200)
    assert {:ok, repeated} = adapter.cancel(store, {"contract", "a"}, 1300)
    assert repeated.cancel_requested_at_ms == cancelled.cancel_requested_at_ms
    assert {:ok, ^repeated} = adapter.fetch(store, {"contract", "a"})
  end
end
