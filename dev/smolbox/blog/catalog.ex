defmodule SmolBox.Blog.Catalog do
  @moduledoc false

  @fields ~w(slug title description published_on updated_on version category image image_alt)

  def load!(source) do
    articles = source |> Path.join("articles.json") |> File.read!() |> Jason.decode!()
    validate!(articles)

    articles
    |> Enum.map(&read_article!(&1, source))
    |> Enum.sort_by(&{&1["published_on"], &1["slug"]}, :desc)
  end

  def validate!(articles) when is_list(articles) and articles != [] do
    Enum.each(articles, &validate_article!/1)
    slugs = Enum.map(articles, & &1["slug"])
    if Enum.uniq(slugs) != slugs, do: raise(ArgumentError, "duplicate article slug")
    :ok
  end

  def validate!(_articles), do: raise(ArgumentError, "articles must be a nonempty list")

  defp validate_article!(article) when is_map(article) do
    for field <- @fields do
      value = article[field]

      unless is_binary(value) and String.trim(value) != "" do
        raise ArgumentError, "missing article field: #{field}"
      end
    end

    unless Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, article["slug"]) and
             Regex.match?(~r/\A[a-z0-9-]+\.png\z/, article["image"]) do
      raise ArgumentError, "invalid article slug or image filename"
    end

    published = Date.from_iso8601!(article["published_on"])
    updated = Date.from_iso8601!(article["updated_on"])
    Version.parse!(article["version"])

    if Date.compare(updated, published) == :lt do
      raise ArgumentError, "article update precedes publication"
    end
  end

  defp validate_article!(_article), do: raise(ArgumentError, "article must be an object")

  defp read_article!(article, source) do
    markdown = File.read!(Path.join(source, article["slug"] <> ".md"))
    words = length(String.split(markdown))
    Map.merge(article, %{"markdown" => markdown, "minutes" => max(1, ceil(words / 220))})
  end
end
