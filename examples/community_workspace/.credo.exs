%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "config/",
          "test/",
          "priv/",
          "scripts/",
          "mix.exs",
          "../support/store/*.ex"
        ],
        excluded: [~r"/fixtures/"]
      },
      plugins: [{ExSlop, []}]
    }
  ]
}
