defmodule SmolBox.MinimalHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :smolbox_minimal_host,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      elixirc_paths: ["lib", Path.expand("../support/lib", __DIR__)],
      deps: [
        {:smolbox, path: "../.."},
        {:jason, "~> 1.4"},
        {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
        {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
      ],
      dialyzer: [plt_local_path: "_build/plts"]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
