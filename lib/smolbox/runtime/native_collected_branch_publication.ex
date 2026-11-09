defmodule SmolBox.Runtime.NativeCollectedBranchPublication do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Embedded.NativeBranchAdmission
  alias SmolBox.Embedded.NativeCollectedBranchPublication, as: Publication
  alias SmolBox.Embedded.NativeCollectedBranchPublicationResult
  alias SmolBox.Runtime.{Deadline, MachineSession, NativeResolution, Session, Target}

  def run(config, coordinator, child, version) do
    with :ok <- ManagedMachine.validate(child),
         true <- matching_version?(child, version) do
      case child.branch.native_authority.collected_publication do
        %{proof: proof} when not is_nil(proof) ->
          {:ok, child}

        _ ->
          publish(config, coordinator, child, version)
      end
    else
      false -> Session.error(:stale_version, :branch)
      error -> error
    end
  end

  defp publish(config, coordinator, child, version) do
    with true <- Publication.eligible?(child),
         {:ok, %{kind: :embedded} = worker} <- MachineSession.worker(config, child),
         :ok <- Target.require_operation(worker, :publish_collected_branch_material) do
      deadline = now() + min(Target.connection(worker).budget.timeout_ms, 30_000)
      fenced(config, coordinator, child, version, worker, deadline)
    else
      false -> Session.error(:unsupported_capability, :branch)
      {:ok, _} -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  defp fenced(config, coordinator, child, version, worker, deadline) do
    with {:ok, _} <- Deadline.remaining(deadline, :branch),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         true <- NativeBranchAdmission.collected_publication_pending?(parent, child) do
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
    with {:ok, _} <- Deadline.remaining(deadline, :branch),
         {:ok, current} <- MachineSession.claim(config, ManagedMachine.key(parent)),
         {:ok, _} <- Deadline.remaining(deadline, :branch),
         {:ok, accepted} <-
           MachineSession.advance_unknown_branch(
             config,
             current,
             child,
             {:accept_collected_publication, version,
              Atom.to_string(Target.connection(worker).context.config.platform)}
           ),
         do: dispatch(config, accepted, worker, deadline)
  end

  defp dispatch(
         _config,
         %{branch: %{native_authority: %{collected_publication: %{proof: proof}}}} = child,
         _worker,
         _deadline
       )
       when not is_nil(proof), do: {:ok, child}

  defp dispatch(config, child, worker, deadline) do
    result =
      with {:ok, _} <- Deadline.remaining(deadline, :branch),
           {:ok, parent} <- MachineSession.claim(config, child.branch.source),
           {:ok, timeout} <- Deadline.remaining(deadline, :branch),
           reference =
             worker
             |> Target.connection(parent)
             |> Backend.bounded(
               timeout_ms: timeout,
               max_request_bytes: 24 * 1024,
               max_response_bytes: 84 * 1024
             ),
           io_record = %{parent | operation_deadline_ms: config.clock.now() + timeout},
           {:native_response, {:ok, %NativeCollectedBranchPublicationResult{} = result}} <-
             MachineSession.io(config, io_record, fn ->
               {:native_response,
                Backend.invoke(reference, :publish_collected_branch_material, [parent, child])}
             end),
           true <- result_bound?(result, parent, child, worker),
           {:ok, _} <- Deadline.remaining(deadline, :branch),
           {:ok, parent} <- MachineSession.claim(config, child.branch.source),
           {:ok, _} <- Deadline.remaining(deadline, :branch),
           do:
             MachineSession.advance_unknown_branch(
               config,
               parent,
               child,
               {:complete_collected_publication, result}
             ),
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

    Error.uncertain(result, :branch)
  end

  defp result_bound?(result, parent, child, worker) do
    context = Target.connection(worker).context

    NativeCollectedBranchPublicationResult.bound?(result, parent, child) and
      get_in(result.proof.change, ~w(child_origin intent epoch)) == context.epoch and
      result.proof.change["platform"] == Atom.to_string(context.config.platform)
  end

  defp matching_version?(child, version) do
    saved = child.branch.native_authority.collected_publication

    version == child.version or
      (saved != nil and version in [saved.version, saved.completion_version])
  end

  defp now, do: System.monotonic_time(:millisecond)
end
