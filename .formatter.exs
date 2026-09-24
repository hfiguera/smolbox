[
  inputs: [
    "mix.exs",
    ".*.exs",
    "{lib,dev,test}/**/*.{ex,exs}",
    "scripts/**/*.exs",
    "examples/support/store/*.ex",
    "examples/*/mix.exs",
    "examples/*/.formatter.exs",
    "examples/*/{lib,config,test,priv,scripts}/**/*.{ex,exs}"
  ],
  excludes: [
    "test/fixtures/**/*.{ex,exs}",
    # The example CI formats HEEx with its Phoenix formatter dependency.
    "examples/community_workspace/lib/workspace_web/workspace_live.ex"
  ]
]
