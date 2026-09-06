defmodule SmolBox.ErrorTest do
  use ExUnit.Case, async: true

  test "uncertain transport errors communicate uncertainty without remote payloads" do
    error =
      SmolBox.Error.exception(
        category: :transport,
        operation: :exec,
        evidence: :dispatch_uncertain
      )

    assert Exception.message(error) == "SmolBox exec failed: transport (dispatch_uncertain)"
  end
end
