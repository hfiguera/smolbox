defmodule SmolBox.DocsSiteTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Mix.Tasks.Smolbox.Ci.Docs

  setup do
    directory =
      Path.join(System.tmp_dir!(), "smolbox-doc-links-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "local assets, encoded anchors, and external links are handled separately", %{
    directory: directory
  } do
    File.write!(Path.join(directory, "index.html"), """
    <a href="guide.html#new%2F1">API</a>
    <a href="https://example.invalid/unavailable">external</a>
    <img src="asset.txt">
    <script defer src="docs_config.js"></script>
    """)

    File.write!(Path.join(directory, "guide.html"), ~s(<h1 id="new/1">New</h1>))
    File.write!(Path.join(directory, "asset.txt"), "fixture")
    assert capture_io(fn -> Docs.run([directory]) end) =~ "2 documentation pages"
  end

  test "missing files and fragments fail instead of accepting a warning-free build", %{
    directory: directory
  } do
    File.write!(Path.join(directory, "index.html"), """
    <a href="evidence/missing.json">evidence</a>
    <a href="#missing">section</a>
    """)

    error = assert_raise Mix.Error, fn -> Docs.run([directory]) end
    assert error.message =~ "evidence/missing.json (missing file)"
    assert error.message =~ "#missing (missing fragment)"
  end

  test "an absent generated site cannot pass", %{directory: directory} do
    assert_raise Mix.Error, ~r/No generated HTML documentation/, fn -> Docs.run([directory]) end
  end
end
