defmodule SmolBox.CI.PackageTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{Package, Util}

  test "release, registry and provisioning documentation is accepted in the published package" do
    root = Util.temporary("smolbox-registry-package")
    on_exit(fn -> File.rm_rf!(root) end)

    names =
      ~w(mix.exs README.md CHANGELOG.md LICENSE lib/smolbox.ex lib/smolbox/runtime.ex docs/images-and-registry-artifacts.md docs/images-and-registry-artifacts-validation.md docs/provisioning-performance.md docs/upgrading-to-0.3.0.md)

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
