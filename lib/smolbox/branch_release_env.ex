defmodule SmolBox.BranchReleaseEnv do
  @moduledoc false
  alias SmolBox.{Command, Validation}

  def normalize(env) do
    if Command.valid_env?(env) and single_line?(env), do: {:ok, Enum.sort(env)}, else: :error
  end

  def valid?(env), do: normalize(env) == {:ok, env}

  def wire?(env) do
    Validation.list?(env, 64) and env != [] and
      Enum.all?(env, &match?([_, _], &1)) and
      valid?(Enum.map(env, &List.to_tuple/1))
  end

  defp single_line?(env) do
    Enum.reduce(env, 0, fn {name, value}, size ->
      size + byte_size(name) + byte_size(value) + 2
    end) <= 4096 and
      Enum.all?(env, fn {_, value} -> not String.contains?(value, ["\r", "\n"]) end)
  end
end
