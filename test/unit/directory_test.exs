defmodule SmolBox.DirectoryTest do
  use ExUnit.Case, async: true
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Error, Files}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "sbx-artifacts-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = Directory.new(root)
    %{root: root, store: store}
  end

  test "bounded binary snapshots are immutable under concurrent identical and conflicting writes",
       %{store: store, root: root} do
    refute inspect(store) =~ root
    bytes = <<0, 255, 19>>
    assert :ok = Directory.seed(store, "tenant", "input", bytes)
    assert {:ok, ^bytes} = Directory.read(store, "tenant", "input", 3)
    assert {:error, %Error{}} = Directory.read(store, "tenant", "input", 2)
    assert {:error, %Error{category: :not_found}} = Directory.read(store, "other", "input", 3)

    results =
      1..24
      |> Task.async_stream(
        fn _ ->
          Directory.put(store, {"tenant", "execution"}, "output", bytes, Files.sha256(bytes))
        end,
        max_concurrency: 12
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, ^bytes} = Directory.read_output(store, {"tenant", "execution"}, "output", 3)

    assert {:error, %Error{category: :identity_conflict}} =
             Directory.put(
               store,
               {"tenant", "execution"},
               "output",
               "changed",
               Files.sha256("changed")
             )

    assert {:ok, ^bytes} = Directory.read_output(store, {"tenant", "execution"}, "output", 3)
    refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".tmp-"))
    assert :ok = Directory.seed(store, "tenant", "empty", "")
    assert {:ok, ""} = Directory.read(store, "tenant", "empty", 1)
  end

  test "unapproved roots, references, oversized input and corrupt stored bytes fail", %{
    store: store,
    root: root
  } do
    assert {:error, %Error{}} = Directory.new("relative")
    assert {:error, %Error{}} = Directory.new(nil)
    assert {:error, %Error{}} = Directory.new(root <> "/missing")
    assert {:error, %Error{}} = Directory.seed(store, "../tenant", "input", "bytes")

    assert {:error, %Error{}} =
             Directory.seed(store, "tenant", "large", :binary.copy(<<0>>, 1_048_577))

    assert {:error, %Error{}} = Directory.read(store, "tenant", "input", 0)
    bytes = "bytes"

    assert {:error, %Error{}} =
             Directory.put(store, {"tenant", "id"}, "out", bytes, Files.sha256("wrong"))

    assert :ok = Directory.seed(store, "tenant", "input", bytes)
    digest = Files.sha256(bytes)
    blob = Path.join(root, digest <> ".blob")
    File.write!(blob, "other")
    assert {:error, %Error{}} = Directory.read(store, "tenant", "input", 10)
    File.rm!(blob)
    File.ln_s!("/etc/hosts", blob)
    assert {:error, %Error{}} = Directory.read(store, "tenant", "input", 100)
    File.chmod!(root, 0o755)
    assert {:error, %Error{}} = Directory.new(root)
    assert {:error, %Error{}} = Directory.read(store, "tenant", "input", 10)
  end
end
