defmodule SmolBox.KubernetesNodeAuthorityContractTest do
  use ExUnit.Case, async: true
  alias SmolBox.Kubernetes.{CleanupProof, Config, Identity, Receipt}
  alias SmolBox.Store.Codec
  alias SmolBox.Test.Kubernetes, as: Fixture
  @vectors "test/fixtures/kubernetes/node-authority-v1/vectors.json"

  test "canonical authority vectors agree with the node's JSON contract" do
    vectors = @vectors |> File.read!() |> Jason.decode!()

    for name <- ~w(configuration protocol) do
      assert File.read!("priv/kubernetes/node_authority/#{name}-v1.schema.json") ==
               File.read!("test/fixtures/kubernetes/node-authority-v1/#{name}.schema.json")
    end

    for {field, encoded, digest} <- [
          {"identity_fields", "identity_canonical", vectors["authority_generation"]},
          {"configuration", "configuration_canonical",
           vectors["identity_fields"]["configuration_sha256"]},
          {"receipt", "receipt_canonical", vectors["receipt_sha256"]}
        ] do
      bytes = canonical(vectors[field])
      assert bytes == vectors[encoded]
      assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == digest
    end

    {:ok, config} = Fixture.config()
    assert Config.binding(config).generation == vectors["identity_fields"]["binding_generation"]
    refute vectors["authority_generation"] == vectors["identity_fields"]["history_epoch"]
  end

  test "v54 and typed receipt comparisons preserve standalone epochs without adopting lab receipts" do
    vectors = @vectors |> File.read!() |> Jason.decode!()
    {:ok, config} = Fixture.config()
    {record, assignment} = Fixture.ready_record(config)
    lab = record.backend_receipt
    observation = %{lab.observation | observer_epoch: vectors["authority_generation"]}

    assert {:error, _} = Receipt.ready(lab, lab.container_id, lab.image_id, observation)
    assert {:ok, created} = Receipt.created(assignment, lab.pod_uid)
    assert {:ok, ready} = Receipt.ready(created, lab.container_id, lab.image_id, observation)
    proof = Fixture.cleanup_proof(ready)
    assert CleanupProof.releasable?(proof, ready)
    refute CleanupProof.releasable?(proof, lab)
    refute CleanupProof.releasable?(Fixture.cleanup_proof(lab), ready)

    record = %{
      record
      | backend_receipt: ready,
        created_machine: %{record.created_machine | backend_identity: %Identity{receipt: ready}}
    }

    assert {:ok, <<"smolbox-record-v54", 0, _::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)
    assert record.backend_receipt.observation.version == 1
    assert record.backend_receipt.version == 1 and ready.binding.version == 1
    assert proof.version == 3

    path =
      Path.join(
        System.tmp_dir!(),
        "node-authority-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.write!(path, bytes)
    on_exit(fn -> File.rm!(path) end)
    sdk = :code.lib_dir(:smolbox) |> List.to_string() |> Path.join("ebin")
    json = :code.lib_dir(:jason) |> List.to_string() |> Path.join("ebin")

    code = """
    Enum.each(~w(authority_generation history_epoch verifier_manifest_sha256), &String.to_atom/1)
    {:ok, _} = Application.ensure_all_started(:crypto)
    {:ok, record} = SmolBox.Store.Codec.decode(File.read!(hd(System.argv())))
    64 = byte_size(record.backend_receipt.observation.observer_epoch)
    {:ok, bytes} = SmolBox.Store.Codec.encode(record)
    {:ok, ^record} = SmolBox.Store.Codec.decode(bytes)
    IO.puts("standalone epoch survived cold decode")
    """

    assert {"standalone epoch survived cold decode\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               ["--erl", "+S 2:2", "-pa", sdk, "-pa", json, "-e", code, "--", path],
               stderr_to_stdout: true
             )
  end

  defp canonical(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, item} -> Jason.encode!(key) <> ":" <> canonical(item) end)

    "{" <> entries <> "}"
  end

  defp canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  defp canonical(value), do: Jason.encode!(value)
end
