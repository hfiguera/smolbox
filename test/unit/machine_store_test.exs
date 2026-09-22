defmodule SmolBox.MachineStoreTest do
  use ExUnit.Case, async: true
  alias SmolBox.Store.{MachineContract, Memory}

  for scenario <- [
        :acceptance,
        :shared_capacity,
        :command_admission,
        :lifecycle_race,
        :completion,
        :uncertainty,
        :takeover
      ] do
    test "memory machine contract: #{scenario}" do
      store = start_supervised!(Memory)
      apply(MachineContract, unquote(scenario), [Memory, store])
    end
  end
end
