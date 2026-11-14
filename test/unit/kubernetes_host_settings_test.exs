defmodule SmolBox.KubernetesHostSettingsTest do
  use ExUnit.Case, async: false
  alias SmolBox.Kubernetes.{Config, LabNodeEvidence, NodeAuthority}
  alias SmolBox.Test.Kubernetes, as: Fixture
  alias SmolBox.Test.NodeAuthority, as: Authority

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-host-settings-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    key = Path.join(root, "fingerprint-key")
    File.write!(key, :crypto.strong_rand_bytes(32))
    path = Path.join(root, "settings.json")
    original = System.get_env("SMOLBOX_KUBERNETES_ENROLLMENT")
    System.put_env("SMOLBOX_KUBERNETES_ENROLLMENT", path)

    on_exit(fn ->
      if original,
        do: System.put_env("SMOLBOX_KUBERNETES_ENROLLMENT", original),
        else: System.delete_env("SMOLBOX_KUBERNETES_ENROLLMENT")

      File.rm_rf!(root)
    end)

    {:ok, config} = Fixture.config()
    {:ok, authority} = Authority.context()

    fields =
      ~w(id api_server ca_file cluster_id cluster_anchor_uid namespace namespace_uid node_name node_uid node_boot_id runtime_class runtime_class_uid runtime_policy_digest runtime_identity)a

    settings = config |> Map.take(fields) |> Jason.encode!() |> Jason.decode!()

    settings =
      Map.merge(settings, %{
        "image" => hd(config.sources).reference,
        "ssh_host" => "linux",
        "inspector_sha256" => Fixture.digest(),
        "history_sha256" => Fixture.digest(),
        "controller_directory" => Path.join(root, "controller"),
        "python_executable" => "/usr/bin/python3",
        "artifact_root" => root,
        "report_root" => Path.join(root, "reports"),
        "fingerprint_key_file" => key,
        "token_file" => "/missing/token",
        "node_authority" => authority |> Map.from_struct() |> Map.delete(:ssh_executable)
      })

    %{settings: settings, path: path, authority: authority}
  end

  test "default lab and explicit standalone construction preserve binding without connecting",
       c do
    for {selection, provider} <- [
          {nil, LabNodeEvidence},
          {"lab", LabNodeEvidence},
          {"node_authority", NodeAuthority}
        ] do
      settings =
        if selection, do: Map.put(c.settings, "node_provider", selection), else: c.settings

      File.write!(c.path, Jason.encode!(settings))
      {host, _} = Code.eval_file("examples/kubernetes_host/settings.exs")
      {SmolBox.Store.Memory, store} = host.store
      on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
      assert {^provider, node} = host.target.node_evidence
      assert Config.validate(host.target) == :ok

      if provider == NodeAuthority do
        assert node.authority_generation == c.authority.authority_generation
        refute inspect(host.target) =~ c.authority.identity_file
        refute inspect(node) =~ c.authority.known_hosts_file
      end
    end
  end

  test "unknown provider is rejected with no implicit fallback", c do
    File.write!(c.path, Jason.encode!(Map.put(c.settings, "node_provider", "unknown")))

    assert_raise RuntimeError, "unknown node evidence provider", fn ->
      Code.eval_file("examples/kubernetes_host/settings.exs")
    end
  end
end
