defmodule Mix.Tasks.Smolbox.Ci.Docs do
  @moduledoc "Checks local links and fragments in an already generated ExDoc site."
  @shortdoc "Reject broken local documentation links"
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    directory = args |> directory() |> Path.expand()
    pages = Path.wildcard(Path.join(directory, "**/*.html"))
    if pages == [], do: Mix.raise("No generated HTML documentation in #{directory}")
    contents = Map.new(pages, &{&1, File.read!(&1)})

    anchors =
      Map.new(contents, fn {file, html} ->
        {file, MapSet.new(attributes(html, ~r/\bid="([^"]*)"/), &unescape/1)}
      end)

    errors =
      Enum.flat_map(contents, fn {file, html} ->
        html
        # ExDoc references this optional hosting-supplied version menu script,
        # but deliberately does not generate it in local builds.
        |> String.replace(~s(<script defer src="docs_config.js"></script>), "")
        |> attributes(~r/\b(?:href|src)="([^"]+)"/)
        |> Enum.flat_map(&check_link(&1, file, directory, anchors))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if errors != [], do: Mix.raise("Broken documentation links:\n" <> Enum.join(errors, "\n"))
    Mix.shell().info("Checked local links and fragments in #{length(pages)} documentation pages")
  end

  defp directory([]), do: "doc"
  defp directory([directory]), do: directory
  defp directory(_args), do: Mix.raise("Usage: mix smolbox.ci.docs [output-directory]")

  defp attributes(html, pattern), do: Enum.map(Regex.scan(pattern, html), &List.last/1)

  defp check_link(link, file, directory, anchors) do
    uri = link |> unescape() |> URI.parse()

    if uri.scheme || uri.host do
      []
    else
      target =
        case uri.path do
          path when path in [nil, ""] -> file
          path -> path |> URI.decode() |> Path.expand(Path.dirname(file))
        end

      case local_error(target, uri.fragment, directory, anchors) do
        nil -> []
        reason -> ["#{Path.relative_to(file, directory)}: #{link} (#{reason})"]
      end
    end
  end

  defp local_error(target, fragment, directory, anchors) do
    cond do
      not String.starts_with?(target, directory <> "/") -> "outside documentation directory"
      not File.regular?(target) -> "missing file"
      missing_fragment?(target, fragment, anchors) -> "missing fragment"
      true -> nil
    end
  end

  defp missing_fragment?(_target, fragment, _anchors) when fragment in [nil, ""], do: false

  defp missing_fragment?(target, fragment, anchors) do
    case Map.fetch(anchors, target) do
      {:ok, ids} -> not MapSet.member?(ids, URI.decode(fragment))
      :error -> false
    end
  end

  defp unescape(value) do
    Enum.reduce(
      [{"&quot;", "\""}, {"&#39;", "'"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&amp;", "&"}],
      value,
      fn {encoded, decoded}, text -> String.replace(text, encoded, decoded) end
    )
  end
end
