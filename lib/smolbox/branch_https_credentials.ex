defmodule SmolBox.BranchHTTPSCredentials do
  @moduledoc """
  Host resolver for held-branch HTTPS Bearer tokens.

  The worker's `:branch_https_credentials` option is `{module, context}`. Resolve
  only an explicitly authorized child and destination. The request identifies the
  scope, child ID, opaque worker machine name, and approved HTTPS hostname. Return
  `:error` to deny the request. The token is transient and must never be logged.
  """
  alias SmolBox.{Error, NetworkPolicy}

  @type request :: %{
          scope: String.t(),
          id: String.t(),
          machine_name: String.t(),
          host: String.t()
        }
  @callback resolve(request(), context :: term()) :: {:ok, String.t()} | :error

  @binding "smolbox-branch-https"

  @doc false
  def configured?(nil, _worker, _version), do: true

  def configured?({module, _context}, worker, "1.34.0") when is_atom(module) do
    secure_transport?(worker) and resolver?({module, nil})
  end

  def configured?(_, _, _), do: false

  @doc false
  def resolver?({module, _context}) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :resolve, 2)

  def resolver?(_), do: false

  @doc false
  def source?(%{checkpointable: true, profile: %{network: network}}), do: network?(network)
  def source?(_), do: false

  @doc false
  def child?(%{
        branch: %{spec: %{hold: true}},
        spec: %{branch_static_egress: false, profile: profile}
      }),
      do: network?(profile.network)

  def child?(_), do: false

  @doc false
  def secure_transport?(worker),
    do: is_binary(worker.unix_socket) or String.starts_with?(worker.base_url, "https://")

  @doc false
  def network?(%NetworkPolicy{hosts: [_host], cidrs: []}), do: true
  def network?(_), do: false

  @doc false
  def policy(%NetworkPolicy{hosts: [host]}) do
    %{
      "credentials" => [
        %{
          "name" => @binding,
          "environment_variable" => "SMOLBOX_BRANCH_HTTPS_TOKEN",
          "allowed_hosts" => [host],
          "set_header" => "authorization"
        }
      ]
    }
  end

  @doc false
  def resolve({module, context}, %{spec: %{profile: %{network: %{hosts: [host]}}}} = child) do
    request = child |> Map.take([:scope, :id, :machine_name]) |> Map.put(:host, host)

    case module.resolve(request, context) do
      {:ok, token} when is_binary(token) and byte_size(token) in 1..2048 ->
        if token?(token),
          do: {:ok, token},
          else: unavailable()

      _ ->
        unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def resolve(_, _), do: unavailable()

  @doc false
  def token?(token) when is_binary(token) and byte_size(token) in 1..2048,
    do: Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, token)

  def token?(_), do: false

  @doc false
  def values(token), do: %{"values" => %{@binding => "Bearer " <> token}}

  @doc false
  def unavailable, do: {:error, %Error{category: :authentication, operation: :branch}}
end
