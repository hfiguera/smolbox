defmodule SmolBox.Store.NativeVolumeCodecTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Binding
  alias SmolBox.Embedded.{JSON, VolumeAuthority}
  alias SmolBox.{Error, Volume, VolumePolicy}
  alias SmolBox.Store.{BackendBindings, Codec, Memory, VolumeContract, VolumeOps}

  defp fixture do
    {:ok, value} =
      File.read!("native/smolbox-protocol/fixtures/volume-authority.json") |> JSON.decode()

    value
  end

  defp record do
    fixture = fixture()
    {:ok, policy} = VolumePolicy.new("local", "/srv/smolvm/volumes")
    v = VolumeContract.record()

    %{
      v
      | worker_volume_id: fixture["request"]["intent"]["worker_volume_id"],
        size_gb: 4,
        policy: policy,
        native_authority: %VolumeAuthority{
          binding: %Binding{
            kind: :embedded,
            target_id: fixture["domain"]["target_id"],
            generation: fixture["domain"]["generation"]
          }
        }
    }
  end

  defp ready do
    {:ok, ready, :changed} =
      VolumeOps.change(record(), 1, {:complete_native, fixture()["outcome"]}, 1001)

    ready
  end

  defp deletion(provision) do
    %{
      "result" => "volume",
      "volume" => %{
        "status" => "deleted",
        "proof" => %{
          "schema" => 1,
          "operation_id" => String.duplicate("d", 32),
          "provision" => provision
        }
      }
    }
  end

  defp abort do
    %{
      "result" => "volume",
      "volume" => %{
        "status" => "aborted",
        "proof" =>
          fixture()["outcome"]["volume"]["proof"]
          |> Map.put("operation_id", String.duplicate("d", 32))
      }
    }
  end

  test "native lifecycle requires exact completion proof and retains uncertain reservations" do
    v = record()
    assert :ok = Volume.validate(v)
    assert Volume.resources(v).disk_gb == 4
    assert {:error, _} = VolumeOps.change(v, 1, {:complete, :ready}, 1001)
    ready = ready()
    assert ready.native_authority.provision == fixture()["outcome"]["volume"]["proof"]
    assert ready.state == :ready
    assert BackendBindings.record_binding(ready) == ready.native_authority.binding
    assert {:ok, deleting, :changed} = VolumeOps.change(ready, ready.version, :delete, 1002)
    assert {:error, _} = VolumeOps.change(deleting, deleting.version, {:complete, :deleted}, 1003)
    assert Volume.resources(deleting).disk_gb == 4
    error = %Error{category: :unknown, operation: :volume}

    assert {:ok, unknown, :changed} =
             VolumeOps.change(deleting, deleting.version, {:unknown, error}, 1003)

    assert unknown.native_authority == ready.native_authority
    assert Volume.resources(unknown).disk_gb == 4

    assert {:ok, resolved, :changed} =
             VolumeOps.change(unknown, unknown.version, :resolve_delete, 1004)

    proof = deletion(ready.native_authority.provision)

    assert {:ok, deleted, :changed} =
             VolumeOps.change(resolved, resolved.version, {:complete_native, proof}, 1005)

    assert deleted.state == :deleted
    assert deleted.native_authority.deletion == proof["volume"]["proof"]
    assert deleted.native_authority.provision == ready.native_authority.provision
    assert Volume.resources(deleted).disk_gb == 0
    assert BackendBindings.record_binding(deleted) == v.native_authority.binding

    assert {:error, _} =
             VolumeOps.change(deleted, deleted.version, {:complete_native, proof}, 1006)
  end

  test "crossed proofs cannot ready a volume or release its reservation" do
    v = record()
    proof = fixture()["outcome"]

    for {path, value} <- [
          {~w(volume proof backing target_id), "other"},
          {~w(volume proof backing domain_generation), String.duplicate("f", 32)},
          {~w(volume proof backing policy root), "/other/volumes"},
          {~w(volume proof backing policy id), "other"},
          {~w(volume proof backing intent worker_volume_id), "sbv-" <> String.duplicate("f", 32)},
          {~w(volume proof backing intent size_gb), 5}
        ] do
      assert {:error, _} =
               VolumeOps.change(v, 1, {:complete_native, put_in(proof, path, value)}, 1001)
    end

    ready = ready()
    {:ok, deleting, _} = VolumeOps.change(ready, ready.version, :delete, 1002)

    changed =
      put_in(
        deletion(ready.native_authority.provision),
        ~w(volume proof provision backing inode),
        7
      )

    assert {:error, _} =
             VolumeOps.change(deleting, deleting.version, {:complete_native, changed}, 1003)

    assert {:error, _} =
             VolumeOps.change(deleting, deleting.version, {:complete_native, abort()}, 1003)

    assert {:error, _} =
             VolumeOps.change(deleting, deleting.version, {:complete_native, proof}, 1003)
  end

  test "explicit resolution of unready storage retains deletion or abort evidence without readiness adoption" do
    v = record()
    {:ok, resolving, _} = VolumeOps.change(v, 1, :resolve_delete, 1001)
    provision = fixture()["outcome"]["volume"]["proof"]

    for proof <- [abort(), deletion(provision)] do
      assert {:ok, deleted, :changed} =
               VolumeOps.change(resolving, resolving.version, {:complete_native, proof}, 1002)

      assert deleted.state == :deleted
      assert :ok = Volume.validate(deleted)
      assert Volume.resources(deleted).disk_gb == 0
      assert {:ok, bytes} = Codec.encode(deleted)
      assert {:ok, ^deleted} = Codec.decode(bytes)
    end

    assert {:error, _} = VolumeOps.change(v, 1, {:complete_native, abort()}, 1001)

    assert {:error, _} =
             VolumeOps.change(
               resolving,
               resolving.version,
               {:complete_native, %{"result" => "volume", "volume" => %{"status" => "absent"}}},
               1002
             )
  end

  test "native owner and proof cannot be erased or replaced through record updates" do
    ready = ready()
    authority = ready.native_authority

    for changes <- [
          %{native_authority: nil},
          %{native_authority: %{authority | provision: nil}},
          %{
            native_authority: %{
              authority
              | provision: put_in(authority.provision, ~w(backing inode), 7)
            }
          },
          %{worker_id: "other"},
          %{size_gb: 5},
          %{fingerprint: String.duplicate("f", 64)}
        ] do
      assert {:error, _} = Volume.update(ready, changes, 1002)
    end

    assert {:error, _} =
             Volume.update(
               VolumeContract.record(),
               %{native_authority: record().native_authority},
               1002
             )

    assert {:error, _} = Volume.validate(%{record() | state: :ready})
    assert {:error, _} = Volume.validate(%{ready | state: :deleted})

    assert {:error, _} =
             Volume.validate(%{ready | native_authority: Map.put(authority, :extra, true)})
  end

  test "selective v20 preserves legacy v15 bytes and rejects envelope relabeling" do
    legacy = VolumeContract.record()
    payload = legacy |> Map.delete(:native_authority) |> :erlang.term_to_binary()
    bytes = "smolbox-record-v15\0" <> payload
    assert {:ok, ^bytes} = Codec.encode(legacy)
    assert {:ok, ^legacy} = Codec.decode(bytes)

    for v <- [record(), ready()] do
      assert {:ok, <<"smolbox-record-v20\0", payload::binary>> = bytes} = Codec.encode(v)
      assert {:ok, ^v} = Codec.decode(bytes)

      for version <- 1..19 do
        assert {:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload)
      end

      assert {:error, _} = Codec.decode(bytes <> <<0>>)

      assert {:error, _} =
               Codec.decode("smolbox-record-v20\0" <> :erlang.term_to_binary(v, compressed: 9))
    end

    assert {:error, _} = Codec.decode("smolbox-record-v20\0" <> :erlang.term_to_binary(legacy))
    assert {:error, _} = Codec.decode("smolbox-record-v15\0" <> :erlang.term_to_binary(legacy))
  end

  test "Memory atomically binds native volume admission and proof-based capacity release" do
    store = start_supervised!(Memory)
    v = record()
    binding = v.native_authority.binding
    capacity = %{disk_gb: 4}
    assert {:error, _} = Memory.volume_accept(store, v, capacity)
    assert {:ok, %{disk_gb: 0}} = Memory.usage(store, "worker")
    assert {:ok, ^binding} = Memory.bind_backend(store, "worker", binding)
    assert {:error, _} = Memory.volume_accept(store, VolumeContract.record(), capacity)
    assert {:ok, ^v, :inserted} = Memory.volume_accept(store, v, capacity)
    assert {:ok, %{disk_gb: 4}} = Memory.usage(store, "worker")
    assert {:ok, ^v, :existing} = Memory.volume_accept(store, v, capacity)

    crossed = %{
      v
      | native_authority: %{
          v.native_authority
          | binding: %{binding | generation: String.duplicate("f", 32)}
        }
    }

    assert {:error, _} = Memory.volume_accept(store, crossed, capacity)
    assert {:error, _} = Memory.volume_change(store, Volume.key(v), 1, {:complete, :ready}, 1001)

    assert {:ok, ready, :changed} =
             Memory.volume_change(
               store,
               Volume.key(v),
               1,
               {:complete_native, fixture()["outcome"]},
               1001
             )

    assert {:ok, [^ready], nil} = Memory.backend_assignments(store, "worker", nil, 10)
    assert {:error, _} = Memory.bind_backend(store, "worker", :http)

    assert {:ok, intent, :changed} =
             Memory.volume_change(store, Volume.key(v), ready.version, :delete, 1002)

    assert {:error, _} =
             Memory.volume_change(
               store,
               Volume.key(v),
               intent.version,
               {:complete, :deleted},
               1003
             )

    assert {:ok, %{disk_gb: 4}} = Memory.usage(store, "worker")

    assert {:ok, deleted, :changed} =
             Memory.volume_change(
               store,
               Volume.key(v),
               intent.version,
               {:complete_native, deletion(ready.native_authority.provision)},
               1003
             )

    assert {:ok, %{disk_gb: 0}} = Memory.usage(store, "worker")
    assert {:ok, [^deleted], nil} = Memory.backend_assignments(store, "worker", nil, 10)
    assert {:error, _} = Memory.bind_backend(store, "worker", :http)

    assert {:error, _} =
             Memory.bind_backend(store, "worker", %{
               binding
               | generation: String.duplicate("f", 32)
             })
  end

  test "fresh BEAM loads fixed volume authority vocabulary before safe v20 decoding" do
    {:ok, bytes} = Codec.encode(ready())

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-native-volume-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

    code = ~S"""
    [path] = System.argv()
    case path |> File.read!() |> SmolBox.Store.Codec.decode() do
      {:ok, %{state: :ready, native_authority: %{provision: %{"backing" => %{"inode" => 18446744073709551614}}}}} -> IO.puts("fresh-volume")
      _ -> System.halt(1)
    end
    """

    assert {"fresh-volume\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end
end
