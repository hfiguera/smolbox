defmodule SmolBox.CI.PackageTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{NativeConsumer, Package, Util}

  test "retained native owners keep their source after failure and repeated cleanup" do
    root = Util.temporary("retained-consumer-model")
    consumer = Path.join(root, "consumer")
    File.mkdir!(consumer)
    source = Path.join(consumer, "native-proof.exs")
    File.write!(source, "original frozen proof")
    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = NativeConsumer.retain_source(consumer, %{retained: true, running: true})
    assert :retained = Package.cleanup_source(root)
    assert File.read!(source) == "original frozen proof"

    # The on-disk guard also survives the original caller, without granting any
    # process signalling, SDK deletion or ownership authority to another caller.
    Process.delete({NativeConsumer, :retained_source, consumer})
    assert :retained = Package.cleanup_source(root)
    marker = Path.join(consumer, ".native-consumer-retained.json")
    assert Bitwise.band(File.stat!(marker).mode, 0o777) == 0o600
    assert JSON.decode!(File.read!(marker))["cleanup_authority"] == false
    assert File.read!(source) == "original frozen proof"
  end

  test "retained source guard remains effective when diagnostic writing fails" do
    root = Util.temporary("retained-consumer-io-model")
    consumer = Path.join(root, "consumer")
    source = Path.join(root, "original.ex")
    File.write!(source, "preserve even when the marker cannot be written")
    on_exit(fn -> File.rm_rf!(root) end)

    assert :diagnostic_unavailable =
             NativeConsumer.retain_source(consumer, %{retained: true, running: true})

    assert :retained = Package.cleanup_source(root)
    assert File.exists?(source)
  end

  test "ordinary completed consumers still clean their temporary source" do
    root = Util.temporary("completed-consumer-model")
    consumer = Path.join(root, "consumer")
    File.mkdir!(consumer)
    on_exit(fn -> File.rm_rf!(root) end)
    assert :ok = NativeConsumer.retain_source(consumer, %{retained: false, running: false})
    Package.cleanup_source(root)
    refute File.exists?(root)
  end

  test "native lifecycle modes require a package and cannot be combined" do
    assert_raise ArgumentError, ~r/native-terminal requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_terminal: true)
    end

    assert_raise ArgumentError, ~r/native-terminal requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_terminal: true, native_ordinary: true)
    end

    for mode <- [:native_public, :native_ordinary] do
      assert_raise ArgumentError, ~r/native lifecycle modes require/, fn ->
        NativeConsumer.validate_options!([{mode, true}])
      end
    end

    assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
      NativeConsumer.validate_options!(
        native_public: true,
        native_ordinary: true,
        native_package: "/approved/package"
      )
    end
  end

  test "native consumers cannot implicitly select deferred interruption validation" do
    for options <- [[native_package: "/approved/package"], [native_fixture: "/approved/fixture"]] do
      assert_raise ArgumentError, ~r/requires explicit.*crash validation is deferred/, fn ->
        NativeConsumer.validate_options!(options)
      end
    end

    NativeConsumer.validate_options!([])
  end

  test "checkpoint consumers require explicit public mode and a separate ordinary campaign" do
    assert_raise ArgumentError, ~r/native-checkpoints requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_checkpoints: true)
    end

    for other <-
          ~w(native_branches native_images native_growth native_volume native_terminal native_network native_workload)a do
      assert_raise ArgumentError, ~r/must run separately/, fn ->
        NativeConsumer.validate_options!(
          [native_checkpoints: true, native_public: true] ++ [{other, true}]
        )
      end
    end
  end

  test "branch consumers require explicit public mode and a separate ordinary campaign" do
    assert_raise ArgumentError, ~r/native-branches requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_branches: true)
    end

    for other <-
          ~w(native_checkpoints native_images native_growth native_volume native_terminal native_network native_workload)a do
      assert_raise ArgumentError, ~r/must run separately/, fn ->
        NativeConsumer.validate_options!(
          [native_branches: true, native_public: true] ++ [{other, true}]
        )
      end
    end
  end

  test "image consumers require explicit separate public mode and bounded private settings" do
    assert_raise ArgumentError, ~r/requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_images: true)
    end

    assert_raise ArgumentError, ~r/must run separately/, fn ->
      NativeConsumer.validate_options!(
        native_images: true,
        native_public: true,
        native_growth: true
      )
    end

    assert_raise ArgumentError, ~r/explicit absolute --native-images-settings/, fn ->
      NativeConsumer.validate_options!(native_images: true, native_public: true)
    end

    assert_raise ArgumentError, ~r/settings require --native-images/, fn ->
      NativeConsumer.validate_options!(native_images_settings: "/private/settings.json")
    end

    root = Util.temporary("image-settings-model")
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "settings.json")
    File.write!(path, "{}")
    File.chmod!(path, 0o644)

    assert_raise ArgumentError, ~r/private file permissions/, fn ->
      NativeConsumer.validate_options!(
        native_images: true,
        native_public: true,
        native_images_settings: path
      )
    end
  end

  test "network consumers require an explicit public isolated-namespace campaign" do
    assert_raise ArgumentError, ~r/requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_network: true)
    end

    assert_raise ArgumentError, ~r/must run separately/, fn ->
      NativeConsumer.validate_options!(
        native_network: true,
        native_terminal: true,
        native_public: true
      )
    end

    assert_raise ArgumentError, ~r/explicit --native-host-port/, fn ->
      NativeConsumer.validate_options!(native_network: true, native_public: true)
    end

    assert_raise ArgumentError, ~r/verified namespace identity/, fn ->
      NativeConsumer.validate_options!(
        native_network: true,
        native_public: true,
        native_host_port: 28_732
      )
    end

    assert_raise ArgumentError, ~r/options require --native-network/, fn ->
      NativeConsumer.validate_options!(namespace_identity: "net:[42]")
    end
  end

  test "startup workload consumers require an explicit separate ordinary campaign" do
    assert_raise ArgumentError, ~r/requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_workload: true)
    end

    assert_raise ArgumentError, ~r/must run separately/, fn ->
      NativeConsumer.validate_options!(
        native_workload: true,
        native_public: true,
        native_network: true
      )
    end

    assert_raise ArgumentError, ~r/verified namespace identity/, fn ->
      NativeConsumer.validate_options!(native_workload: true, native_public: true)
    end
  end

  test "growth consumers require explicit public mode and a separate campaign" do
    assert_raise ArgumentError, ~r/requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_growth: true)
    end

    for other <- [:native_volume, :native_terminal, :native_network, :native_workload] do
      assert_raise ArgumentError, ~r/must run separately/, fn ->
        NativeConsumer.validate_options!(
          [native_growth: true, native_public: true] ++ [{other, true}]
        )
      end
    end
  end

  test "optional growth settings require the growth campaign and private bounded absolute input" do
    assert_raise ArgumentError, ~r/settings require --native-growth/, fn ->
      NativeConsumer.validate_options!(native_growth_settings: "/private/settings.json")
    end

    assert_raise ArgumentError, ~r/explicit absolute path/, fn ->
      NativeConsumer.validate_options!(
        native_growth: true,
        native_public: true,
        native_growth_settings: "settings.json"
      )
    end

    root = Util.temporary("growth-settings-model")
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "settings.json")
    File.write!(path, "{}")
    File.chmod!(path, 0o644)

    assert_raise ArgumentError, ~r/private file permissions/, fn ->
      NativeConsumer.validate_options!(
        native_growth: true,
        native_public: true,
        native_growth_settings: path
      )
    end

    File.chmod!(path, 0o600)
    File.write!(path, String.duplicate(" ", 65_537))

    assert_raise ArgumentError, ~r/private file permissions or size/, fn ->
      NativeConsumer.validate_options!(
        native_growth: true,
        native_public: true,
        native_growth_settings: path
      )
    end
  end

  test "volume consumers require a separate explicit public campaign and canonical-root approval" do
    assert_raise ArgumentError, ~r/requires explicit --native-public/, fn ->
      NativeConsumer.validate_options!(native_volume: true)
    end

    assert_raise ArgumentError, ~r/explicit absolute --native-volume-root/, fn ->
      NativeConsumer.validate_options!(native_volume: true, native_public: true)
    end

    assert_raise ArgumentError, ~r/must run separately/, fn ->
      NativeConsumer.validate_options!(
        native_volume: true,
        native_public: true,
        native_terminal: true
      )
    end

    assert_raise ArgumentError, ~r/root requires --native-volume/, fn ->
      NativeConsumer.validate_options!(native_volume_root: "/approved/volumes")
    end
  end

  test "public documentation and onboarding examples are accepted in the published package" do
    root = Util.temporary("smolbox-registry-package")
    on_exit(fn -> File.rm_rf!(root) end)

    names =
      ~w(mix.exs README.md CHANGELOG.md LICENSE lib/smolbox.ex lib/smolbox/runtime.ex priv/kubernetes/guest_helper_v1.py docs/notebooks/getting-started.livemd docs/images-and-registry-artifacts.md docs/images-and-registry-artifacts-validation.md docs/provisioning-performance.md docs/upgrading-to-0.3.0.md docs/upgrading-to-0.4.3.md docs/upgrading.md docs/upgrading-within-0.1.x.md docs/supported-platforms.md docs/testing.md docs/embedded-port.md docs/embedded-quickstart.md examples/embedded_port/scripts/quickstart.exs docs/network-access-validation.md docs/worker-measurements-validation.md docs/worker-draining-validation.md)

    inner = Path.join(root, "contents.tar")
    members = Enum.map(names, &{String.to_charlist(&1), "fixture"})
    :ok = :erl_tar.create(String.to_charlist(inner), members, [])
    outer = Path.join(root, "package.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(outer),
        [
          {~c"VERSION", "3"},
          {~c"CHECKSUM", "fixture"},
          {~c"metadata.config", <<>>},
          {~c"contents.tar.gz", :zlib.gzip(File.read!(inner))}
        ],
        []
      )

    output = Path.join(root, "output")
    assert Enum.sort(Package.unpack!(outer, output)) == Enum.sort(names)
    assert File.read!(Path.join(output, "docs/images-and-registry-artifacts.md")) == "fixture"
    assert File.read!(Path.join(output, "docs/provisioning-performance.md")) == "fixture"
    assert File.read!(Path.join(output, "docs/upgrading-to-0.3.0.md")) == "fixture"
    assert File.read!(Path.join(output, "docs/notebooks/getting-started.livemd")) == "fixture"
    assert File.read!(Path.join(output, "priv/kubernetes/guest_helper_v1.py")) == "fixture"

    assert File.read!(Path.join(output, "examples/embedded_port/scripts/quickstart.exs")) ==
             "fixture"
  end

  test "truncated gzip fails before any package files are written" do
    root = Util.temporary("smolbox-truncated-package")
    on_exit(fn -> File.rm_rf!(root) end)
    inner = Path.join(root, "contents.tar")
    :ok = :erl_tar.create(String.to_charlist(inner), [{~c"README.md", "fixture"}], [])
    compressed = :zlib.gzip(File.read!(inner))
    truncated = binary_part(compressed, 0, byte_size(compressed) - 8)
    outer = Path.join(root, "package.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(outer),
        [
          {~c"VERSION", "3"},
          {~c"CHECKSUM", "fixture"},
          {~c"metadata.config", <<>>},
          {~c"contents.tar.gz", truncated}
        ],
        []
      )

    output = Path.join(root, "output")
    assert_raise ErlangError, fn -> Package.unpack!(outer, output) end
    refute File.exists?(output)
  end

  test "archive validation rejects traversal, symlinks and duplicate files before extraction" do
    root = Util.temporary("smolbox-package-test")
    on_exit(fn -> File.rm_rf!(root) end)
    target = Path.join(root, "target")
    File.write!(target, "fixture")
    link = Path.join(root, "link")
    File.ln_s!(target, link)

    for {label, members} <- [
          {"unlisted-doc", [{~c"docs/private-notes.md", <<>>}]},
          {"unlisted-notebook", [{~c"docs/notebooks/private-notes.livemd", <<>>}]},
          {"traversal", [{~c"../escape.ex", <<>>}]},
          {"symlink", [{~c"lib/link.ex", String.to_charlist(link)}]},
          {"duplicate", [{~c"README.md", <<>>}, {~c"README.md", <<>>}]}
        ] do
      inner = Path.join(root, label <> ".tar")
      :ok = :erl_tar.create(String.to_charlist(inner), members, [])
      outer = Path.join(root, label <> "-hex.tar")

      :ok =
        :erl_tar.create(
          String.to_charlist(outer),
          [
            {~c"VERSION", "3"},
            {~c"CHECKSUM", "fixture"},
            {~c"metadata.config", <<>>},
            {~c"contents.tar.gz", :zlib.gzip(File.read!(inner))}
          ],
          []
        )

      output = Path.join(root, label)
      assert_raise ArgumentError, fn -> Package.unpack!(outer, output) end
      refute File.exists?(output)
      refute File.exists?(Path.join(root, "escape.ex"))
    end
  end
end
