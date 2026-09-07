defmodule SmolBox.CI.HTTP do
  @moduledoc false
  alias SmolBox.CI.{Child, Util}

  # curl supplies HTTP framing across both supported hosts. Its output is bounded
  # by our owned child, including non-2xx responses. No redirects, proxies or
  # mutation retries are enabled. These maintainer probes only use loopback HTTP.
  def request(url, method \\ "GET", body \\ nil, cap \\ 2_097_152) do
    uri = URI.parse(url)

    Util.ensure!(
      uri.scheme == "http" and uri.host == "127.0.0.1" and
        is_nil(uri.userinfo) and is_nil(uri.fragment),
      "probe requires explicit loopback HTTP"
    )

    directory = Util.temporary("smolbox-http")

    try do
      arguments =
        [
          "curl",
          "-q",
          "--silent",
          "--show-error",
          "--noproxy",
          "*",
          "--proto",
          "=http",
          "--max-time",
          "3",
          "--connect-timeout",
          "3",
          "--request",
          method,
          "--url",
          url,
          "--write-out",
          "\n%{http_code}"
        ] ++ body_args(body, directory)

      {data, report} = Child.execute(arguments, timeout: 5_000, output_limit: cap + 4)

      Util.ensure!(
        report.status == "passed" and byte_size(data) >= 4,
        "bounded HTTP probe failed"
      )

      size = byte_size(data) - 4
      <<bytes::binary-size(^size), "\n", code::binary-size(3)>> = data
      {String.to_integer(code), bytes}
    after
      File.rm_rf!(directory)
    end
  end

  def json!(url, method \\ "GET", body \\ nil, cap \\ 2_097_152) do
    {status, bytes} = request(url, method, body, cap)
    Util.ensure!(status in 200..299, "unexpected worker HTTP status #{status}")
    if bytes == "", do: nil, else: JSON.decode!(bytes)
  end

  defp body_args(nil, _), do: []

  defp body_args(body, directory) do
    file = Path.join(directory, "body.json")
    File.write!(file, JSON.encode!(body), [:exclusive])
    File.chmod!(file, 0o600)
    ["--header", "Content-Type: application/json", "--data-binary", "@" <> file]
  end
end
