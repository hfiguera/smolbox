defmodule SmolBox.Identity do
  @moduledoc """
  Opaque machine names for an exclusively managed worker namespace.

  Persist the generated name before creation. Names have 100 random bits and do
  not embed user identifiers. A namespace match identifies candidates for an
  orphan report, never authorization to delete. Creation evidence and exclusive
  worker ownership are still required; SmolVM exposes no immutable generation ID.
  """

  alias SmolBox.Error

  @spec machine_name(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def machine_name(namespace) do
    if namespace?(namespace) do
      suffix =
        13
        |> :crypto.strong_rand_bytes()
        |> Base.encode32(case: :lower, padding: false)
        |> binary_part(0, 20)

      {:ok, namespace <> "-" <> suffix}
    else
      {:error, %Error{category: :validation, operation: :identity}}
    end
  end

  @doc "Select only syntactically valid orphan-report candidates; this does not prove ownership."
  @spec candidate?(term(), term()) :: boolean()
  def candidate?(namespace, name) do
    namespace?(namespace) and is_binary(name) and
      String.starts_with?(name, namespace <> "-") and
      byte_size(name) == byte_size(namespace) + 21 and
      Regex.match?(~r/\A[a-z0-9]+-[a-z2-7]{20}\z/, name)
  end

  defp namespace?(value) do
    is_binary(value) and byte_size(value) in 1..10 and Regex.match?(~r/\A[a-z][a-z0-9]*\z/, value)
  end
end
