defmodule SmolBox.Command do
  @moduledoc """
  A bounded argument-vector command. No shell is inserted by SmolBox.

  Timeouts are positive whole seconds, matching SmolVM's `timeoutSecs` field.
  The initial maximum is five minutes; managed execution can impose an earlier
  absolute deadline. `stdin` must be UTF-8 and is only supported by buffered
  execution in SmolVM 1.14.1. Arbitrary binary data belongs in staged files.
  """

  alias SmolBox.{Error, Files}

  @enforce_keys [:argv]
  @derive {Inspect, only: [:timeout_secs]}
  defstruct [:argv, :stdin, :user, env: [], workdir: "/workspace", timeout_secs: 30]

  @type t :: %__MODULE__{
          argv: [String.t()],
          stdin: String.t() | nil,
          user: String.t() | nil,
          env: [{String.t(), String.t()}],
          workdir: String.t(),
          timeout_secs: pos_integer()
        }

  @doc "Validate arguments and reject duplicate or unknown options."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(argv, options \\ []) do
    if valid_options?(options) do
      command = struct!(__MODULE__, Keyword.put(options, :argv, argv))
      with :ok <- validate(command), do: {:ok, command}
    else
      invalid()
    end
  end

  @doc "Revalidate a struct before transport, including manually constructed values."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = command) do
    if SmolBox.Validation.struct_shape?(command, __MODULE__),
      do: validate_fields(command),
      else: invalid()
  end

  def validate(_command), do: invalid()

  @doc "Return the exact camelCase request fields after validation."
  @spec to_wire(t()) :: {:ok, map()} | {:error, Error.t()}
  def to_wire(command) do
    with :ok <- validate(command) do
      wire = %{
        "command" => command.argv,
        "env" =>
          Enum.map(command.env, fn {name, value} -> %{"name" => name, "value" => value} end),
        "workdir" => command.workdir,
        "timeoutSecs" => command.timeout_secs,
        "background" => false,
        "secrets" => %{}
      }

      {:ok, wire |> optional("stdin", command.stdin) |> optional("user", command.user)}
    end
  end

  defp validate_fields(command) do
    checks = [
      valid_argv?(command.argv),
      valid_env?(command.env),
      valid_stdin?(command.stdin),
      valid_user?(command.user),
      valid_timeout?(command.timeout_secs),
      Files.validate_path(command.workdir) == :ok
    ]

    if Enum.all?(checks), do: :ok, else: invalid()
  end

  defp valid_options?(options) do
    within_limit?(options, 5) and Keyword.keyword?(options) and
      Enum.all?(Keyword.keys(options), &(&1 in [:stdin, :user, :env, :workdir, :timeout_secs])) and
      length(Keyword.keys(options)) == MapSet.size(MapSet.new(Keyword.keys(options)))
  end

  defp valid_argv?([first | _rest] = argv) do
    within_limit?(argv, 256) and is_binary(first) and first != "" and
      Enum.all?(argv, &text?(&1, 16_384)) and
      Enum.reduce(argv, 0, fn arg, size -> size + byte_size(arg) end) <= 65_536
  end

  defp valid_argv?(_argv), do: false

  defp valid_env?(env) do
    within_limit?(env, 64) and Enum.all?(env, &valid_env_entry?/1) and
      length(env) == MapSet.size(MapSet.new(env, &elem(&1, 0)))
  end

  defp valid_env_entry?({name, value}) do
    text?(name, 128) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) and
      text?(value, 8192)
  end

  defp valid_env_entry?(_entry), do: false
  defp valid_stdin?(nil), do: true

  defp valid_stdin?(stdin),
    do: is_binary(stdin) and byte_size(stdin) <= 65_536 and String.valid?(stdin)

  defp valid_user?(nil), do: true
  defp valid_user?(user), do: text?(user, 128) and user != ""
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout in 1..300

  defp text?(value, limit) do
    is_binary(value) and byte_size(value) <= limit and String.valid?(value) and
      not String.contains?(value, "\0")
  end

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp within_limit?([], _remaining), do: true

  defp within_limit?([_head | tail], remaining) when remaining > 0,
    do: within_limit?(tail, remaining - 1)

  defp within_limit?(_value, _remaining), do: false

  defp invalid, do: {:error, %Error{category: :validation, operation: :command}}
end
