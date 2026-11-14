defmodule SmolBox.KubernetesStoreTest do
  use SmolBox.Store.KubernetesContract, async: true

  setup do
    %{adapter: SmolBox.Store.Memory, store: start_supervised!(SmolBox.Store.Memory)}
  end
end
