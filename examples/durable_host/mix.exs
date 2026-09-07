defmodule SmolBox.DurableHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :smolbox_durable_host,
      version: "0.1.0-rc.2",
      elixir: "~> 1.18",
      elixirc_paths: paths(Mix.env()),
      deps: [
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

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {SmolBox.DurableHost.Application, []}]

  defp paths(:test),
    do: [
      "lib",
      "test/support",
      Path.expand("../../test/support/store", __DIR__),
      Path.expand("../../test/support/fault", __DIR__),
      Path.expand("../support/lib", __DIR__)
    ]

  defp paths(_env), do: ["lib", Path.expand("../support/lib", __DIR__)]
end
