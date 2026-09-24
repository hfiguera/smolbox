defmodule SmolBox.GuestPathsTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Command, ExecutionSpec, Files, GuestPaths, ManagedMachineSpec, Manifest, Profile}
  alias SmolBox.Store.{Codec, Contract, MachineContract}
  alias SmolBox.Terminal.Spec, as: TerminalSpec

  test "directional roots are canonical, segment-aware and deny malformed paths" do
    {:ok, paths} =
      GuestPaths.new(
        upload_roots: ["/home/dev", "/app", "/app"],
        download_roots: ["/artifacts"],
        workdir_roots: ["/app"]
      )

    assert paths.upload_roots == ["/app", "/home/dev"]
    assert GuestPaths.allowed?(paths, :upload, "/home/dev/.config/tool.json")
    refute GuestPaths.allowed?(paths, :download, "/home/dev/.config/tool.json")
    assert GuestPaths.allowed?(paths, :workdir, "/app")
    refute GuestPaths.allowed?(paths, :workdir, "/application")
    assert {:ok, "app/caf%C3%A9/a%20b"} = Files.encode_path("/app/café/a b", paths, :upload)
    refute inspect(paths) =~ "/home/dev"

    for path <- [
          "relative",
          "/app/../x",
          "/app/./x",
          "/app//x",
          "/app/",
          "/app/%2e",
          "/app/\\x",
          "/app/\0",
          <<255>>,
          nil,
          "/" <> String.duplicate("a", 1024)
        ] do
      refute GuestPaths.allowed?(paths, :upload, path)
      assert {:error, _} = GuestPaths.new(upload_roots: [path])
    end

    assert {:error, _} = GuestPaths.new(workdir_roots: [])
    assert {:error, _} = GuestPaths.new(upload_roots: ["/app"], upload_roots: ["/"])
    assert {:error, _} = GuestPaths.new(download_roots: List.duplicate("/app", 33))
    assert {:ok, denied} = GuestPaths.new(upload_roots: [], download_roots: [])
    refute GuestPaths.allowed?(denied, :upload, "/workspace/x")
    {:ok, all} = GuestPaths.new(upload_roots: ["/"], download_roots: ["/"], workdir_roots: ["/"])
    assert GuestPaths.subset?(paths, all)
    refute GuestPaths.subset?(all, paths)
    refute GuestPaths.valid?(Map.put(paths, :surprise, true))
  end

  test "profile approval covers command cwd, verification reads and aggregate limits" do
    {:ok, paths} =
      GuestPaths.new(
        upload_roots: ["/app"],
        download_roots: ["/app", "/out"],
        workdir_roots: ["/app"]
      )

    {:ok, profile} =
      Profile.new("files-v2",
        guest_paths: paths,
        max_file_bytes: 16_777_216,
        max_total_file_bytes: 32_000_000
      )

    {:ok, command} = Command.new(["true"], workdir: "/app/project")
    base = Contract.record().spec
    spec = %{base | command: command, profile: profile}
    assert :ok = ExecutionSpec.validate(spec)
    assert {:error, _} = ExecutionSpec.validate(%{base | command: command})

    input = %{
      "source" => "file",
      "path" => "/app/in",
      "size" => 16_777_216,
      "sha256" => Files.sha256("fixture"),
      "mode" => "runtime_default"
    }

    output = %{"destination" => "result", "path" => "/out/result", "max_bytes" => 16_777_216}
    assert :ok = Manifest.validate([input], [output], profile)

    assert {:error, _} =
             Manifest.validate([input], [], %{
               profile
               | guest_paths: %{paths | download_roots: ["/out"]}
             })

    assert {:error, _} =
             Manifest.validate(
               [input, %{input | "source" => "second", "path" => "/app/second"}],
               [],
               profile
             )

    assert {:error, _} = Profile.new("bad", max_file_bytes: 16_777_217)
    assert {:error, _} = Profile.new("bad", max_total_file_bytes: 67_108_865)
    machine = MachineContract.record().spec

    assert {:ok, _} =
             ManagedMachineSpec.new(Map.to_list(Map.from_struct(%{machine | profile: profile})))
  end

  test "v9 preserves policies and older envelopes cannot acquire broader permissions" do
    old = Contract.record()
    {:ok, paths} = GuestPaths.new(workdir_roots: ["/app", "/workspace"])
    updated = %{old | spec: %{old.spec | profile: %{old.spec.profile | guest_paths: paths}}}
    assert {:ok, <<"smolbox-record-v9\0", payload::binary>> = bytes} = Codec.encode(updated)
    assert {:ok, ^updated} = Codec.decode(bytes)
    assert {:error, _} = Codec.decode(bytes <> "extra")

    assert {:error, _} =
             Codec.decode("smolbox-record-v9\0" <> :erlang.term_to_binary(updated, compressed: 9))

    for version <- 1..8 do
      assert {:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload)
    end

    assert {:ok, <<"smolbox-record-v2\0", legacy::binary>> = old_bytes} = Codec.encode(old)
    refute Map.has_key?(:erlang.binary_to_term(legacy).spec.profile, :guest_paths)
    assert {:ok, ^old} = Codec.decode(old_bytes)
    forged = :erlang.binary_to_term(legacy)

    for forged <- [
          %{
            forged
            | spec: %{forged.spec | profile: %{forged.spec.profile | max_file_bytes: 2_000_000}}
          },
          %{forged | spec: %{forged.spec | command: %{forged.spec.command | workdir: "/app"}}}
        ] do
      assert {:error, _} = Codec.decode("smolbox-record-v2\0" <> :erlang.term_to_binary(forged))
    end

    assert {:error, _} = Codec.decode("smolbox-record-v9\0" <> :erlang.term_to_binary(old))
    key = :binary.copy(<<1>>, 32)
    assert {:ok, fingerprint} = ExecutionSpec.fingerprint(old.spec, key)
    assert fingerprint == old.fingerprint
    refute ExecutionSpec.fingerprint(updated.spec, key) == {:ok, fingerprint}
  end

  test "v9 composes with terminal, background and startup workload records" do
    base = Contract.record()
    {:ok, paths} = GuestPaths.new()
    profile = %{base.spec.profile | guest_paths: paths}
    {:ok, terminal} = TerminalSpec.new()
    {:ok, background} = Command.new(["server"], background: true)

    for command <- [terminal, background] do
      spec = %{base.spec | command: command, profile: profile}
      {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
      {:ok, record} = SmolBox.Execution.new(spec, fingerprint, 1000)
      assert {:ok, <<"smolbox-record-v9", 0, _::binary>> = bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end

    base = MachineContract.record()
    {:ok, workload} = SmolBox.Workload.new(cmd: ["server"])
    spec = %{base.spec | profile: profile, workload: workload}
    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, record} = SmolBox.ManagedMachine.new(spec, fingerprint, 1000)
    assert {:ok, <<"smolbox-record-v9", 0, _::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)
  end
end
