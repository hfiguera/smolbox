defmodule SmolBox.Runtime.NativePartialBranchCollection do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Embedded.NativePartialBranchCollection, as: Collection
  alias SmolBox.Embedded.NativePartialBranchCollectionResult
  alias SmolBox.Embedded.PartialBranchCollectionCandidate
  alias SmolBox.Runtime.{MachineSession, NativeResolution, Session, Target}

  def run(config, coordinator, child, version) do
    with :ok <- ManagedMachine.validate(child),
         true <- matching_version?(child, version) do
      case child.branch.native_authority.partial_collection do
        %{proof: proof} when not is_nil(proof) ->
          {:ok, child}

        _ ->
          collect(config, coordinator, child, version)
      end
    else
      false -> Session.error(:stale_version, :branch)
      error -> error
    end
  end

  defp collect(config, coordinator, child, version) do
    with true <- Collection.eligible?(child),
         {:ok, %{kind: :embedded} = worker} <- MachineSession.worker(config, child),
         :ok <- Target.require_operation(worker, :collect_partial_branch),
         :ok <- require_candidate_operation(worker, child) do
      deadline = now() + min(Target.connection(worker).budget.timeout_ms, 30_000)
      fenced(config, coordinator, child, version, worker, deadline)
    else
      false -> Session.error(:unsupported_capability, :branch)
      {:ok, _} -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  defp require_candidate_operation(worker, %{
         branch: %{native_authority: %{partial_collection: nil}}
       }),
       do: Target.require_operation(worker, :inspect_partial_branch_collection)

  defp require_candidate_operation(_, _), do: :ok

  defp fenced(config, coordinator, child, version, worker, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         true <- Collection.pending?(parent, child) do
      NativeResolution.run(
        config,
        coordinator,
        parent,
        worker,
        :branch,
        fn pinned ->
          accept(config, parent, child, version, pinned, deadline)
        end,
        deadline
      )
    else
      false -> Session.error(:identity_conflict, :branch)
      error -> error
    end
  end

  defp accept(config, parent, child, version, worker, deadline) do
    with :ok <- inspect_candidate(config, parent, child, worker, deadline),
         do: accept_checked(config, parent, child, version, worker, deadline)
  end

  # Previously accepted actions retain their exact request and resume semantics.
  # A new candidate can neither replace them nor extend their captured deadline.
  defp inspect_candidate(_, _, %{branch: %{native_authority: %{partial_collection: saved}}}, _, _)
       when not is_nil(saved), do: :ok

  defp inspect_candidate(config, parent, child, worker, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, current} <- MachineSession.claim(config, ManagedMachine.key(parent)),
         {:ok, timeout} <- remaining(deadline),
         reference =
           worker
           |> Target.connection(current)
           |> Backend.bounded(
             timeout_ms: timeout,
             max_request_bytes: 21 * 1024,
             max_response_bytes: 6 * 1024
           ),
         io_record = %{current | operation_deadline_ms: config.clock.now() + timeout},
         {:native_response, {:ok, %PartialBranchCollectionCandidate{} = candidate}} <-
           MachineSession.io(config, io_record, fn ->
             {:native_response,
              Backend.invoke(reference, :inspect_partial_branch_collection, [current, child])}
           end),
         prospective =
           Collection.new(
             child.branch.native_authority,
             child.version,
             Atom.to_string(Target.connection(worker).context.config.platform)
           ).request,
         true <- PartialBranchCollectionCandidate.matches?(candidate, prospective),
         true <-
           candidate.epoch == Target.connection(worker).context.epoch and
             candidate.platform ==
               Atom.to_string(Target.connection(worker).context.config.platform),
         {:ok, _} <- remaining(deadline),
         do: :ok,
         else: (
           {:native_response, {:error, %Error{} = error}} ->
             {:error, %{error | operation: :branch}}

           {:error, _} = error ->
             error

           _ ->
             Session.error(:identity_conflict, :branch)
         )
  end

  defp accept_checked(config, parent, child, version, worker, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, current} <- MachineSession.claim(config, ManagedMachine.key(parent)),
         {:ok, _} <- remaining(deadline),
         {:ok, accepted} <-
           advance(
             config,
             current,
             child,
             {:accept_partial_collection, version,
              Atom.to_string(Target.connection(worker).context.config.platform)}
           ),
         do: dispatch(config, accepted, worker, deadline)
  end

  defp dispatch(
         _config,
         %{branch: %{native_authority: %{partial_collection: %{proof: proof}}}} = child,
         _worker,
         _deadline
       )
       when not is_nil(proof), do: {:ok, child}

  defp dispatch(config, child, worker, deadline) do
    result =
      with {:ok, _} <- remaining(deadline),
           {:ok, parent} <- MachineSession.claim(config, child.branch.source),
           {:ok, timeout} <- remaining(deadline),
           reference =
             worker
             |> Target.connection(parent)
             |> Backend.bounded(
               timeout_ms: timeout,
               max_request_bytes: 21 * 1024,
               max_response_bytes: 6 * 1024
             ),
           io_record = %{parent | operation_deadline_ms: config.clock.now() + timeout},
           {:native_response, {:ok, %NativePartialBranchCollectionResult{} = result}} <-
             MachineSession.io(config, io_record, fn ->
               {:native_response,
                Backend.invoke(reference, :collect_partial_branch, [parent, child])}
             end),
           true <- NativePartialBranchCollectionResult.bound?(result, child),
           {:ok, _} <- remaining(deadline),
           {:ok, parent} <- MachineSession.claim(config, child.branch.source),
           {:ok, _} <- remaining(deadline),
           do: advance(config, parent, child, {:complete_partial_collection, result}),
           else: (
             {:native_response, {:error, %Error{evidence: :not_dispatched} = error}} ->
               {:definitive_rejection, error}

             {:native_response, {:error, %Error{} = error}} ->
               {:error, error}

             {:error, %Error{}} = error ->
               error

             _ ->
               Session.error(:identity_conflict, :branch)
           )

    uncertain(result)
  end

  defp matching_version?(child, version) do
    saved = child.branch.native_authority.partial_collection
    version == child.version or (saved != nil and version == saved.version)
  end

  defp advance(config, parent, child, change),
    do:
      MachineSession.store(config, :branch_advance, [
        ManagedMachine.key(parent),
        Session.guard(parent),
        child.id,
        :unknown,
        change,
        config.clock.now()
      ])

  defp remaining(deadline) do
    timeout = deadline - now()
    if timeout > 0, do: {:ok, timeout}, else: Session.error(:expired, :branch)
  end

  defp uncertain({:error, %Error{} = error}),
    do: {:error, %{error | evidence: :dispatch_uncertain, operation: :branch}}

  defp uncertain({:definitive_rejection, %Error{} = error}),
    do: {:error, %{error | operation: :branch}}

  defp uncertain(value), do: value
  defp now, do: System.monotonic_time(:millisecond)
end
