defmodule SmolBox.BackendParityCoverageTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend
  alias SmolBox.Backend.{Embedded, HTTP}

  @root Path.expand("../..", __DIR__)
  @manifest Path.join(@root, "docs/design/embedded-port-http-parity-coverage.json")
  @external_resource @manifest
  @coverage Jason.decode!(File.read!(@manifest))

  test "parity inventory covers the actual operation signatures exactly once" do
    expected = Backend.operations()
    names = Map.new(expected, fn {name, _arity} -> {Atom.to_string(name), name} end)

    signatures =
      for operation <- @coverage["operations"], arity <- operation["arities"] do
        {Map.fetch!(names, operation["name"]), arity}
      end

    assert length(signatures) == MapSet.size(MapSet.new(signatures))
    assert MapSet.new(signatures) == MapSet.new(expected)

    for operation <- @coverage["operations"] do
      name = Map.fetch!(names, operation["name"])
      assert HTTP.supports_operation?(nil, name) == operation["http_supported"]

      assert Embedded.supports_operation?(nil, name) == operation["port_operation_supported"],
             "Update parity coverage and acceptance evidence when enabling #{name}"
    end
  end

  test "every operation has a feature contract and explicit acceptance requirements" do
    contracts = Map.new(@coverage["contracts"], &{&1["id"], &1})
    assert map_size(contracts) == length(@coverage["contracts"])

    for operation <- @coverage["operations"] do
      assert Map.has_key?(contracts, operation["contract"])
      assert operation["arities"] != []
      assert Enum.all?(operation["arities"], &(is_integer(&1) and &1 > 0))
      assert Enum.count_until(operation["acceptance"], 3) == 3
      assert operation["parity_status"] in ["pending", "qualified"]
    end

    for contract <- Map.values(contracts) do
      assert contract["phase"] in Enum.map(0..9, &"P#{&1}")
      assert contract["platforms"] != [] and contract["sources"] != []
      assert contract["restrictions"] != []
      assert File.regular?(Path.join(@root, contract["guide"]))
    end
  end

  test "specification coverage includes features that have no separate backend operation" do
    ids = Enum.map(@coverage["specifications"], & &1["id"])

    assert MapSet.new(ids) ==
             MapSet.new(~w(networking ports workloads guest-paths credentials checkpoint-restore
                           mounts draining-and-upgrade))

    assert length(ids) == MapSet.size(MapSet.new(ids))

    for spec <- @coverage["specifications"] do
      assert File.regular?(Path.join(@root, spec["guide"]))
      assert is_binary(spec["contract"]) and spec["contract"] != ""
      assert Enum.count_until(spec["acceptance"], 3) == 3
      assert spec["parity_status"] in ["pending", "qualified"]
    end
  end

  test "coverage cannot declare completion while requirements or evidence remain pending" do
    all_qualified =
      Enum.all?(@coverage["operations"], &(&1["parity_status"] == "qualified")) and
        Enum.all?(@coverage["contracts"], fn contract ->
          contract["acceptance_status"] == "qualified" and contract["evidence"] != []
        end) and
        Enum.all?(@coverage["specifications"], fn spec ->
          spec["parity_status"] == "qualified" and spec["evidence"] != []
        end)

    assert @coverage["parity_complete"] == all_qualified
    assert @coverage["crash_validation_deferred"]
    refute @coverage["crash_handling_qualified"]
    refute @coverage["distribution_approved"]

    source = @root |> Path.join("native/vendor/source.json") |> File.read!() |> Jason.decode!()
    assert @coverage["sdk_revision"] == source["revision"]
    assert source["patches"] == []
  end
end
