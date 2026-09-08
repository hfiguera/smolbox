defmodule SmolBox.BlogTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias SmolBox.Blog
  alias SmolBox.Blog.{Catalog, HTML, Verify}

  setup do
    output = Path.join(System.tmp_dir!(), "smolbox-blog-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(output) end)
    %{output: output}
  end

  test "real site has correct links and no analytics in a preview", %{output: output} do
    capture_io(fn -> Blog.build!(output) end)
    pages = length(Catalog.load!("docs/blog")) + 3
    assert capture_io(fn -> Verify.run!(output) end) =~ "#{pages} blog pages"
  end

  test "deployment adds one beacon to every page", %{output: output} do
    capture_io(fn -> Blog.build!(output, analytics: true) end)
    assert capture_io(fn -> Verify.run!(output, analytics: true) end) =~ "analytics mode"
    assert_raise ArgumentError, ~r/analytics beacon count/, fn -> Verify.run!(output) end
  end

  test "broken article anchors cannot pass verification", %{output: output} do
    capture_io(fn -> Blog.build!(output) end)
    page = Path.join(output, "index.html")
    File.write!(page, File.read!(page) <> ~s(<a href="#absent">Broken</a>))
    assert_raise ArgumentError, ~r/missing fragment/, fn -> Verify.run!(output) end
  end

  test "build never wipes a nonempty output directory", %{output: output} do
    File.mkdir_p!(output)
    File.write!(Path.join(output, "important.txt"), "retain")
    assert_raise ArgumentError, ~r/output must be empty/, fn -> Blog.build!(output) end
    assert File.read!(Path.join(output, "important.txt")) == "retain"
  end

  test "metadata rejects duplicate identities, traversal, and reversed dates" do
    [article | _articles] = Jason.decode!(File.read!("docs/blog/articles.json"))
    assert_raise ArgumentError, ~r/duplicate/, fn -> Catalog.validate!([article, article]) end

    for changes <- [%{"slug" => "../escape"}, %{"updated_on" => "2020-01-01"}] do
      assert_raise ArgumentError, fn -> Catalog.validate!([Map.merge(article, changes)]) end
    end
  end

  test "section links remain unique when headings repeat" do
    {:ok, _apps} = Application.ensure_all_started(:makeup_elixir)
    {html, contents} = HTML.article("## Run\n\nFirst.\n\n## Run\n\nAgain.")
    assert Enum.map(contents, & &1.id) == ["run", "run-2"]
    assert html =~ ~s(id="run-2")
    assert_raise ArgumentError, ~r/title belongs/, fn -> HTML.article("# A second title") end
  end

  test "metadata is escaped for HTML and XML" do
    assert HTML.escape(~s(<script title="x">Tom & 'Sam'</script>)) ==
             "&lt;script title=&quot;x&quot;&gt;Tom &amp; &#39;Sam&#39;&lt;/script&gt;"
  end

  test "Elixir and shell fences produce syntax tokens with matching theme selectors", %{
    output: output
  } do
    capture_io(fn -> Blog.build!(output) end)
    stylesheet = File.read!(Path.join(output, "assets/syntax.css"))

    for language <- ~w(elixir sh bash) do
      code = if language == "elixir", do: "if ready, do: :ok", else: ~s(export NAME="SmolBox")
      {html, _contents} = HTML.article("```#{language}\n#{code}\n```")
      assert html =~ ~s(class="makeup #{language}")

      classes = Regex.scan(~r/<span class="([^"]+)"/, html, capture: :all_but_first)
      assert [_, _ | _] = Enum.uniq(classes)

      assert Enum.any?(classes, fn [class] ->
               String.contains?(stylesheet, ".makeup .#{class} {")
             end)
    end
  end
end
