alias SmolBox.DurableHost.{Repo, Store}
alias SmolBox.Store.Contract

{:ok, _apps} = Application.ensure_all_started(:ex_unit)

ExUnit.CaptureLog.capture_log(fn ->
  {:ok, _apps} = Application.ensure_all_started(:smolbox_durable_host)
  {:ok, store} = Store.new(Repo, "unavailable-probe", :crypto.strong_rand_bytes(32))

  for result <- [
        Store.capabilities(store),
        Store.fetch(store, {"contract", "one"}),
        Store.accept(store, Contract.record(), 1)
      ] do
    {:error, %SmolBox.Error{category: :store}} = result
  end
end)

IO.puts("database-unavailable-confirmed")
