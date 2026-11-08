defmodule SmolBox.NativeVolumeAttachmentTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Binding
  alias SmolBox.Embedded.{JSON, VolumeAttachment, VolumeAuthority}
  alias SmolBox.{ManagedMachine, Volume, VolumePolicy}

  alias SmolBox.Store.{
    BackendBindings,
    Codec,
    Memory,
    VolumeAttachments,
    VolumeContract,
    VolumeOps
  }

  defp fixture do
    {:ok, fixture} =
      File.read!("native/smolbox-protocol/fixtures/volume-authority.json") |> JSON.decode()

    fixture
  end

  defp volume do
    {:ok, policy} = VolumePolicy.new("local", "/srv/smolvm/volumes")

    v = %{
      VolumeContract.record()
      | policy: policy,
        size_gb: 4,
        worker_volume_id: fixture()["request"]["intent"]["worker_volume_id"],
        native_authority: %VolumeAuthority{
          binding: %Binding{
            kind: :embedded,
            target_id: "worker",
            generation: String.duplicate("b", 32)
          }
        }
    }

    {:ok, ready, _} = VolumeOps.change(v, 1, {:complete_native, fixture()["outcome"]}, 1001)
    ready
  end

  defp attached do
    v = volume()
    m = VolumeContract.machine("mounted")
    {:ok, m, volumes} = VolumeOps.attach(m, %{Volume.key(v) => v}, 1100)
    {m, volumes[Volume.key(v)]}
  end

  test "native attachment preserves exact private proof and public mount identity" do
    {machine, volume} = attached()
    assert :ok = ManagedMachine.validate(machine)
    assert VolumeAttachments.valid?(machine)
    [attachment] = machine.native_mounts
    assert attachment.volume_key == Volume.key(volume)
    assert attachment.binding == volume.native_authority.binding
    assert attachment.proof == volume.native_authority.provision
    assert VolumeAttachment.matches?(attachment, volume)
    assert VolumeAttachment.path(attachment) == Volume.path(volume)

    assert VolumeAttachment.wire(attachment) == %{
             "proof" => attachment.proof,
             "target" => "/mnt/volumes/data",
             "readonly" => false
           }

    refute inspect(attachment) =~ attachment.proof["backing"]["owner_token"]
    assert BackendBindings.record_binding(machine) == attachment.binding
    assert {:error, _} = BackendBindings.mounts(nil, machine)
    assert :ok = BackendBindings.mounts(attachment.binding, machine)
    assert {:error, _} = BackendBindings.mounts(:http, machine)
  end

  test "corrupted scope, proof, path and readonly mode cannot become a valid attachment" do
    {machine, volume} = attached()
    [attachment] = machine.native_mounts

    for changed <- [
          %{attachment | volume_key: {"other", volume.id}},
          %{attachment | binding: %{attachment.binding | generation: String.duplicate("f", 32)}},
          %{attachment | target: "/etc"},
          %{attachment | readonly: true},
          %{
            attachment
            | proof: put_in(attachment.proof, ~w(backing policy root), "/other/volumes")
          },
          Map.put(attachment, :extra, true)
        ] do
      assert {:error, _} = ManagedMachine.validate(%{machine | native_mounts: [changed]})
    end

    assert {:error, _} = ManagedMachine.update(machine, %{native_mounts: []}, 1200)

    assert :error =
             VolumeAttachment.new(%{volume | native_authority: :bad}, hd(machine.spec.volumes))

    assert {:error, _} = ManagedMachine.validate(%{machine | native_mounts: [attachment | :bad]})
  end

  test "mixed HTTP/native or different-domain volume sets reject without releasing existing authority" do
    v = volume()
    m = VolumeContract.machine("mixed", ["data", "other"])
    http = %{VolumeContract.record("other") | state: :ready}
    volumes = %{Volume.key(v) => v, Volume.key(http) => http}
    assert {:error, _} = VolumeOps.attach(m, volumes, 1100)
    assert volumes[Volume.key(v)].attached_to == nil
    assert volumes[Volume.key(http)].attached_to == nil
    binding = %{v.native_authority.binding | generation: String.duplicate("f", 32)}

    proof =
      put_in(v.native_authority.provision, ~w(backing domain_generation), binding.generation)

    other = %{
      v
      | id: "other",
        native_authority: %{v.native_authority | binding: binding, provision: proof}
    }

    assert {:error, _} =
             VolumeOps.attach(m, %{Volume.key(v) => v, Volume.key(other) => other}, 1100)
  end

  test "native release needs exact committed proof and preserves volume through machine retirement" do
    {machine, volume} = attached()
    assert {:ok, unchanged} = VolumeOps.release(machine, %{Volume.key(volume) => volume})
    assert unchanged[Volume.key(volume)] == volume

    {:ok, retired} =
      ManagedMachine.update(machine, %{state: :deleted, operation: nil, phase: nil}, 1200)

    assert {:ok, released} = VolumeOps.release(retired, %{Volume.key(volume) => volume})
    assert released[Volume.key(volume)].attached_to == nil
    assert released[Volume.key(volume)].native_authority == volume.native_authority
    assert Volume.resources(released[Volume.key(volume)]).disk_gb == 4
    crossed = put_in(volume.native_authority.provision, ~w(backing inode), 7)
    volume = %{volume | native_authority: %{volume.native_authority | provision: crossed}}
    assert {:error, _} = VolumeOps.release(retired, %{Volume.key(volume) => volume})
  end

  test "selective v21 roundtrips before allocation and rejects old envelopes or rewritten bindings" do
    {machine, _volume} = attached()
    assert {:ok, <<"smolbox-record-v21\0", payload::binary>> = bytes} = Codec.encode(machine)
    assert {:ok, ^machine} = Codec.decode(bytes)

    for version <- 1..20,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

    assert {:error, _} = Codec.decode(bytes <> <<0>>)

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v21\0" <> :erlang.term_to_binary(machine, compressed: 9)
             )

    legacy = VolumeContract.machine("http")
    assert {:ok, bytes} = Codec.encode(legacy)
    assert {:ok, ^legacy} = Codec.decode(bytes)
    assert {:error, _} = Codec.decode("smolbox-record-v21\0" <> :erlang.term_to_binary(legacy))

    assert {:ok, ^bytes} =
             Codec.encode(legacy |> Map.delete(:native_mounts) |> Map.put(:native_mounts, []))
  end

  test "Memory attachment is atomic, exclusive, binding-checked and released on unassigned cancellation" do
    store = start_supervised!(Memory)
    v = volume()

    creating = %{
      v
      | state: :creating,
        version: 1,
        native_authority: %{v.native_authority | provision: nil}
    }

    binding = v.native_authority.binding
    assert {:ok, _} = Memory.bind_backend(store, "worker", binding)
    assert {:ok, _, _} = Memory.volume_accept(store, creating, %{disk_gb: 4})

    assert {:ok, ready, _} =
             Memory.volume_change(
               store,
               Volume.key(v),
               1,
               {:complete_native, fixture()["outcome"]},
               1001
             )

    machine = VolumeContract.machine("atomic")
    assert {:ok, saved} = Memory.machine(store, :accept, [machine, 10])
    assert [_attachment] = saved.native_mounts
    assert {:ok, held} = Memory.volume_fetch(store, Volume.key(v))
    assert held.attached_to == ManagedMachine.key(saved)
    assert held.native_authority == ready.native_authority
    assert {:error, _} = Memory.machine(store, :accept, [VolumeContract.machine("competing"), 10])
    assert {:error, _} = Memory.volume_change(store, Volume.key(v), held.version, :delete, 1200)

    assert {:ok, retired} =
             Memory.machine(store, :request, [
               ManagedMachine.key(saved),
               :delete,
               saved.version,
               1200
             ])

    assert retired.native_mounts == saved.native_mounts
    assert {:ok, free} = Memory.volume_fetch(store, Volume.key(v))
    assert free.attached_to == nil
    assert free.native_authority == ready.native_authority
    assert {:ok, %{disk_gb: 4}} = Memory.usage(store, "worker")
  end

  test "fresh BEAM loads native attachment vocabulary before safe v21 decoding" do
    {machine, _} = attached()
    {:ok, bytes} = Codec.encode(machine)

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-native-mount-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code = ~S"""
    [path] = System.argv()
    case path |> File.read!() |> SmolBox.Store.Codec.decode() do
      {:ok, %{native_mounts: [%SmolBox.Embedded.VolumeAttachment{proof: %{"backing" => %{"inode" => 18446744073709551614}}}]}} -> IO.puts("fresh-mount")
      _ -> System.halt(1)
    end
    """

    assert {"fresh-mount\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end
end
