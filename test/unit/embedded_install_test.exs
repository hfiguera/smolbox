defmodule SmolBox.EmbeddedInstallTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.Smolbox.Embedded.Install

  @tag_name "v0.5.0-rc.1"

  setup do
    root =
      Path.join(System.tmp_dir!(), "smolbox-install-test-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{archive: Path.join(root, "candidate.tar.gz"), destination: Path.join(root, "install")}
  end

  test "rejects changed bytes before extraction and removes staging", context do
    File.write!(context.archive, "this is not a tar archive")

    assert_raise Mix.Error, ~r/SHA-256 mismatch/, fn ->
      Install.run(args(context, String.duplicate("0", 64)))
    end

    refute File.exists?(context.destination)
    refute File.exists?(context.destination <> ".installing")
  end

  test "rejects another release after digest verification", context do
    package = Path.join(Path.dirname(context.archive), "package")
    File.mkdir!(package)
    metadata = Path.join(Path.dirname(context.archive), "release.json")
    File.write!(metadata, Jason.encode!(%{schema: 1, tag: "v0.9.0"}))

    {_, 0} =
      System.cmd("tar", [
        "-czf",
        context.archive,
        "-C",
        Path.dirname(context.archive),
        "package",
        "release.json"
      ])

    assert_raise Mix.Error, ~r/does not match this release and host/, fn ->
      Install.run(args(context, context.archive |> File.read!() |> SmolBox.Files.sha256()))
    end

    refute File.exists?(context.destination)
    refute File.exists?(context.destination <> ".installing")
  end

  test "preserves a previous install", context do
    File.mkdir!(context.destination)
    marker = Path.join(context.destination, "keep")
    File.write!(marker, "owned")

    assert_raise Mix.Error, ~r/install directory already exists/, fn ->
      Install.run(args(context, String.duplicate("0", 64)))
    end

    assert File.read!(marker) == "owned"
    refute File.exists?(context.destination <> ".installing")
  end

  defp args(context, digest) do
    [
      "--tag",
      @tag_name,
      "--install-dir",
      context.destination,
      "--archive",
      context.archive,
      "--sha256",
      digest
    ]
  end
end
