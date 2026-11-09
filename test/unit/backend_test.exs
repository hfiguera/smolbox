defmodule SmolBox.BackendTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Client, Error, Worker}
  alias SmolBox.Backend.{Budget, HTTP, Reference}
  alias SmolBox.Runtime.{Target, WorkerConfig}

  defmodule DomainAdapter do
    @behaviour SmolBox.Backend

    @impl true
    def supports_operation?(_context, operation), do: operation == :exec_stream

    @impl true
    def invoke(observer, operation, arguments, budget) do
      send(observer, {:invoked, operation, arguments, budget})

      {:error,
       %SmolBox.Error{category: :unknown, operation: operation, evidence: :dispatch_uncertain}}
    end
  end

  defmodule CaptureTransport do
    @behaviour SmolBox.Transport

    @impl true
    def request(worker, request) do
      send(self(), {:http_request, worker, request})

      {:error,
       %SmolBox.Error{category: :transport, operation: :create, evidence: :dispatch_uncertain}}
    end
  end

  defp reference do
    %Reference{
      adapter: DomainAdapter,
      kind: :embedded,
      id: "local",
      context: self(),
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 1024, max_response_bytes: 2048}
    }
  end

  test "unsupported lifecycle operations cannot enter the adapter" do
    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             Backend.delete(reference(), "owned")

    refute_received {:invoked, _, _, _}
  end

  test "domain adapters need no HTTP endpoint and uncertain outcomes are preserved" do
    ref = Backend.bounded(reference(), timeout_ms: 50, max_response_bytes: 128)
    {:ok, command} = SmolBox.Command.new(["/bin/true"])

    assert {:error, %Error{category: :unknown, evidence: :dispatch_uncertain}} =
             Backend.exec_stream(ref, "owned", command)

    assert_received {:invoked, :exec_stream, ["owned", ^command], budget}
    assert budget.timeout_ms == 50
    assert budget.max_response_bytes == 128
  end

  test "budgets only tighten and malformed references cannot dispatch" do
    ref = reference()
    assert Backend.bounded(ref, timeout_ms: 2000, max_response_bytes: 9999).budget == ref.budget

    for invalid <- [
          nil,
          %{ref | budget: %{ref.budget | timeout_ms: 0}},
          Map.put(ref, :extra, true)
        ] do
      assert {:error, %Error{category: :validation, evidence: :not_dispatched}} =
               Backend.exec_stream(invalid, "owned", %{})
    end

    assert_raise Error, fn -> Backend.bounded(ref, timeout_ms: 0) end
    assert_raise Error, fn -> Backend.bounded(ref, unrelated: 1) end
    refute_received {:invoked, _, _, _}
  end

  test "the HTTP adapter respects existing transport extensions and clamps their budgets" do
    {:ok, worker} = Worker.new("http", "https://worker.example", token: "private-token")
    {:ok, client} = Client.new(worker, transport: CaptureTransport)
    reference = Backend.bounded(HTTP.reference(client), timeout_ms: 75, max_response_bytes: 256)
    assert Backend.pin(reference) == reference
    refute_received {:http_request, _, _}
    {:ok, machine} = SmolBox.MachineSpec.new("owned", "/approved/image.smolmachine")

    assert {:error, %Error{evidence: :dispatch_uncertain}} = Backend.create(reference, machine)
    assert_received {:http_request, bounded, %{method: :post, path: "/api/v1/machines"}}
    assert bounded.operation_timeout_ms == 75
    assert bounded.max_response_bytes == 256
    assert client.worker == worker
  end

  test "normalized targets preserve approvals and redact host context" do
    worker = WorkerConfig.__struct__()
    keys = Map.keys(worker) -- [:__struct__]
    target_keys = Map.keys(Target.__struct__())
    assert Enum.all?(keys, &(&1 in target_keys))

    target = %Target{kind: :http, id: "local", artifacts: ["private-artifact"], client: "secret"}
    refute inspect(target) =~ "private-artifact"
    refute inspect(target) =~ "secret"
    assert {:error, %Error{category: :validation}} = Target.validate(target)
    assert {:error, %Error{category: :validation}} = Target.validate(%{target | client: nil})
  end

  test "HTTP rejects native partial branch collection without transport IO" do
    {:ok, worker} = Worker.new("http", "https://worker.example", token: "private-token")
    {:ok, client} = Client.new(worker, transport: CaptureTransport)

    for operation <- [
          :publish_collected_branch_material,
          :collect_partial_branch,
          :dispose_partial_branch,
          :resolve_partial_branch_disposal,
          :cleanup_partial_branch_disposal,
          :qualify_partial_branch_cleanup
        ] do
      assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
               Backend.invoke(HTTP.reference(client), operation, [nil, nil])
    end

    refute_received {:http_request, _, _}
  end
end
