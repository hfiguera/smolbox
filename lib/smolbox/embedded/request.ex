defmodule SmolBox.Embedded.Request do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.Validation

  @lifecycle ~w(inspect start stop delete)

  def valid?(operation, budget_ms) do
    Validation.integer?(budget_ms, 1, 86_400_000) and operation?(operation, budget_ms)
  end

  def command_valid?(command), do: command?(command)

  defp operation?(
         %{
           "operation" => "qualify_creation",
           "artifact" => artifact,
           "resources" => resources,
           "user" => user
         } = operation,
         budget
       ),
       do:
         Shape.keys?(operation, ~w(operation artifact resources user)) and budget <= 30_000 and
           artifact?(artifact) and Shape.resources?(resources) and
           Shape.optional?(user, &Shape.text?(&1, 16_384, false))

  defp operation?(%{"operation" => "create", "create" => create} = operation, _budget),
    do: Shape.keys?(operation, ~w(operation create)) and create?(create)

  defp operation?(%{"operation" => "inspect_creation", "create" => create} = operation, budget),
    do: Shape.keys?(operation, ~w(operation create)) and budget <= 30_000 and create?(create)

  defp operation?(
         %{"operation" => "exec", "receipt" => receipt, "command" => command} = operation,
         _budget
       ),
       do:
         Shape.keys?(operation, ~w(operation receipt command)) and Shape.receipt?(receipt) and
           command?(command)

  defp operation?(%{"operation" => name, "receipt" => receipt} = operation, _budget)
       when name in @lifecycle,
       do: Shape.keys?(operation, ~w(operation receipt)) and Shape.receipt?(receipt)

  defp operation?(
         %{"operation" => "read_file", "receipt" => receipt, "options" => options} = operation,
         budget
       ),
       do:
         Shape.keys?(operation, ~w(operation receipt options)) and Shape.receipt?(receipt) and
           budget <= 600_000 and file?(options) and options["mode"] == nil

  defp operation?(
         %{
           "operation" => "write_file",
           "receipt" => receipt,
           "options" => options,
           "total_bytes" => total
         } = operation,
         budget
       ),
       do:
         Shape.keys?(operation, ~w(operation receipt options total_bytes)) and
           Shape.receipt?(receipt) and
           budget <= 600_000 and file?(options) and
           Validation.integer?(total, 0, options["max_bytes"])

  defp operation?(_operation, _budget), do: false

  defp create?(create) do
    Shape.keys?(create, ~w(name owner_token incarnation artifact resources labels)) and
      Shape.id?(create["name"]) and Shape.hex?(create["owner_token"], 64) and
      Shape.hex?(create["incarnation"], 32) and artifact?(create["artifact"]) and
      Shape.resources?(create["resources"]) and labels?(create["labels"])
  end

  defp artifact?(artifact),
    do:
      Shape.keys?(artifact, ~w(path sha256 max_bytes guest_platform)) and
        Shape.path?(artifact["path"]) and Validation.digest?(artifact["sha256"]) and
        Validation.integer?(artifact["max_bytes"], 1, 34_359_738_368) and
        artifact["guest_platform"] in ["linux/arm64", "linux/amd64"]

  defp labels?(labels),
    do:
      is_map(labels) and map_size(labels) <= 64 and
        Enum.all?(labels, fn {key, value} ->
          Shape.text?(key, 128, false) and not String.starts_with?(key, "smolbox.") and
            Shape.text?(value, 1024, true)
        end)

  defp command?(command) do
    Shape.keys?(command, ~w(argv env workdir user max_output_bytes)) and
      argv?(command["argv"]) and environment?(command["env"]) and
      command_bytes(command) <= 131_072 and
      Shape.optional?(command["workdir"], &Shape.path?/1) and
      Shape.optional?(command["user"], &Shape.text?(&1, 16_384, false)) and
      Validation.integer?(command["max_output_bytes"], 1, 16_777_216)
  end

  defp argv?([first | rest] = argv),
    do:
      Validation.list?(argv, 256) and Shape.text?(first, 16_384, false) and
        Enum.all?(rest, &Shape.text?(&1, 16_384, true))

  defp argv?(_argv), do: false

  defp environment?(environment),
    do:
      is_map(environment) and map_size(environment) <= 256 and
        Enum.all?(environment, fn {key, value} ->
          Shape.text?(key, 16_384, false) and not String.contains?(key, "=") and
            Shape.text?(value, 16_384, true)
        end)

  defp command_bytes(command),
    do:
      Enum.reduce(command["argv"], 0, fn value, total -> total + byte_size(value) end) +
        Enum.reduce(command["env"], 0, fn {key, value}, total ->
          total + byte_size(key) + byte_size(value)
        end)

  defp file?(options),
    do:
      Shape.keys?(options, ~w(guest_path max_bytes mode)) and Shape.path?(options["guest_path"]) and
        options["guest_path"] != "/" and not String.ends_with?(options["guest_path"], "/") and
        Validation.integer?(options["max_bytes"], 1, 16_777_216) and
        Shape.optional?(options["mode"], &Validation.integer?(&1, 0, 511))
end
