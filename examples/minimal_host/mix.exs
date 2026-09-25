defmodule SmolBox.MinimalHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :smolbox_minimal_host,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: ["lib", Path.expand("../support/lib", __DIR__)],
      aliases: [
        quality: [
          "compile --warnings-as-errors",
          "credo --strict",
          "ex_dna lib scripts ../support/lib --max-clones 0",
          "dialyzer --force-check"
        ]
      ],
      deps: [
        {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
        {:ex_slop, "~> 0.4.5", only: [:dev, :test], runtime: false},
        {:ex_dna, "~> 1.5.4", only: [:dev, :test], runtime: false},
        {:smolbox, path: "../.."},
        {:jason, "~> 1.4"},
        {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
        {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
      ],
      dialyzer: [plt_local_path: "_build/plts"]
    ]
  end

  def cli, do: [preferred_envs: [quality: :test]]

  def application, do: [extra_applications: [:logger, :crypto]]
end
