defmodule SmolBox.KubernetesEnrollmentScriptTest do
  use ExUnit.Case, async: false
  alias SmolBox.Kubernetes.{Config, Enrollment}
  alias SmolBox.Kubernetes.NodeAuthority.JSON
  alias SmolBox.KubernetesPeer
  alias SmolBox.Test.Kubernetes, as: Fixture

  test "manual binding export uses canonical wire types and refuses replacement" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "smolbox-enrollment-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(directory)
    previous = System.get_env("SMOLBOX_NODE_AUTHORITY_QUALIFICATION")
    System.put_env("SMOLBOX_NODE_AUTHORITY_QUALIFICATION", directory)

    on_exit(fn ->
      if previous,
        do: System.put_env("SMOLBOX_NODE_AUTHORITY_QUALIFICATION", previous),
        else: System.delete_env("SMOLBOX_NODE_AUTHORITY_QUALIFICATION")

      File.rm_rf!(directory)
    end)

    {:ok, config} =
      Fixture.config(id: "node-authority-v1", cluster_id: "node-authority-qualification-v1")

    objects = KubernetesPeer.objects(config)
    digest = Enrollment.policy_digest(objects.runtime, objects.policy)
    binding = Config.binding(%{config | runtime_policy_digest: digest})

    metadata = %{
      cluster_anchor: objects.anchor,
      namespace: objects.namespace,
      node: objects.node,
      runtime_class: objects.runtime,
      network_policy: objects.policy,
      node_boot_id: config.node_boot_id,
      runtime_identity: config.runtime_identity
    }

    File.write!(Path.join(directory, "metadata.json"), Jason.encode!(metadata))

    ExUnit.CaptureIO.capture_io(fn ->
      Code.eval_file("scripts/kubernetes/node-authority/enrollment.exs")
    end)

    encoded = File.read!(Path.join(directory, "binding.json"))
    wire = binding |> Map.from_struct() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^wire} = JSON.decode(encoded)
    assert {:ok, ^encoded} = JSON.encode(wire)
    assert wire["kind"] == "kubernetes"
    refute Map.has_key?(wire, "__struct__")

    assert_raise File.Error, fn ->
      Code.eval_file("scripts/kubernetes/node-authority/enrollment.exs")
    end

    assert File.read!(Path.join(directory, "binding.json")) == encoded
  end
end
