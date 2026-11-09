defmodule SmolBox.Runtime.NativeReadyBranchResolution do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Embedded.{BranchCompletion, NativeBranchAuthority, NativeBranchResult}
  alias SmolBox.Runtime.{Deadline, MachineSession, NativeResolution, Session, Target}

  def run(
        _,
        _,
        %{branch: %{state: state, native_authority: %{completion: %BranchCompletion{}}}} = child
      )
      when state in [:held, :ready] do
    if ManagedMachine.validate(child) == :ok,
      do: {:ok, child},
      else: Session.error(:identity_conflict, :branch)
  end

  def run(config, coordinator, child) do
    with :ok <- ManagedMachine.validate(child),
         true <- eligible?(child),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         :ok <- Target.require_operation(worker, :resolve_ready_branch) do
      deadline = now() + min(Target.connection(worker).budget.timeout_ms, 30_000)

      NativeResolution.run(
        config,
        coordinator,
        parent,
        worker,
        {:ordinary_branch, :branch_resolve_ready},
        fn pinned -> resume(config, parent, child, pinned, deadline) end,
        deadline
      )
    else
      false -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  defp resume(config, parent, child, worker, deadline) do
    with {:ok, timeout} <- Deadline.remaining(deadline, :branch),
         {:ok, result} <- observe(config, parent, child, worker, timeout),
         do: uncertain(commit(config, child, result, deadline))
  end

  defp eligible?(
         %{
           branch: %{
             state: :unknown,
             native_authority: %{
               completion: nil,
               release: nil,
               disposal: nil,
               partial_collection: nil
             }
           }
         } = child
       ),
       do: NativeBranchAuthority.child?(child)

  defp eligible?(_), do: false

  defp observe(config, parent, child, worker, timeout) do
    reference =
      worker
      |> Target.connection(parent)
      |> Backend.bounded(
        timeout_ms: timeout,
        max_request_bytes: 28 * 1024,
        max_response_bytes: 100 * 1024
      )

    io_record = %{parent | operation_deadline_ms: config.clock.now() + timeout}

    case MachineSession.io(config, io_record, fn ->
           {:native_response, Backend.resolve_ready_branch(reference, parent, child)}
         end) do
      {:native_response, {:ok, %NativeBranchResult{} = result}} ->
        if NativeBranchResult.bound?(result, parent, child) and
             get_in(result.completion.publication, ~w(change child_origin intent epoch)) ==
               Target.connection(worker).context.epoch and
             result.completion.publication["change"]["platform"] ==
               Atom.to_string(Target.connection(worker).context.config.platform),
           do: {:ok, result},
           else: uncertain(Session.error(:identity_conflict, :branch))

      {:native_response, {:error, %Error{}} = error} ->
        error

      {:error, %Error{}} = error ->
        uncertain(error)

      _ ->
        uncertain(Session.error(:unknown, :branch))
    end
  end

  defp commit(config, child, result, deadline),
    do: MachineSession.commit_branch_result(config, child, result, deadline)

  defp uncertain(result), do: Error.uncertain(result, :branch)
  defp now, do: System.monotonic_time(:millisecond)
end
