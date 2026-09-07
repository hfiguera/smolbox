alias SmolBox.DurableHost.{Repo, Store}

[partition, key_file] = System.argv()
{:ok, store} = Store.new(Repo, partition, File.read!(key_file))
{:ok, record} = Store.fetch(store, {"contract", "one"})
:accepted = record.state
true = record.deadlines.queue == 61_000
{:ok, [due], nil} = Store.due(store, 1000, nil, 10)
true = due.id == record.id and due.version == record.version
IO.puts("durable-read-ok")
