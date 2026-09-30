defmodule SmolBox.ExpansionStoreTest do
  use SmolBox.Store.ExpansionContract, async: true

  setup do
    %{adapter: SmolBox.Store.Memory, store: start_supervised!(SmolBox.Store.Memory)}
  end
end
