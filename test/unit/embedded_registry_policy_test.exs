defmodule SmolBox.EmbeddedRegistryPolicyTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{RegistryContract, RegistryPolicy}
  alias SmolBox.Source

  defp policy(options \\ []) do
    RegistryPolicy.new(
      Keyword.merge(
        [max_download_bytes: 1024, max_cache_bytes: 4096, max_cache_files: 2],
        options
      )
    )
  end

  defp source(options \\ []) do
    {:ok, source} =
      Source.registry(
        Keyword.merge(
          [
            id: "approved",
            reference: "registry.example/team/app@sha256:" <> String.duplicate("a", 64),
            content_sha256: String.duplicate("b", 64),
            architecture: "aarch64"
          ],
          options
        )
      )

    source
  end

  test "explicit policy bounds and unknown token fields reject" do
    assert {:ok, policy} = policy()
    assert :ok = RegistryPolicy.validate(policy)

    for options <- [
          [max_download_bytes: 0],
          [max_cache_bytes: 68_719_476_737],
          [max_cache_files: 1025],
          [identity_token: "private"]
        ] do
      assert {:error, _} = policy(options)
    end

    assert RegistryPolicy.catalog?(nil, [source()])
    refute RegistryPolicy.catalog?(policy, [source(credential_ref: "missing")])
  end

  test "token endpoints reject private addresses and malformed authority" do
    refute RegistryPolicy.realm?(<<255>>)
    refute RegistryPolicy.realm?("https://auth.example:0/token")
    refute RegistryPolicy.realm?("https://auth.example:65536/token")

    for realm <- [
          "http://auth.example/token",
          "https://user:secret@auth.example/token",
          "https://auth.example/token?query=1",
          "https://auth.example/token#fragment",
          "https://localhost/token",
          "https://127.0.0.1/token",
          "https://10.0.0.1/token",
          "https://169.254.169.254/token",
          "https://[::1]/token",
          "https://[fc00::1]/token",
          "https://[::ffff:127.0.0.1]/token"
        ] do
      refute RegistryPolicy.realm?(realm), realm
    end

    assert RegistryPolicy.realm?("https://auth.example/exchange")
  end

  test "source approval translation carries policy and credential references without tokens" do
    {:ok, policy} = policy(token_realms: %{"tenant-read" => "https://auth.example/exchange"})
    source = source(credential_ref: "tenant-read")
    config = %{sources: [source], registry_policy: policy}
    assert RegistryPolicy.catalog?(policy, config.sources)
    assert [approval] = RegistryContract.approvals(config)
    assert approval["source"] == RegistryContract.source(source)
    assert approval["max_bytes"] == 1024
    assert approval["cache_policy"] == %{"max_bytes" => 4096, "max_files" => 2}
    assert approval["credential_ref"] == "tenant-read"
    assert approval["token_realm"] == "https://auth.example/exchange"
    refute inspect(policy) =~ "auth.example"
    refute Map.has_key?(approval, "identity_token")
    private = %{source | reference: "127.0.0.1/team/app@sha256:" <> source.sha256}
    refute RegistryPolicy.catalog?(policy, [private])
    assert RegistryPolicy.catalog?(policy, [%{private | credential_ref: nil}])
  end

  test "transport aliases deduplicate only with matching credential reference" do
    {:ok, policy} =
      policy(
        token_realms: %{
          "tenant-read" => "https://auth.example/exchange",
          "tenant-other" => "https://auth.example/exchange"
        }
      )

    one = source(credential_ref: "tenant-read")
    alias_source = %{one | id: "alias"}
    other = %{one | id: "other", credential_ref: "tenant-other"}

    assert [first, second] =
             RegistryContract.approvals(%{
               sources: [one, alias_source, other],
               registry_policy: policy
             })

    assert first["source"] == second["source"]
    assert first["credential_ref"] != second["credential_ref"]
  end
end
