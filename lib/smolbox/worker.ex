defmodule SmolBox.Worker do
  @moduledoc """
  Trusted host configuration for a worker control endpoint.

  Remote endpoints require HTTPS and a bearer token. Plain HTTP requires an
  explicit loopback opt-in or a local Unix socket. TLS verification cannot be
  disabled. Credentials are excluded from inspection and never enter job state.
  This configuration does not attest to virtualization readiness or isolation.
  """

  alias SmolBox.Error

  @schema [
    token: [type: :string],
    ca_cert_file: [type: :string],
    unix_socket: [type: :string],
    allow_insecure_loopback: [type: :boolean, default: false],
    connect_timeout_ms: [type: :pos_integer, default: 1000],
    receive_timeout_ms: [type: :pos_integer, default: 15_000],
    pool_timeout_ms: [type: :pos_integer, default: 5000],
    operation_timeout_ms: [type: :pos_integer, default: 30_000],
    max_request_bytes: [type: :pos_integer, default: 1_048_576],
    max_response_bytes: [type: :pos_integer, default: 16_777_216]
  ]

  @enforce_keys [:id, :base_url]
  @derive {Inspect, only: [:id, :base_url]}
  defstruct [
    :id,
    :base_url,
    :token,
    :ca_cert_file,
    :unix_socket,
    allow_insecure_loopback: false,
    connect_timeout_ms: 1000,
    receive_timeout_ms: 15_000,
    pool_timeout_ms: 5000,
    operation_timeout_ms: 30_000,
    max_request_bytes: 1_048_576,
    max_response_bytes: 16_777_216
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          base_url: String.t(),
          token: String.t() | nil,
          ca_cert_file: String.t() | nil,
          unix_socket: String.t() | nil,
          allow_insecure_loopback: boolean(),
          connect_timeout_ms: pos_integer(),
          receive_timeout_ms: pos_integer(),
          pool_timeout_ms: pos_integer(),
          operation_timeout_ms: pos_integer(),
          max_request_bytes: pos_integer(),
          max_response_bytes: pos_integer()
        }

  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, base_url, options \\ []) do
    with true <- Keyword.keyword?(options),
         {:ok, options} <- NimbleOptions.validate(options, @schema),
         worker = struct!(__MODULE__, [id: id, base_url: base_url] ++ options),
         :ok <- validate(worker) do
      {:ok, %{worker | base_url: String.trim_trailing(base_url, "/")}}
    else
      _invalid -> invalid()
    end
  end

  @doc "Revalidate configuration before using credentials or starting network I/O."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = worker) do
    with true <- identifier?(worker.id),
         {:ok, uri} <- endpoint(worker.base_url),
         true <- authorized_transport?(uri, worker),
         true <- valid_bounds?(worker),
         true <- certificate?(worker.ca_cert_file) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_worker), do: invalid()

  defp identifier?(id) do
    is_binary(id) and byte_size(id) <= 64 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, id)
  end

  defp endpoint(url) when is_binary(url) and byte_size(url) <= 2048 do
    with {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- uri.userinfo == nil and uri.query == nil and uri.fragment == nil,
         true <- uri.path in [nil, "", "/"] do
      {:ok, uri}
    else
      _invalid -> invalid()
    end
  end

  defp endpoint(_url), do: invalid()

  defp authorized_transport?(%URI{scheme: "https"}, worker) do
    worker.unix_socket == nil and token?(worker.token)
  end

  defp authorized_transport?(%URI{scheme: "http", host: host}, worker) do
    host in ["127.0.0.1", "localhost", "::1"] and worker.ca_cert_file == nil and
      (worker.token == nil or token?(worker.token)) and
      ((worker.allow_insecure_loopback == true and worker.unix_socket == nil) or
         socket?(worker.unix_socket))
  end

  defp token?(token) do
    is_binary(token) and Regex.match?(~r/\A[\x21-\x7E]{1,4096}\z/, token)
  end

  defp socket?(socket) do
    is_binary(socket) and byte_size(socket) <= 100 and String.valid?(socket) and
      String.starts_with?(socket, "/") and not String.contains?(socket, "\0")
  end

  defp certificate?(nil), do: true
  defp certificate?(file), do: is_binary(file) and File.regular?(file)

  defp valid_bounds?(worker) do
    Enum.all?(
      [
        worker.connect_timeout_ms,
        worker.receive_timeout_ms,
        worker.pool_timeout_ms,
        worker.operation_timeout_ms
      ],
      &bounded?(&1, 900_000)
    ) and
      bounded?(worker.max_request_bytes, 2_097_152) and
      bounded?(worker.max_response_bytes, 33_554_432)
  end

  defp bounded?(value, max), do: is_integer(value) and value > 0 and value <= max
  defp invalid, do: {:error, %Error{category: :validation, operation: :worker}}
end
