defmodule SmolBox.Blog do
  @moduledoc false

  alias SmolBox.Blog.{Catalog, HTML}

  @site_url "https://hfiguera.github.io/smolbox/"
  # Public browser identifier for the shared hfiguera.github.io analytics property.
  @analytics_token "f968ea7d6e614cc9a3e2d537ced91a10"
  @source "docs/blog"

  def site_url, do: @site_url

  def build!(output \\ "_site", options \\ []) do
    source = Keyword.get(options, :source, @source)
    articles = Catalog.load!(source)
    File.mkdir_p!(output)

    if File.ls!(output) != [], do: raise(ArgumentError, "blog output must be empty: #{output}")

    site = %{
      source: source,
      output: output,
      url: @site_url,
      token: if(Keyword.get(options, :analytics, false), do: @analytics_token),
      articles: articles
    }

    File.cp_r!(Path.join(source, "assets"), Path.join(output, "assets"))
    File.cp_r!(Path.join(source, "media"), Path.join(output, "media"))

    File.write!(
      Path.join(output, "assets/syntax.css"),
      Makeup.stylesheet(:one_dark_style, "makeup")
    )

    Enum.each(articles, &write_article(site, &1))

    write_page(site, "index", "",
      title: "SmolBox engineering notes",
      description:
        "Practical guides to running Python, JavaScript, and other programs from Elixir with SmolBox."
    )

    write_page(site, "privacy", "privacy/",
      title: "Analytics privacy · SmolBox",
      description: "What the SmolBox blog measures with Cloudflare Web Analytics."
    )

    write_page(site, "not_found", "404.html",
      title: "Page not found · SmolBox",
      description: "Find the SmolBox engineering blog and documentation.",
      noindex: true
    )

    write_feeds(site)
    File.write!(Path.join(output, ".nojekyll"), "")

    IO.puts(
      "Built #{length(articles)} article(s) in #{output}; analytics #{if site.token, do: "enabled", else: "disabled"}"
    )

    output
  end

  defp write_article(site, article) do
    {body, contents} = HTML.article(article["markdown"])
    path = "blog/#{article["slug"]}/"

    write_page(site, "article", path,
      title: article["title"] <> " · SmolBox",
      description: article["description"],
      article: article,
      article_html: body,
      contents: contents,
      image: site.url <> "media/#{article["slug"]}/#{article["image"]}"
    )
  end

  defp write_page(site, template, path, fields) do
    uri = URI.parse(site.url)
    root = uri.path

    assigns =
      Map.merge(
        %{
          site: site,
          root: root,
          canonical: site.url <> path,
          article: nil,
          image: site.url <> "assets/social.png",
          noindex: false
        },
        Map.new(fields)
      )

    body = HTML.render(site.source, template, assigns)
    html = HTML.render(site.source, "layout", Map.put(assigns, :body, body))
    filename = if Path.extname(path) == ".html", do: path, else: path <> "index.html"
    destination = Path.join(site.output, filename)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, html)
  end

  defp write_feeds(site) do
    assigns = %{site: site, latest: Enum.max_by(site.articles, & &1["updated_on"])["updated_on"]}

    for name <- ~w(feed sitemap) do
      File.write!(Path.join(site.output, name <> ".xml"), HTML.render(site.source, name, assigns))
    end
  end

  def rss_date(date) do
    date |> Date.from_iso8601!() |> Calendar.strftime("%a, %d %b %Y 00:00:00 GMT")
  end
end
