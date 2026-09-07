defmodule SmolBox.MixProject do
  use Mix.Project

  def project do
    [
      app: :smolbox,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "An Elixir client and supervised execution runtime for self-hosted SmolVM workers",
      package: [
        licenses: ["MIT"],
        links: %{"SmolVM upstream" => "https://github.com/smol-machines/smolvm"},
        files: [
          "lib",
          "mix.exs",
          "README.md",
          "CHANGELOG.md",
          "LICENSE",
          "docs/client.md",
          "docs/host-integration.md",
          "docs/recovery.md",
          "docs/compatibility.md",
          "docs/evidence/*.json"
        ]
      ],
      docs: [
        extras: [
          "README.md",
          "docs/client.md",
          "docs/host-integration.md",
          "docs/recovery.md",
          "docs/compatibility.md"
        ]
      ],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :credence, :dialyxir],
        plt_local_path: "_build/plts"
      ],
      # Canaries exercise developer tasks. Peer fixtures and shared adapter tests
      # are not production library code and must not inflate its coverage floor.
      test_coverage: [
        ignore_modules: [
          ~r/^Mix.Tasks.Smolbox.Ci\./,
          SmolBox.TestPeer,
          SmolBox.TestArtifacts,
          SmolBox.ManagedPeer,
          SmolBox.TestTLS,
          SmolBox.Store.Contract
        ],
        summary: [threshold: 90]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  def cli do
    [preferred_envs: [ci: :test, "smolbox.ci.credence": :test, "smolbox.ci.verify_checks": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:nimble_options, "~> 1.1"},
      {:stream_data, "~> 1.2", only: :test},
      {:plug, "~> 1.18", only: :test},
      {:bandit, "~> 1.8", only: :test},
      {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5.4", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.4", only: [:dev, :test], runtime: false},
      {:credence, "~> 0.8.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "compile --warnings-as-errors",
        "test --warnings-as-errors",
        "credo --strict",
        "ex_dna lib dev test/support examples/durable_host/lib examples/durable_host/priv --max-clones 0",
        "smolbox.ci.credence",
        "dialyzer"
      ]
    ]
  end
end
