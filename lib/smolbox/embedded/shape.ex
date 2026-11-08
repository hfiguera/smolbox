defmodule SmolBox.Embedded.Shape do
  @moduledoc false
  alias SmolBox.Validation

  def keys?(value, keys),
    do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  def hex?(value, length),
    do:
      is_binary(value) and byte_size(value) == length and
        Regex.match?(~r/\A[0-9a-f]+\z/, value)

  def id?(value),
    do:
      text?(value, 128, false) and value not in [".", ".."] and
        Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, value)

  def text?(value, limit, empty),
    do: Validation.text?(value, limit) and (empty or value != "")

  def path?(value),
    do:
      text?(value, 4096, false) and String.starts_with?(value, "/") and
        not Enum.member?(String.split(value, "/"), "..")

  def optional?(nil, _predicate), do: true
  def optional?(value, predicate), do: predicate.(value)

  def receipt?(receipt) do
    keys?(receipt, ~w(target_id domain_generation name owner_token incarnation material_sha256)) and
      id?(receipt["target_id"]) and id?(receipt["name"]) and
      hex?(receipt["domain_generation"], 32) and hex?(receipt["owner_token"], 64) and
      hex?(receipt["incarnation"], 32) and Validation.digest?(receipt["material_sha256"])
  end

  def resources?(resources),
    do:
      keys?(resources, ~w(cpus memory_mib storage_gib overlay_gib)) and
        Validation.integer?(resources["cpus"], 1, 16) and
        Validation.integer?(resources["memory_mib"], 64, 65_536) and
        Validation.integer?(resources["storage_gib"], 1, 1024) and
        Validation.integer?(resources["overlay_gib"], 1, 1024)

  def chunk(encoded) when is_binary(encoded) and byte_size(encoded) <= 87_384 do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) > 0 and byte_size(bytes) <= 65_536,
         true <- Base.encode64(bytes) == encoded,
         do: {:ok, bytes}
  end

  def chunk(_encoded), do: :error
end
