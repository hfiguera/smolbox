defmodule SmolBox.DurableHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :smolbox_durable_host,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      elixirc_paths: paths(Mix.env()),
      deps: [
        {:smolbox, path: "../.."},
        {:ecto_sql, "~> 3.14.0"},
        {:postgrex, "~> 0.22.4"},
        {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
        {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
      ],
      dialyzer: [plt_add_apps: [:ex_unit], plt_local_path: "_build/plts"]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {SmolBox.DurableHost.Application, []}]

  defp paths(:test), do: ["lib", Path.expand("../../test/support/store", __DIR__)]
  defp paths(_env), do: ["lib"]
end
