defmodule SmolBox.Test.NodeAuthority do
  @moduledoc false
  alias SmolBox.Kubernetes.{Config, NodeAuthority, Receipt}
  alias SmolBox.Kubernetes.NodeEvidence.Projection
  alias SmolBox.Test.Kubernetes, as: Fixture

  def vectors,
    do:
      "test/fixtures/kubernetes/node-authority-v1/vectors.json" |> File.read!() |> Jason.decode!()

  def context(overrides \\ []) do
    values = vectors()

    NodeAuthority.new(
      Keyword.merge(
        [
          ssh_host: "127.0.0.1",
          ssh_port: 2222,
          ssh_user: "smolbox-evidence",
          identity_file: "/missing/authority-key",
          known_hosts_file: "/missing/authority-known-hosts",
          authority_generation: values["authority_generation"],
          verifier_manifest_sha256: values["identity_fields"]["verifier_manifest_sha256"]
        ],
        overrides
      )
    )
  end

  def receipt(now \\ 1000) do
    value = vectors()["receipt"]
    {:ok, config} = Fixture.config()
    {:ok, observation} = Projection.observation(value["observation"])

    fields =
      Map.new(Map.from_struct(Receipt.__struct__()), fn {key, _} ->
        {key, value[Atom.to_string(key)]}
      end)

    struct!(
      Receipt,
      Map.merge(fields, %{
        binding: Config.binding(config),
        phase: :ready,
        observation: %{observation | observed_at_ms: now}
      })
    )
  end
end
