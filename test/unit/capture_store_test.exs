defmodule SmolBox.CaptureStoreTest do
  use ExUnit.Case, async: true
  alias SmolBox.Store.{CaptureContract, Codec, Memory}
  setup do: %{store: start_supervised!(Memory)}

  for scenario <- [:admission, :cancellation, :unknown, :retention, :competition] do
    test("capture contract #{scenario}", %{store: store},
      do: apply(CaptureContract, unquote(scenario), [Memory, store])
    )
  end

  test "v12 preserves opt-in identity and rejects history smuggling in old envelopes", %{
    store: store
  } do
    m = CaptureContract.running(Memory, store)
    {:ok, m} = CaptureContract.accept(Memory, store, m)
    assert {:ok, <<"smolbox-record-v12\0", body::binary>> = bytes} = Codec.encode(m)
    assert {:ok, ^m} = Codec.decode(bytes)

    for version <- 1..11,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "trailing")
    assert {:error, _} = Codec.encode(%{m | active_capture: nil})
  end
end
