defmodule SmolBox.CI.PackageTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{Package, Util}

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
