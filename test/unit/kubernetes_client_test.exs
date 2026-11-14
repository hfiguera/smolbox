defmodule SmolBox.KubernetesClientTest do
  use ExUnit.Case, async: true
  alias SmolBox.Kubernetes.{Client, Operation}
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.TestPeer

  defmodule SlowCredentials do
    @moduledoc false
    def resolve(owner, _budget) do
      send(owner, {:resolver, self()})
      Process.sleep(:infinity)
    end
  end

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "smolbox-kube-client-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tls: SmolBox.TestTLS.create(dir), directory: dir}
  end

  setup context do
    {config, peer} = Peer.start(context.tls)
    %{config: config, peer: peer}
  end

  defp operation(config, options \\ []),
    do: elem(Operation.new(config, struct!(config.budget, options), :create), 1)

  test "credential rotation is read within each operation and never changes authority", c do
    path =
      Path.join(
        c.directory,
        "token-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      )

    File.write!(path, "token-a\n")
    config = %{c.config | credential_provider: {:token_file, path}}
    assert {:ok, _} = Client.request(operation(config), "GET", "/version")
    File.write!(path, "token-b")
    Peer.change(c.peer, &%{&1 | expected_token: "token-b"})
    assert {:ok, _} = Client.request(operation(config), "GET", "/version")
    assert Enum.map(Peer.requests(c.peer), & &1.auth) == [["Bearer token-a"], ["Bearer token-b"]]
    File.write!(path, String.duplicate("a", 16_384) <> "\nignored")

    assert {:error, %{category: :authentication, evidence: :not_dispatched}} =
             Client.request(operation(config), "GET", "/version")
  end

  test "credential callback timeout cannot open a connection or escape total budget", c do
    config = %{c.config | credential_provider: {SlowCredentials, self()}}
    started = Operation.now()

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             Client.request(operation(config, timeout_ms: 75), "GET", "/version")

    assert Operation.now() - started < 500
    assert_receive {:resolver, resolver}
    refute Process.alive?(resolver)
    assert Peer.requests(c.peer) == []
  end

  test "caller death kills the credential worker instead of leaving an orphan", c do
    owner = self()
    config = %{c.config | credential_provider: {SlowCredentials, owner}}
    {caller, ref} = spawn_monitor(fn -> Client.request(operation(config), "GET", "/version") end)
    assert_receive {:resolver, resolver}
    monitor = Process.monitor(resolver)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, _}
    assert_receive {:DOWN, ^monitor, :process, ^resolver, _}
    assert Peer.requests(c.peer) == []
  end

  @tag capture_log: true
  test "redirects never forward authorization, and a bad CA cannot send a request", c do
    owner = self()

    sink =
      TestPeer.start(fn conn ->
        send(owner, :credential_leak)
        TestPeer.json(conn, %{})
      end)

    redirect = "http://localhost:#{sink}/stolen"

    Peer.change(
      c.peer,
      &put_in(&1, [:overrides, {"GET", "/version"}], fn conn ->
        conn |> Plug.Conn.put_resp_header("location", redirect) |> Plug.Conn.send_resp(302, "")
      end)
    )

    assert {:error, %{category: :protocol}} =
             Client.request(operation(c.config), "GET", "/version")

    refute_receive :credential_leak, 50

    wrong_host = %{
      c.config
      | api_server: String.replace(c.config.api_server, "localhost", "127.0.0.1")
    }

    assert {:error, %{evidence: :not_dispatched}} =
             Client.request(operation(wrong_host), "GET", "/version")

    bad = %{c.config | ca_file: "/nonexistent/smolbox-ca.pem"}

    assert {:error, %{evidence: :not_dispatched}} =
             Client.request(operation(bad), "GET", "/version")

    assert Enum.count(Peer.requests(c.peer)) == 1
  end

  test "response budget accumulates across pages and never resets between requests", c do
    op = operation(c.config, max_response_bytes: 40)
    assert {:ok, _} = Client.request(op, "GET", "/version")
    assert {:error, %{category: :output_limit}} = Client.request(op, "GET", "/version")
  end

  test "stalled response consumes the same total deadline after request dispatch", c do
    Peer.change(
      c.peer,
      &put_in(&1, [:overrides, {"GET", "/version"}], fn conn ->
        Process.sleep(700)
        TestPeer.json(conn, %{})
      end)
    )

    started = Operation.now()

    assert {:error, %{evidence: :dispatch_uncertain}} =
             Client.request(operation(c.config, timeout_ms: 300), "GET", "/version")

    assert Operation.now() - started < 1000
  end

  test "request byte cap is checked before credentials and HTTP dispatch", c do
    assert {:error, %{evidence: :not_dispatched}} =
             Client.request(
               operation(c.config, max_request_bytes: 1),
               "POST",
               "/api/v1/namespaces/smolbox-preview/pods",
               %{"too" => "large"}
             )

    assert Peer.requests(c.peer) == []
  end
end
