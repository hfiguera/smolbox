Code.require_file("examples/embedded_port/lib/images_demo.ex")
Code.require_file("examples/embedded_port/lib/images_control.ex")

defmodule SmolBox.EmbeddedImagesExampleTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Config, Launch}
  alias SmolBox.Example.{EmbeddedImages, EmbeddedImagesControl}
  alias SmolBox.Test.EmbeddedPackage

  defp settings do
    source = %{
      "kind" => "oci",
      "id" => "original",
      "architecture" => "x86_64",
      "reference" => "registry.example/team/app@sha256:" <> String.duplicate("a", 64)
    }

    %{
      "source" => source,
      "pull_source" => %{
        source
        | "id" => "pull",
          "reference" => "registry.example/team/other@sha256:" <> String.duplicate("b", 64)
      },
      "network" => %{"hosts" => ["registry.example"], "cidrs" => []},
      "startup_workload" => true
    }
  end

  setup do
    hello =
      File.read!("native/smolbox-protocol/fixtures/hello-v2-linux-images.json") |> Jason.decode!()

    target =
      EmbeddedPackage.create(
        protocol_major: 2,
        platform: :linux,
        sdk_identity: hello["hello"]["sdk"]
      )

    root = Path.expand(".local/images-model-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(target.package_path)
    end)

    %{target: target, root: root}
  end

  test "public OCI fixture uses explicit source/network approvals and no local artifact", %{
    target: target
  } do
    configured = EmbeddedImages.configure(target, settings())
    assert :ok = Config.validate(configured)
    assert configured.artifacts == []
    assert Enum.map(configured.sources, & &1.id) == ~w(original pull)
    assert hd(configured.profiles).guest_paths.workdir_roots == ["/tmp"]
    assert hd(configured.profiles).network.hosts == ["registry.example"]
    assert [_, _] = Launch.helper_config(configured)["approved_oci_sources"]
    assert EmbeddedPackage.received(target) == []
  end

  test "registry fixture keeps host cache approval separate from offline guest capacity", %{
    target: target
  } do
    source =
      Map.merge(settings()["source"], %{
        "kind" => "registry",
        "content_sha256" => String.duplicate("c", 64)
      })

    settings = %{
      "source" => source,
      "cache_policy" => %{
        "max_download_bytes" => 1000,
        "max_cache_bytes" => 2000,
        "max_cache_files" => 2
      }
    }

    configured = EmbeddedImages.configure(target, settings)
    assert hd(configured.profiles).network == :offline
    assert configured.capacity.disk_gb == 2
    assert configured.registry_policy.max_cache_bytes == 2000

    assert [%{"source" => %{"content_sha256" => hash}}] =
             Launch.helper_config(configured)["approved_registry_sources"]

    assert hash == source["content_sha256"]
    assert EmbeddedPackage.received(target) == []
  end

  test "fixture rejects unpinned sources, credentials, missing networking and ambiguous catalogs before dispatch",
       %{target: target} do
    original = settings()

    invalid = [
      put_in(original, ["source", "reference"], "registry.example/team/app:latest"),
      put_in(original, ["source", "password"], "must-not-enter-settings"),
      put_in(original, ["source", "architecture"], "aarch64"),
      Map.put(original, "credentials", "not-supported"),
      Map.delete(original, "network"),
      put_in(original, ["network", "proxy"], "not-supported"),
      put_in(original, ["pull_source", "id"], "original"),
      Map.put(original, "startup_workload", "true")
    ]

    for settings <- invalid do
      result =
        try do
          EmbeddedImages.configure(target, settings)
          :unexpected_success
        rescue
          _ -> :rejected
        end

      assert result == :rejected
    end

    assert EmbeddedPackage.received(target) == []
  end

  test "control consumes exact versions once and rejects broader actions or nonprivate files", %{
    root: root
  } do
    request = %{
      "action" => "stop_machine",
      "id" => "original",
      "version" => 42,
      "request_id" => "once"
    }

    publish(root, request)
    assert {:ok, ^request} = EmbeddedImagesControl.receive_request(root)
    publish(root, request)
    assert :rejected = EmbeddedImagesControl.receive_request(root)

    for value <- [
          Map.delete(request, "version"),
          %{request | "version" => 0},
          %{request | "id" => "sibling"},
          %{request | "action" => "signal"},
          Map.put(request, "pid", 1234),
          %{request | "request_id" => "../escape"}
        ] do
      publish(root, value)
      assert :rejected = EmbeddedImagesControl.receive_request(root)
    end

    publish(root, %{request | "request_id" => "public"}, 0o644)
    assert :rejected = EmbeddedImagesControl.receive_request(root)

    publish(root, %{
      "action" => "resolve_machine",
      "id" => "original",
      "version" => 42,
      "quiesced" => false,
      "request_id" => "unproven"
    })

    assert :rejected = EmbeddedImagesControl.receive_request(root)

    resolution = %{
      "action" => "resolve_machine",
      "id" => "original",
      "version" => 43,
      "quiesced" => true,
      "disposition" => "deleted",
      "request_id" => "explicitabsence"
    }

    publish(root, resolution)
    assert {:ok, ^resolution} = EmbeddedImagesControl.receive_request(root)

    stop = %{
      "action" => "stop_owned_machine",
      "id" => "original",
      "version" => 44,
      "request_id" => "ownedstop"
    }

    publish(root, stop)
    assert {:ok, ^stop} = EmbeddedImagesControl.receive_request(root)
    publish(root, Map.put(stop, "pid", 1234))
    assert :rejected = EmbeddedImagesControl.receive_request(root)
  end

  test "close predicate rejects incomplete records and retained execution uncertainty" do
    refute EmbeddedImages.collected?(
             struct(SmolBox.ManagedMachine,
               scope: "public-images-proof",
               state: :deleted,
               reservation: nil
             )
           )

    refute EmbeddedImages.collected?(
             struct(SmolBox.Execution,
               scope: "public-images-proof",
               state: :completed,
               cleanup: :complete,
               reservation: nil
             )
           )

    refute EmbeddedImages.collected?(%{state: :deleted, reservation: nil})
  end

  test "unassigned accepted machines cannot count as collected even with no reservation", %{
    target: target
  } do
    configured = EmbeddedImages.configure(target, settings())

    {:ok, spec} =
      SmolBox.ManagedMachineSpec.new(
        scope: "public-images-proof",
        id: "original",
        profile: hd(configured.profiles),
        artifact: SmolBox.Source.artifact(hd(configured.sources))
      )

    {:ok, record} = SmolBox.ManagedMachine.new(spec, String.duplicate("a", 64), 1000)
    assert record.worker_id == nil and record.reservation == nil
    refute EmbeddedImages.collected?(record)
    deleted = %{record | state: :deleted, operation: nil, phase: nil}
    assert SmolBox.ManagedMachine.validate(deleted) == :ok
    assert EmbeddedImages.collected?(deleted)
  end

  defp publish(root, value, mode \\ 0o600) do
    path = Path.join(root, "control.json")
    File.write!(path, Jason.encode!(value))
    File.chmod!(path, mode)
  end
end
