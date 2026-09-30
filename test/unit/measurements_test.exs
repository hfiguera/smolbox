defmodule SmolBox.MeasurementsTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machine, MachineMeasurements, WorkerCapacity}

  @capacity %{
    "allocated_cpus" => 2,
    "allocated_memory_mb" => 512,
    "used_cpus" => 0.25,
    "used_memory_mb" => 0,
    "used_disk_gb" => 1
  }

  test "missing counters stay unavailable while zero and fractional CPU retain their meaning" do
    wire = machine()
    assert {:ok, first} = MachineMeasurements.from_wire(wire)
    assert first.cpu_millis == nil and first.egress_bytes == nil

    assert {:ok, second} =
             MachineMeasurements.from_wire(
               Map.merge(wire, %{"cpuMillis" => 0, "diskUsedMb" => 12})
             )

    assert second.cpu_millis == 0 and second.disk_used_mb == 12
    assert Machine.same_incarnation?(first.machine, second.machine)
    assert Map.keys(Map.from_struct(first.machine)) == Map.keys(Map.from_struct(second.machine))
    refute Map.has_key?(first.machine, :cpu_millis)
    assert is_integer(second.checked_at_ms)

    assert {:ok, capacity} = WorkerCapacity.from_wire(@capacity)
    assert capacity.used_cpus == 0.25 and capacity.used_memory_mb == 0
    assert capacity.host_memory_available_mb == nil and capacity.used_memory_pss_mb == nil
    assert capacity.boot_id == nil
  end

  test "optional measurements reject malformed values without exposing the response" do
    for value <- [-1, 1.1, "12", true, %{}, 18_446_744_073_709_551_616],
        field <-
          ~w(cpuSeconds cpuMillis rssMb pssMb privateMemoryMb sharedMemoryMappedMb diskUsedMb egressBytes) do
      assert {:error, %{category: :protocol, operation: :machine_measurements} = error} =
               MachineMeasurements.from_wire(Map.put(machine(), field, value))

      refute inspect(error) =~ "fixture"
    end

    assert {:ok, %{cpu_millis: nil}} =
             MachineMeasurements.from_wire(Map.put(machine(), "cpuMillis", nil))

    assert {:ok, %{egress_bytes: 18_446_744_073_709_551_615}} =
             MachineMeasurements.from_wire(
               Map.put(machine(), "egressBytes", 18_446_744_073_709_551_615)
             )

    assert {:error, %{category: :protocol}} = MachineMeasurements.from_wire(nil)
  end

  test "capacity requires its core contract and accepts additive upstream fields" do
    for field <- Map.keys(@capacity) do
      assert {:error, %{category: :protocol}} =
               WorkerCapacity.from_wire(Map.delete(@capacity, field))

      assert {:error, %{category: :protocol}} =
               WorkerCapacity.from_wire(Map.put(@capacity, field, nil))
    end

    for changes <- [
          %{"used_cpus" => -0.1},
          %{"used_cpus" => "0.2"},
          %{"used_memory_mb" => 1.5},
          %{"host_memory_available_mb" => -1},
          %{"boot_id" => String.duplicate("x", 257)},
          %{"boot_id" => <<255>>}
        ] do
      assert {:error, %{category: :protocol}} =
               WorkerCapacity.from_wire(Map.merge(@capacity, changes))
    end

    assert {:ok, %{boot_id: "epoch", used_memory_pss_mb: 0}} =
             WorkerCapacity.from_wire(
               Map.merge(@capacity, %{
                 "boot_id" => "epoch",
                 "used_memory_pss_mb" => 0,
                 "future_field" => %{}
               })
             )

    assert {:error, %{category: :protocol}} = WorkerCapacity.from_wire([])
  end

  defp machine, do: "test/fixtures/wire/created.json" |> File.read!() |> Jason.decode!()
end
