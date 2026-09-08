# Run with mix run inside the disposable Linux guest only.
import ExUnit.Assertions
alias SmolBox.{Client, Command, Error, Files, Identity, Machine, MachineSpec, Worker}

assert :os.type() == {:unix, :linux}
assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
assert {"kvm\n", 0} = System.cmd("systemd-detect-virt", [])
assert File.exists?("/dev/kvm")
assert System.version() == "1.20.4"
assert :erlang.system_info(:otp_release) == ~c"29"

{:ok, worker} =
  Worker.new("nested-lab", System.fetch_env!("SMOLBOX_RUNTIME_URL"),
    allow_insecure_loopback: true
  )

{:ok, client} = Client.new(worker)
assert {:ok, %{version: "1.14.1"}} = Client.health(client)
assert {:ok, []} = Client.list(client)
{:ok, name} = Identity.machine_name("nested")

{:ok, spec} =
  MachineSpec.new(name, System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT"),
    storage_gb: 20,
    overlay_gb: 10
  )

assert {:ok, created} = Client.create(client, spec)

try do
  assert {:ok, running} = Client.start(client, name)
  assert Machine.same_incarnation?(created, running)

  {descriptors, 0} = System.cmd("sudo", ["bash", "/home/lab/input/kvm-fds.sh"])
  # libkrun may close the initial /dev/kvm descriptor after creating the VM.
  # Live kernel VM and vCPU descriptors plus successful execution prove its use.
  assert descriptors =~ "anon_inode:kvm-vm"
  assert descriptors =~ "anon_inode:kvm-vcpu"

  source = """
  import pathlib, platform
  data = pathlib.Path('/workspace/input.bin').read_bytes()
  pathlib.Path('/workspace/output.bin').write_bytes(data[::-1])
  print(platform.system())
  raise SystemExit(7)
  """

  bytes = <<0, 255, 42>>
  assert :ok = Client.upload(client, name, "/workspace/main.py", source, Files.sha256(source))
  assert :ok = Client.upload(client, name, "/workspace/input.bin", bytes, Files.sha256(bytes))
  {:ok, command} = Command.new(["python", "/workspace/main.py"])
  assert {:ok, %{stdout: "Linux\n", exit_code: 7}} = Client.exec(client, name, command)
  assert {:ok, <<42, 255, 0>>} = Client.download(client, name, "/workspace/output.bin", 32)

  report = %{
    "nested_kvm_descriptors" => String.split(descriptors, "\n", trim: true),
    "guest_kernel" => System.cmd("uname", ["-r"]) |> elem(0) |> String.trim(),
    "elixir" => System.version(),
    "otp" =>
      File.read!(Path.join([to_string(:code.root_dir()), "releases", "29", "OTP_VERSION"]))
      |> String.trim(),
    "smolvm" => "1.14.1",
    "source_commit" => File.read!("/opt/smolbox/source-commit.txt") |> String.trim(),
    "source_staging" => true,
    "binary_roundtrip" => true,
    "nonzero_exit" => 7,
    "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
  }

  File.write!("/home/lab/nested-execution.json", Jason.encode!(report, pretty: true))
after
  assert {:ok, observed} = Client.inspect_machine(client, name)
  assert Machine.same_incarnation?(created, observed)
  assert {:ok, _stopped} = Client.stop(client, name)
  assert :ok = Client.delete(client, name)
  assert {:error, %Error{category: :not_found}} = Client.inspect_machine(client, name)
end

assert {:ok, []} = Client.list(client)
report = File.read!("/home/lab/nested-execution.json") |> Jason.decode!()
report = Map.merge(report, %{"cleanup" => "verified_absent", "status" => "passed"})
File.write!("/home/lab/nested-execution.json", Jason.encode!(report, pretty: true))
IO.puts("Real nested KVM, source/input staging, execution, collection and deletion passed.")
