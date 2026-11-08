defmodule SmolBox.BackendFeaturesTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Features

  defp worker(version, platform \\ :linux, architecture \\ "x86_64"),
    do: %{runtime_version: version, platform: platform, architecture: architecture}

  test "HTTP eligibility retains distinct network, extended and saved-state version boundaries" do
    assert Features.supports?(worker("1.14.1"), :foreground_exec)
    refute Features.supports?(worker("1.14.6"), :networking)
    assert Features.supports?(worker("1.16.0"), :networking)
    refute Features.supports?(worker("1.16.1"), :terminals)
    assert Features.supports?(worker("1.17.0"), :terminals)
    refute Features.supports?(worker("1.17.0"), :remote_sources)
    assert Features.supports?(worker("1.19.0"), :remote_sources)
    refute Features.supports?(worker("1.19.0"), :disk_growth)
    assert Features.supports?(worker("1.20.2"), :disk_growth)

    for feature <- ~w(lifecycle foreground_exec files networking extended_exec background_exec
                       terminals workloads extended_files remote_sources images checkpoints
                       exports branches disk_growth volumes ports)a do
      assert Features.supports?(worker("1.22.0"), feature)
      refute Features.supports?(worker("0.1.0"), feature)
      refute Features.supports?(worker("future"), feature)
    end
  end

  test "volume and port eligibility preserves platform restrictions" do
    assert Features.supports?(worker("1.22.0"), :volumes)
    refute Features.supports?(worker("1.22.0", :macos, "aarch64"), :volumes)
    assert Features.supports?(worker("1.22.0", :macos, "aarch64"), :ports)
    refute Features.supports?(worker("1.22.0", :linux, "aarch64"), :ports)
    refute Features.supports?(worker("1.22.0", :macos, "x86_64"), :ports)
  end

  test "unknown target shapes and features cannot enlarge the native contract" do
    for invalid <- [
          nil,
          %{},
          :embedded,
          %{engine_version: "1.22.0"},
          %{kind: :embedded, runtime_version: "1.22.0"}
        ] do
      refute Features.supports?(invalid, :networking)
      assert Features.native_versions(invalid) == %{}
    end

    refute Features.supports?(worker("1.22.0"), :made_up)
  end
end
