{options, [], []} =
  OptionParser.parse(System.argv(), strict: [analytics: :boolean, output: :string])

SmolBox.Blog.Verify.run!(Keyword.get(options, :output, "_site"), options)

# xmerl is an OTP tool used only by this verification script, not a library dependency.
Mix.ensure_application!(:xmerl)

for name <- ~w(feed sitemap) do
  file = Path.join(Keyword.get(options, :output, "_site"), name <> ".xml")
  {_document, []} = :xmerl_scan.string(String.to_charlist(File.read!(file)), quiet: true)
end

IO.puts("Both XML feeds parsed successfully")
