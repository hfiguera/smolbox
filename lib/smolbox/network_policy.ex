defmodule SmolBox.NetworkPolicy do
  @moduledoc """
  Explicit outbound allowlist for smolvm 1.16.0. Offline remains the default.

  Hosts are lowercase DNS names; a name also allows its subdomains upstream.
  smolvm learns destination IPs from DNS responses, so this is not HTTP hostname,
  URL, TLS identity or port filtering. Other services on an allowed IP can be
  reachable. CIDRs and learned IPs are combined. DNS is needed for host policies.

  Policies are trusted operator configuration, never guest-selected authority.
  Approve a new profile revision when changing access. No inbound ports, host
  mounts or automatic image pulls are enabled. Upstream and deployment controls
  can deny additional destinations; an allowlist is not proof of reachability.

  The upstream DNS gateway and authenticated rollout endpoint are infrastructure
  exceptions to the allowlist. The server's strict egress floor is deployment
  configuration, not a guarantee attested by this struct. See the controlled
  network access guide for the tested platform and protocol boundaries.
  """

  alias SmolBox.{Error, Validation}

  defstruct hosts: [], cidrs: []
  @type t :: %__MODULE__{hosts: [String.t()], cidrs: [String.t()]}

  @doc """
  Build a nonempty allowlist with at most 32 hosts and 32 canonical CIDRs.

  Use `hosts: ["api.example.com"]` or `cidrs: ["203.0.113.0/24"]`, or both.
  Hosts exclude URLs, wildcards, IP literals and trailing dots. CIDRs require
  network-aligned IPv4/IPv6 addresses and a nonzero prefix. Duplicate entries
  are rejected; order is canonicalized for durable identity comparisons.
  Bare networking flags and empty policies are rejected; use `:offline` instead.
  Broad CIDRs grant broad access; operators must review the complete policy.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(options, [:hosts, :cidrs]) do
      policy = struct!(__MODULE__, options)

      if entries?(policy) do
        {:ok, %{policy | hosts: Enum.sort(policy.hosts), cidrs: Enum.sort(policy.cidrs)}}
      else
        invalid()
      end
    else
      invalid()
    end
  end

  @doc "Revalidate a canonical policy or the offline sentinel."
  @spec valid?(term()) :: boolean()
  def valid?(:offline), do: true

  def valid?(%__MODULE__{} = policy) do
    Validation.struct_shape?(policy, __MODULE__) and entries?(policy) and
      policy.hosts == Enum.sort(policy.hosts) and policy.cidrs == Enum.sort(policy.cidrs)
  end

  def valid?(_policy), do: false

  @doc false
  @spec to_wire(:offline | t()) :: map()
  def to_wire(:offline), do: %{"network" => false}

  def to_wire(%__MODULE__{} = policy) do
    %{
      "network" => true,
      "networkBackend" => "virtio-net",
      "allowedHosts" => policy.hosts,
      "allowedCidrs" => policy.cidrs
    }
  end

  @doc false
  @spec from_wire(term()) :: {:ok, :offline | t()} | {:error, Error.t()}
  def from_wire(%{"network" => false} = wire) do
    if wire["allowedHosts"] in [nil, []] and wire["allowedCidrs"] in [nil, []],
      do: {:ok, :offline},
      else: invalid()
  end

  def from_wire(%{
        "network" => true,
        "networkBackend" => "virtio-net",
        "allowedHosts" => hosts,
        "allowedCidrs" => cidrs
      }),
      do: new(hosts: hosts, cidrs: cidrs)

  def from_wire(_wire), do: invalid()

  defp entries?(policy) do
    entries?(policy.hosts, &host?/1) and entries?(policy.cidrs, &cidr?/1) and
      (policy.hosts != [] or policy.cidrs != [])
  end

  defp entries?(values, predicate) do
    Validation.list?(values, 32) and Enum.all?(values, predicate) and
      length(values) == MapSet.size(MapSet.new(values))
  end

  defp host?(host) when is_binary(host) and byte_size(host) <= 253 do
    labels = String.split(host, ".")

    match?([_, _ | _], labels) and
      Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)) and
      match?({:error, _reason}, :inet.parse_strict_address(String.to_charlist(host)))
  end

  defp host?(_host), do: false

  defp cidr?(cidr) when is_binary(cidr) and byte_size(cidr) <= 49 do
    with true <- String.valid?(cidr),
         [address, prefix] <- String.split(cidr, "/"),
         {bits, ""} <- Integer.parse(prefix),
         true <- Integer.to_string(bits) == prefix,
         {:ok, tuple} <- :inet.parse_strict_address(String.to_charlist(address)),
         size = tuple_size(tuple) * if(tuple_size(tuple) == 4, do: 8, else: 16),
         true <- bits in 1..size,
         true <- address == to_string(:inet.ntoa(tuple)) do
      width = if tuple_size(tuple) == 4, do: 8, else: 16
      number = Enum.reduce(Tuple.to_list(tuple), 0, &(Bitwise.bsl(&2, width) + &1))
      rem(number, Integer.pow(2, size - bits)) == 0
    else
      _invalid -> false
    end
  end

  defp cidr?(_cidr), do: false
  defp invalid, do: {:error, %Error{category: :validation, operation: :profile}}
end
