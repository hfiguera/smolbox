defmodule SmolBox.ResultTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SmolBox.{Error, Result}

  test "decodes a captured worker response without using its lossy text fields" do
    for prefix <- ["", "1.14.6/"] do
      wire = "test/fixtures/wire/#{prefix}exec.json" |> File.read!() |> Jason.decode!()

      assert {:ok, %Result{exit_code: 7, stdout: <<0, 255, 254>>, stderr: "err"}} =
               Result.from_wire(wire, 64)
    end
  end

  property "buffered decoding preserves arbitrary bytes and nonzero exits" do
    check all(
            stdout <- binary(max_length: 128),
            stderr <- binary(max_length: 128),
            exit_code <- integer(-1..255)
          ) do
      wire = %{
        "exitCode" => exit_code,
        "stdoutB64" => Base.encode64(stdout),
        "stderrB64" => Base.encode64(stderr),
        "stdout" => "lossy",
        "futureField" => true
      }

      assert {:ok, result} = Result.from_wire(wire, 256)
      assert result.stdout == stdout
      assert result.stderr == stderr
      assert result.exit_code == exit_code
    end
  end

  test "malformed or missing byte fields cannot silently fall back to text" do
    for wire <- [
          %{},
          %{"exitCode" => 0, "stdout" => "text", "stderr" => ""},
          %{"exitCode" => 0, "stdoutB64" => "???", "stderrB64" => ""},
          %{"exitCode" => "0", "stdoutB64" => "", "stderrB64" => ""}
        ] do
      assert {:error, %Error{category: :protocol}} = Result.from_wire(wire, 256)
    end
  end

  test "aggregate output bounds include both streams" do
    for {bytes, cap} <- [{String.duplicate("x", 128), 1}, {"abc", 5}] do
      encoded = Base.encode64(bytes)
      wire = %{"exitCode" => 0, "stdoutB64" => encoded, "stderrB64" => encoded}

      assert {:error, %Error{category: :output_limit, evidence: :exited}} =
               Result.from_wire(wire, cap)
    end
  end

  test "output collection failure retains the observed exit code and inspection hides bytes" do
    wire = %{"exitCode" => 7, "stdoutB64" => Base.encode64("private output"), "stderrB64" => ""}
    assert {:error, %Error{evidence: :exited, exit_code: 7}} = Result.from_wire(wire, 1)
    assert {:ok, result} = Result.from_wire(wire, 128)
    refute inspect(result) =~ "private output"
  end
end
