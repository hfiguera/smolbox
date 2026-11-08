defmodule SmolBox.Store.CodecMaterial do
  @moduledoc false
  alias SmolBox.Backend.Assignment
  alias SmolBox.Store.CodecFields

  @defaults %{Assignment => [version: 1]}

  def background_launches, do: 1
  def streaming_commands, do: 1
  def terminal_sessions, do: 1

  def required?(%{backend_assignment: %Assignment{version: 2}}), do: true
  def required?(_record), do: false
  def strip(record), do: CodecFields.transform(record, @defaults, :strip)
  def upgrade(record), do: CodecFields.transform(record, @defaults, :upgrade)
end
