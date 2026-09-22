case System.argv() do
  [phase] when phase in ["prepare", "resume"] -> SmolBox.DurableHost.PersistentDemo.run(phase)
  _invalid -> raise "usage: mix run scripts/persistent_machine.exs prepare|resume"
end
