defmodule SmolBox.KubernetesControllerTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.{Config, Controller, LabController, Operation}
  alias SmolBox.Test.Kubernetes, as: Fixture
  @budget %Budget{timeout_ms: 3000, max_request_bytes: 65_544, max_response_bytes: 65_544}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-controller-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    executable = Path.join(root, "python-peer")
    File.cp!("test/support/kubernetes_node_peer.py", executable)
    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, context} =
      LabController.new(directory: "/private/controller '☃", python_executable: executable)

    {:ok, config} = Fixture.config()
    %{root: root, context: context, config: config, binding: Config.binding(config)}
  end

  defp grant(c, changes \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "binding_generation" => c.binding.generation,
        "domain_id" => "domain-a",
        "generation" => 1,
        "owner" => "owner-a",
        "known_owners" => ["owner-a"],
        "enrolled" => false,
        "host_id" => "host-a",
        "boot_id" => "boot-a",
        "pid" => String.to_integer(System.pid()),
        "birth" => "birth-a"
      },
      changes
    )
  end

  defp response(c, value, mode \\ "normal"),
    do:
      File.write!(
        Path.join(c.root, "response.json"),
        Jason.encode!(%{mode: mode, response: %{"ok" => true, "grant" => value}})
      )

  defp acquire(c) do
    response(c, grant(c))
    {:ok, current} = LabController.acquire(c.binding, "owner-a", @budget, c.context)
    current
  end

  test "constructor performs no I/O and rejects paths or caller-injected authority", c do
    assert :error = LabController.new(directory: "relative", python_executable: "/python")

    assert :error =
             LabController.new(
               directory: "/path",
               python_executable: "/python",
               owner: "injected"
             )

    assert c.context.owner == nil
    refute inspect(c.context) =~ c.context.directory
    refute inspect(c.context) =~ c.context.python_executable
    refute File.exists?(Path.join(c.root, "request.json"))
  end

  test "framed fixed source keeps private directory out of argv and freezes owner continuity",
       c do
    context = acquire(c)
    request = File.read!(Path.join(c.root, "request.json")) |> Jason.decode!()
    assert request["request"]["directory"] == c.context.directory
    assert ["-I", "-S", "-u", "-c", program] = request["argv"]
    refute program =~ c.context.directory
    assert program =~ "controller authority unavailable"
    assert context.known_owners == ["owner-a"] and not context.enrolled
    assert :ok = LabController.check(c.binding, @budget, context)
    response(c, grant(c, %{"enrolled" => true}))
    assert {:ok, activated} = LabController.activate(c.binding, @budget, context)
    assert activated.enrolled
    response(c, grant(c))
    assert {:error, _} = LabController.check(c.binding, @budget, activated)
  end

  test "changed domain, owner corpus, PID and malformed frames cannot authorize", c do
    context = acquire(c)

    for changed <- [
          %{"domain_id" => "other"},
          %{"known_owners" => ["owner-b", "owner-a"]},
          %{"pid" => 1},
          %{"extra" => true}
        ] do
      response(c, grant(c, changed))
      assert {:error, _} = LabController.check(c.binding, @budget, context)
    end

    for mode <- ["partial", "trailing", "oversized", "diagnostic"] do
      response(c, grant(c), mode)
      assert {:error, error} = LabController.check(c.binding, @budget, context)
      refute inspect(error) =~ "private-node-diagnostic"
    end
  end

  test "controller authorization is charged once per operation and failures stay closed", c do
    context = acquire(c)
    config = %{c.config | controller_guard: context}
    {:ok, operation} = Operation.new(config, config.budget, :inspect)
    assert :ok = Controller.authorize(config, operation.budget, operation.bytes)
    spent = {:atomics.get(operation.bytes, 1), :atomics.get(operation.bytes, 2)}
    File.rm!(Path.join(c.root, "response.json"))
    assert :ok = Controller.authorize(config, operation.budget, operation.bytes)
    assert spent == {:atomics.get(operation.bytes, 1), :atomics.get(operation.bytes, 2)}
    {:ok, failed} = Operation.new(config, config.budget, :inspect)
    assert {:error, _} = Controller.authorize(config, failed.budget, failed.bytes)
    response(c, grant(c))
    assert {:error, _} = Controller.authorize(config, failed.budget, failed.bytes)
  end

  test "guard configuration is outside persisted binding identity", c do
    context = acquire(c)

    {:ok, guarded} =
      Config.new(
        c.config
        |> Map.from_struct()
        |> Map.put(:controller_guard, context)
        |> Map.to_list()
      )

    assert Config.binding(guarded) == c.binding
  end
end
