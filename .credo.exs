%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "dev/",
          "scripts/",
          "test/",
          "mix.exs",
          "examples/support/store/*.ex",
          "examples/*/mix.exs",
          "examples/*/{lib,config,test,priv,scripts}/**/*.{ex,exs}"
        ],
        excluded: [~r"/fixtures/"]
      },
      plugins: [{ExSlop, []}]
    }
  ]
}
