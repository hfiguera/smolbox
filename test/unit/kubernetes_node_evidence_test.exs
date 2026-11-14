defmodule SmolBox.KubernetesNodeEvidenceTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.{Config, LabNodeEvidence, Operation}
  alias SmolBox.Test.Kubernetes, as: Fixture
  @budget %Budget{timeout_ms: 3000, max_request_bytes: 65_544, max_response_bytes: 65_544}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-node-peer-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    executable = Path.join(root, "ssh-peer")
    File.cp!("test/support/kubernetes_node_peer.py", executable)
    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, context} =
      LabNodeEvidence.new(
        ssh_host: "linux",
        ssh_executable: executable,
        inspector_sha256: Fixture.digest(),
        history_sha256: Fixture.digest()
      )

    {:ok, config} = Fixture.config()
    {_record, assignment} = Fixture.assigned(config)
    receipt = Fixture.ready_receipt(assignment)

    receipt = %{
      receipt
      | observation: %{
          receipt.observation
          | observed_at_ms: System.system_time(:millisecond) - 100
        }
    }

    %{root: root, context: context, binding: Config.binding(config), receipt: receipt}
  end

  defp json(value) when is_struct(value), do: value |> Map.from_struct() |> json()

  defp json(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json(v)} end)

  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(value), do: value

  defp response(c, action, value, mode \\ "normal") do
    envelope = %{
      "ok" => true,
      "version" => 1,
      "action" => action,
      "inspector_sha256" => Fixture.digest(),
      "history_sha256" => Fixture.digest(),
      "journal_watermark" => 2,
      "journal_hash" => Fixture.digest(),
      "value" => json(value)
    }

    File.write!(
      Path.join(c.root, "response.json"),
      Jason.encode!(%{mode: mode, response: envelope})
    )
  end

  defp proof(receipt),
    do: %{Fixture.cleanup_proof(receipt) | observed_at_ms: System.system_time(:millisecond)}

  defp status(c, complete \\ true) do
    response(c, "check", %{epoch: "epoch-a", complete_history: complete, idle: true})
  end

  defp wait_file(path, remaining \\ 100)
  defp wait_file(_path, 0), do: flunk("owned peer did not observe EOF")

  defp wait_file(path, remaining) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_file(path, remaining - 1)
        )
  end

  test "verified framed check/capture/cleanup return typed authority with a fixed command", c do
    status(c)

    assert {:ok, %{complete_history: true, idle: true}} =
             LabNodeEvidence.check(c.binding, @budget, c.context)

    response(c, "capture", c.receipt.observation)

    assert {:ok, observation} =
             LabNodeEvidence.capture(c.binding, c.receipt.pod_uid, @budget, c.context)

    assert observation == c.receipt.observation

    proof = proof(c.receipt)
    response(c, "cleanup", proof |> Map.from_struct() |> Map.delete(:receipt))
    assert {:ok, ^proof} = LabNodeEvidence.cleanup(c.binding, c.receipt, @budget, c.context)
    request = Path.join(c.root, "request.json") |> File.read!() |> Jason.decode!()
    assert List.last(request["argv"]) =~ "node_inspector.py inspect"
    refute List.last(request["argv"]) =~ "private-command-value"
    assert "ForwardAgent=no" in request["argv"]
    assert "StrictHostKeyChecking=yes" in request["argv"]
    assert request["request"]["receipt"]["pod_uid"] == c.receipt.pod_uid
  end

  test "incomplete history, stale capture, missing fields and changed cleanup epoch fail",
       c do
    status(c, false)
    assert {:error, _} = LabNodeEvidence.check(c.binding, @budget, c.context)

    for observation <- [
          %{c.receipt.observation | complete_history: false},
          %{c.receipt.observation | isolated: false},
          %{c.receipt.observation | observed_at_ms: 1},
          Map.delete(Map.from_struct(c.receipt.observation), :processes)
        ] do
      response(c, "capture", observation)

      assert {:error, _} =
               LabNodeEvidence.capture(c.binding, c.receipt.pod_uid, @budget, c.context)
    end

    proof = proof(c.receipt) |> Map.from_struct() |> Map.delete(:receipt)
    response(c, "cleanup", %{proof | observer_epoch: "different"})
    assert {:error, _} = LabNodeEvidence.cleanup(c.binding, c.receipt, @budget, c.context)
  end

  test "truncated, extra, oversized and diagnostic bytes fail closed without leaking data", c do
    for mode <- ~w(partial trailing oversized diagnostic) do
      response(c, "check", %{}, mode)
      assert {:error, error} = LabNodeEvidence.check(c.binding, @budget, c.context)
      refute inspect(error) =~ "private-node-diagnostic"
    end

    status(c)

    assert {:error, _} =
             LabNodeEvidence.check(c.binding, %{@budget | max_response_bytes: 10}, c.context)

    File.rm!(Path.join(c.root, "request.json"))

    assert {:error, _} =
             LabNodeEvidence.check(c.binding, %{@budget | max_request_bytes: 1}, c.context)

    refute File.exists?(Path.join(c.root, "request.json"))
  end

  test "deadline and caller death close the owned evidence channel", c do
    response(c, "check", %{}, "hold")
    assert {:error, _} = LabNodeEvidence.check(c.binding, %{@budget | timeout_ms: 300}, c.context)
    wait_file(Path.join(c.root, "closed"))
    File.rm!(Path.join(c.root, "closed"))
    File.rm!(Path.join(c.root, "request.json"))

    {pid, monitor} =
      spawn_monitor(fn -> LabNodeEvidence.check(c.binding, @budget, c.context) end)

    wait_file(Path.join(c.root, "request.json"))
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    wait_file(Path.join(c.root, "closed"))
  end

  test "provider construction is offline and rejects command/SSH argument injection", c do
    for host <- ["-oProxyCommand=bad", "linux;bad", "linux bad", "user@linux"] do
      assert :error =
               LabNodeEvidence.new(
                 ssh_host: host,
                 inspector_sha256: Fixture.digest(),
                 history_sha256: Fixture.digest()
               )
    end

    status(c)

    assert {:error, _} =
             LabNodeEvidence.check(c.binding, @budget, %{
               c.context
               | inspector_sha256: String.duplicate("b", 64)
             })

    refute inspect(c.context) =~ c.context.ssh_executable
  end

  test "opaque node callbacks reserve their byte allowance across the enclosing operation" do
    {:ok, config} = Fixture.config()
    {:ok, operation} = Operation.new(config, @budget, :exec)
    {:ok, granted} = Operation.node_budget(operation)
    Operation.account(operation, 2, 1000)
    {:ok, next} = Operation.node_budget(operation)

    assert :atomics.get(operation.bytes, 2) ==
             granted.max_response_bytes + 1000 + next.max_response_bytes

    assert Operation.response_left(operation) + :atomics.get(operation.bytes, 2) ==
             @budget.max_response_bytes

    Operation.account(operation, 2, Operation.response_left(operation))
    assert {:error, %{category: :output_limit}} = Operation.node_budget(operation)
  end
end
