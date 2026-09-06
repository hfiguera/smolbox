defmodule SmolBox.ExecutionSpecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SmolBox.{Command, Error, ExecutionSpec, Files, Profile}

  @key :binary.copy(<<42>>, 32)

  defp spec do
    {:ok, command} =
      Command.new(["python", "/workspace/main.py"], env: [{"TOKEN", "secret"}, {"A", "b"}])

    {:ok, profile} = Profile.new("offline-v1")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "tenant:one",
        id: "request:1",
        command: command,
        profile: profile,
        artifact: %{
          "id" => "python",
          "architecture" => "aarch64",
          "sha256" => Files.sha256("image")
        },
        inputs: [
          %{
            "source" => "source:1",
            "path" => "/workspace/main.py",
            "size" => 1,
            "sha256" => Files.sha256("a"),
            "mode" => "runtime_default"
          }
        ],
        outputs: [
          %{"destination" => "output:1", "path" => "/workspace/result", "max_bytes" => 20}
        ]
      )

    spec
  end

  property "semantic environment ordering does not change request identity" do
    check all(
            values <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 8), max_length: 16)
          ) do
      spec = spec()
      env = Enum.map(values, &{"VAR_" <> &1, &1})
      first = %{spec | command: %{spec.command | env: env}}
      second = %{first | command: %{first.command | env: Enum.reverse(env)}}
      assert ExecutionSpec.fingerprint(first, @key) == ExecutionSpec.fingerprint(second, @key)
    end
  end

  test "every execution-affecting field changes identity, including collection and retention" do
    spec = spec()
    {:ok, original} = ExecutionSpec.fingerprint(spec, @key)

    changes = [
      %{spec | id: "another"},
      %{spec | scope: "another"},
      %{spec | artifact: Map.put(spec.artifact, "sha256", Files.sha256("other"))},
      %{spec | artifact: Map.put(spec.artifact, "architecture", "x86_64")},
      %{spec | command: %{spec.command | argv: ["false"]}},
      %{spec | command: %{spec.command | env: [{"TOKEN", "different"}]}},
      %{spec | command: %{spec.command | stdin: "secret"}},
      %{spec | profile: %{spec.profile | max_output_bytes: 200}},
      %{spec | profile: %{spec.profile | id: "offline-v2"}},
      %{spec | inputs: []},
      %{spec | outputs: []},
      %{spec | queue_ms: 1234},
      %{spec | retention_ms: 123_456},
      %{spec | metadata: %{"correlation" => "one"}}
    ]

    for changed <- changes do
      assert {:ok, fingerprint} = ExecutionSpec.fingerprint(changed, @key)
      refute fingerprint == original
    end

    refute ExecutionSpec.fingerprint(spec, :binary.copy(<<43>>, 32)) == {:ok, original}
    refute inspect(spec) =~ "secret"
    assert {:error, %Error{category: :validation}} = ExecutionSpec.fingerprint(spec, "short")
  end

  test "manifest reordering is stable but traversal, permission claims and aliases are rejected" do
    spec = spec()
    input = hd(spec.inputs)
    second = %{input | "source" => "source:2", "path" => "/workspace/lib.py"}
    first = %{spec | inputs: [input, second]}

    assert ExecutionSpec.fingerprint(first, @key) ==
             ExecutionSpec.fingerprint(%{first | inputs: [second, input]}, @key)

    invalid_inputs = [
      [input, input],
      [%{input | "path" => "/etc/passwd"}],
      [%{input | "path" => "/workspace"}],
      [%{input | "path" => "/workspace/../x"}],
      [%{input | "source" => "https://evil.example/code"}],
      [%{input | "mode" => "0755"}],
      [%{input | "size" => 2_000_000}],
      [%{input | "sha256" => "wrong"}],
      [Map.put(input, "mount", "/")],
      [input | :improper],
      [:bad]
    ]

    for inputs <- invalid_inputs,
        do: assert({:error, _} = ExecutionSpec.validate(%{spec | inputs: inputs}))

    output = hd(spec.outputs)

    for outputs <- [[output, output], [%{output | "max_bytes" => 0}], [:bad]] do
      assert {:error, _} = ExecutionSpec.validate(%{spec | outputs: outputs})
    end

    assert {:error, _} =
             ExecutionSpec.validate(%{
               spec
               | profile: %{spec.profile | max_total_file_bytes: 10, max_file_bytes: 10}
             })
  end

  test "invalid or unbounded specs cannot be fingerprinted or constructed" do
    spec = spec()

    for invalid <- [
          nil,
          %{spec | artifact: %{}},
          %{spec | command: nil},
          %{spec | profile: nil},
          %{spec | metadata: %{bad: self()}},
          %{spec | metadata: []},
          %{spec | metadata: %{"number" => 9_007_199_254_740_992}},
          %{spec | queue_ms: 0},
          %{spec | retention_ms: 1},
          %{spec | profile: %{spec.profile | execution_ms: 1000}}
        ] do
      assert {:error, _} = ExecutionSpec.fingerprint(invalid, @key)
    end

    for options <- [[], [id: "x", id: "y"], [unexpected: true], %{}, [:bad]] do
      assert {:error, _} = ExecutionSpec.new(options)
    end

    assert :ok =
             ExecutionSpec.validate(%{
               spec
               | metadata: %{"boolean" => true, "empty" => nil, "integer" => 5}
             })

    options = Map.to_list(Map.from_struct(spec))
    assert {:ok, ^spec} = ExecutionSpec.new(options)
    assert {:error, _} = ExecutionSpec.new(Keyword.put(options, :id, "bad/id"))
  end
end
