defmodule SmolBox.LogOptions do
  @moduledoc false
  alias SmolBox.{Error, Validation}

  def validate(options) do
    with true <-
           Validation.keys?(options, [:tail, :follow, :timeout_ms, :max_output_bytes, :on_event]),
         tail = Keyword.get(options, :tail, 100),
         follow = Keyword.get(options, :follow, false),
         timeout = Keyword.get(options, :timeout_ms, 30_000),
         max = Keyword.get(options, :max_output_bytes, 1_048_576),
         callback = Keyword.get(options, :on_event),
         true <- Validation.integer?(tail, 0, 10_000),
         true <- is_boolean(follow),
         true <- Validation.integer?(timeout, 1000, 300_000),
         true <- Validation.integer?(max, 1, 8_388_608),
         true <- is_nil(callback) or is_function(callback, 1),
         true <- not follow or is_function(callback, 1) do
      {:ok, %{tail: tail, follow: follow, timeout_ms: timeout, max: max, callback: callback}}
    else
      _invalid -> {:error, %Error{category: :validation, operation: :logs}}
    end
  end
end
