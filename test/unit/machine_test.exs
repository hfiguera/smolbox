defmodule SmolBox.MachineTest do
  use ExUnit.Case, async: true

  alias SmolBox.Machine

  defp fixture(name), do: "test/fixtures/wire/#{name}.json" |> File.read!() |> Jason.decode!()

  test "unsupported network policies have a specific reason without remote fields" do
    body = fixture("1.22.0/created")

    for network <- [
          %{"network" => true},
          %{
            "network" => true,
            "networkBackend" => "virtio-net",
            "allowedHosts" => [],
            "allowedCidrs" => []
          },
          %{
            "network" => true,
            "networkBackend" => "tsi",
            "allowedHosts" => ["api.example.com"],
            "allowedCidrs" => []
          },
          %{"network" => false, "allowedHosts" => ["api.example.com"]}
        ] do
      assert {:error,
              %SmolBox.Error{
                category: :unsupported_network_policy,
                operation: :machine,
                evidence: :not_dispatched
              }} = Machine.from_wire(Map.merge(body, network))
    end

    assert {:ok, %{network: :offline}} = Machine.from_wire(body)

    assert {:ok, %{network: %SmolBox.NetworkPolicy{hosts: ["api.example.com"]}}} =
             Machine.from_wire(
               Map.merge(body, %{
                 "network" => true,
                 "networkBackend" => "virtio-net",
                 "allowedHosts" => ["api.example.com"],
                 "allowedCidrs" => []
               })
             )
  end

  test "captured lifecycle observations retain weak creation evidence across states" do
    for prefix <- ["", "1.14.6/", "1.16.0/", "1.16.1/", "1.17.0/", "1.19.0/", "1.20.2/"] do
      assert {:ok, created} = Machine.from_wire(fixture(prefix <> "created"))
      assert {:ok, running} = Machine.from_wire(fixture(prefix <> "running"))
      assert Machine.same_incarnation?(created, running)
      refute Machine.same_incarnation?(created, %{running | created_at: running.created_at + 1})
      refute Machine.same_incarnation?(created, %{running | memory_mb: 512})

      assert {:ok, stopped} =
               Machine.from_wire(Map.put(fixture(prefix <> "running"), "state", "stopped"))

      assert stopped.state == :stopped
    end
  end

  test "missing, unsafe and malformed observations fail closed" do
    body = fixture("created")

    for changed <- [
          Map.delete(body, "network"),
          Map.put(body, "network", true),
          Map.put(body, "state", "surprise"),
          Map.put(body, "state", "paused"),
          Map.put(body, "state", "pausing"),
          Map.put(body, "createdAt", "yesterday"),
          Map.put(body, "mounts", ["/"]),
          Map.put(body, "cpus", 0),
          %{},
          nil
        ] do
      assert {:error, _} = Machine.from_wire(changed)
    end
  end
end
