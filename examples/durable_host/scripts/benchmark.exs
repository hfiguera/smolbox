[settings_file] = System.argv()
settings_file |> File.read!() |> Jason.decode!() |> SmolBox.DurableHost.Benchmark.run()
IO.puts("Durable benchmark passed; inspect the private JSON report.")
