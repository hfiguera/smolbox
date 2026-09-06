defmodule SmolBox.MachineTest do
  use ExUnit.Case, async: true

  alias SmolBox.Machine

  defp fixture(name), do: "test/fixtures/wire/#{name}.json" |> File.read!() |> Jason.decode!()

  test "captured lifecycle observations retain weak creation evidence across states" do
    assert {:ok, created} = Machine.from_wire(fixture("created"))
    assert {:ok, running} = Machine.from_wire(fixture("running"))
    assert Machine.same_incarnation?(created, running)
    refute Machine.same_incarnation?(created, %{running | created_at: running.created_at + 1})
    refute Machine.same_incarnation?(created, %{running | memory_mb: 512})
    assert {:ok, stopped} = Machine.from_wire(Map.put(fixture("running"), "state", "stopped"))
    assert stopped.state == :stopped
  end

  test "missing, unsafe and malformed observations fail closed" do
    body = fixture("created")

    for changed <- [
          Map.delete(body, "network"),
          Map.put(body, "network", true),
          Map.put(body, "state", "surprise"),
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
