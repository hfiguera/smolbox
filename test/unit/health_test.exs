defmodule SmolBox.HealthTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Error, Health}

  test "version is bounded and omitted inventory is represented as unavailable" do
    wire = %{"status" => "ok", "version" => "1.14.1"}
    assert {:ok, %{total: nil, running: nil, uptime_seconds: nil}} = Health.from_wire(wire)

    for changes <- [
          %{"status" => "failed"},
          %{"version" => nil},
          %{"version" => String.duplicate("1", 65)},
          %{"version" => "invalid"},
          %{"machines" => []},
          %{"machines" => %{"total" => 0, "running" => 1}},
          %{"machines" => %{"total" => -1, "running" => 0}},
          %{"uptime_seconds" => 1.5}
        ] do
      assert {:error, %Error{category: :protocol}} = Health.from_wire(Map.merge(wire, changes))
    end

    assert {:error, %Error{category: :protocol}} = Health.from_wire(nil)
  end
end
