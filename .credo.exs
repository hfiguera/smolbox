%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "dev/",
          "test/",
          "mix.exs",
          "examples/*/mix.exs",
          "examples/*/{lib,config,test,priv,scripts}/**/*.{ex,exs}"
        ],
        excluded: [~r"/fixtures/"]
      },
      plugins: [{ExSlop, []}]
    }
  ]
}
