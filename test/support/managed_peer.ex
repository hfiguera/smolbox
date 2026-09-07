defmodule SmolBox.ManagedPeer do
  @moduledoc false
  alias SmolBox.TestPeer

  def start(options \\ []) do
    agent =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{machines: %{}, files: %{}, commands: [], operations: [], options: options}
         end},
        id: make_ref()
      )

    port = TestPeer.start(&handle(&1, agent))
    {agent, port}
  end

  def snapshot(agent), do: Agent.get(agent, & &1)

  defp handle(conn, agent) do
    {:ok, body, conn} = TestPeer.body(conn)
    segments = conn.path_info

    response =
      Agent.get_and_update(agent, fn state ->
        state = %{state | operations: [{conn.method, conn.request_path} | state.operations]}
        route(conn.method, segments, body, state)
      end)

    respond(conn, response, agent)
  end

  defp route("GET", ["api", "v1", "machines"], _body, state),
    do: {{:json, 200, %{"machines" => Map.values(state.machines)}}, state}

  defp route("POST", ["api", "v1", "machines"], body, state) do
    input = Jason.decode!(body)

    machine =
      "test/fixtures/wire/created.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("name", input["name"])

    response = if state.options[:create_lost], do: {:json, 503, %{}}, else: {:json, 200, machine}
    {response, %{state | machines: Map.put(state.machines, machine["name"], machine)}}
  end

  defp route(method, ["api", "v1", "machines", name | suffix], body, state) do
    case Map.fetch(state.machines, name) do
      {:ok, machine} -> machine_route(method, suffix, body, machine, state)
      :error -> {{:json, 404, %{}}, state}
    end
  end

  defp machine_route("GET", [], _body, machine, state), do: {{:json, 200, machine}, state}

  defp machine_route("POST", [operation], _body, machine, state)
       when operation in ["start", "stop"] do
    updated = Map.put(machine, "state", if(operation == "start", do: "running", else: "stopped"))

    {{:json, 200, updated},
     %{state | machines: Map.put(state.machines, machine["name"], updated)}}
  end

  defp machine_route("DELETE", [], _body, machine, state) do
    failures = Keyword.get(state.options, :delete_failures, 0)

    if failures > 0 do
      {{:json, 503, %{}},
       %{state | options: Keyword.put(state.options, :delete_failures, failures - 1)}}
    else
      {{:json, 200, %{"deleted" => machine["name"]}},
       %{state | machines: Map.delete(state.machines, machine["name"])}}
    end
  end

  defp machine_route("POST", ["exec" | _stream], body, machine, state) do
    command = Jason.decode!(body)
    files = Map.put(state.files, {machine["name"], ["workspace", "out.bin"]}, <<0, 255, 17>>)

    {{:exec, machine["name"], state.options},
     %{state | commands: [command | state.commands], files: files}}
  end

  defp machine_route("PUT", ["files" | file], body, machine, state) do
    response = %{"path" => "/" <> Enum.join(file, "/"), "size" => byte_size(body)}

    {{:json, 200, response},
     %{state | files: Map.put(state.files, {machine["name"], file}, body)}}
  end

  defp machine_route("GET", ["files" | file], _body, machine, state) do
    case Map.fetch(state.files, {machine["name"], file}) do
      {:ok, bytes} -> {{:bytes, bytes}, state}
      :error -> {{:json, 404, %{}}, state}
    end
  end

  defp respond(conn, {:json, status, body}, _agent), do: TestPeer.json(conn, body, status)

  defp respond(conn, {:bytes, bytes}, _agent),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.send_resp(200, bytes)

  defp respond(conn, {:exec, name, options}, agent) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, "event: stdout\ndata: started\n\n")

    if options[:hold] do
      wait_stopped(agent, name, System.monotonic_time(:millisecond) + 5000)
      conn
    else
      {:ok, conn} = Plug.Conn.chunk(conn, "event: exit\ndata: {\"exitCode\":7}\n\n")
      conn
    end
  end

  defp wait_stopped(agent, name, deadline) do
    running = Agent.get(agent, &(get_in(&1, [:machines, name, "state"]) == "running"))

    if running and System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        20 -> wait_stopped(agent, name, deadline)
      end
    end
  end
end
