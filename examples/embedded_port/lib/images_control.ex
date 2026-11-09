defmodule SmolBox.Example.EmbeddedImagesControl do
  @moduledoc """
  Same-owner control for a retained ordinary image qualification. Publish a
  private `control.json` atomically. Exact inspected versions are required for
  mutations, and request IDs are consumed before dispatch. No automatic retry,
  process signaling, SDK editing or quiescence inference is available here.
  """
  import Bitwise
  alias SmolBox.Example.EmbeddedImages, as: Workflow
  alias SmolBox.Machines
  @scope "public-images-proof"

  def wait(c, close) do
    case receive_request(c.root) do
      {:ok, request} ->
        result = dispatch_safe(c, request, close)

        try do
          Workflow.save(c.root, "control-result-" <> request["request_id"], result)
        rescue
          _ -> :diagnostic_unavailable
        end

        unless result == %{status: "closed"}, do: again(c, close)

      _ ->
        again(c, close)
    end
  end

  defp again(c, close) do
    Process.sleep(100)
    wait(c, close)
  end

  @doc false
  def receive_request(root) do
    path = Path.join(root, "control.json")

    case File.lstat(path) do
      {:error, :enoent} ->
        :none

      {:ok, stat} ->
        with true <-
               stat.type == :regular and stat.size <= 4096 and stat.uid == File.stat!(root).uid,
             true <- band(stat.mode, 0o7777) == 0o600,
             {:ok, bytes} <- read_request(path),
             {:ok, request} <- Jason.decode(bytes),
             true <- valid?(request),
             processed = Path.join(root, "control-processed-" <> request["request_id"] <> ".json"),
             {:error, :enoent} <- File.lstat(processed),
             :ok <- File.rename(path, processed) do
          {:ok, request}
        else
          _ -> reject(root, path)
        end

      _ ->
        :rejected
    end
  rescue
    _ -> :rejected
  end

  defp read_request(path) do
    File.open(path, [:read, :binary], fn stream ->
      case IO.binread(stream, 4097) do
        bytes when is_binary(bytes) and byte_size(bytes) <= 4096 -> bytes
        _ -> raise ArgumentError, "control request exceeded its bound"
      end
    end)
  end

  defp valid?(%{"request_id" => id, "action" => action} = request) do
    is_binary(id) and byte_size(id) in 1..64 and Regex.match?(~r/\A[a-z0-9]+\z/, id) and
      shape?(action, request)
  end

  defp valid?(_), do: false

  defp shape?(action, request) when action in ["status", "close"],
    do: Enum.sort(Map.keys(request)) == ~w(action request_id)

  defp shape?(action, request) when action in ["stop_machine", "delete_machine"],
    do: Enum.sort(Map.keys(request)) == ~w(action id request_id version) and machine?(request)

  defp shape?("stop_owned_machine", request),
    do: Enum.sort(Map.keys(request)) == ~w(action id request_id version) and machine?(request)

  defp shape?("resolve_machine", request),
    do:
      Enum.sort(Map.keys(request)) == ~w(action disposition id quiesced request_id version) and
        request["quiesced"] == true and request["disposition"] in ~w(stopped deleted) and
        machine?(request)

  defp shape?(_, _), do: false

  defp machine?(request),
    do:
      request["id"] in ~w(original warm) and
        is_integer(request["version"]) and request["version"] > 0

  defp reject(root, path) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    File.rename(path, Path.join(root, "control-rejected-" <> suffix <> ".json"))
    :rejected
  end

  defp dispatch_safe(c, request, close) do
    dispatch(c, request, close)
  rescue
    _ -> %{status: "rejected"}
  catch
    _, _ -> %{status: "rejected"}
  end

  defp dispatch(_c, %{"action" => "status"}, _close) do
    Map.new(~w(original warm), fn id ->
      value =
        case Machines.inspect(Workflow, {@scope, id}) do
          {:ok, record} ->
            Map.put(
              Map.take(record, [:state, :version, :operation, :phase]),
              :active_execution,
              record.active_execution != nil
            )

          {:error, error} ->
            %{category: error.category}
        end

      {id, value}
    end)
  end

  defp dispatch(c, %{"action" => "close"}, close) do
    :ok = close.(c)
    %{status: "closed"}
  end

  defp dispatch(c, %{"action" => "stop_owned_machine"} = request, _close),
    do: result(Workflow.stop_owned(c, request["id"], request["version"]))

  defp dispatch(_c, %{"action" => "resolve_machine"} = request, _close),
    do:
      result(
        Machines.resolve(Workflow, {@scope, request["id"]}, request["version"],
          quiesced: true,
          disposition: if(request["disposition"] == "deleted", do: :deleted, else: :stopped)
        )
      )

  defp dispatch(_c, %{"action" => action} = request, _close) do
    result =
      case action do
        "stop_machine" -> Machines.stop(Workflow, {@scope, request["id"]}, request["version"])
        "delete_machine" -> Machines.delete(Workflow, {@scope, request["id"]}, request["version"])
      end

    result(result)
  end

  defp result({:ok, _}), do: %{status: "accepted"}

  defp result({:error, error}),
    do: Map.merge(%{status: "rejected"}, Map.take(error, [:category, :evidence]))
end
