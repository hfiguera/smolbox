{options, [], []} =
  OptionParser.parse(System.argv(), strict: [analytics: :boolean, output: :string])

SmolBox.Blog.build!(Keyword.get(options, :output, "_site"), options)
