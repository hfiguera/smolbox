defmodule SmolBox.Embedded.ProtocolTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Frame, JSON, Protocol, Request}

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!()

  test "native fixtures retain explicit negative completion and observed Exit evidence" do
    assert {:ok, request} = JSON.decode(fixture("exec-request.json"))
    assert Request.valid?(request["operation"], request["budget_ms"])
    assert request["initial_event_credit"] == 64
    assert {:ok, terminal} = Protocol.decode(fixture("exec-terminal.json"))
    assert terminal["outcome"]["completion"] == "native_error"
    assert terminal["outcome"]["observed_exit"] == 0
    assert terminal["outcome"]["dispatch"] == "may_have_dispatched"
  end

  test "fragmented and concatenated frames preserve boundaries with length guarding" do
    {:ok, first} = Frame.encode(fixture("exec-request.json"))
    {:ok, second} = Frame.encode(fixture("exec-terminal.json"))

    {state, frames} =
      for <<byte <- first <> second>>, reduce: {%Frame{}, []} do
        {state, frames} ->
          assert {:ok, next, ready} = Frame.push(state, <<byte>>)
          {next, frames ++ ready}
      end

    assert Frame.complete?(state)
    assert frames == [fixture("exec-request.json"), fixture("exec-terminal.json")]
    assert {:ok, empty, ^frames} = Frame.push(%Frame{}, first <> second)
    assert Frame.complete?(empty)

    for length <- [0, Frame.maximum() + 1, 4_294_967_295] do
      assert :error = Frame.push(%Frame{}, <<length::unsigned-big-32>>)
    end

    assert {:ok, partial, []} = Frame.push(%Frame{}, <<0, 0, 0>>)
    refute Frame.complete?(partial)
    assert {:ok, partial, []} = Frame.push(%Frame{}, <<0, 0, 0, 2, 123>>)
    refute Frame.complete?(partial)
    refute inspect(partial) =~ "123"
  end

  test "duplicate decoded keys, parser depth and integer tokens fail closed" do
    for body <- [
          ~s({"id":1,"id":2}),
          ~s({"receipt":{"owner_token":"secret","owner_token":"other"}}),
          ~S({"id":1,"\u0069d":2}),
          "{} trailing",
          <<255>>,
          String.duplicate("[", 10_000) <> "null" <> String.duplicate("]", 10_000),
          String.duplicate("9", 10_000)
        ] do
      assert :error = JSON.decode(body)
    end

    assert {:ok, %{"text" => "[ { \"quoted\""}} = JSON.decode(~s({"text":"[ { \\\"quoted\\\""}))
    assert {:ok, 9_007_199_254_740_991} = JSON.decode("9007199254740991")
    assert :error = JSON.decode("18446744073709551616")
  end

  test "wire collections and serialization are bounded before framing" do
    for value <- [
          List.duplicate(0, 257),
          String.duplicate("x", 131_073),
          %{String.duplicate("k", 129) => nil},
          List.duplicate(String.duplicate("x", 131_072), 9),
          %Jason.OrderedObject{values: [{"same", 1}, {"same", 2}]},
          %Jason.OrderedObject{values: [nil]}
        ] do
      assert :error = JSON.encode(value)
    end

    assert {:ok, frame} = JSON.encode(%{"text" => String.duplicate("\n", 65_536)})
    assert {:ok, _state, [body]} = Frame.push(%Frame{}, frame)
    assert {:ok, %{"text" => text}} = JSON.decode(body)
    assert byte_size(text) == 65_536
  end

  test "serialization admits the exact frame bound and rejects an extra byte" do
    strings =
      List.duplicate(String.duplicate("x", 131_072), 7) ++ [String.duplicate("x", 131_047)]

    assert {:ok, <<length::unsigned-big-32, body::binary>>} = JSON.encode(strings)
    assert length == Frame.maximum()
    assert byte_size(body) == length
    assert {:ok, ^strings} = JSON.decode(body)
    assert :error = JSON.encode(List.update_at(strings, 7, &(&1 <> "x")))
  end

  test "command and file validation reject capabilities with no native representation" do
    {:ok, request} = JSON.decode(fixture("exec-request.json"))
    operation = request["operation"]

    for invalid <- [
          Map.put(operation, "stdin", "private-input"),
          Map.put(operation, "background", true),
          put_in(operation, ["command", "argv"], []),
          put_in(operation, ["command", "env"], %{"BAD=KEY" => "value"}),
          put_in(operation, ["command", "workdir"], "/workspace/../etc"),
          put_in(operation, ["command", "max_output_bytes"], 16_777_217),
          put_in(operation, ["receipt", "material_sha256"], "bad"),
          put_in(operation, ["receipt", "name"], "."),
          put_in(operation, ["receipt", "name"], "..")
        ] do
      refute Request.valid?(invalid, 1000)
    end

    read = %{
      "operation" => "read_file",
      "receipt" => operation["receipt"],
      "options" => %{"guest_path" => "/workspace/a", "max_bytes" => 1024, "mode" => nil}
    }

    assert Request.valid?(read, 600_000)
    refute Request.valid?(read, 600_001)
    refute Request.valid?(put_in(read, ["options", "mode"], 420), 1000)
    refute Request.valid?(put_in(read, ["options", "guest_path"], "/"), 1000)
  end

  test "terminal evidence never converts missing Exit or file acknowledgment to success" do
    {:ok, terminal} = Protocol.decode(fixture("exec-terminal.json"))

    for invalid <- [
          put_in(terminal, ["outcome", "observed_exit"], "0"),
          put_in(terminal, ["outcome", "dispatch"], "not_dispatched"),
          terminal
          |> put_in(["outcome", "completion"], "exited")
          |> put_in(["outcome", "observed_exit"], nil),
          put_in(terminal, ["outcome", "running_observed"], false),
          Map.put(terminal, "unexpected", "secret")
        ] do
      assert :error = Protocol.decode(Jason.encode!(invalid))
    end

    file = %{
      terminal
      | "outcome" => %{
          "result" => "file",
          "completion" => "completed",
          "dispatch" => "may_have_dispatched",
          "observed_bytes" => 7,
          "native_acknowledged" => false
        }
    }

    assert :error = Protocol.decode(Jason.encode!(file))

    assert {:ok, _terminal} =
             file
             |> put_in(["outcome", "native_acknowledged"], true)
             |> Jason.encode!()
             |> Protocol.decode()
  end

  test "canonical base64 and event shape reject oversized or malformed chunks" do
    {:ok, terminal} = Protocol.decode(fixture("exec-terminal.json"))

    event =
      terminal
      |> Map.delete("outcome")
      |> Map.put("type", "event")
      |> Map.put("event", %{"stream" => "stdout", "data_base64" => "YQ=="})

    assert {:ok, _event} = Protocol.decode(Jason.encode!(event))

    for encoded <- [
          "YQ",
          "YR==",
          "YQ==\n",
          "_w==",
          "",
          Base.encode64(:binary.copy(<<0>>, 65_537))
        ] do
      assert :error =
               event
               |> put_in(["event", "data_base64"], encoded)
               |> Jason.encode!()
               |> Protocol.decode()
    end
  end

  test "approval matches exact package, generation, protocol and effective limits" do
    package = %{
      "engine_version" => "0.1.0",
      "smolvm_revision" => String.duplicate("a", 40),
      "source_sha256" => String.duplicate("b", 64),
      "build_sha256" => String.duplicate("c", 64),
      "assets_sha256" => String.duplicate("d", 64),
      "platform" => "macos",
      "architecture" => "aarch64"
    }

    config = %{
      id: "local",
      domain_generation: String.duplicate("e", 32),
      package_identity: package
    }

    hello = %{
      "major" => 1,
      "minor" => 3,
      "epoch" => String.duplicate("f", 32),
      "domain" => %{"target_id" => config.id, "generation" => config.domain_generation},
      "package" => package,
      "capabilities" => Protocol.capabilities(),
      "limits" => Protocol.limits(3),
      "preflight" => %{"status" => "ready"}
    }

    assert Protocol.approve(hello, config)

    current = %{hello | "minor" => 4, "limits" => Protocol.limits(4)}
    assert Protocol.approve(current, Map.put(config, :limits, %{cancel_grace_ms: 4000}))
    refute Protocol.approve(current, Map.put(config, :limits, %{cancel_grace_ms: 3000}))

    assert {:ok, _hello} =
             Protocol.decode(Jason.encode!(%{"type" => "hello", "hello" => current}))

    assert :error =
             Protocol.decode(
               Jason.encode!(%{"type" => "hello", "hello" => %{current | "minor" => 5}})
             )

    refute Protocol.approve(%{hello | "limits" => Protocol.limits(4)}, config)

    for invalid <- [
          %{hello | "minor" => 0},
          %{hello | "minor" => 2},
          put_in(hello, ["domain", "generation"], String.duplicate("0", 32)),
          put_in(hello, ["package", "assets_sha256"], String.duplicate("0", 64)),
          put_in(hello, ["limits", "initial_credit_events"], 65),
          %{hello | "capabilities" => ["exec"]},
          %{hello | "preflight" => %{"status" => "rejected", "code" => "package"}}
        ] do
      refute Protocol.approve(invalid, config)
    end
  end
end
