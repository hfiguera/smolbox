defmodule SmolBox.Result do
  @moduledoc """
  Observed command output and exit status. A nonzero exit is still an observed result.

  Buffered execution uses `:bytes`; SSE output uses `:lossy_utf8` because SmolVM
  1.14.1 does not preserve arbitrary bytes on that route. This result does not
  assert application success, artifact collection, or machine cleanup.
  """

  alias SmolBox.Error

  @enforce_keys [:exit_code, :stdout, :stderr]
  @derive {Inspect, only: [:exit_code, :encoding]}
  defstruct [:exit_code, :stdout, :stderr, encoding: :bytes]

  @type t :: %__MODULE__{
          exit_code: integer(),
          stdout: binary(),
          stderr: binary(),
          encoding: :bytes | :lossy_utf8
        }

  @doc "Decode byte-exact buffered output; lossy fallback is deliberately unsupported."
  @spec from_wire(term(), pos_integer()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(body, max_output_bytes)

  def from_wire(%{"exitCode" => exit_code, "stdoutB64" => stdout, "stderrB64" => stderr}, max)
      when is_integer(exit_code) and exit_code >= -2_147_483_648 and exit_code <= 2_147_483_647 and
             is_binary(stdout) and is_binary(stderr) and is_integer(max) and max > 0 do
    with :ok <- check_encoded_size(stdout, stderr, max),
         {:ok, out} <- Base.decode64(stdout),
         {:ok, err} <- Base.decode64(stderr),
         :ok <- check_decoded_size(out, err, max) do
      {:ok, %__MODULE__{exit_code: exit_code, stdout: out, stderr: err}}
    else
      :error -> invalid()
      {:error, error} -> {:error, %{error | exit_code: exit_code}}
    end
  end

  def from_wire(_body, _max), do: invalid()

  defp check_encoded_size(stdout, stderr, max) do
    # Two independently padded base64 streams require up to eight padding bytes.
    if byte_size(stdout) + byte_size(stderr) <= div(max + 2, 3) * 4 + 8 do
      :ok
    else
      output_limit()
    end
  end

  defp check_decoded_size(stdout, stderr, max) do
    if byte_size(stdout) + byte_size(stderr) <= max, do: :ok, else: output_limit()
  end

  defp invalid,
    do: {:error, %Error{category: :protocol, operation: :exec, evidence: :dispatch_uncertain}}

  defp output_limit,
    do: {:error, %Error{category: :output_limit, operation: :exec, evidence: :exited}}
end
