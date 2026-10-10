defmodule SmolBox.CI.LivebookTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{Livebook, Util}

  @source File.read!(Path.expand("../../docs/notebooks/getting-started.livemd", __DIR__))

  test "published mode preserves every executable cell except the documented configuration" do
    configured =
      Livebook.configure!(@source, "/tmp/demo", "approved", "http://127.0.0.1:9999", nil)

    assert configured =~ ~s|Mix.install([{:smolbox, "~> 0.4.2"}])|

    restored =
      configured
      |> String.replace(
        ~s(demo_root = "/tmp/demo"),
        ~s(demo_root = "/absolute/path/printed/by/setup")
      )
      |> String.replace(
        ~s(approved_sha256 = "approved"),
        ~s(approved_sha256 = "paste_the_sha256_printed_by_setup")
      )
      |> String.replace(
        ~s(runtime_url = "http://127.0.0.1:9999"),
        ~s(runtime_url = "http://127.0.0.1:19471")
      )

    assert restored == @source
  end

  test "candidate mode escapes Elixir paths and rejects missing or ambiguous configuration" do
    configured =
      Livebook.configure!(@source, "/tmp/demo", "approved", "http://127.0.0.1:9999", "/tmp/a\"b")

    assert configured =~ ~s|Mix.install([{:smolbox, path: "/tmp/a\\\"b"}])|

    for source <- ["", @source <> @source, String.replace(@source, "demo_root =", "root =")] do
      assert_raise ArgumentError, fn ->
        Livebook.configure!(source, "/tmp/demo", "hash", "url", nil)
      end
    end
  end

  test "failed, skipped and incomplete sessions cannot pass even with expected text" do
    result = valid_result()
    assert :ok = Livebook.validate_result!(result)

    for field <- ~w(execution stdout collection cleanup reservation inventory supervisor),
        value <- [nil, false, "true"] do
      invalid = put_in(result, ["checks", field], value)
      assert_raise ArgumentError, fn -> Livebook.validate_result!(invalid) end
    end

    for invalid <- [
          Map.put(result, "cells", []),
          Map.put(result, "cells", tl(result["cells"])),
          Map.put(result, "cells", List.duplicate(hd(result["cells"]), 6)),
          put_in(result, ["cells"], [%{"id" => "failed", "errored" => true} | tl(result["cells"])]),
          Map.put(result, "status", "failed"),
          Map.put(result, "runtime", "Elixir.Livebook.Runtime.Attached"),
          Map.put(result, "livebook_version", "0.19.9"),
          Map.put(result, "import_warnings", ["ignored code"]),
          Map.put(result, "export_warnings", ["unsupported output"])
        ] do
      assert_raise ArgumentError, fn -> Livebook.validate_result!(invalid) end
    end
  end

  test "existing reports prevent any worker interaction" do
    directory = Util.temporary("livebook-report-test")
    on_exit(fn -> File.rm_rf!(directory) end)
    report = Path.join(directory, "report.json")
    File.write!(report, "preserved")

    assert_raise File.Error, fn ->
      Livebook.run([
        "--report",
        report,
        "--url",
        "http://127.0.0.1:1",
        "--worker-pid",
        "2",
        "--python",
        "missing",
        "--sha256",
        "missing",
        "--livebook",
        "missing"
      ])
    end

    assert File.read!(report) == "preserved"
  end

  defp valid_result do
    %{
      "status" => "passed",
      "livebook_version" => "0.19.10",
      "runtime" => "Elixir.Livebook.Runtime.Standalone",
      "import_warnings" => [],
      "export_warnings" => [],
      "cells" =>
        Enum.map(
          1..6,
          &%{
            "id" => to_string(&1),
            "validity" => "evaluated",
            "status" => "ready",
            "errored" => false
          }
        ),
      "checks" =>
        Map.new(
          ~w(execution stdout collection cleanup reservation inventory supervisor),
          &{&1, true}
        )
    }
  end
end
