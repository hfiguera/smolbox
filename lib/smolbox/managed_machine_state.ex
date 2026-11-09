defmodule SmolBox.ManagedMachineState do
  @moduledoc false

  def key(record), do: {record.scope, record.id}

  def idle?(record),
    do: record.active_execution == nil and record.operation == nil and record.phase == nil
end
