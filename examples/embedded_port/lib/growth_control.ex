defmodule SmolBox.Example.EmbeddedGrowthControl do
  @moduledoc """
  Same-owner control for an unresolved ordinary disk-growth witness. Requests
  must be atomically published as mode-0600 `control.json` in its private output
  directory. Each request ID is consumed once before any API call. Mutations use
  the operator's exact inspected version; uncertain outcomes are never replayed.
  Closing requires the workflow's positive cleanup predicate.
  """
  import Bitwise
  alias SmolBox.Example.EmbeddedGrowth, as: Workflow
  alias SmolBox.Machines
  @machines ~w(original)

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
       when action in ["stop_machine", "stop_owned_machine", "delete_machine"] do
    Enum.sort(Map.keys(request)) == ~w(action id request_id version) and
      request["id"] in @machines and is_integer(request["version"]) and request["version"] > 0
  end

  defp shape?("resolve_growth", request) do
    Enum.sort(Map.keys(request)) == ~w(action expansion id quiesced request_id version) and
      request["id"] in @machines and request["expansion"] in ~w(first second) and
      request["quiesced"] == true and is_integer(request["version"]) and request["version"] > 0
  end

  defp shape?("resolve_machine", request) do
    Enum.sort(Map.keys(request)) == ~w(action id quiesced request_id version) and
      request["id"] in @machines and request["quiesced"] == true and
      is_integer(request["version"]) and request["version"] > 0
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
    case Machines.inspect(Workflow, {c.scope, "original"}) do
      {:ok, record} ->
        %{
          state: record.state,
          version: record.version,
          active_expansion: record.active_expansion,
          expansions: Map.new(record.disk_expansions, fn {id, value} -> {id, value.state} end)
        }

      {:error, error} ->
        %{category: error.category}
    end
  end

  defp dispatch(c, %{"action" => "close"}, close) do
    :ok = close.(c)
    %{status: "closed"}
  rescue
    _ -> %{status: "rejected"}
  catch
    _, _ -> %{status: "rejected"}
  end

  defp dispatch(c, %{"action" => "resolve_growth"} = request, _close) do
    result =
      Machines.resolve_disk_expansion(
        Workflow,
        {c.scope, request["id"]},
        request["expansion"],
        request["version"],
        quiesced: true
      )

    result(result)
  end

  defp dispatch(c, %{"action" => "resolve_machine"} = request, _close) do
    result(
      Machines.resolve(Workflow, {c.scope, request["id"]}, request["version"], quiesced: true)
    )
  end

  defp dispatch(c, %{"action" => "stop_owned_machine"} = request, _close),
    do: result(Workflow.stop_owned(c, request["id"], request["version"]))

  defp dispatch(c, request, _close) do
    operation = %{"stop_machine" => :stop, "delete_machine" => :delete}[request["action"]]
    result(apply(Machines, operation, [Workflow, {c.scope, request["id"]}, request["version"]]))
  end

  defp result({:ok, _}), do: %{status: "accepted"}

  defp result({:error, error}),
    do: %{status: "rejected", category: error.category, evidence: error.evidence}

  defp save(root, name, result) do
    path = Path.join(root, name <> ".json")
    File.write!(path <> ".new", Jason.encode!(result), [:exclusive])
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
  end
end
