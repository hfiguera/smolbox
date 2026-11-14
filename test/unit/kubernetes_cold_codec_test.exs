defmodule SmolBox.KubernetesColdCodecTest do
  use ExUnit.Case, async: true
  alias SmolBox.Execution
  alias SmolBox.Kubernetes.Receipt
  alias SmolBox.Store.Codec
  alias SmolBox.Test.Kubernetes, as: Fixture

  test "tuple-wrapped authority and dispatched receipts survive fresh BEAM processes" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "smolbox-kube-cold-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, config} = Fixture.config()
    {record, assignment} = Fixture.assigned(config)
    {:ok, dispatched} = Execution.transition(record, [backend_create_state: :dispatched], 1000)
    {:ok, created} = Receipt.created(assignment, "pod-original")
    {:ok, saved} = Execution.transition(dispatched, [backend_receipt: created], 1000)

    {:ok, ready} =
      Execution.transition(saved, [backend_receipt: Fixture.ready_receipt(assignment)], 1000)

    code = """
    # Deliberately intern enrollment keys in another order before loading SDK modules.
    Enum.each(~w(runtime_policy_digest node_boot_id namespace_uid cluster_anchor_uid runtime_identity), &String.to_atom/1)
    {:ok, _} = Application.ensure_all_started(:crypto)
    Enum.each(System.argv(), fn path ->
      {:ok, record} = SmolBox.Store.Codec.decode(File.read!(path))
      :ok = SmolBox.Execution.validate(record)
      {:ok, bytes} = SmolBox.Store.Codec.encode(record)
      {:ok, ^record} = SmolBox.Store.Codec.decode(bytes)
    end)
    IO.puts("authority survived fresh VM")
    """

    paths =
      Enum.with_index([record, dispatched, saved, ready], fn value, index ->
        path = Path.join(directory, "authority-#{index}.etf")
        {:ok, bytes} = Codec.encode(value)
        File.write!(path, bytes)
        path
      end)

    sdk = :code.lib_dir(:smolbox) |> List.to_string() |> Path.join("ebin")
    json = :code.lib_dir(:jason) |> List.to_string() |> Path.join("ebin")
    args = ["--erl", "+S 2:2", "-pa", sdk, "-pa", json, "-e", code, "--"] ++ paths

    assert {"authority survived fresh VM\n", 0} =
             System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
  end
end
