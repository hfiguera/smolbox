defmodule SmolBox.DurableHost.NodeAuthorityRuntimeTest do
  use SmolBox.Test.NodeAuthorityRuntimeContract, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}

  def contract_store do
    partition = "authority-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    {Store, store}
  end
end
