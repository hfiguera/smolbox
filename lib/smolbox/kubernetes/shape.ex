defmodule SmolBox.Kubernetes.Shape do
  @moduledoc false
  alias SmolBox.Validation

  def uid?(value), do: Validation.identifier?(value)

  def dns_label?(value),
    do:
      Validation.text?(value, 63) and byte_size(value) > 0 and
        Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, value)

  def dns_name?(value),
    do:
      Validation.text?(value, 253) and byte_size(value) > 0 and
        Enum.all?(String.split(value, "."), &dns_label?/1)

  def boot_id?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/, value)

  def absolute_path?(value),
    do:
      Validation.text?(value, 4096) and String.starts_with?(value, "/") and
        Path.expand(value) == value

  def callback?({module, _context}, functions),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and
        Enum.all?(functions, fn {name, arity} -> function_exported?(module, name, arity) end)

  def callback?(_value, _functions), do: false

  def exact_keys?(map, keys),
    do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  def unique_list?(value, limit, predicate),
    do:
      Validation.list?(value, limit) and Enum.all?(value, predicate) and
        length(value) == MapSet.size(MapSet.new(value))

  # Tagged containers preserve map/list distinction. Values are validated before
  # hashing; no operational handles or credentials belong in these digests.
  def digest(value),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({"smolbox-kubernetes-v1", canonical(value)})
      )
      |> Base.encode16(case: :lower)

  defp canonical(value) when is_struct(value), do: canonical(Map.from_struct(value))

  defp canonical(value) when is_map(value),
    do: {:map, value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, canonical(item)} end)}

  defp canonical(value) when is_list(value), do: {:list, Enum.map(value, &canonical/1)}

  defp canonical(value) when is_tuple(value),
    do: {:tuple, value |> Tuple.to_list() |> Enum.map(&canonical/1)}

  defp canonical(value), do: value
end
