defmodule SmolBox.DocumentationTest do
  use ExUnit.Case, async: true

  doctest SmolBox.Worker
  doctest SmolBox.Command
  doctest SmolBox.Profile
  doctest SmolBox.ExecutionSpec
end
