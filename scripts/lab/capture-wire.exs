# Capture synthetic responses only, inside the disposable Linux candidate.
defmodule SmolBox.CaptureWire do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Client, Command, Health, Identity, Machine, MachineSpec, Result, Worker}
  alias SmolBox.Transport.Req
  alias SmolBox.Wire.SSE

  def run do
    assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
    version = System.fetch_env!("SMOLBOX_RUNTIME_VERSION")
    assert version in ["1.14.1", "1.14.6"]
    directory = "/home/lab/qualification/wire-#{version}"
    File.mkdir!(directory)

    {:ok, worker} =
      Worker.new("capture", "http://localhost", unix_socket: "/srv/sbq/run/api.sock")

    {:ok, client} = Client.new(worker)
    health = request(worker, :get, "/health", nil)
    assert {:ok, %Health{version: ^version, total: 0}} = Health.from_wire(Jason.decode!(health))
    File.write!(directory <> "/health.json", health)
    {:ok, name} = Identity.machine_name("wire")
    {:ok, spec} = MachineSpec.new(name, "/opt/smolbox/catalog/python.smolmachine")
    {:ok, wire} = MachineSpec.to_wire(spec)
    root = "/api/v1/machines"
    created = request(worker, :post, root, wire)
    assert {:ok, original} = Machine.from_wire(Jason.decode!(created))
    save_machine(directory, "created", created)

    running = request(worker, :post, root <> "/#{name}/start", %{})
    assert {:ok, observed} = Machine.from_wire(Jason.decode!(running))
    assert Machine.same_incarnation?(original, observed)
    save_machine(directory, "running", running)

    {:ok, command} =
      Command.new([
        "python",
        "-c",
        "import sys; sys.stdout.buffer.write(bytes([0,255,254])); sys.stderr.write('err'); sys.exit(7)"
      ])

    {:ok, wire} = Command.to_wire(command)
    bytes = request(worker, :post, root <> "/#{name}/exec", wire)

    assert {:ok, %Result{exit_code: 7, stdout: <<0, 255, 254>>, stderr: "err"}} =
             Result.from_wire(Jason.decode!(bytes), 1024)

    File.write!(directory <> "/exec.json", bytes)

    {:ok, command} = Command.new(["python", "-c", "print('café')"])
    {:ok, wire} = Command.to_wire(command)
    stream = request(worker, :post, root <> "/#{name}/exec/stream", wire, "text/event-stream")
    assert {:ok, parser, [{:stdout, "café\n"}, {:exit, 0}]} = SSE.feed(%SSE{}, stream)
    assert :ok = SSE.finish(parser)
    File.write!(directory <> "/exec.sse", stream)

    assert {:ok, observed} = Client.inspect_machine(client, name)
    assert Machine.same_incarnation?(original, observed)
    assert {:ok, %{state: :stopped}} = Client.stop(client, name)
    assert :ok = Client.delete(client, name)
    assert {:ok, []} = Client.list(client)
    IO.puts("Captured #{version} synthetic fixtures; owned machine deleted and inventory empty.")
  end

  defp request(worker, method, path, body, accept \\ "application/json") do
    request = %{
      method: method,
      path: path,
      body: if(body, do: Jason.encode!(body), else: ""),
      content_type: "application/json",
      accept: accept,
      max_bytes: 65_536,
      mode: :buffer
    }

    assert {:ok, bytes} = Req.request(worker, request)
    bytes
  end

  defp save_machine(directory, label, bytes) do
    normalized =
      bytes |> Jason.decode!() |> Map.merge(%{"name" => "fixture", "createdAt" => 1_700_000_000})

    normalized =
      if Map.has_key?(normalized, "pid"), do: Map.put(normalized, "pid", 123), else: normalized

    File.write!(directory <> "/#{label}.json", Jason.encode!(normalized, pretty: true))
  end
end

SmolBox.CaptureWire.run()
