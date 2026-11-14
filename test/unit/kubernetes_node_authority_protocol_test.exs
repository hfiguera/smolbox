defmodule SmolBox.KubernetesNodeAuthorityProtocolTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.{CleanupProof, Observation}
  alias SmolBox.Kubernetes.NodeAuthority.{JSON, Protocol}
  alias SmolBox.Test.NodeAuthority, as: Fixture

  @budget %Budget{timeout_ms: 5000, max_request_bytes: 65_544, max_response_bytes: 65_544}

  setup do
    {:ok, context} = Fixture.context()
    receipt = Fixture.receipt()
    %{vectors: Fixture.vectors(), context: context, receipt: receipt, binding: receipt.binding}
  end

  test "canonical JSON and digests match every frozen cross-language vector", c do
    for {field, canonical, digest} <- [
          {"configuration", "configuration_canonical",
           c.vectors["identity_fields"]["configuration_sha256"]},
          {"identity_fields", "identity_canonical", c.vectors["authority_generation"]},
          {"receipt", "receipt_canonical", c.vectors["receipt_sha256"]}
        ] do
      assert {:ok, bytes} = JSON.encode(c.vectors[field])
      assert bytes == c.vectors[canonical]
      assert {:ok, ^digest} = JSON.digest(c.vectors[field])
      assert {:ok, value} = JSON.decode(bytes)
      assert value == c.vectors[field]
    end
  end

  test "all three requests match the frozen schema and cleanup digest", c do
    for {action, argument} <- [check: nil, capture: c.receipt.pod_uid, cleanup: c.receipt] do
      vector = c.vectors["requests"][Atom.to_string(action)]
      budget = %{@budget | timeout_ms: vector["timeout_ms"]}

      assert {:ok, request, bytes} =
               Protocol.request(action, c.binding, argument, c.context, budget, vector["nonce"])

      assert request == vector
      assert {:ok, ^request} = JSON.decode(bytes)
    end
  end

  test "successful vectors project current typed evidence and original receipt", c do
    for action <- ~w(check capture cleanup) do
      request = c.vectors["requests"][action]
      {:ok, bytes} = JSON.encode(c.vectors["successes"][action])
      assert {:ok, value} = Protocol.response(bytes, request, c.binding, c.receipt, 1100)

      case action do
        "capture" ->
          assert %Observation{} = value

        "cleanup" ->
          assert %CleanupProof{receipt: receipt, version: 3} = value
          assert receipt == c.receipt
          assert CleanupProof.releasable?(value, receipt)

        "check" ->
          assert value == %{
                   complete_history: true,
                   idle: true,
                   observer_epoch: c.context.authority_generation
                 }
      end
    end
  end

  test "response identity is compared against the original request", c do
    for key <- ~w(nonce action binding_generation authority_generation verifier_manifest_sha256) do
      response = put_in(c.vectors["successes"]["capture"][key], "f" <> String.duplicate("e", 63))
      {:ok, body} = JSON.encode(response["successes"]["capture"])

      assert {:error, :protocol} =
               Protocol.response(body, c.vectors["requests"]["capture"], c.binding, nil, 1100)
    end
  end

  test "exact nested schemas, journal identity and rejection envelopes fail closed", c do
    success = c.vectors["successes"]["check"]

    for value <- [
          Map.put(success, "unknown", nil),
          Map.delete(success, "nonce"),
          Map.put(success, "version", 2),
          put_in(success, ["journal", "history_epoch"], c.context.authority_generation),
          put_in(success, ["journal", "watermark"], 4097),
          put_in(success, ["value", "unexpected"], nil)
        ] do
      {:ok, body} = JSON.encode(value)

      assert {:error, _} =
               Protocol.response(body, c.vectors["requests"]["check"], c.binding, nil, 1100)
    end

    rejection = c.vectors["rejections"]["check"]

    for value <- [
          Map.put(rejection, "error", "private /etc/token"),
          Map.put(rejection, "value", %{}),
          Map.put(rejection, "journal", %{}),
          Map.put(rejection, "error", [])
        ] do
      {:ok, body} = JSON.encode(value)

      assert {:error, :protocol} =
               Protocol.response(body, c.vectors["requests"]["check"], c.binding, nil, 1100)
    end
  end

  test "approved rejection codes map only to bounded errors", c do
    for {code, category} <- [
          {"invalid_request", :protocol},
          {"identity_conflict", :identity_conflict},
          {"unavailable", :identity_conflict},
          {"expired", :expired},
          {"output_limit", :output_limit}
        ] do
      {:ok, body} = c.vectors["rejections"]["check"] |> Map.put("error", code) |> JSON.encode()

      assert {:error, ^category} =
               Protocol.response(body, c.vectors["requests"]["check"], c.binding, nil, 1100)
    end
  end

  test "five-second dispatch freshness rejects future and stale node clocks", c do
    {:ok, body} = JSON.encode(c.vectors["successes"]["capture"])
    request = c.vectors["requests"]["capture"]

    for now <- [999, 6001] do
      assert {:error, :identity_conflict} = Protocol.response(body, request, c.binding, nil, now)
    end

    assert {:ok, _} = Protocol.response(body, request, c.binding, nil, 6000)
  end

  test "cleanup never substitutes receipts or downgrades proof authority", c do
    response = c.vectors["successes"]["cleanup"]

    for value <- [
          put_in(response, ["value", "version"], 1),
          put_in(response, ["value", "version"], 2),
          put_in(response, ["value", "observed_at_ms"], 999),
          put_in(response, ["value", "api_absent"], false),
          put_in(response, ["value", "absent_shares"], []),
          put_in(response, ["value", "receipt"], c.vectors["receipt"])
        ] do
      {:ok, body} = JSON.encode(value)

      assert {:error, _} =
               Protocol.response(
                 body,
                 c.vectors["requests"]["cleanup"],
                 c.binding,
                 c.receipt,
                 1100
               )
    end

    {:ok, body} = JSON.encode(response)

    assert {:error, _} =
             Protocol.response(body, c.vectors["requests"]["cleanup"], c.binding, c.receipt, 1000)
  end

  test "old epochs and invalid capture identities fail before transport", c do
    for uid <- ["pod-original", "../pod", "UPPERCASE-UID", <<255>>, nil] do
      assert {:error, :identity_conflict} =
               Protocol.request(
                 :capture,
                 c.binding,
                 uid,
                 c.context,
                 @budget,
                 String.duplicate("a", 64)
               )
    end

    old = %{
      c.receipt
      | observation: %{
          c.receipt.observation
          | observer_epoch: c.vectors["identity_fields"]["history_epoch"]
        }
    }

    assert {:error, :identity_conflict} =
             Protocol.request(
               :cleanup,
               c.binding,
               old,
               c.context,
               @budget,
               String.duplicate("a", 64)
             )
  end

  test "the request grant includes framing and cannot expand the response grant", c do
    nonce = c.vectors["requests"]["check"]["nonce"]
    assert {:ok, _, bytes} = Protocol.request(:check, c.binding, nil, c.context, @budget, nonce)
    exact = %{@budget | max_request_bytes: byte_size(bytes) + 8}
    assert {:ok, _, _} = Protocol.request(:check, c.binding, nil, c.context, exact, nonce)

    assert {:error, :output_limit} =
             Protocol.request(
               :check,
               c.binding,
               nil,
               c.context,
               %{exact | max_request_bytes: exact.max_request_bytes - 1},
               nonce
             )

    assert {:error, :output_limit} =
             Protocol.request(
               :check,
               c.binding,
               nil,
               c.context,
               %{@budget | max_response_bytes: 8},
               nonce
             )

    assert {:ok, limited, _} =
             Protocol.request(
               :check,
               c.binding,
               nil,
               c.context,
               %{@budget | timeout_ms: 60_000, max_response_bytes: 1_000_000},
               nonce
             )

    assert limited["timeout_ms"] == 30_000 and limited["max_response_bytes"] == 65_544
  end

  test "duplicate decoded keys, non-ASCII, floats, huge integers and parser depth reject" do
    for bytes <- [
          ~s({"v":1,"v":1}),
          ~S({"v":1,"\u0076":1}),
          ~s({"nested":{"v":1,"v":1}}),
          ~s({"v":1.0}),
          ~s({"v":NaN}),
          ~S({"v":"\u0000"}),
          ~S({"v":"\u00e9"}),
          ~s({"v":9223372036854775808}),
          ~s({"v":-9223372036854775809}),
          String.duplicate("9", 10_000),
          String.duplicate("[", 25) <> "0" <> String.duplicate("]", 25)
        ] do
      assert :error = JSON.decode(bytes)
    end

    assert {:ok, %{"v" => -9_223_372_036_854_775_808}} =
             JSON.decode(~s({"v":-9223372036854775808}))

    assert {:ok, %{"v" => 9_223_372_036_854_775_807}} = JSON.decode(~s({"v":9223372036854775807}))
    nested = String.duplicate("[", 24) <> "0" <> String.duplicate("]", 24)
    assert {:ok, _} = JSON.decode(nested)
    assert {:ok, %{"v" => "[{\"}"}} = JSON.decode(~S({"v":"[{\"}"}))
  end

  test "canonical serialization admits exactly 65536 bytes and bounded collections" do
    assert {:ok, body} = JSON.encode(%{"v" => String.duplicate("x", 65_528)})
    assert byte_size(body) == 65_536
    assert {:ok, _} = JSON.decode(body)
    assert :error = JSON.encode(%{"v" => String.duplicate("x", 65_529)})
    assert :error = JSON.decode(body <> " ")
    assert {:ok, _} = JSON.encode(List.duplicate(0, 4096))
    assert :error = JSON.encode(List.duplicate(0, 4097))

    for value <- [
          %{"" => nil},
          %{String.duplicate("k", 129) => nil},
          %{a: 1},
          1.0,
          %Jason.OrderedObject{values: [{"same", 1}, {"same", 2}]}
        ] do
      assert :error = JSON.encode(value)
    end

    key = "authority_unknown_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert {:ok, _} = JSON.decode(Jason.encode!(%{key => true}))
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end
end
