defmodule Workspace.CollectionTest do
  use ExUnit.Case, async: true
  alias Workspace.Collection

  setup do
    root = Path.join(System.tmp_dir!(), "collection-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, target: Path.join(root, "snapshot"), source: Path.join(root, "source")}
  end

  defp collect(source, target, limit) do
    System.cmd("python3", ["-c", Collection.script(), source, target, to_string(limit)],
      stderr_to_stdout: true
    )
  end

  test "actual guest program snapshots binary bytes at the limit and replaces staging symlinks",
       c do
    bytes = :binary.copy(<<0, 255>>, 1024)
    File.write!(c.source, bytes)
    other = Path.join(c.root, "untouched")
    File.write!(other, "original")
    File.ln_s!(other, c.target)
    assert {"", 0} = collect(c.source, c.target, byte_size(bytes))
    assert File.read!(c.target) == bytes
    assert File.read!(other) == "original"
    assert {:ok, %{type: :regular, mode: mode}} = File.lstat(c.target)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "missing, directory, FIFO, oversize and reserved paths produce known errors and an empty output",
       c do
    fifo = Path.join(c.root, "pipe")
    assert {_, 0} = System.cmd("mkfifo", [fifo])
    File.write!(c.source, "12345")

    for source <- [Path.join(c.root, "missing"), c.root, fifo, c.source, c.target] do
      File.write!(c.target, "previous confidential bytes")
      assert {message, 1} = collect(source, c.target, 4)
      assert message =~ "File not collected:"
      assert File.read!(c.target) == ""
    end
  end

  test "empty files succeed", c do
    File.write!(c.source, "")
    assert {"", 0} = collect(c.source, c.target, 1)
    assert File.read!(c.target) == ""
  end
end
