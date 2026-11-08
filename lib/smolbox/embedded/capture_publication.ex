defmodule SmolBox.Embedded.CapturePublication do
  @moduledoc false
  alias SmolBox.Backend.Budget

  alias SmolBox.Embedded.{CaptureTransition, Shape}

  alias SmolBox.{CheckpointCapture, Error}

  # Only a frozen approved capture reaches this boundary. Output selection is
  # local; no controller path is sent to the native worker or reopened for bytes.
  def receive(capture, request, %Budget{} = budget, transfer) do
    deadline = System.monotonic_time(:millisecond) + budget.timeout_ms
    root = capture.spec.policy.root
    output = CheckpointCapture.path(capture)
    directory = Path.dirname(output)
    partial = output <> ".partial"

    with :ok <- CheckpointCapture.validate(capture),
         true <- capture_request?(capture, request),
         true <- Shape.id?(capture.fingerprint),
         {:ok, root_stat} <- private_directory(root),
         :ok <- fresh_directory(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, directory_stat} <- private_directory(directory),
         true <- directory_stat.uid == root_stat.uid,
         {:ok, result} <-
           File.open(partial, [:read, :write, :exclusive, :binary], fn io ->
             prepare_open(io, %{
               paths: {root, root_stat, directory, directory_stat},
               partial: partial,
               output: output,
               request: request,
               budget: budget,
               deadline: deadline,
               transfer: transfer
             })
           end) do
      result
    else
      {:error, %Error{} = failure} -> {:error, failure}
      _ -> error(:identity_conflict, :not_dispatched)
    end
  rescue
    _ -> error(:unknown, :dispatch_uncertain)
  end

  defp prepare_open(io, state) do
    {root, root_stat, directory, directory_stat} = state.paths

    with {:ok, opened} <- fd_stat(io),
         true <- opened.uid == root_stat.uid,
         :ok <- named_file(state.partial, opened),
         :ok <- File.chmod(state.partial, 0o600),
         {:ok, opened} <- fd_stat(io),
         :ok <- private_paths(root, root_stat, directory, directory_stat),
         :ok <- sync_directory(directory, directory_stat),
         :ok <- sync_directory(root, root_stat),
         :ok <- named_file(state.partial, opened) do
      receive_open(Map.merge(state, %{io: io, opened: opened}))
    else
      _ -> error(:identity_conflict, :not_dispatched)
    end
  end

  defp receive_open(%{
         io: io,
         opened: opened,
         paths: paths,
         partial: partial,
         output: output,
         request: request,
         budget: budget,
         deadline: deadline,
         transfer: transfer
       }) do
    count = :atomics.new(1, [])

    consumer =
      consumer(io, count, budget.max_response_bytes, request["request"]["max_bytes"], deadline)

    remaining = deadline - System.monotonic_time(:millisecond)

    result =
      with true <- remaining > 0,
           {:ok, transfer_budget} <- Budget.constrain(budget, timeout_ms: remaining),
           do: transfer.(consumer, transfer_budget),
           else: (_ ->
                    {:error,
                     %Error{category: :expired, operation: :checkpoint, evidence: :not_dispatched}})

    case result do
      {:ok, %{"result" => "captured", "transition" => wire},
       %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil} ->
        with {:ok, proof} <- CaptureTransition.from_wire(wire),
             true <-
               CaptureTransition.bound?(
                 proof,
                 request["receipt"],
                 request["operation_id"],
                 request["request"]
               ),
             :ok <- :file.sync(io),
             :ok <- verify_bytes(io, opened, proof.change["artifact"], deadline),
             :ok <- verify_paths(paths),
             :ok <- named_file(partial, opened),
             :ok <- File.ln(partial, output),
             :ok <- verify_paths(paths),
             :ok <- named_file(output, opened),
             :ok <- sync_directory(elem(paths, 2), elem(paths, 3)),
             :ok <- named_file(partial, opened),
             :ok <- File.rm(partial),
             :ok <- sync_directory(elem(paths, 2), elem(paths, 3)),
             true <- System.monotonic_time(:millisecond) < deadline do
          {:ok,
           %{
             sha256: proof.change["artifact"]["sha256"],
             size_bytes: proof.change["artifact"]["size_bytes"],
             native_transition: proof
           }}
        else
          _ -> error(:unknown, :dispatch_uncertain)
        end

      {:error, %Error{evidence: :not_dispatched} = failure} ->
        case fd_stat(io) do
          {:ok, %{size: 0}} -> {:error, %{failure | operation: :checkpoint}}
          _ -> error(:unknown, :dispatch_uncertain)
        end

      _ ->
        error(:unknown, :dispatch_uncertain)
    end
  rescue
    _ -> error(:unknown, :dispatch_uncertain)
  catch
    _, _ -> error(:unknown, :dispatch_uncertain)
  end

  defp consumer(io, count, window, maximum, deadline) do
    fn {:checkpoint, bytes} ->
      if System.monotonic_time(:millisecond) < deadline and byte_size(bytes) in 1..65_536 and
           byte_size(bytes) <= window and :atomics.add_get(count, 1, byte_size(bytes)) <= maximum,
         do: IO.binwrite(io, bytes),
         else: {:error, :expired}
    end
  end

  defp capture_request?(capture, request),
    do:
      capture.state == :dispatching and
        request["operation"] == "capture_checkpoint" and Shape.receipt?(request["receipt"], 2) and
        request["operation_id"] == capture.spec.id and
        request["request"] == %{
          "max_bytes" => capture.spec.policy.max_bytes,
          "idle" => capture.spec.idle
        }

  defp verify_bytes(io, opened, artifact, deadline) do
    with {:ok, current} <- fd_stat(io),
         true <- identity(current) == identity(opened) and current.size == artifact["size_bytes"],
         {:ok, 0} <- :file.position(io, :bof),
         {:ok, digest, size} <-
           hash(io, :crypto.hash_init(:sha256), 0, artifact["size_bytes"], deadline),
         true <- size == artifact["size_bytes"] and digest == artifact["sha256"],
         {:ok, final} <- fd_stat(io),
         true <- identity(final) == identity(opened) and final.size == size do
      :ok
    else
      _ -> :error
    end
  end

  defp hash(io, digest, size, maximum, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      case IO.binread(io, 65_536) do
        :eof ->
          {:ok, Base.encode16(:crypto.hash_final(digest), case: :lower), size}

        bytes when is_binary(bytes) and size + byte_size(bytes) <= maximum ->
          hash(io, :crypto.hash_update(digest, bytes), size + byte_size(bytes), maximum, deadline)

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp fd_stat(io) do
    case :file.read_file_info(io) do
      {:ok, record} -> {:ok, File.Stat.from_record(record)}
      _ -> :error
    end
  end

  defp fresh_directory(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> error(:identity_conflict, :dispatch_uncertain)
      _ -> error(:identity_conflict, :not_dispatched)
    end
  end

  defp named_file(path, opened) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and identity(stat) == identity(opened),
         do: :ok,
         else: (_ -> :error)
  end

  defp private_directory(path) do
    with {:ok, %{type: :directory, mode: mode} = stat} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o700,
         do: {:ok, stat},
         else: (_ -> :error)
  end

  defp sync_directory(path, original) do
    case :file.open(path, [:read, :raw, :directory]) do
      {:ok, io} ->
        try do
          with {:ok, actual} <- fd_stat(io),
               true <- identity(actual) == identity(original),
               :ok <- :file.sync(io),
               do: :ok,
               else: (_ -> :error)
        after
          :file.close(io)
        end

      _ ->
        :error
    end
  end

  defp private_paths(root, original_root, directory, original_directory) do
    with {:ok, actual_root} <- private_directory(root),
         {:ok, actual_directory} <- private_directory(directory),
         true <-
           identity(actual_root) == identity(original_root) and
             identity(actual_directory) == identity(original_directory),
         do: :ok,
         else: (_ -> :error)
  end

  defp verify_paths({root, root_stat, directory, directory_stat}),
    do: private_paths(root, root_stat, directory, directory_stat)

  defp identity(stat),
    do: {stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.gid, stat.mode}

  defp error(category, evidence),
    do: {:error, %Error{category: category, evidence: evidence, operation: :checkpoint}}
end
