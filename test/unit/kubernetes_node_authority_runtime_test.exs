defmodule SmolBox.KubernetesNodeAuthorityRuntimeTest do
  use SmolBox.Test.NodeAuthorityRuntimeContract, async: false

  def contract_store, do: {SmolBox.Store.Memory, start_supervised!({SmolBox.Store.Memory, []})}
end
