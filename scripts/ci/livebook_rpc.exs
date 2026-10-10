# Evaluated in a bounded client process, never the user's running Livebook.
workspace = System.fetch_env!("SMOLBOX_LIVEBOOK_WORKSPACE")
{:ok, _} = Node.start(String.to_atom("smolboxlbclient#{System.pid()}@127.0.0.1"), :longnames)
Node.set_cookie(workspace |> Path.join("cookie") |> File.read!() |> String.to_atom())
remote = String.to_atom(System.fetch_env!("SMOLBOX_LIVEBOOK_NODE"))
true = Node.connect(remote)
evaluator = System.fetch_env!("SMOLBOX_LIVEBOOK_EVALUATOR")

case :rpc.call(
       remote,
       Code,
       :eval_string,
       [File.read!(evaluator), [], [file: evaluator]],
       480_000
     ) do
  {%{status: "passed"}, _} -> :ok
  _ -> raise "Livebook evaluation failed; inspect private evaluation evidence"
end
