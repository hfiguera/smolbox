defmodule SmolBox.Example.EmbeddedBranchControl do
  @moduledoc false
  import Bitwise
  alias SmolBox.{Branches, Checkpoints, Machines}
  alias SmolBox.Example.EmbeddedBranches, as: Workflow
  @ids ~w(source first held)
  @partial ~w(collect_partial publish_collected dispose_partial cleanup_partial)
  @versioned ~w(stop delete release retire backing resolve_ready resolve_deleted resolve_capture release_capture collect_deletion continue_deletion cleanup_deletion) ++
               @partial

  def wait(c) do
    result =
      case receive_request(c.root) do
        {:ok, request} ->
          result = safe_dispatch(c, request)

          try do
            Workflow.save(c.root, "control-result-" <> request["request_id"], result)
          rescue
            _ -> :diagnostic_unavailable
          catch
            _, _ -> :diagnostic_unavailable
          end

          result

        _ ->
          %{}
      end

    unless result[:closed] do
      Process.sleep(100)
      wait(c)
    end
  end

  def receive_request(root) do
    path = Path.join(root, "control.json")

    with {:ok, info} <- File.lstat(path),
         true <- info.type == :regular and info.size <= 4096 and info.uid == File.stat!(root).uid,
         true <- band(info.mode, 0o7777) == 0o600,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= 4096,
         {:ok, request} <- Jason.decode(bytes),
         true <- valid?(request),
         processed = Path.join(root, "control-processed-" <> request["request_id"] <> ".json"),
         {:error, :enoent} <- File.lstat(processed),
         :ok <- File.rename(path, processed) do
      {:ok, request}
    else
      {:error, :enoent} -> :none
      _ -> :rejected
    end
  rescue
    _ -> :rejected
  end

  defp valid?(%{"request_id" => id, "action" => action} = request) do
    is_binary(id) and byte_size(id) in 1..64 and Regex.match?(~r/\A[a-z0-9]+\z/, id) and
      shape?(action, request)
  end

  defp valid?(_), do: false

  defp shape?(action, request) when action in ~w(status close shutdown_retained),
    do: Enum.sort(Map.keys(request)) == ~w(action request_id)

  defp shape?(action, request) when action in @versioned do
    attestation = attestation(action)
    keys = ~w(action id request_id version) ++ Enum.map(attestation, &elem(&1, 0))

    Enum.sort(Map.keys(request)) == Enum.sort(keys) and
      original_handle?(request) and
      (action in ~w(stop delete) or
         (action in ~w(resolve_capture release_capture) and
            request["id"] == "source") or
         (action not in ~w(resolve_capture release_capture) and
            request["id"] != "source")) and
      Enum.all?(attestation, fn {key, value} -> request[key] == value end)
  end

  defp shape?(_, _), do: false

  defp attestation(action)
       when action in ~w(retire resolve_ready resolve_deleted resolve_capture collect_deletion continue_deletion cleanup_deletion),
       do: [{"quiesced", true}]

  defp attestation(action) when action in @partial, do: [{"quiesced", true}]
  defp attestation("release_capture"), do: [{"artifacts_removed", true}]
  defp attestation("backing"), do: [{"backing_removed", true}]
  defp attestation(_), do: []

  defp original_handle?(request),
    do: request["id"] in @ids and is_integer(request["version"]) and request["version"] > 0

  defp safe_dispatch(c, request) do
    dispatch(c, request)
  rescue
    _ -> %{status: "rejected"}
  catch
    _, _ -> %{status: "rejected"}
  end

  defp dispatch(c, %{"action" => "status"}) do
    records =
      Map.new(@ids, fn id ->
        value =
          case Machines.inspect(Workflow, {c.scope, id}) do
            {:ok, r} ->
              %{
                state: r.state,
                version: r.version,
                branch: if(r.branch, do: r.branch.state),
                captures: Map.new(r.captures, fn {id, capture} -> {id, capture.state} end)
              }

            {:error, e} ->
              %{category: e.category}
          end

        {id, value}
      end)

    %{records: records}
  end

  defp dispatch(c, %{"action" => "close"}) do
    :ok = Workflow.close(c)
    %{closed: true, retained_disks: false}
  end

  defp dispatch(c, %{"action" => "shutdown_retained", "request_id" => id}) do
    # Normal supervised shutdown only. Preserve records first and never claim
    # deletion, absence, backing release or reusable capacity from this action.
    :ok = Workflow.checkpoint(c, "shutdown-" <> id)
    :ok = Workflow.shutdown(c)
    %{closed: true, retained_disks: true}
  end

  defp dispatch(c, %{"id" => id, "version" => version} = request) do
    key = {c.scope, id}
    {:ok, %{version: ^version}} = Machines.inspect(Workflow, key)

    response = action(request["action"], key, version)

    case response do
      {:ok, _} ->
        %{status: "accepted"}

      {:error, e} ->
        %{status: "rejected", category: e.category, operation: e.operation, evidence: e.evidence}
    end
  end

  defp action("resolve_capture", {scope, "source"}, version),
    do: Checkpoints.resolve(Workflow, {scope, "source", "prepared"}, version, quiesced: true)

  defp action("release_capture", {scope, "source"}, _version),
    do: Checkpoints.release(Workflow, {scope, "source", "prepared"}, artifacts_removed: true)

  defp action("collect_deletion", key, version),
    do: Machines.collect_deletion(Workflow, key, version, quiesced: true)

  defp action("continue_deletion", key, version),
    do: Machines.continue_deletion(Workflow, key, version, quiesced: true)

  defp action("cleanup_deletion", key, version),
    do: Machines.cleanup_deletion(Workflow, key, version, quiesced: true)

  defp action("stop", key, version), do: Machines.stop(Workflow, key, version)
  defp action("delete", key, version), do: Machines.delete(Workflow, key, version)
  defp action("release", key, version), do: Branches.release(Workflow, key, version)
  defp action("retire", key, _version), do: Branches.retire(Workflow, key, quiesced: true)

  defp action("backing", key, _version),
    do: Branches.release_storage(Workflow, key, backing_removed: true)

  defp action("resolve_ready", key, _version),
    do: Branches.resolve(Workflow, key, quiesced: true, disposition: :keep)

  defp action("resolve_deleted", key, _version),
    do: Branches.resolve(Workflow, key, quiesced: true, disposition: :deleted)

  defp action("collect_partial", key, version),
    do: Branches.collect_partial(Workflow, key, version, quiesced: true)

  defp action("publish_collected", key, version),
    do: Branches.publish_collected(Workflow, key, version, quiesced: true)

  defp action("dispose_partial", key, version),
    do: Branches.dispose_partial(Workflow, key, version, quiesced: true)

  defp action("cleanup_partial", key, version),
    do: Branches.cleanup_partial(Workflow, key, version, quiesced: true)
end
