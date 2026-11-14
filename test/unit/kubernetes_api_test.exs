defmodule SmolBox.KubernetesAPITest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Execution}
  alias SmolBox.Kubernetes.{Assignment, Client, Enrollment, Operation, Pod, PodTemplate}
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.Runtime.Target
  alias SmolBox.Test.Kubernetes, as: Fixture
  alias SmolBox.TestPeer

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "smolbox-kube-tls-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tls: SmolBox.TestTLS.create(dir)}
  end

  setup context do
    {config, peer} = Peer.start(context.tls)
    {record, _} = Fixture.assigned(config)
    {:ok, record} = Execution.transition(record, [backend_create_state: :dispatched], 1000)
    %{config: config, peer: peer, record: record}
  end

  defp operation(config, name \\ :create, ms \\ 3000) do
    {:ok, value} = Operation.new(config, %{config.budget | timeout_ms: ms}, name)
    value
  end

  defp created(context) do
    assert {:ok, receipt} = Pod.create_once(operation(context.config), context.record)
    assert {:ok, record} = Execution.transition(context.record, [backend_receipt: receipt], 1000)
    record
  end

  test "the assigned backend port accepts only its durable object intent", c do
    reference =
      c.config |> Target.normalize() |> Target.connection() |> Backend.assigned(c.record)

    assert {:error, _} = Backend.create(reference, %{unexpected: "spec"})
    assert Peer.requests(c.peer) == []
    assert {:ok, receipt} = Backend.create(reference, c.record.backend_assignment)
    {:ok, record} = Execution.transition(c.record, [backend_receipt: receipt], 1000)
    reference = Backend.assigned(reference, record)
    assert {:ok, %{phase: :pending}} = Backend.inspect_machine(reference, record.machine_name)
    assert {:error, _} = Backend.delete(reference, "different-name")
    assert {:error, _} = Backend.exec(reference, record.machine_name, record.spec.command)
    assert {:ok, :api_absent} = Backend.delete(reference, record.machine_name)
  end

  test "known creation mutation retains its original UID for cleanup, but recovery cannot adopt it",
       c do
    object = c.record.backend_assignment |> Assignment.manifest() |> Peer.effective()
    mutated = put_in(object, ["spec", "hostPID"], true)

    Peer.change(
      c.peer,
      &put_in(&1, [:overrides, {"POST", "/api/v1/namespaces/smolbox-preview/pods"}], fn conn ->
        TestPeer.json(conn, mutated, 201)
      end)
    )

    assert {:error, %{category: :identity_conflict}, receipt} =
             Pod.create_once(operation(c.config), c.record)

    assert receipt.pod_uid == "pod-original"
    Peer.change(c.peer, &%{&1 | pod: mutated})

    assert {:error, %{category: :identity_conflict}} =
             Pod.reconcile(operation(c.config), c.record)

    assert Enum.count(Peer.requests(c.peer), &(&1.method == "POST")) == 1
  end

  test "bounded HTTPS creates once, observes readiness and deletes the original UID", c do
    assert :ok == Enrollment.observe(operation(c.config, :worker))
    record = created(c)
    assert {:ok, %{phase: :pending}} = Pod.observe(operation(c.config, :inspect), record)
    Peer.change(c.peer, &%{&1 | pod: Peer.effective(&1.pod, true)})

    assert {:ok, %{phase: :ready, container_id: container}} =
             Pod.await_ready(operation(c.config, :start), record)

    assert String.starts_with?(container, "containerd://")
    assert {:ok, :api_absent} = Pod.delete(operation(c.config, :delete), record)
    deletes = Enum.filter(Peer.requests(c.peer), &(&1.method == "DELETE"))
    assert [request] = deletes
    assert request.body["preconditions"] == %{"uid" => "pod-original"}
    assert request.body["gracePeriodSeconds"] == 10
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "POST")) == 1
  end

  @tag capture_log: true
  test "a lost successful create reconciles only by GET and never replays POST", c do
    Peer.change(c.peer, &%{&1 | mode: :lost_create})

    assert {:error, %{evidence: :dispatch_uncertain}} =
             Pod.create_once(operation(c.config), c.record)

    assert {:ok, receipt} = Pod.reconcile(operation(c.config), c.record)
    assert receipt.pod_uid == "pod-original"
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "POST")) == 1
  end

  test "recovery cannot adopt mutated intent or a conflicting saved UID", c do
    record = created(c)
    Peer.change(c.peer, &put_in(&1, [:pod, "metadata", "uid"], "replacement"))
    assert {:error, %{category: :identity_conflict}} = Pod.reconcile(operation(c.config), record)
    assert {:error, %{category: :identity_conflict}} = Pod.delete(operation(c.config), record)
    refute Enum.any?(Peer.requests(c.peer), &(&1.method == "DELETE"))
  end

  test "admission rejects sidecars, mounts, altered resources and restart before exec", c do
    record = created(c)

    original =
      Peer.requests(c.peer)
      |> Enum.find(&(&1.method == "POST"))
      |> Map.fetch!(:body)
      |> Peer.effective(true)

    mutations = [
      put_in(
        original,
        ["spec", "containers"],
        original["spec"]["containers"] ++ [%{"name" => "injected"}]
      ),
      put_in(original, ["spec", "hostNetwork"], true),
      put_in(original, ["spec", "volumes"], [%{"name" => "host", "hostPath" => %{"path" => "/"}}]),
      put_in(original, ["spec", "overhead"], %{"cpu" => "0", "memory" => "0"}),
      put_in(original, ["status", "containerStatuses", Access.at(0), "restartCount"], 1)
    ]

    for changed <- mutations do
      Peer.change(c.peer, &%{&1 | pod: changed})
      assert {:error, %{category: :identity_conflict}} = Pod.observe(operation(c.config), record)
    end
  end

  test "changed namespace, node boot, class or offline policy drains admission", c do
    original = Peer.objects(c.config)

    mutations = [
      put_in(original, [:namespace, "metadata", "uid"], "new-namespace"),
      put_in(original, [:node, "status", "nodeInfo", "bootID"], "new-boot"),
      put_in(original, [:runtime, "metadata", "uid"], "new-class"),
      put_in(original, [:policy, "spec", "egress"], [%{}])
    ]

    for objects <- mutations do
      Peer.change(c.peer, &%{&1 | objects: objects})

      assert {:error, %{category: :identity_conflict}} =
               Pod.create_once(operation(c.config), c.record)
    end

    refute Enum.any?(Peer.requests(c.peer), &(&1.method == "POST"))
  end

  test "API errors are redacted, definitive rejections do not retry", c do
    for {status, category} <- [
          {401, :authentication},
          {403, :authentication},
          {409, :identity_conflict},
          {429, :admission_exhausted}
        ] do
      Peer.change(
        c.peer,
        &put_in(&1, [:overrides, {"GET", "/version"}], fn conn ->
          TestPeer.json(conn, %{"secret" => "private-response"}, status)
        end)
      )

      assert {:error, error} = Client.request(operation(c.config), "GET", "/version")
      assert error.category == category
      refute inspect(error) =~ "private-response"
    end

    assert Enum.count(Peer.requests(c.peer)) == 4
  end

  test "malformed and oversized response bytes fail before JSON accumulation", c do
    for body <- ["not-json", String.duplicate("x", c.config.budget.max_response_bytes + 1)] do
      Peer.change(
        c.peer,
        &put_in(&1, [:overrides, {"GET", "/version"}], fn conn ->
          Plug.Conn.send_resp(conn, 200, body)
        end)
      )

      assert {:error, error} = Client.request(operation(c.config), "GET", "/version")
      assert error.category in [:protocol, :output_limit]
    end
  end

  test "a finalizer retains API presence and does not produce cleanup success", c do
    record = created(c)
    Peer.change(c.peer, &%{&1 | mode: :finalizer})
    assert {:error, _} = Pod.delete(operation(c.config, :delete, 350), record)
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "DELETE")) == 1
  end

  test "inventory binds resourceVersion and rejects repeated continuation", c do
    assert {:ok, []} = Pod.inventory(operation(c.config, :list))

    response = %{
      "kind" => "PodList",
      "metadata" => %{"resourceVersion" => "42", "continue" => "same"},
      "items" => []
    }

    Peer.change(
      c.peer,
      &put_in(&1, [:overrides, {"GET", "/api/v1/namespaces/smolbox-preview/pods"}], fn conn ->
        TestPeer.json(conn, response)
      end)
    )

    assert {:error, %{category: :protocol}} = Pod.inventory(operation(c.config, :list))
  end

  test "inventory follows opaque tokens and rejects an inconsistent snapshot", c do
    object = c.record.backend_assignment |> Assignment.manifest() |> Peer.effective()
    token = "opaque+token/&?"

    response = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      metadata =
        if conn.query_params["continue"] == token,
          do: %{"resourceVersion" => "42"},
          else: %{"resourceVersion" => "42", "continue" => token}

      items = if Map.has_key?(metadata, "continue"), do: [object], else: []
      TestPeer.json(conn, %{"kind" => "PodList", "metadata" => metadata, "items" => items})
    end

    key = {"GET", "/api/v1/namespaces/smolbox-preview/pods"}
    Peer.change(c.peer, &put_in(&1, [:overrides, key], response))
    assert {:ok, [^object]} = Pod.inventory(operation(c.config, :list))

    Peer.change(
      c.peer,
      &put_in(&1, [:overrides, key], fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        version = if conn.query_params["continue"] == token, do: "43", else: "42"

        TestPeer.json(conn, %{
          "kind" => "PodList",
          "metadata" => %{"resourceVersion" => version, "continue" => token},
          "items" => []
        })
      end)
    )

    assert {:error, %{category: :protocol}} = Pod.inventory(operation(c.config, :list))
  end

  test "replacement between inspect and DELETE is protected atomically by UID", c do
    record = created(c)
    original = c.record.backend_assignment |> Assignment.manifest() |> Peer.effective()
    key = {"GET", "/api/v1/namespaces/smolbox-preview/pods/" <> record.machine_name}

    Peer.change(
      c.peer,
      &%{
        &1
        | pod: put_in(original, ["metadata", "uid"], "replacement"),
          overrides: Map.put(&1.overrides, key, fn conn -> TestPeer.json(conn, original) end)
      }
    )

    assert {:error, %{category: :identity_conflict}} =
             Pod.delete(operation(c.config, :delete), record)

    assert Agent.get(c.peer, &get_in(&1, [:pod, "metadata", "uid"])) == "replacement"
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "DELETE")) == 1
  end

  test "template handles qualified API defaults and never tolerates arbitrary fields", c do
    object =
      Peer.effective(Assignment.manifest(c.record.backend_assignment), true)

    object =
      put_in(
        object,
        ["spec", "containers", Access.at(0), "resources", "requests", "memory"],
        "1Gi"
      )

    assert PodTemplate.matches?(object, c.record.backend_assignment)

    refute PodTemplate.matches?(
             put_in(object, ["spec", "unexpected"], true),
             c.record.backend_assignment
           )

    refute PodTemplate.matches?(%{"metadata" => "invalid"}, c.record.backend_assignment)
  end
end
