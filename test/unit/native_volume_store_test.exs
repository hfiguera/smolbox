defmodule SmolBox.NativeVolumeStoreTest do
  use SmolBox.Store.NativeVolumeContract, async: true

  setup do
    %{adapter: SmolBox.Store.Memory, store: start_supervised!(SmolBox.Store.Memory)}
  end
end
