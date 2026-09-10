defmodule SmolBox.CI.Runtime do
  @moduledoc false
  alias SmolBox.CI.Util

  @pins %{
    {"linux", "1.14.1"} =>
      {"x86_64", "bb2432804d4bf5d6cbb688d3af160a6a01c99194830f0099d64f291d4ad62373"},
    {"macos", "1.14.1"} =>
      {"arm64", "af238c1190aefbc1c293f515c720c9c15f968498ad67624a9b9f824a51af0c79"},
    {"linux", "1.14.6"} =>
      {"x86_64", "cc1f9b5f14613191ca83c706d52f4350f69b69a6c431c867cd662b51cb36d7d6"}
  }

  def pin!(platform, version) do
    Util.ensure!(Map.has_key?(@pins, {platform, version}), "unsupported runtime/platform pair")
    Map.fetch!(@pins, {platform, version})
  end

  def selected_version, do: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.14.1")
end
