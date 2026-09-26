defmodule SmolBox.CI.Runtime do
  @moduledoc false
  alias SmolBox.CI.Util

  @pins %{
    {"linux", "1.19.0"} =>
      {"x86_64", "9133f40b13e0d08bb0c7b1c939c0ee4d656681445fd739db9a37ed4b14500582"},
    {"macos", "1.19.0"} =>
      {"arm64", "aefa1fc34f22bfe287738ec82ea4b23030913a037f2805f76e56eca53942d5da"},
    {"linux", "1.17.0"} =>
      {"x86_64", "40b9bc8f24f7cc77c371db4784742e6b6724f09a11b83d63776b944734b7912d"},
    {"macos", "1.17.0"} =>
      {"arm64", "bee762e648f2c90e2339c6c3f37d6fd47d3645888e2b4d73963e511032d2195a"},
    {"linux", "1.14.1"} =>
      {"x86_64", "bb2432804d4bf5d6cbb688d3af160a6a01c99194830f0099d64f291d4ad62373"},
    {"macos", "1.14.1"} =>
      {"arm64", "af238c1190aefbc1c293f515c720c9c15f968498ad67624a9b9f824a51af0c79"},
    {"linux", "1.14.6"} =>
      {"x86_64", "cc1f9b5f14613191ca83c706d52f4350f69b69a6c431c867cd662b51cb36d7d6"},
    {"macos", "1.14.6"} =>
      {"arm64", "f62d06160f674ba516f828758b6dcf981c531d548987a6e7e34f56f5bddb41b7"},
    {"linux", "1.16.0"} =>
      {"x86_64", "487f20b84053ce6441c67d4d8af35fc028d3bfc7fcfd2da4309c070930fe46a1"},
    {"linux", "1.16.1"} =>
      {"x86_64", "017f61853a8f19450472052080f95cd8ef5b80b61d1715e4524c67ea085f11a5"},
    {"macos", "1.16.1"} =>
      {"arm64", "d587f858cae14fd34025aaf627b0c63e1443d9e4059855a80597ae6a5b8d93be"},
    {"macos", "1.16.0"} =>
      {"arm64", "d9172bd4640ec0c30a267f9559746b12158cdc445443c21a01dd813c4eb6be45"}
  }

  def pin!(platform, version) do
    Util.ensure!(Map.has_key?(@pins, {platform, version}), "unsupported runtime/platform pair")
    Map.fetch!(@pins, {platform, version})
  end

  def selected_version, do: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.19.0")
end
