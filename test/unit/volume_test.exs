defmodule SmolBox.VolumeTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ManagedMachineSpec, Mount, Volume, VolumeMount, VolumePolicy}
  alias SmolBox.Store.{Codec, CodecExpansion, MachineContract, Memory, VolumeContract}

  test "paths are explicit, canonical, bounded and isolated from guest system targets" do
    for path <- [
          "/",
          "relative",
          "/a/../b",
          "/a/./b",
          "/a//b",
          "/a/",
          "/a\0b",
          "/a\\b",
          <<255>>,
          String.duplicate("/a", 3000)
        ] do
      assert {:error, _} = VolumePolicy.new("local", path)
      assert {:error, _} = Mount.new(path, "/mnt/volumes/data")
    end

    for target <- [
          "/etc",
          "/workspace",
          "/mnt/volumes",
          "/mnt/volumes-other/data",
          "/mnt/volumes/../etc"
        ] do
      assert {:error, _} = VolumeMount.new("data", target)
    end

    assert {:error, _} = Mount.from_wire([%{} | :improper])
    assert {:error, _} = VolumeMount.new("data", "/mnt/volumes/data", readonly: "true")
    assert {:error, _} = Mount.new("/owned/data", "/mnt/volumes/data", staged: true)
    {:ok, a} = VolumeMount.new("data", "/mnt/volumes/a")
    {:ok, b} = VolumeMount.new("other", "/mnt/volumes/a/b")
    refute VolumeMount.valid_list?([a, b])
    refute VolumeMount.valid_list?([a, %{a | target: "/mnt/volumes/b"}])
  end

  test "volumes cannot silently enter checkpoint machines or older durable envelopes" do
    m = VolumeContract.machine("mounted")
    assert {:error, _} = ManagedMachineSpec.validate(%{m.spec | checkpointable: true})

    assert {:error, _} =
             ManagedMachineSpec.validate(%{
               m.spec
               | artifact: Map.put(m.spec.artifact, "kind", "checkpoint")
             })

    assert {:ok, <<"smolbox-record-v15\0", _::binary>> = encoded} = Codec.encode(m)
    assert {:ok, ^m} = Codec.decode(encoded)

    assert {:error, _} =
             Codec.decode(
               String.replace_prefix(encoded, "smolbox-record-v15", "smolbox-record-v14")
             )

    ordinary = MachineContract.record("ordinary")
    assert {:ok, <<"smolbox-record-v5\0", _::binary>>} = Codec.encode(ordinary)
    legacy = CodecExpansion.strip(ordinary)

    for fields <- [%{mounts: []}, %{volume_worker_id: nil}] do
      forged = "smolbox-record-v5\0" <> :erlang.term_to_binary(Map.merge(legacy, fields))
      assert {:error, _} = Codec.decode(forged)
    end
  end

  test "codec rejects malformed volume fields, shape and state without losing tombstone identity" do
    v = VolumeContract.record()

    for changes <- [
          %{size_gb: 0},
          %{worker_volume_id: "../data"},
          %{state: :absent},
          %{attached_to: {"other", "id"}},
          %{policy: nil},
          %{updated_at_ms: 999},
          %{request_version: 3},
          %{extra: true}
        ] do
      altered = Map.merge(v, changes)
      assert {:error, _} = Volume.validate(altered)
      assert {:error, _} = Codec.encode(altered)
      assert {:error, _} = Codec.decode("smolbox-record-v15\0" <> :erlang.term_to_binary(altered))
    end

    for term <- [self(), [v | :improper], %{v | last_error: self()}] do
      assert {:error, _} = Codec.decode("smolbox-record-v15\0" <> :erlang.term_to_binary(term))
    end
  end

  test "memory record and byte limits include volumes and reject malformed inputs without crashing" do
    store = start_supervised!({Memory, max_records: 1})
    v = VolumeContract.ready(Memory, store)

    assert {:error, %{category: :admission_exhausted}} =
             Memory.machine(store, :accept, [VolumeContract.machine("too-many"), 10])

    assert {:ok, ^v} = Memory.volume_fetch(store, Volume.key(v))
    assert {:error, _} = Memory.volume_accept(store, %{}, %{})
    assert Process.alive?(store)
    small = start_supervised!({Memory, max_bytes: 1}, id: :small)

    assert {:error, %{category: :admission_exhausted}} =
             Memory.volume_accept(small, VolumeContract.record(), %{disk_gb: 10})

    assert {:ok, [], nil} = Memory.volume_list(small, "contract", nil, 1)
  end
end
