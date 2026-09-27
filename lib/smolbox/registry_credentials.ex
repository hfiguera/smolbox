defmodule SmolBox.RegistryCredentials do
  @moduledoc """
  Host-owned registry credential resolver for prepared sources and publication.

  Configure `{module, context}` as a worker's `:registry_credentials`. Sources
  contain only a safe `credential_ref`; implementations retrieve its current
  scoped bearer token with `fetch(context, reference)`. Rotation of the token
  does not change the source identity. Changing the reference does.

  Tokens stay within the bounded worker operation. SmolBox does not persist
  them, return them as results, or forward resolver error details. Implementations
  must also avoid logging secrets. A nil source reference omits the request token
  and uses upstream's operator-configured registry authentication instead.

  Export destinations resolve a pre-scoped OCI bearer with read and push rights.
  Unlike prepared-source identity tokens, publication does not exchange this token
  through an authentication service. Use distinct references where needed.

  This is separate from worker API authentication and guest workload credentials.
  The OCI create/pull endpoints have no corresponding per-request token field.
  """
  alias SmolBox.{Error, Source, Validation}

  @callback fetch(term(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc false
  def valid?(nil), do: true

  def valid?({module, _context}),
    do: is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :fetch, 2)

  def valid?(_resolver), do: false

  @doc false
  def resolve(_resolver, %Source{credential_ref: nil}), do: {:ok, []}

  def resolve({module, context}, %Source{kind: :registry, credential_ref: reference}) do
    case module.fetch(context, reference) do
      {:ok, token} ->
        if token?(token),
          do: {:ok, [identity_token: token]},
          else: invalid()

      _failure ->
        invalid()
    end
  rescue
    _failure -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def resolve(_resolver, _source), do: invalid()
  @doc false
  def publication({module, context}, reference) do
    case module.fetch(context, reference) do
      {:ok, token} ->
        if token?(token), do: {:ok, token}, else: invalid()

      _failure ->
        invalid()
    end
  rescue
    _failure -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def publication(_resolver, _reference), do: invalid()

  @doc false
  def token?(token),
    do:
      Validation.text?(token, 16_384) and byte_size(token) > 0 and
        Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, token)

  defp invalid, do: {:error, %Error{category: :authentication, operation: :registry_credentials}}
end
