defmodule SmolBox.KubernetesRemoteCommandTest do
  use ExUnit.Case, async: true
  alias SmolBox.Kubernetes.{ExitStatus, GuestHelper, RemoteCommand}
  alias SmolBox.WebSocket.Wire

  defp status(0), do: Jason.encode!(%{"metadata" => %{}, "status" => "Success"})

  defp status(code),
    do:
      Jason.encode!(%{
        "status" => "Failure",
        "reason" => "NonZeroExitCode",
        "details" => %{
          "causes" => [%{"reason" => "ExitCode", "message" => Integer.to_string(code)}]
        }
      })

  defp feed(state, frame) do
    {:ok, next, _} = RemoteCommand.feed(state, frame)
    next
  end

  test "binary streams, split acknowledgement and nonzero exit preserve exact bytes" do
    state = RemoteCommand.new(100)
    {:ok, state, []} = RemoteCommand.feed(state, {:binary, <<2, 255, 0>>})
    state = feed(state, {:binary, <<1, "SBK1">>})
    {:ok, state, events} = RemoteCommand.feed(state, {:binary, <<1, 0::32, 0, 254>>})
    assert events == [stdout: <<0, 254>>, stderr: <<255, 0>>]
    message = status(7)
    <<first::binary-size(10), rest::binary>> = message

    state =
      state
      |> feed({:binary, <<3, first::binary>>})
      |> feed({:binary, <<3, rest::binary>>})
      |> feed({:close, 1000, ""})

    assert {:ok, result} = RemoteCommand.result(state)

    assert {result.exit_code, result.stdout, result.stderr, result.encoding} ==
             {7, <<0, 254>>, <<255, 0>>, :bytes}

    refute result.truncated
  end

  test "silent success needs helper acknowledgement, terminal status and complete closure" do
    state = RemoteCommand.new(100) |> feed({:binary, <<1, GuestHelper.ack()::binary>>})
    assert {:error, :protocol} = RemoteCommand.result(feed(state, {:close, 1000, ""}))
    state = feed(state, {:binary, <<3, status(0)::binary>>})
    assert {:error, :protocol, %{exit_code: 0, truncated: true}} = RemoteCommand.result(state)

    assert {:ok, %{exit_code: 0, stdout: "", stderr: ""}} =
             RemoteCommand.result(feed(state, {:close, 1000, ""}))

    no_ack =
      RemoteCommand.new(100)
      |> feed({:binary, <<3, status(0)::binary>>})
      |> feed({:close, 1000, ""})

    assert {:error, :protocol} = RemoteCommand.result(no_ack)
  end

  test "duplicate or conflicting status disqualifies completion while retaining observed exit" do
    state =
      RemoteCommand.new(100)
      |> feed({:binary, <<1, GuestHelper.ack()::binary>>})
      |> feed({:binary, <<3, status(7)::binary>>})

    for code <- [0, 7] do
      assert {:error, :protocol, next, []} =
               RemoteCommand.feed(state, {:binary, <<3, status(code)::binary>>})

      assert {:error, :protocol, %{exit_code: 7, truncated: true}} = RemoteCommand.result(next)
    end

    assert {:error, :protocol, interrupted, []} = RemoteCommand.feed(state, {:close, 1001, ""})

    assert {:error, :protocol, %{exit_code: 7, truncated: true}} =
             RemoteCommand.result(interrupted)
  end

  test "status/control data cannot become application stderr or a synthetic exit" do
    for bytes <- [
          "",
          "broken",
          ~s({"status":"Failure"}),
          ~s({"status":"Failure","status":"Success"}),
          ~s({"status":"Failure","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"7","message":"0"}]}}),
          ~s({"status":"Success","reason":"NonZeroExitCode"})
        ] do
      assert :error = ExitStatus.decode(bytes)

      state =
        RemoteCommand.new(100)
        |> feed({:binary, <<3, bytes::binary>>})
        |> feed({:close, 1000, ""})

      assert {:error, :protocol} = RemoteCommand.result(state)
    end

    state = RemoteCommand.new(100)
    assert {:ok, state, []} = RemoteCommand.feed(state, {:binary, <<2, "helper diagnostic">>})
    assert {:error, :protocol} = RemoteCommand.result(feed(state, {:close, 1000, ""}))

    assert {:error, :output_limit, _, []} =
             RemoteCommand.feed(RemoteCommand.new(3), {:binary, <<2, "helper diagnostic">>})

    assert {:ok, _, [{:pong, "probe"}]} = RemoteCommand.feed(state, {:ping, "probe"})
    assert {:error, :protocol, _, _} = RemoteCommand.feed(state, {:binary, <<4, 1>>})
  end

  test "output cap retains only the bounded prefix and never reports success" do
    state =
      RemoteCommand.new(3)
      |> feed({:binary, <<1, GuestHelper.ack()::binary>>})
      |> feed({:binary, <<3, status(7)::binary>>})

    assert {:error, :output_limit, state, [{:stdout, "abc"}]} =
             RemoteCommand.feed(state, {:binary, <<1, "abcdef">>})

    assert {:error, :output_limit, %{stdout: "abc", exit_code: 7, truncated: true}} =
             RemoteCommand.result(state)

    assert {:error, :output_limit, _, _} =
             RemoteCommand.feed(RemoteCommand.new(100), {:binary, <<3, 0::size(65_544)>>})
  end

  test "closed streams reject late bytes and control frames never complete a command" do
    state = RemoteCommand.new(100) |> feed({:binary, <<255, 1>>})
    assert {:error, :protocol, _, _} = RemoteCommand.feed(state, {:binary, <<1, "late">>})
    assert {:error, :protocol} = RemoteCommand.result(state)
  end

  test "wire parser bounds fragments before assembly and decodes binary plus controls" do
    wire = Wire.new(%Mint.WebSocket{}, 1024)
    {:ok, wire, []} = Wire.feed(wire, <<2, 2, 1, 255>>)
    {:ok, wire, [{:ping, "x"}]} = Wire.feed(wire, <<137, 1, "x">>)
    {:ok, _, [{:binary, <<1, 255, 0, 254>>}]} = Wire.feed(wire, <<128, 2, 0, 254>>)

    assert {:error, :output_limit} =
             Wire.feed(Wire.new(%Mint.WebSocket{}, 1_048_576), <<130, 127, 2_000_000::64>>)

    assert {:error, :protocol} = Wire.feed(Wire.new(%Mint.WebSocket{}, 100), <<194, 0>>)
    assert {:error, :protocol} = Wire.feed(Wire.new(%Mint.WebSocket{}, 100), <<130, 128>>)
  end
end
