root = Path.expand("..", __DIR__)
files = Path.wildcard(Path.join(root, "dev/smolbox/ci/**/*.ex"))
{:ok, _, diagnostics} = Kernel.ParallelCompiler.compile(files, return_diagnostics: true)
true = diagnostics.compile_warnings == [] and diagnostics.runtime_warnings == []
SmolBox.CI.CLI.run(System.argv())
