output = Path.expand("_site")
true = File.regular?(Path.join(output, ".nojekyll"))
Mix.ensure_application!(:inets)
{:ok, _apps} = Application.ensure_all_started(:inets)

{:ok, _server} =
  :inets.start(:httpd,
    bind_address: {127, 0, 0, 1},
    port: 4173,
    server_name: ~c"SmolBox blog preview",
    server_root: String.to_charlist(output),
    document_root: String.to_charlist(output),
    modules: [:mod_alias, :mod_get, :mod_head],
    alias: {~c"/smolbox", String.to_charlist(output)},
    directory_index: [~c"index.html"],
    mime_types: [
      {~c"html", ~c"text/html"},
      {~c"css", ~c"text/css"},
      {~c"js", ~c"application/javascript"},
      {~c"svg", ~c"image/svg+xml"},
      {~c"png", ~c"image/png"},
      {~c"xml", ~c"application/xml"}
    ]
  )

IO.puts("SmolBox blog preview: http://127.0.0.1:4173/smolbox/")
