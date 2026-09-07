[
  inputs: [
    "mix.exs",
    ".*.exs",
    "{lib,dev,test}/**/*.{ex,exs}",
    "examples/*/mix.exs",
    "examples/*/.formatter.exs",
    "examples/*/{lib,config,test,priv,scripts}/**/*.{ex,exs}"
  ],
  excludes: ["test/fixtures/**/*.{ex,exs}"]
]
