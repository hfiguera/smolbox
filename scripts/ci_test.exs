root = Path.expand("..", __DIR__)
files = Path.wildcard(Path.join(root, "dev/smolbox/ci/**/*.ex"))
{:ok, _, diagnostics} = Kernel.ParallelCompiler.compile(files, return_diagnostics: true)
true = diagnostics.compile_warnings == [] and diagnostics.runtime_warnings == []
ExUnit.start()
root |> Path.join("test/ci/*_test.exs") |> Path.wildcard() |> Enum.each(&Code.require_file/1)
