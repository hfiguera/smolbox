defmodule SmolBox.DurableHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :smolbox_durable_host,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: paths(Mix.env()),
      aliases: [
        quality: [
          "compile --warnings-as-errors",
          "credo --strict",
          "ex_dna lib config priv scripts test/support ../support/lib ../support/store --max-clones 0",
          "dialyzer --force-check"
        ]
      ],
      deps: [
        {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
        {:ex_slop, "~> 0.4.4", only: [:dev, :test], runtime: false},
        {:ex_dna, "~> 1.5.4", only: [:dev, :test], runtime: false},
        {:smolbox, path: "../.."},
        {:ecto_sql, "~> 3.14.0"},
        {:postgrex, "~> 0.22.4"},
        {:jason, "~> 1.4"},
        {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
        {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
      ],
      dialyzer: [plt_add_apps: [:ex_unit], plt_local_path: "_build/plts"]
    ]
  end

  def cli, do: [preferred_envs: [quality: :test]]

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {SmolBox.DurableHost.Application, []}]

  defp paths(:test),
    do: [
      "lib",
      Path.expand("../support/store", __DIR__),
      "test/support",
      Path.expand("../../test/support/store", __DIR__),
      Path.expand("../../test/support/fault", __DIR__),
      Path.expand("../../test/support/lab", __DIR__),
      Path.expand("../support/lib", __DIR__)
    ]

  defp paths(_env),
    do: ["lib", Path.expand("../support/lib", __DIR__), Path.expand("../support/store", __DIR__)]
end
