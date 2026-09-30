defmodule SmolBox.VolumeStoreTest do
  use SmolBox.Store.VolumeContract, async: true

  setup do
    %{adapter: SmolBox.Store.Memory, store: start_supervised!(SmolBox.Store.Memory)}
  end
end
