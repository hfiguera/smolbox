defmodule SmolBox.CommandTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Command, Error}

  test "shell metacharacters remain literal argv and safety fields use exact wire names" do
    assert {:ok, command} =
             Command.new(["python3", "-c", "print('$HOME; `echo bad`')"],
               timeout_secs: 2,
               env: [{"LANG", "C.UTF-8"}],
               stdin: "input\0bytes",
               user: "1000:1000"
             )

    assert {:ok, wire} = Command.to_wire(command)
    assert wire["command"] == command.argv
    assert wire["timeoutSecs"] == 2
    assert wire["background"] == false
    assert wire["secrets"] == %{}
    assert wire["stdin"] == "input\0bytes"
    refute Map.has_key?(wire, "timeout_secs")
    refute inspect(command) =~ "$HOME"
    refute inspect(command) =~ "input"
  end

  test "rejects invalid, duplicate, and unsupported options before transport" do
    for options <- [
          [timeout_secs: 0],
          [timeout_secs: 301],
          [timeout_secs: 1.5],
          [timeout_secs: 1, timeout_secs: 2],
          [background: true],
          [env: [{"A", "1"}, {"A", "2"}]],
          [env: [{"BAD=NAME", "x"}]],
          [env: [:invalid]],
          [env: %{}],
          [stdin: <<255>>],
          [user: ""],
          [workdir: "/workspace/../etc"],
          [stdin: String.duplicate("x", 65_537)],
          [user: 12],
          [env: [{"A", "bad\0value"}]],
          %{},
          nil
        ] do
      assert {:error, %Error{category: :validation}} = Command.new(["true"], options)
    end
  end

  test "rejects malformed argv and revalidates manually changed structs" do
    for argv <- [
          [],
          [""],
          [1],
          ["echo", 1],
          ["bad\0arg"],
          [<<255>>],
          List.duplicate("x", 257),
          [String.duplicate("x", 16_385)],
          List.duplicate(String.duplicate("x", 16_384), 5),
          :invalid
        ] do
      assert {:error, %Error{}} = Command.new(argv)
    end

    assert {:ok, command} = Command.new(["true"])
    assert {:error, %Error{}} = Command.to_wire(%{command | timeout_secs: 0})
    assert {:error, %Error{}} = Command.validate(%{})
    assert {:ok, wire} = Command.to_wire(command)
    refute Map.has_key?(wire, "stdin")
    refute Map.has_key?(wire, "user")
  end
end
