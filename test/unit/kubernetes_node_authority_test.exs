defmodule SmolBox.KubernetesNodeAuthorityTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.{CleanupProof, NodeAuthority, Observation}
  alias SmolBox.Kubernetes.NodeAuthority.{Context, Protocol}
  alias SmolBox.Test.Kubernetes, as: Kubernetes
  alias SmolBox.Test.NodeAuthority, as: Fixture

  @budget %Budget{timeout_ms: 3000, max_request_bytes: 65_544, max_response_bytes: 65_544}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-authority-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    executable = Path.join(root, "ssh-peer")
    File.cp!("test/support/kubernetes_node_peer.py", executable)
    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, context} = Fixture.context(ssh_executable: executable)
    receipt = Fixture.receipt(System.system_time(:millisecond) - 100)
    %{root: root, context: context, receipt: receipt, binding: receipt.binding}
  end

  defp reply(c, action, value, mode \\ "normal", extra \\ %{}) do
    response = Fixture.vectors()["successes"][action] |> Map.put("value", json(value))

    File.write!(
      Path.join(c.root, "response.json"),
      Jason.encode!(Map.merge(%{mode: mode, response: response}, extra))
    )
  end

  defp json(value) when is_struct(value), do: value |> Map.from_struct() |> json()

  defp json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json(item)} end)

  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(value), do: value

  defp status(c, mode \\ "normal"),
    do:
      reply(
        c,
        "check",
        %{complete_history: true, idle: true, observer_epoch: c.context.authority_generation},
        mode
      )

  defp request(c), do: Path.join(c.root, "request.json") |> File.read!() |> Jason.decode!()

  defp wait_file(path, count \\ 500)
  defp wait_file(_path, 0), do: flunk("owned authority peer did not report channel closure")

  defp wait_file(path, count) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_file(path, count - 1)
        )
  end

  test "check/capture/cleanup use fixed direct SSH and return original typed authority", c do
    status(c)

    assert {:ok, %{complete_history: true, idle: true, observer_epoch: epoch}} =
             NodeAuthority.check(c.binding, @budget, c.context)

    assert epoch == c.context.authority_generation
    reply(c, "capture", c.receipt.observation)

    assert {:ok, %Observation{} = observation} =
             NodeAuthority.capture(c.binding, c.receipt.pod_uid, @budget, c.context)

    assert observation == c.receipt.observation

    proof = %{
      Kubernetes.cleanup_proof(c.receipt)
      | observed_at_ms: System.system_time(:millisecond)
    }

    reply(c, "cleanup", proof |> Map.from_struct() |> Map.delete(:receipt))

    assert {:ok, %CleanupProof{} = actual} =
             NodeAuthority.cleanup(c.binding, c.receipt, @budget, c.context)

    assert actual == proof and actual.receipt == c.receipt
    wire = request(c)
    assert List.last(wire["argv"]) == "smolbox-node-authority-v1"
    refute inspect(wire) =~ "lab.sh"
    refute inspect(wire) =~ "private-command-value"
    assert wire["request"]["arguments"]["receipt"]["pod_uid"] == c.receipt.pod_uid
    assert wire["request"]["arguments"]["receipt_sha256"] != ""

    for option <- [
          "StrictHostKeyChecking=yes",
          "IdentitiesOnly=yes",
          "IdentityFile=none",
          "IdentityAgent=none",
          "GlobalKnownHostsFile=/dev/null",
          "KnownHostsCommand=none",
          "UpdateHostKeys=no",
          "VerifyHostKeyDNS=no",
          "PreferredAuthentications=publickey",
          "PasswordAuthentication=no",
          "KbdInteractiveAuthentication=no",
          "ForwardAgent=no",
          "ForwardX11=no",
          "ClearAllForwardings=yes",
          "ProxyCommand=none",
          "ProxyJump=none",
          "ControlMaster=no",
          "ControlPath=none",
          "ControlPersist=no",
          "PermitLocalCommand=no"
        ] do
      assert option in wire["argv"]
    end

    assert Enum.take(wire["argv"], 3) == ["-F", "/dev/null", "-T"]
    assert ("UserKnownHostsFile=" <> c.context.known_hosts_file) in wire["argv"]

    assert wire["argv"] |> Enum.reverse() |> Enum.take(9) ==
             [
               "-l",
               c.context.ssh_user,
               "-p",
               Integer.to_string(c.context.ssh_port),
               "-i",
               c.context.identity_file,
               "--",
               c.context.ssh_host,
               "smolbox-node-authority-v1"
             ]
             |> Enum.reverse()
  end

  test "every invocation has a new nonce and a recorded prior response is rejected", c do
    status(c)
    assert {:ok, _} = NodeAuthority.check(c.binding, @budget, c.context)
    first = request(c)["request"]
    assert {:ok, _} = NodeAuthority.check(c.binding, @budget, c.context)
    second = request(c)["request"]
    assert first["nonce"] != second["nonce"]
    assert byte_size(first["nonce"]) == 64

    response =
      Fixture.vectors()["successes"]["check"]
      |> Map.merge(
        Map.take(
          first,
          ~w(version action nonce binding_generation authority_generation verifier_manifest_sha256)
        )
      )

    File.write!(
      Path.join(c.root, "response.json"),
      Jason.encode!(%{mode: "normal", recorded: true, response: response})
    )

    assert {:error, %{category: :protocol, exit_code: nil}} =
             NodeAuthority.check(c.binding, @budget, c.context)
  end

  test "helper failure can report a bounded rejection but cannot qualify positive evidence", c do
    for code <- [1, 7, 255] do
      status(c)
      options = Path.join(c.root, "response.json") |> File.read!() |> Jason.decode!()
      options = options |> Map.put("mode", "status") |> Map.put("exit_code", code)
      File.write!(Path.join(c.root, "response.json"), Jason.encode!(options))

      assert {:error, %{category: :transport, exit_code: nil}} =
               NodeAuthority.check(c.binding, @budget, c.context)

      options = put_in(options, ["response", "ok"], false)
      options = put_in(options, ["response", "value"], nil)
      options = put_in(options, ["response", "journal"], nil)
      options = put_in(options, ["response", "error"], "unavailable")
      File.write!(Path.join(c.root, "response.json"), Jason.encode!(options))

      assert {:error, %{category: :identity_conflict, exit_code: nil}} =
               NodeAuthority.check(c.binding, @budget, c.context)
    end

    proof = %{
      Kubernetes.cleanup_proof(c.receipt)
      | observed_at_ms: System.system_time(:millisecond)
    }

    for {action, argument, value} <- [
          {:capture, c.receipt.pod_uid, c.receipt.observation},
          {:cleanup, c.receipt, proof |> Map.from_struct() |> Map.delete(:receipt)}
        ] do
      reply(c, Atom.to_string(action), value, "status", %{exit_code: 7})

      assert {:error, %{category: :transport, exit_code: nil}} =
               apply(NodeAuthority, action, [c.binding, argument, @budget, c.context])
    end
  end

  test "malformed, duplicate, oversize, extra, wrong-magic and diagnostic replies fail closed",
       c do
    for mode <-
          ~w(partial trailing oversized diagnostic duplicate nested_duplicate wrongmagic exit) do
      status(c, mode)
      assert {:error, error} = NodeAuthority.check(c.binding, @budget, c.context)
      assert error.exit_code == nil
      refute inspect(error) =~ "private-node-diagnostic"
    end
  end

  test "a valid body at 65536 bytes is accepted and frame overhead is charged", c do
    status(c, "padded")
    assert {:ok, _} = NodeAuthority.check(c.binding, @budget, c.context)

    assert {:error, _} =
             NodeAuthority.check(c.binding, %{@budget | max_response_bytes: 65_543}, c.context)

    assert {:error, _} =
             NodeAuthority.check(c.binding, %{@budget | max_response_bytes: 9}, c.context)

    File.rm!(Path.join(c.root, "request.json"))

    assert {:error, %{category: :output_limit}} =
             NodeAuthority.check(c.binding, %{@budget | max_request_bytes: 1}, c.context)

    refute File.exists?(Path.join(c.root, "request.json"))
  end

  test "exact request allowance succeeds and one fewer byte opens no channel", c do
    status(c)
    nonce = String.duplicate("a", 64)
    assert {:ok, _, bytes} = Protocol.request(:check, c.binding, nil, c.context, @budget, nonce)
    exact = %{@budget | max_request_bytes: byte_size(bytes) + 8}
    assert {:ok, _} = NodeAuthority.check(c.binding, exact, c.context)
    File.rm!(Path.join(c.root, "request.json"))

    assert {:error, %{category: :output_limit}} =
             NodeAuthority.check(
               c.binding,
               %{exact | max_request_bytes: exact.max_request_bytes - 1},
               c.context
             )

    refute File.exists?(Path.join(c.root, "request.json"))
  end

  test "future/stale captures and mismatched authority cannot authorize application dispatch",
       c do
    now = System.system_time(:millisecond)

    for observation <- [
          %{c.receipt.observation | observed_at_ms: now + 60_000},
          %{c.receipt.observation | observed_at_ms: now - 5001},
          %{c.receipt.observation | observer_epoch: "epoch-a"},
          %{c.receipt.observation | isolated: false},
          %{c.receipt.observation | complete_history: false},
          %{c.receipt.observation | binding_generation: String.duplicate("b", 64)},
          %{c.receipt.observation | pod_uid: "99999999-2222-4333-8444-555555555555"}
        ] do
      reply(c, "capture", observation)
      assert {:error, _} = NodeAuthority.capture(c.binding, c.receipt.pod_uid, @budget, c.context)
    end
  end

  test "old-provider receipts and unsafe Pod IDs never reach SSH", c do
    status(c)
    old = %{c.receipt | observation: %{c.receipt.observation | observer_epoch: "epoch-a"}}

    assert {:error, %{category: :identity_conflict}} =
             NodeAuthority.cleanup(c.binding, old, @budget, c.context)

    for uid <- ["pod-original", "../pod", <<0>>, nil] do
      assert {:error, _} = NodeAuthority.capture(c.binding, uid, @budget, c.context)
    end

    refute File.exists?(Path.join(c.root, "request.json"))
  end

  test "timeout and caller death close only the owned evidence channel", c do
    status(c, "hold")
    started = System.monotonic_time(:millisecond)

    assert {:error, %{category: :expired}} =
             NodeAuthority.check(c.binding, %{@budget | timeout_ms: 500}, c.context)

    assert System.monotonic_time(:millisecond) - started < 2000
    wait_file(Path.join(c.root, "closed"))
    File.rm!(Path.join(c.root, "closed"))
    File.rm!(Path.join(c.root, "request.json"))
    {pid, monitor} = spawn_monitor(fn -> NodeAuthority.check(c.binding, @budget, c.context) end)
    wait_file(Path.join(c.root, "request.json"))
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    wait_file(Path.join(c.root, "closed"))
  end

  test "construction is offline, redacted and requires explicit safe connection/approval fields",
       c do
    assert :ok = Context.validate(c.context)

    for field <- [
          :ssh_host,
          :ssh_user,
          :identity_file,
          :known_hosts_file,
          :authority_generation,
          :verifier_manifest_sha256,
          :ssh_executable
        ] do
      refute inspect(c.context) =~ Map.fetch!(c.context, field)
    end

    assert {:ok, _} = Fixture.context(ssh_executable: "/missing/ssh")
    assert {:ok, _} = Fixture.context(ssh_host: "::1")

    for {field, bad} <- [
          ssh_host: "-oProxyCommand=bad",
          ssh_host: "user@node",
          ssh_host: "node;bad",
          ssh_host: <<255>>,
          ssh_user: "root bad",
          ssh_user: "-root",
          ssh_port: 0,
          ssh_port: 65_536,
          identity_file: "relative",
          identity_file: "/tmp/%d/key",
          known_hosts_file: "/tmp/a b",
          known_hosts_file: "/tmp/a\nother",
          known_hosts_file: "/tmp/../key",
          ssh_executable: "/tmp/x/",
          authority_generation: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
          verifier_manifest_sha256: String.duplicate("A", 64)
        ] do
      assert :error = Fixture.context([{field, bad}])
    end

    for bad <- [
          [command: "arbitrary"],
          [ssh_options: ["-oProxyCommand=bad"]],
          [ssh_host: "node", ssh_host: "other"]
        ] do
      assert :error =
               NodeAuthority.new(Map.from_struct(c.context) |> Map.to_list() |> Kernel.++(bad))
    end

    assert {:error, %{category: :validation}} =
             NodeAuthority.check(c.binding, @budget, Map.put(c.context, :unknown, "private"))
  end
end
