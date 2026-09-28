defmodule Workspace.CaptureFilesTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Workspace.SavedState

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  test "dangling symlinks still count as files", %{tmp_dir: dir} do
    path = Path.join(dir, "capture")
    File.ln_s!(Path.join(dir, "missing"), path)
    assert [%{state: :present}, %{state: :absent}] = files(path)
  end

  test "an inaccessible path is not reported as absence and blocks the release control", %{
    tmp_dir: dir
  } do
    parent = Path.join(dir, "not-a-directory")
    File.write!(parent, "file")
    path = Path.join(parent, "capture")
    assert [%{state: :unavailable}, %{state: :unavailable}] = files(path)

    data = %{
      source: nil,
      child: nil,
      source_id: "source",
      child_id: "child",
      commands: %{},
      capture: %{state: :completed, released_at_ms: nil, result: nil},
      capture_files: files(path),
      usage: {:error, :unavailable}
    }

    html =
      render_component(&WorkspaceWeb.SavedStatePanel.panel/1, result: {:ok, data}, busy: false)

    assert html =~ "Cannot check this path"
    assert html =~ path

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("#saved-release-capture button")
           |> Enum.count() == 0
  end

  defp files(path), do: SavedState.capture_files(%{result: %{path: path}})
end
