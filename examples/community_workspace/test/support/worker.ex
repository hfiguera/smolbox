defmodule Workspace.TestWorker do
  @moduledoc "Simulated transport for application tests; never real-worker evidence."
  @behaviour SmolBox.Transport
  def start_link(_),
    do:
      Agent.start_link(
        fn ->
          %{machines: %{}, files: %{}, commands: [], unavailable: false, lost_exec: false}
        end,
        name: __MODULE__
      )

  def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  def snapshot, do: Agent.get(__MODULE__, & &1)
  def configure(changes), do: Agent.update(__MODULE__, &Map.merge(&1, Map.new(changes)))

  def request(_worker, request) do
    Agent.get_and_update(__MODULE__, fn state ->
      if state.unavailable, do: {error(:unavailable), state}, else: route(request, state)
    end)
  end

  defp route(%{path: "/health"}, s),
    do:
      {json(%{
         "status" => "ok",
         "version" => "1.17.0",
         "machines" => %{"total" => map_size(s.machines), "running" => 0},
         "uptime_seconds" => 0
       }), s}

  defp route(%{path: "/readyz"}, s), do: {{:ok, ""}, s}

  defp route(%{method: :post, path: "/api/v1/machines", body: body}, s) do
    input = Jason.decode!(body)

    machine =
      Map.merge(
        %{
          "state" => "created",
          "createdAt" => 1_700_000_000,
          "mounts" => [],
          "gpu" => false,
          "cuda" => false,
          "branchable" => false,
          "image" => input["from"]
        },
        Map.take(
          input,
          ~w(image name cpus memoryMb storageGb overlayGb ports network networkBackend allowedHosts allowedCidrs)
        )
      )

    {json(machine), %{s | machines: Map.put(s.machines, input["name"], machine)}}
  end

  defp route(r, s) do
    case String.split(r.path, "/", trim: true) do
      ["api", "v1", "machines", name | suffix] ->
        case Map.fetch(s.machines, name) do
          {:ok, machine} -> machine(r, suffix, machine, s)
          :error -> {error(:not_found), s}
        end

      _ ->
        {error(:not_found), s}
    end
  end

  defp machine(%{method: :get}, [], m, s), do: {json(m), s}

  defp machine(%{method: :post}, [op], m, s) when op in ["start", "stop"] do
    updated = Map.put(m, "state", if(op == "start", do: "running", else: "stopped"))
    {json(updated), %{s | machines: Map.put(s.machines, m["name"], updated)}}
  end

  defp machine(%{method: :delete}, [], m, s),
    do: {json(%{"deleted" => m["name"]}), %{s | machines: Map.delete(s.machines, m["name"])}}

  defp machine(%{method: :post, body: body, mode: mode}, ["exec" | _], _m, s) do
    input = Jason.decode!(body)

    result =
      cond do
        s.lost_exec ->
          {:error,
           %SmolBox.Error{category: :unknown, operation: :exec, evidence: :dispatch_uncertain}}

        input["background"] ->
          json(%{"exitCode" => 0, "stdoutB64" => Base.encode64("pid=42\n"), "stderrB64" => ""})

        match?({:sse, _, _}, mode) ->
          {:ok,
           %SmolBox.Result{
             exit_code: 0,
             stdout: "simulated command output",
             stderr: "",
             encoding: :lossy_utf8
           }}

        true ->
          json(%{
            "exitCode" => 0,
            "stdoutB64" => Base.encode64("simulated command output"),
            "stderrB64" => ""
          })
      end

    {result, %{s | commands: [input | s.commands]}}
  end

  defp machine(%{method: :put, body: bytes}, ["files" | path], m, s) do
    {json(%{"path" => "/" <> Enum.join(path, "/"), "size" => byte_size(bytes)}),
     %{s | files: Map.put(s.files, {m["name"], path}, bytes)}}
  end

  defp machine(%{method: :get}, ["files" | path], m, s) do
    result =
      case Map.fetch(s.files, {m["name"], path}) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> error(:not_found)
      end

    {result, s}
  end

  defp machine(%{method: :get}, ["logs"], _m, s),
    do: {{:ok, %SmolBox.LogResult{lines: ["simulated console"]}}, s}

  defp json(value), do: {:ok, Jason.encode!(value)}

  defp error(category),
    do: {:error, %SmolBox.Error{category: category, operation: :test, evidence: :not_dispatched}}
end
