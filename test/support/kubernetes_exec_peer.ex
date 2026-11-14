defmodule SmolBox.KubernetesExecPeer do
  @moduledoc false
  @behaviour WebSock
  alias SmolBox.Files
  alias SmolBox.Kubernetes.{GuestHelper, WebSocket}
  alias SmolBox.KubernetesPeer, as: Peer

  defmodule Proof do
    @moduledoc false
    def check(_, _, _), do: {:error, :unused}
    def cleanup(_, _, _, _), do: {:error, :unused}

    def capture(_, _, _, observation),
      do: {:ok, %{observation | observed_at_ms: System.system_time(:millisecond)}}
  end

  def status(code) do
    object =
      if code == 0,
        do: %{"metadata" => %{}, "status" => "Success"},
        else: %{
          "status" => "Failure",
          "reason" => "NonZeroExitCode",
          "details" => %{
            "causes" => [%{"reason" => "ExitCode", "message" => Integer.to_string(code)}]
          }
        }

    {:binary, <<3, Jason.encode!(object)::binary>>}
  end

  def file_frames(operation, path, bytes, fields \\ %{}) do
    header =
      Map.merge(
        %{
          "version" => 1,
          "operation" => operation,
          "path" => path,
          "size" => byte_size(bytes),
          "sha256" => Files.sha256(bytes)
        },
        fields
      )
      |> Jason.encode!()

    data = if operation == "download", do: bytes, else: <<>>

    stdout =
      GuestHelper.ack() <>
        "SBF1" <> <<byte_size(header)::32>> <> header <> data

    parts = for <<part::binary-size(16_000) <- stdout>>, do: part
    tail = binary_part(stdout, length(parts) * 16_000, rem(byte_size(stdout), 16_000))

    Enum.map(parts ++ if(tail == "", do: [], else: [tail]), &{:binary, <<1, &1::binary>>}) ++
      [status(0)]
  end

  def install(peer, record, frames, options \\ []) do
    owner = self()
    route = "/api/v1/namespaces/smolbox-preview/pods/" <> record.machine_name <> "/exec"

    callback = fn conn ->
      offered = Plug.Conn.get_req_header(conn, "sec-websocket-protocol")
      send(owner, {:offered, offered})

      conn
      |> Plug.Conn.put_resp_header(
        "sec-websocket-protocol",
        Keyword.get(options, :protocol, WebSocket.protocol())
      )
      |> Plug.Conn.upgrade_adapter(
        :websocket,
        {__MODULE__, %{owner: owner, frames: frames, mode: Keyword.get(options, :mode, :normal)},
         []}
      )
    end

    Peer.change(peer, &put_in(&1, [:overrides, {"GET", route}], callback))
  end

  @impl true
  def init(options) do
    send(options.owner, {:exec_socket, self()})
    {:ok, Map.merge(options, %{input: <<>>, produced: false})}
  end

  @impl true
  def handle_in({<<0, bytes::binary>>, [opcode: :binary]}, state) do
    input = state.input <> bytes
    next = %{state | input: input}

    case request(input) do
      {:ok, header, data} when not state.produced ->
        send(state.owner, {:exec_request, self(), header})
        next = %{next | produced: true}

        respond(next, header, data)

      _ ->
        {:ok, next}
    end
  end

  def handle_in({<<255, 0>>, _}, state) do
    send(state.owner, :unexpected_eof)
    {:stop, :normal, state}
  end

  def handle_in(_, state), do: {:stop, :normal, state}

  defp respond(%{mode: :hold} = state, _, _), do: {:ok, state}

  defp respond(state, header, data) do
    frames = if is_function(state.frames, 2), do: state.frames.(header, data), else: state.frames
    send(self(), :finish)
    {:push, frames, state}
  end

  defp request(<<"SBP1", size::32, rest::binary>>)
       when size <= 65_536 and byte_size(rest) >= size + 8 do
    <<source::binary-size(^size), control::binary>> = rest
    digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    if digest == GuestHelper.sha256(), do: control(control), else: :more
  end

  defp request(_), do: :more

  defp control(<<"SBK1", size::32, rest::binary>>)
       when size <= 1_048_576 and byte_size(rest) >= size do
    <<header::binary-size(^size), data::binary>> = rest
    value = Jason.decode!(header)
    if byte_size(data) == value["data_bytes"], do: {:ok, value, data}, else: :more
  end

  defp control(_), do: :more

  @impl true
  def handle_info(:finish, state), do: {:stop, :normal, 1000, state}
  def handle_info({:frames, frames}, state), do: {:push, frames, state}
  @impl true
  def terminate(_, state), do: send(state.owner, {:exec_socket_closed, self()})
end
