defmodule SmolBox.CI.PreflightTest do
  use ExUnit.Case, async: true
  alias SmolBox.CI.{Child, Preflight, Util}

  test "process executable inspection uses executable identity even with a spoofed argv zero" do
    {:ok, child} =
      Child.start_link(["bash", "-c", "sleep 0.2; exec -a smolbox-fake-name sleep 30"])

    try do
      pid = Child.os_pid(child)
      await_spoofed_argv(pid, System.monotonic_time(:millisecond) + 5_000)
      file = Preflight.executable!(pid, Util.platform())
      assert Util.digest(file) == Util.digest(System.find_executable("sleep"))
    after
      Child.stop(child)
      GenServer.stop(child)
    end
  end

  test "missing lifecycle cannot qualify CI and development is explicit" do
    manifest = manifest()
    assert Preflight.validate!(manifest, "linux", false, %{}).port == 19_470
    persistent = Map.put(manifest, "ephemeral_runner", false)
    assert_raise ArgumentError, fn -> Preflight.validate!(persistent, "linux", false, %{}) end
    assert Preflight.validate!(persistent, "linux", true, %{}).port == 19_470

    assert_raise ArgumentError, fn ->
      Preflight.validate!(manifest, "linux", true, %{"GITHUB_ACTIONS" => "true"})
    end
  end

  test "bad routes, expired lifecycles and database overrides fail closed" do
    for {key, value} <- [
          {"worker_url", "http://example.invalid:19470"},
          {"worker_url", "http://127.0.0.1:19470/path"},
          {"worker_url", "http://127.0.0.1:\n19470"},
          {"worker_url", "http://user:password@127.0.0.1:19470"},
          {"python_artifact", "/private/file\nINJECTED=1"},
          {"worker_pid", true},
          {"database_port", 0},
          {"expires_at_unix", System.os_time(:second) - 1},
          {"expires_at_unix", System.os_time(:second) + 100_000}
        ] do
      assert_raise ArgumentError, fn ->
        Preflight.validate!(Map.put(manifest(), key, value), "linux", false, %{})
      end
    end

    assert_raise ArgumentError, fn ->
      Preflight.validate!(manifest(), "linux", false, %{
        "DATABASE_URL" => "ecto://unexpected.invalid/database"
      })
    end
  end

  test "manifest files must be private, regular, owned and bounded" do
    root = Util.temporary("smolbox-preflight-test")
    on_exit(fn -> File.rm_rf!(root) end)
    file = Path.join(root, "manifest.json")
    manifest = manifest()
    Util.write_json!(file, manifest)
    File.chmod!(file, 0o600)
    assert JSON.decode!(Util.private_file!(file, 16_384)) == manifest
    assert_raise ArgumentError, fn -> Util.private_file!(file, 1) end
    link = Path.join(root, "link.json")
    File.ln_s!(file, link)
    assert_raise ArgumentError, fn -> Util.private_file!(link, 16_384) end
    File.chmod!(file, 0o644)
    assert_raise ArgumentError, fn -> Util.private_file!(file, 16_384) end
  end

  defp await_spoofed_argv(pid, deadline) do
    {arguments, 0} = System.cmd("ps", ["-p", to_string(pid), "-o", "args="])

    cond do
      String.starts_with?(String.trim(arguments), "smolbox-fake-name ") ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("owned child did not exec the spoofed command before its deadline")

      true ->
        Process.sleep(10)
        await_spoofed_argv(pid, deadline)
    end
  end

  defp manifest do
    %{
      "schema" => 1,
      "platform" => "linux",
      "ephemeral_runner" => true,
      "expires_at_unix" => System.os_time(:second) + 3600,
      "lifecycle_id" => "fixture-worker-123",
      "worker_pid" => String.to_integer(System.pid()),
      "worker_url" => "http://127.0.0.1:19470",
      "python_sha256" => String.duplicate("a", 64),
      "javascript_sha256" => String.duplicate("b", 64),
      "python_artifact" => "/private/python.smolmachine",
      "javascript_artifact" => "/private/node.smolmachine",
      "database_socket_dir" => "/private/socket",
      "database_port" => 25_432,
      "database_user" => "smolbox",
      "database_name" => "smolbox_contract"
    }
  end
end
