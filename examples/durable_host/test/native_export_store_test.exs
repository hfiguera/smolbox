defmodule SmolBox.DurableHost.NativeExportStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Store.NativeExportContract

  test "PostgreSQL atomically retains unknown exports and releases only matching cleanup" do
    partition =
      "native-export-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    NativeExportContract.lifecycle(Store, store)
  end
end
