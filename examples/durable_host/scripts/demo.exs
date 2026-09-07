alias SmolBox.DurableHost.Demo
alias SmolBox.Example.Setup

settings =
  Setup.environment()
  |> Map.put("partition", System.fetch_env!("SMOLBOX_STORE_PARTITION"))
  |> Map.put("encryption_key_file", System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
  |> Map.put("cancel", System.get_env("SMOLBOX_EXAMPLE_CANCEL", "false") == "true")

Demo.run(settings)
