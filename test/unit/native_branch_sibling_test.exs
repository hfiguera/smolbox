defmodule SmolBox.NativeBranchSiblingTest do
  use ExUnit.Case, async: true
  alias SmolBox.Store.{Memory, NativeBranchSiblingContract}

  for first <- [:held, :ready, :released],
      second <- [:held, :ready, :released],
      reverse <- [false, true] do
    test "#{first}/#{second} siblings retire independently in reverse=#{reverse} order" do
      NativeBranchSiblingContract.complete(
        Memory,
        start_supervised!(Memory),
        unquote(first),
        unquote(second),
        unquote(reverse)
      )
    end
  end
end
