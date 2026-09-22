case System.argv() do
  [phase] when phase in ["prepare", "resume"] -> SmolBox.DurableHost.PersistentHTTPDemo.run(phase)
  _invalid -> raise "usage: mix run scripts/persistent_http.exs prepare|resume"
end
