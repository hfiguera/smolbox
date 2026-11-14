defmodule SmolBox.KubernetesExecTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Execution}
  alias SmolBox.Kubernetes.{Assignment, GuestHelper}
  alias SmolBox.KubernetesExecPeer, as: ExecPeer
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.Runtime.Target
  alias SmolBox.Test.Kubernetes, as: Fixture
  @moduletag capture_log: true

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "smolbox-kube-exec-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{tls: SmolBox.TestTLS.create(directory)}
  end

  setup context do
    {config, peer} = Peer.start(context.tls)
    {record, assignment} = Fixture.ready_record(config)
    config = %{config | node_evidence: {ExecPeer.Proof, record.backend_receipt.observation}}

    {:ok, record} =
      Execution.transition(record, [state: :dispatching, evidence: :dispatch_uncertain], 1000)

    Peer.change(peer, &%{&1 | pod: Peer.effective(Assignment.manifest(assignment), true)})
    %{config: config, peer: peer, record: record}
  end

  defp reference(c, budget \\ []) do
    c.config
    |> Target.normalize()
    |> Target.connection()
    |> Backend.assigned(c.record)
    |> Backend.bounded(budget)
  end

  defp status(code), do: ExecPeer.status(code)
  defp install(c, frames, options \\ []), do: ExecPeer.install(c.peer, c.record, frames, options)

  test "assigned exec_stream returns byte-exact stdout/stderr and actual nonzero status", c do
    frames = [
      {:binary, <<1, GuestHelper.ack()::binary, 255, 0>>},
      {:binary, <<2, 254, 1>>},
      status(7)
    ]

    install(c, frames)
    owner = self()

    assert {:ok, result} =
             Backend.exec_stream(reference(c), c.record.machine_name, c.record.spec.command,
               on_event: &send(owner, {:event, &1})
             )

    assert {result.exit_code, result.stdout, result.stderr, result.encoding} ==
             {7, <<255, 0>>, <<254, 1>>, :bytes}

    assert_receive {:offered, ["v5.channel.k8s.io"]}
    assert_receive {:exec_request, _, header}
    assert header["argv"] == c.record.spec.command.argv
    assert header["env"] == Enum.map(c.record.spec.command.env, &Tuple.to_list/1)
    assert_receive {:event, {:stdout, <<255, 0>>}}
    assert_receive {:event, {:stderr, <<254, 1>>}}
    assert_receive {:event, {:exit, 7}}
    refute_receive :unexpected_eof, 20
    request = Peer.requests(c.peer) |> Enum.find(&String.ends_with?(&1.path, "/exec"))
    refute URI.decode_query(request.query) |> Map.fetch!("command") =~ "private-command-value"
    refute request.query =~ "private-env-value"
  end

  test "silent exit zero is a real result and never requires an output callback", c do
    install(c, [{:binary, <<1, GuestHelper.ack()::binary>>}, status(0)])

    assert {:ok, %{exit_code: 0, stdout: "", stderr: ""}} =
             Backend.exec(reference(c), c.record.machine_name, c.record.spec.command)
  end

  test "explicit exec authorization rejection is definitive and does not retry", c do
    route = "/api/v1/namespaces/smolbox-preview/pods/" <> c.record.machine_name <> "/exec"
    denied = &SmolBox.TestPeer.json(&1, %{}, 403)
    Peer.change(c.peer, &put_in(&1, [:overrides, {"GET", route}], denied))

    assert {:error, %{category: :authentication, evidence: :not_dispatched}} =
             Backend.exec(reference(c), c.record.machine_name, c.record.spec.command)

    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
    refute_receive {:exec_request, _, _}, 20
  end

  test "missing status, duplicate status and protocol fallback cannot become success", c do
    for frames <- [
          [{:binary, <<1, GuestHelper.ack()::binary>>}],
          [{:binary, <<1, GuestHelper.ack()::binary>>}, status(7), status(0)]
        ] do
      install(c, frames)

      assert {:error, error, _partial} =
               Backend.exec(reference(c), c.record.machine_name, c.record.spec.command)
               |> normalize_error()

      assert error.category == :protocol
    end

    install(c, [], protocol: "v4.channel.k8s.io")

    assert {:error, %{category: :protocol}} =
             Backend.exec(reference(c), c.record.machine_name, c.record.spec.command)

    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 3
  end

  defp normalize_error({:error, error}), do: {:error, error, nil}
  defp normalize_error(other), do: other

  test "deadline closes observation with no second exec", c do
    install(c, [], mode: :hold)

    assert {:error, %{evidence: :dispatch_uncertain}} =
             Backend.exec(
               reference(c, timeout_ms: 2000),
               c.record.machine_name,
               c.record.spec.command
             )

    assert_receive {:exec_socket, socket}
    assert_receive {:exec_socket_closed, ^socket}, 1000
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
  end

  test "slow consumer preserves an observed exit and bounded partial output", c do
    install(c, [
      {:binary, <<1, GuestHelper.ack()::binary>>},
      status(7),
      {:binary, <<1, "observed">>}
    ])

    callback = fn _ -> Process.sleep(5000) end

    assert {:error, %{exit_code: 7}, %{exit_code: 7, stdout: "observed", truncated: true}} =
             Backend.exec_stream(
               reference(c, timeout_ms: 2000),
               c.record.machine_name,
               c.record.spec.command,
               on_event: callback
             )
  end

  test "caller death closes the upgraded socket and cannot leave an exec observer orphan", c do
    install(c, [], mode: :hold)
    ref = reference(c, timeout_ms: 5000)

    {caller, monitor} =
      spawn_monitor(fn -> Backend.exec(ref, c.record.machine_name, c.record.spec.command) end)

    assert_receive {:exec_request, socket, _}, 1000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, _}
    assert_receive {:exec_socket_closed, ^socket}, 1000
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
  end

  test "incomplete history, failed isolation or changed node incarnation blocks upgrade", c do
    install(c, [])
    {module, observation} = c.config.node_evidence

    for bad <- [
          %{observation | complete_history: false},
          %{observation | isolated: false},
          %{observation | observer_epoch: "another-epoch"},
          %{
            observation
            | processes: Enum.map(observation.processes, &%{&1 | start_ticks: &1.start_ticks + 1})
          }
        ] do
      config = %{c.config | node_evidence: {module, bad}}

      assert {:error, %{category: :identity_conflict, evidence: :not_dispatched}} =
               Backend.exec(
                 reference(%{c | config: config}),
                 c.record.machine_name,
                 c.record.spec.command
               )
    end

    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end

  test "user stdin, background, unknown names and changed command intent reject before upgrade",
       c do
    install(c, [])

    for command <- [
          %{c.record.spec.command | stdin: "data"},
          %{c.record.spec.command | background: true},
          %{c.record.spec.command | argv: ["different"]}
        ] do
      assert {:error, _} = Backend.exec(reference(c), c.record.machine_name, command)
    end

    assert {:error, _} = Backend.exec(reference(c), "different", c.record.spec.command)
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end
end
