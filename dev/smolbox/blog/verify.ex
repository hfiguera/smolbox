defmodule SmolBox.Blog.Verify do
  @moduledoc false

  alias SmolBox.Blog
  alias SmolBox.Blog.Catalog

  @beacon "https://static.cloudflareinsights.com/beacon.min.js"

  def run!(output, options \\ []) do
    output = Path.expand(output)
    articles = Catalog.load!(Keyword.get(options, :source, "docs/blog"))
    pages = Path.wildcard(Path.join(output, "**/*.html"))
    ensure!(length(pages) == length(articles) + 3, "unexpected generated page count")
    analytics = Keyword.get(options, :analytics, false)
    Enum.each(pages, &verify_page!(&1, output, analytics))
    verify_articles!(articles, output)
    verify_feeds!(articles, output)
    ensure!(File.regular?(Path.join(output, ".nojekyll")), "missing .nojekyll")

    IO.puts(
      "Verified #{length(pages)} blog pages, links/fragments, article metadata, media, RSS, sitemap, and analytics mode"
    )

    :ok
  end

  defp verify_page!(page, output, analytics) do
    html = File.read!(page)
    relative = Path.relative_to(page, output) |> String.replace(~r/index\.html\z/, "")

    ensure!(
      String.contains?(html, ~s(href="#{Blog.site_url()}#{relative}")),
      "wrong canonical URL"
    )

    ensure!(match?([_heading], Regex.scan(~r/<h1(?:\s|>)/, html)), "page must have one h1")
    ensure!(String.contains?(html, ~s(<html lang="en">)), "missing document language")
    ensure!(String.contains?(html, "Skip to content"), "missing skip link")

    ensure!(
      not String.contains?(html, ["localhost", "TODO(", "/Users/", "/tmp/"]),
      "private or unfinished content"
    )

    count = length(:binary.matches(html, @beacon))
    ensure!(count == if(analytics, do: 1, else: 0), "unexpected analytics beacon count")
    verify_ids!(html)

    for [_, reference] <- Regex.scan(~r/(?:href|src)="([^"]+)"/, html) do
      verify_reference!(reference, page, output)
    end

    for [_, srcset] <- Regex.scan(~r/srcset="([^"]+)"/, html),
        candidate <- String.split(srcset, ",") do
      candidate |> String.split() |> hd() |> verify_reference!(page, output)
    end
  end

  defp verify_ids!(html) do
    ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
    ensure!(length(ids) == length(Enum.uniq(ids)), "duplicate HTML id")
  end

  defp verify_reference!(reference, page, output) do
    uri = URI.parse(reference)

    if is_nil(uri.scheme) and is_nil(uri.host) do
      path = local_path!(uri.path, page, output)
      ensure!(File.regular?(path), "missing local file: #{reference}")

      if uri.fragment do
        fragment = URI.decode(uri.fragment)

        ensure!(
          String.contains?(File.read!(path), ~s(id="#{fragment}")),
          "missing fragment: #{reference}"
        )
      end
    end
  end

  defp local_path!(path, page, _output) when path in [nil, ""], do: page

  defp local_path!(path, page, output) do
    prefix = URI.parse(Blog.site_url()).path

    resolved =
      if String.starts_with?(path, "/") do
        ensure!(String.starts_with?(path, prefix), "local path escapes project prefix: #{path}")
        Path.expand(String.replace_prefix(path, prefix, ""), output)
      else
        Path.expand(URI.decode(path), Path.dirname(page))
      end

    ensure!(
      String.starts_with?(resolved, output <> "/") or resolved == output,
      "reference escapes site"
    )

    if File.dir?(resolved), do: Path.join(resolved, "index.html"), else: resolved
  end

  defp verify_articles!(articles, output) do
    for article <- articles do
      html = File.read!(Path.join(output, "blog/#{article["slug"]}/index.html"))
      [_, metadata] = Regex.run(~r/<script type="application\/ld\+json">(.+?)<\/script>/s, html)
      structured = Jason.decode!(metadata)
      ensure!(structured["headline"] == article["title"], "wrong article headline")
      ensure!(structured["datePublished"] == article["published_on"], "wrong publication date")
      ensure!(structured["dateModified"] == article["updated_on"], "wrong update date")
      image = Path.join(output, "media/#{article["slug"]}/#{article["image"]}")
      <<0x89, "PNG", 13, 10, 26, 10, _::binary>> = File.read!(image)
      ensure!(File.stat!(image).size < 500_000, "social image exceeds 500 KB budget")
    end
  end

  defp verify_feeds!(articles, output) do
    feed = File.read!(Path.join(output, "feed.xml"))
    sitemap = File.read!(Path.join(output, "sitemap.xml"))
    ensure!(length(:binary.matches(feed, "<item>")) == length(articles), "wrong RSS entry count")

    for article <- articles do
      url = Blog.site_url() <> "blog/#{article["slug"]}/"
      ensure!(String.contains?(feed, "<link>#{url}</link>"), "article absent from RSS")
      ensure!(String.contains?(sitemap, "<loc>#{url}</loc>"), "article absent from sitemap")
    end

    ensure!(
      String.contains?(sitemap, "<loc>#{Blog.site_url()}privacy/</loc>"),
      "privacy page absent from sitemap"
    )
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)
end
