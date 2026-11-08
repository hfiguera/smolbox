Code.require_file(Path.expand("../lib/demo.ex", __DIR__))
{target, _bindings} = Code.eval_file(Path.expand("../config.example.exs", __DIR__))
root = System.fetch_env!("SMOLBOX_EMBEDDED_RUN_DIRECTORY")

terminal =
  case System.get_env("SMOLBOX_EMBEDDED_TERMINAL", "false") do
    "true" -> true
    "false" -> false
    _ -> raise "SMOLBOX_EMBEDDED_TERMINAL must be true or false"
  end

evidence = SmolBox.Example.EmbeddedPort.run(target, root, terminal: terminal)
IO.puts(Jason.encode!(evidence))
