defmodule SmolBox.Example.EmbeddedVolumeControl do
  @moduledoc """
  Same-owner control for an unresolved ordinary mounted-volume witness. Requests
  must be atomically published as mode-0600 `control.json` in its private output
  directory. Each request ID is consumed once before any API call. Mutations use
  the operator's exact inspected version; uncertain outcomes are never replayed.
  Closing requires the workflow's positive cleanup predicate.
  """
  import Bitwise
  alias SmolBox.Example.EmbeddedVolumes, as: Workflow
  alias SmolBox.{Machines, Volumes}
  @machines ~w(original readonly contender)
  @volumes ~w(data sibling rejected budget)

  def wait(context, close) do
    case receive_request(context.root) do
      {:ok, request} ->
        result = safe_dispatch(context, request, close)
        save_result(context.root, request["request_id"], result)
        if result == %{status: "closed"}, do: :ok, else: again(context, close)

      _ ->
        again(context, close)
    end
  end

  defp again(context, close) do
    Process.sleep(100)
    wait(context, close)
  end

  def receive_request(root) do
    path = Path.join(root, "control.json")

    case File.lstat(path) do
      {:error, :enoent} ->
        :none

      {:ok, stat} ->
        owner = File.stat!(root).uid

        with true <- stat.type == :regular and stat.size <= 4096 and stat.uid == owner,
             true <- band(stat.mode, 0o7777) == 0o600,
             {:ok, bytes} <- File.read(path),
             {:ok, request} <- Jason.decode(bytes),
             true <- valid?(request),
             processed = Path.join(root, "control-processed-" <> request["request_id"] <> ".json"),
             {:error, :enoent} <- File.lstat(processed),
             :ok <- File.rename(path, processed) do
          {:ok, request}
        else
          _ -> reject(path, root)
        end

      _ ->
        :rejected
    end
  rescue
    _ -> :rejected
  end

  defp valid?(%{"request_id" => id, "action" => action} = request) do
    request_id?(id) and shape?(action, request)
  end

  defp valid?(_), do: false

  defp request_id?(id),
    do: is_binary(id) and byte_size(id) in 1..64 and Regex.match?(~r/\A[a-z0-9]+\z/, id)

  defp shape?(action, request) when action in ["status", "close"],
    do: Enum.sort(Map.keys(request)) == ~w(action request_id)

  defp shape?(action, request)
       when action in ["stop_machine", "delete_machine", "delete_volume"] do
    ids = if action == "delete_volume", do: @volumes, else: @machines

    Enum.sort(Map.keys(request)) == ~w(action id request_id version) and
      request["id"] in ids and is_integer(request["version"]) and request["version"] > 0
  end

  defp shape?(_, _), do: false

  defp reject(path, root) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    File.rename(path, Path.join(root, "control-rejected-" <> suffix <> ".json"))
    :rejected
  end

  defp safe_dispatch(context, request, close) do
    dispatch(context, request, close)
  rescue
    _ -> %{status: "rejected"}
  catch
    _, _ -> %{status: "rejected"}
  end

  defp save_result(root, id, result) do
    save(root, "control-result-" <> id, result)
  rescue
    _ -> :diagnostic_unavailable
  catch
    _, _ -> :diagnostic_unavailable
  end

  defp dispatch(c, %{"action" => "status"}, _close) do
    machines = Enum.map(@machines, &state(Machines, c.scope, &1))
    volumes = Enum.map(@volumes, &state(Volumes, c.scope, &1))
    %{machines: machines, volumes: volumes}
  end

  defp dispatch(c, %{"action" => "close"}, close) do
    :ok = close.(c)
    %{status: "closed"}
  rescue
    _ -> %{status: "rejected"}
  catch
    _, _ -> %{status: "rejected"}
  end

  defp dispatch(c, request, _close) do
    {module, operation} =
      case request["action"] do
        "stop_machine" -> {Machines, :stop}
        "delete_machine" -> {Machines, :delete}
        "delete_volume" -> {Volumes, :delete}
      end

    case apply(module, operation, [Workflow, {c.scope, request["id"]}, request["version"]]) do
      {:ok, _} -> %{status: "accepted"}
      {:error, error} -> %{status: "rejected", category: error.category, evidence: error.evidence}
    end
  rescue
    _ -> %{status: "rejected"}
  catch
    _, _ -> %{status: "rejected"}
  end

  defp state(module, scope, id) do
    case module.inspect(Workflow, {scope, id}) do
      {:ok, record} -> %{id: id, state: record.state, version: record.version}
      {:error, error} -> %{id: id, category: error.category}
    end
  end

  defp save(root, name, result) do
    path = Path.join(root, name <> ".json")
    File.write!(path <> ".new", Jason.encode!(result), [:exclusive])
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
  end
end
