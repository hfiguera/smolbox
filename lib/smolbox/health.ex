defmodule SmolBox.Health do
  @moduledoc """
  Bounded worker health observation from SmolVM's `/health` endpoint.

  The version is reported by the server, not cryptographically attested. Missing
  machine counts indicate unavailable inventory; a successful HTTP status alone
  is insufficient for managed admission. Readiness is a separate blocking-pool
  probe. Neither endpoint certifies host quotas, artifact identity, or isolation.
  """
  alias SmolBox.{Error, Validation}

  @enforce_keys [:version, :total, :running, :uptime_seconds]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: String.t(),
          total: non_neg_integer() | nil,
          running: non_neg_integer() | nil,
          uptime_seconds: non_neg_integer() | nil
        }

  @spec from_wire(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(%{"status" => "ok", "version" => version} = body) do
    with true <- Validation.text?(version, 64),
         {:ok, _version} <- Version.parse(version),
         {:ok, total, running} <- counts(Map.get(body, "machines")),
         uptime = Map.get(body, "uptime_seconds"),
         true <- is_nil(uptime) or Validation.integer?(uptime, 0, 18_446_744_073_709_551_615) do
      {:ok, %__MODULE__{version: version, total: total, running: running, uptime_seconds: uptime}}
    else
      _invalid -> invalid()
    end
  end

  def from_wire(_body), do: invalid()

  defp counts(nil), do: {:ok, nil, nil}

  defp counts(%{"total" => total, "running" => running}) do
    if Validation.integer?(total, 0, 1_000_000) and Validation.integer?(running, 0, total),
      do: {:ok, total, running},
      else: invalid()
  end

  defp counts(_counts), do: invalid()

  defp invalid,
    do: {:error, %Error{category: :protocol, operation: :health}}
end
