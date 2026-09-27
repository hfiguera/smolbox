defmodule Workspace.TestWorker do
  @moduledoc "Simulated transport for application tests; never real-worker evidence."
  @behaviour SmolBox.Transport
  def start_link(_),
    do:
      Agent.start_link(
        fn ->
          %{
            machines: %{},
            files: %{},
            commands: [],
            unavailable: false,
            lost_exec: false,
            lost_capture: false,
            lost_branch: false,
            saved: %{}
          }
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
         "version" => "1.19.0",
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
          "storageGb" => 1,
          "overlayGb" => 1,
          "createdAt" => 1_700_000_000,
          "mounts" => [],
          "gpu" => false,
          "cuda" => false,
          "branchable" => String.ends_with?(input["from"] || "", ".smolcheckpoint"),
          "image" =>
            if(String.ends_with?(input["from"] || "", ".smolcheckpoint"),
              do: nil,
              else: input["from"]
            )
        },
        Map.take(
          input,
          ~w(image name cpus memoryMb storageGb overlayGb ports network networkBackend allowedHosts allowedCidrs)
        )
      )

    {json(machine), %{s | machines: Map.put(s.machines, input["name"], machine)}}
  end

  defp route(r, s) do
    case String.split(URI.parse(r.path).path, "/", trim: true) do
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

  defp machine(%{method: :post} = r, [op], m, s) when op in ["start", "stop"] do
    updated =
      m
      |> Map.put("state", if(op == "start", do: "running", else: "stopped"))
      |> Map.put(
        "branchable",
        String.contains?(r.path, "branchable=true") or m["branchable"]
      )

    {json(updated), %{s | machines: Map.put(s.machines, m["name"], updated)}}
  end

  defp machine(%{method: :post, mode: {:file, io}}, ["checkpoint"], _m, s) do
    bytes = Workspace.SavedStateFixture.bytes()
    :ok = IO.binwrite(io, bytes)

    result =
      if s.lost_capture,
        do: uncertain(:checkpoint),
        else: {:ok, %{size_bytes: byte_size(bytes), sha256: SmolBox.Files.sha256(bytes)}}

    {result, s}
  end

  defp machine(%{method: :post, body: body}, ["branches"], m, s) do
    name = Jason.decode!(body)["name"]
    child = Map.merge(m, %{"name" => name, "branchable" => false, "branchpointHeld" => false})

    next = %{
      s
      | machines: Map.put(s.machines, name, child),
        saved: Map.put(s.saved, name, s.saved[m["name"]])
    }

    {if(s.lost_branch, do: uncertain(:branch), else: json(child)), next}
  end

  defp machine(%{method: :delete}, [], m, s),
    do: {json(%{"deleted" => m["name"]}), %{s | machines: Map.delete(s.machines, m["name"])}}

  defp machine(%{method: :post, body: body, mode: mode}, ["exec" | _], m, s) do
    input = Jason.decode!(body)
    {s, exit_code, stderr} = snapshot_file(input["command"], m, s)
    {s, stdout} = saved_command(input["command"], m, s)

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
             exit_code: exit_code,
             stdout: stdout,
             stderr: stderr,
             encoding: :lossy_utf8
           }}

        true ->
          json(%{
            "exitCode" => exit_code,
            "stdoutB64" => Base.encode64(stdout),
            "stderrB64" => Base.encode64(stderr)
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

  # Only model the snapshot protocol here; CollectionTest runs the actual Python.
  defp snapshot_file(["python3", "-c", _, source, destination, _], m, s) do
    bytes = Map.get(s.files, {m["name"], String.split(source, "/", trim: true)})
    files = Map.put(s.files, {m["name"], String.split(destination, "/", trim: true)}, bytes || "")

    {%{s | files: files}, if(bytes, do: 0, else: 1),
     if(bytes, do: "", else: "File not collected: missing")}
  end

  defp snapshot_file(_, _, s), do: {s, 0, ""}

  defp saved_command(["/bin/sh", "-lc", text], m, s) do
    value =
      cond do
        String.contains?(text, "printf 'Original recipe") ->
          "Original recipe: basil and lemon\nPrepared in memory\n"

        String.contains?(text, "printf 'Branch recipe") ->
          "Branch recipe: ginger and lime\nChanged in branch memory\n"

        true ->
          s.saved[m["name"]]
      end

    {%{s | saved: Map.put(s.saved, m["name"], value)}, value || "simulated command output"}
  end

  defp saved_command(_, _, s), do: {s, "simulated command output"}

  defp uncertain(op),
    do: {:error, %SmolBox.Error{category: :unknown, operation: op, evidence: :dispatch_uncertain}}

  defp json(value), do: {:ok, Jason.encode!(value)}

  defp error(category),
    do: {:error, %SmolBox.Error{category: category, operation: :test, evidence: :not_dispatched}}
end
