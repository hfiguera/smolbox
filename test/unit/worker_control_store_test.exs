defmodule SmolBox.WorkerControlStoreTest do
  use SmolBox.Store.WorkerControlContract, async: true

  setup do
    %{adapter: SmolBox.Store.Memory, store: start_supervised!(SmolBox.Store.Memory)}
  end
end
