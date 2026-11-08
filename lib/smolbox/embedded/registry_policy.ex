defmodule SmolBox.Embedded.RegistryPolicy do
  @moduledoc """
  Explicit host registry preparation allowance for an embedded target.

  Download and retained cache allowances are separate from machine disk capacity.
  `token_realms` maps safe credential references to exact approved HTTPS exchange
  endpoints. It contains no tokens; the worker credential resolver supplies them
  per operation. No cache eviction is implied by these limits.
  """
  alias SmolBox.{Error, Validation}
  @enforce_keys [:max_download_bytes, :max_cache_bytes, :max_cache_files]
  @derive {Inspect, only: [:max_download_bytes, :max_cache_bytes, :max_cache_files]}
  defstruct @enforce_keys ++ [token_realms: %{}]

  @type t :: %__MODULE__{
          max_download_bytes: pos_integer(),
          max_cache_bytes: pos_integer(),
          max_cache_files: pos_integer(),
          token_realms: %{String.t() => String.t()}
        }

  def new(options) do
    with true <- Validation.keys?(options, @enforce_keys ++ [:token_realms]),
         values = Map.new(options),
         true <- Enum.all?(@enforce_keys, &Map.has_key?(values, &1)),
         policy = struct!(__MODULE__, values),
         :ok <- validate(policy) do
      {:ok, policy}
    else
      _invalid -> invalid()
    end
  end

  def validate(%__MODULE__{} = policy) do
    if Validation.struct_shape?(policy, __MODULE__) and
         Validation.integer?(policy.max_download_bytes, 1, 34_359_738_368) and
         Validation.integer?(policy.max_cache_bytes, 1, 68_719_476_736) and
         Validation.integer?(policy.max_cache_files, 1, 1024) and realms?(policy.token_realms),
       do: :ok,
       else: invalid()
  end

  def validate(_policy), do: invalid()

  def catalog?(nil, _sources), do: true

  def catalog?(%__MODULE__{} = policy, sources),
    do:
      validate(policy) == :ok and
        Enum.all?(sources, fn source ->
          source_policy?(source, policy)
        end)

  def catalog?(_policy, _sources), do: false

  def realm?(value) when is_binary(value) and byte_size(value) <= 2048 do
    with true <- String.valid?(value),
         uri = URI.parse(value),
         true <- uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
      uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
        Validation.integer?(uri.port, 1, 65_535) and public_host?(uri.host)
    else
      _invalid -> false
    end
  rescue
    _invalid -> false
  end

  def realm?(_value), do: false

  defp realms?(realms),
    do:
      is_map(realms) and map_size(realms) <= 32 and
        Enum.all?(realms, fn {reference, realm} ->
          Validation.identifier?(reference) and realm?(realm)
        end)

  defp source_policy?(
         %SmolBox.Source{kind: :registry, credential_ref: reference} = source,
         policy
       ),
       do:
         reference == nil or
           (Map.has_key?(policy.token_realms, reference) and public_source?(source))

  defp source_policy?(%SmolBox.Source{}, _policy), do: true
  defp source_policy?(_source, _policy), do: false

  defp public_source?(source),
    do: realm?("https://" <> hd(String.split(source.reference, "/")))

  defp public_host?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {0, 0, 0, 0, 0, 65_535, high, low}} ->
        public_host?(
          Enum.join(
            [
              Bitwise.bsr(high, 8),
              Bitwise.band(high, 255),
              Bitwise.bsr(low, 8),
              Bitwise.band(low, 255)
            ],
            "."
          )
        )

      {:ok, address} ->
        public_address?(address)

      _ ->
        host != "localhost" and not String.ends_with?(host, ".localhost")
    end
  end

  defp public_address?({a, b, _c, _d}),
    do:
      a not in [0, 10, 127] and {a, b} not in [{169, 254}, {192, 168}] and
        not (a == 172 and b in 16..31)

  defp public_address?({a, _, _, _, _, _, _, _} = address),
    do:
      address not in [{0, 0, 0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 1}] and
        Bitwise.band(a, 0xFFC0) != 0xFE80 and Bitwise.band(a, 0xFE00) != 0xFC00

  defp invalid,
    do:
      {:error,
       %Error{
         category: :validation,
         operation: :embedded_registry_policy,
         evidence: :not_dispatched
       }}
end
