defmodule SmolBox.FilesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SmolBox.Files

  test "workspace paths preserve Unicode and encode each route segment once" do
    assert :ok = Files.validate_path("/workspace")
    assert {:ok, "workspace/caf%C3%A9/a%20b.py"} = Files.encode_path("/workspace/café/a b.py")

    for path <- [
          "/etc/passwd",
          "/workspace/../etc",
          "/workspace/./x",
          "/workspace//x",
          "/workspace/x/",
          "/workspace/%2e%2e",
          "/workspace/x\\y",
          "/workspace/\0",
          "workspace/x",
          "/workspace-other/a",
          <<255>>,
          12,
          "/workspace/" <> String.duplicate("x", 1024)
        ] do
      assert {:error, _error} = Files.encode_path(path)
    end
  end

  property "accepted simple filenames survive a single URL decode exactly" do
    check all(name <- string(:alphanumeric, min_length: 1, max_length: 80)) do
      path = "/workspace/" <> name
      assert {:ok, encoded} = Files.encode_path(path)
      assert "/" <> URI.decode(encoded) == path
    end
  end

  test "digests match byte-oriented SHA-256 including non-UTF-8 input" do
    assert Files.sha256("abc") ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    refute Files.sha256(<<255>>) == Files.sha256("�")
  end
end
