defmodule SmolBox.Blog.HTML do
  @moduledoc false
  alias ExDoc.DocAST
  alias ExDoc.Language.Elixir, as: ElixirLanguage
  alias ExDoc.Markdown.Earmark
  alias Makeup.Registry

  def escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  def render(source, template, assigns) do
    source
    |> Path.join("templates/#{template}.html.eex")
    |> EEx.eval_file(assigns: assigns)
  end

  def arrow(direction) when direction in [:left, :right, :external] do
    path =
      case direction do
        :left -> "M20 12H4m7-7-7 7 7 7"
        :right -> "M4 12h16m-7-7 7 7-7 7"
        :external -> "M5 19 19 5M5 5h14v14"
      end

    ~s(<svg class="action-icon" width="16" height="16" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="#{path}"/></svg>)
  end

  def article(markdown) do
    start_highlighters()
    ast = Earmark.to_ast(markdown, file: "blog.md")
    {ast, contents} = headings(ast)

    html =
      ast
      |> DocAST.highlight(ElixirLanguage)
      |> DocAST.to_html()

    {html, contents}
  end

  defp start_highlighters do
    {:ok, _apps} = Application.ensure_all_started(:makeup_elixir)

    Application.put_env(:makeup_syntect, :register_for_languages, ["bourne_again_shell_bash"])
    {:ok, _apps} = Application.ensure_all_started(:makeup_syntect)
    lexer = Registry.fetch_lexer_by_name!("bourne_again_shell_bash")

    for language <- ~w(sh bash) do
      Registry.register_lexer_with_name(language, lexer)
    end
  end

  defp headings(ast) do
    {nodes, {contents, _counts}} = Enum.map_reduce(ast, {[], %{}}, &heading/2)
    {nodes, Enum.reverse(contents)}
  end

  defp heading({:h1, _, _, _}, _state) do
    raise ArgumentError, "article title belongs in articles.json; begin Markdown with prose"
  end

  defp heading({tag, attrs, children, meta}, {contents, counts}) when tag in [:h2, :h3] do
    title = plain_text(children)
    slug = title |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
    slug = String.trim(slug, "-")
    count = Map.get(counts, slug, 0) + 1
    id = if count == 1, do: slug, else: "#{slug}-#{count}"
    entry = %{id: id, title: title, level: tag}
    node = {tag, Keyword.put(attrs, :id, id), children, meta}
    {node, {[entry | contents], Map.put(counts, slug, count)}}
  end

  defp heading(node, state), do: {node, state}

  defp plain_text(nodes) do
    Enum.map_join(nodes, fn
      text when is_binary(text) -> text
      {_tag, _attrs, children, _meta} -> plain_text(children)
    end)
  end
end
