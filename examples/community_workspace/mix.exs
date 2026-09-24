defmodule Workspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :community_workspace,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      aliases: ["assets.build": ["cmd --cd assets npm run build"]],
      deps: [
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

  def application do
    [extra_applications: [:logger, :crypto], mod: {Workspace.Application, []}]
  end

  defp elixirc_paths(env) do
    ["lib", Path.expand("../support/store", __DIR__)] ++
      if(env == :test, do: ["test/support"], else: [])
  end
end
