defmodule SmolBox.BranchStoreTest do
  use ExUnit.Case, async: true
  alias SmolBox.Store.{BranchContract, Memory}
  setup do: %{store: start_supervised!(Memory)}

  test "branch admission respects the memory store record bound" do
    store = start_supervised!({Memory, max_records: 1}, id: :bounded)
    source = BranchContract.running(Memory, store)

    assert {:error, %{category: :admission_exhausted}} =
             BranchContract.accept(Memory, store, source)

    assert {:ok, ^source} = Memory.machine(store, :fetch, [{source.scope, source.id}])

    assert {:error, %{category: :not_found}} =
             Memory.machine(store, :fetch, [{source.scope, "child"}])
  end

  for scenario <- [:admission, :cancellation, :unknown, :competition] do
    test("branch contract #{scenario}", %{store: store},
      do: apply(BranchContract, unquote(scenario), [Memory, store])
    )
  end
end
