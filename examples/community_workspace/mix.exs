defmodule Workspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :community_workspace,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      aliases: [
        "assets.build": ["cmd --cd assets npm run build"],
        quality: [
          "compile --warnings-as-errors",
          "credo --strict",
          "ex_dna lib config priv test/support ../support/store --max-clones 0",
          "dialyzer --force-check"
        ]
      ],
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_local_path: "_build/plts"],
      deps: [
        {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
        {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
        {:ex_slop, "~> 0.4.5", only: [:dev, :test], runtime: false},
        {:ex_dna, "~> 1.5.4", only: [:dev, :test], runtime: false},
        {:smolbox, "~> 0.2.0"},
        {:phoenix, "~> 1.8.0"},
        {:phoenix_live_view, "~> 1.1.0"},
        {:phoenix_html, "~> 4.3"},
        {:bandit, "~> 1.8"},
        {:ecto_sql, "~> 3.14.0"},
        {:postgrex, "~> 0.22.4"},
        {:jason, "~> 1.4"},
        {:lazy_html, ">= 0.1.0", only: :test}
      ]
    ]
  end

  def cli, do: [preferred_envs: [quality: :test]]

  def application do
    [extra_applications: [:logger, :crypto], mod: {Workspace.Application, []}]
  end

  defp elixirc_paths(env) do
    ["lib", Path.expand("../support/store", __DIR__)] ++
      if(env == :test, do: ["test/support"], else: [])
  end
end
