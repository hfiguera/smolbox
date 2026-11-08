defmodule SmolBox.Embedded.GrowthTransitionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.GrowthTransition

  defp transitions do
    "../../native/smolbox-protocol/fixtures/growth-transitions-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn wire ->
      assert {:ok, transition} = GrowthTransition.from_wire(wire)
      transition
    end)
  end

  test "Rust fixture binds root, previous proof, exact request and unchanged creation authority" do
    [first, second] = transitions()
    assert first.receipt == second.previous
    assert GrowthTransition.root?(first.previous)

    assert GrowthTransition.bound?(
             first,
             first.previous,
             "grow.1",
             first.change["request"],
             %{"storage_gib" => 1, "overlay_gib" => 1},
             %{"storage_gib" => 2, "overlay_gib" => 1}
           )

    assert {:ok, receipt, %{"storage_gib" => 2, "overlay_gib" => 3}} =
             GrowthTransition.chain([first, second], first.previous, %{
               "storage_gib" => 1,
               "overlay_gib" => 1
             })

    assert receipt == second.receipt

    refute GrowthTransition.bound?(
             first,
             second.previous,
             "grow.1",
             first.change["request"],
             %{"storage_gib" => 1, "overlay_gib" => 1},
             %{"storage_gib" => 2, "overlay_gib" => 1}
           )

    refute GrowthTransition.bound?(
             first,
             first.previous,
             "foreign",
             first.change["request"],
             %{"storage_gib" => 1, "overlay_gib" => 1},
             %{"storage_gib" => 2, "overlay_gib" => 1}
           )
  end

  test "changed fields cannot borrow a valid chain digest or conflate null with unchanged targets" do
    [first, _] = transitions()

    for path <- [
          [:change, "operation_id"],
          [:change, "immutable_sha256"],
          [:change, "previous", "record_sha256"],
          [:previous, "incarnation"],
          [:receipt, "material", "record_sha256"],
          [:receipt, "material", "chain_sha256"]
        ] do
      refute first
             |> put_in(Enum.map(path, &Access.key/1), String.duplicate("9", 64))
             |> GrowthTransition.valid?()
    end

    refute GrowthTransition.valid?(put_in(first.change["request"]["overlay_gib"], 1))
    refute GrowthTransition.valid?(put_in(first.change["previous_storage_gib"], 3))
    refute GrowthTransition.valid?(put_in(first.receipt["material"]["revision"], 1025))
    refute GrowthTransition.valid?(%{first | schema: 2})

    refute GrowthTransition.root?(
             put_in(first.previous["material"]["chain_sha256"], String.duplicate("9", 64))
           )
  end

  test "history rejects reorder, gaps, duplicate links and bounds without creating authority" do
    [first, second] = transitions()
    sizes = %{"storage_gib" => 1, "overlay_gib" => 1}

    for history <- [
          [second],
          [second, first],
          [first, first],
          [first, second, second],
          List.duplicate(first, 33),
          [%{first | receipt: first.previous}]
        ] do
      assert :error = GrowthTransition.chain(history, first.previous, sizes)
    end

    assert :error = GrowthTransition.chain([], second.previous, sizes)

    assert :error =
             GrowthTransition.chain([first], first.previous, %{
               "storage_gib" => 2,
               "overlay_gib" => 1
             })

    assert {:ok, origin, ^sizes} = GrowthTransition.chain([], first.previous, sizes)
    assert origin == first.previous
  end

  test "individually valid links cannot introduce a different immutable SDK configuration" do
    [first, _] = transitions()

    wire =
      "../../native/smolbox-protocol/fixtures/growth-transition-other-config-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, changed} = GrowthTransition.from_wire(wire)
    assert changed.previous == first.receipt

    assert :error =
             GrowthTransition.chain([first, changed], first.previous, %{
               "storage_gib" => 1,
               "overlay_gib" => 1
             })
  end

  test "strict bounded shapes reject malformed payloads and inspect keeps private evidence hidden" do
    [first, _] = transitions()
    wire = first |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    for invalid <- [
          nil,
          [],
          Map.put(wire, "extra", 1),
          Map.delete(wire, "previous"),
          put_in(wire["change"]["request"]["overlay_gib"], 65),
          put_in(wire["change"]["request"], %{"storage_gib" => 2}),
          put_in(wire["change"]["request"], %{"storage_gib" => nil, "overlay_gib" => nil})
        ] do
      assert :error = GrowthTransition.from_wire(invalid)
    end

    refute inspect(first) =~ first.previous["owner_token"]
    refute inspect(first) =~ first.change["operation_id"]
    refute inspect(first) =~ first.receipt["material"]["chain_sha256"]
  end
end
