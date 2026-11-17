defmodule SmolBox.Kubernetes.NodeAuthority do
  @moduledoc """
  Explicit node evidence through an administrator-installed standalone authority.

  Connection fields name one host/port/user, private identity file and pinned
  known-hosts file. Expected authority and verifier-manifest digests come from the
  administrator's enrollment descriptor. Construction is offline: no SSH,
  credential lookup or installation occurs. Inspect redacts the context.

  This provider has no lab-wrapper or API-only fallback. It observes one enrolled
  node using bounded framed SSH requests; it cannot install/reset infrastructure
  or create, stop or delete workloads. The existing same-host controller guard
  remains required. Operational selection requires manual qualification of the
  exact node/runtime/access setup; this module alone makes no qualification claim.
  """
  @behaviour SmolBox.Kubernetes.NodeEvidence
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.{Binding, Operation}
  alias SmolBox.Kubernetes.NodeAuthority.{Context, Protocol, Transport}
  alias SmolBox.Validation

  @doc "Validate explicit connection/approval data without accessing files or a node."
  def new(options),
    do:
      Validation.construct(
        Context,
        options,
        [
          :ssh_host,
          :ssh_port,
          :ssh_user,
          :identity_file,
          :known_hosts_file,
          :authority_generation,
          :verifier_manifest_sha256
        ],
        [:ssh_executable]
      )

  @impl true
  def check(binding, budget, context), do: request(:check, binding, nil, budget, context)

  @impl true
  def capture(binding, pod_uid, budget, context),
    do: request(:capture, binding, pod_uid, budget, context)

  @impl true
  def cleanup(binding, receipt, budget, context),
    do: request(:cleanup, binding, receipt, budget, context)

  defp request(action, binding, argument, budget, context) do
    started = Operation.now()

    with :ok <- Context.validate(context),
         true <- Budget.valid?(budget) and Binding.valid?(binding) do
      deadline = started + min(30_000, budget.timeout_ms)
      exchange(action, binding, argument, budget, context, deadline)
    else
      _ -> failure(:validation)
    end
  rescue
    _ -> failure(:identity_conflict)
  catch
    _, _ -> failure(:identity_conflict)
  end

  defp exchange(action, binding, argument, budget, context, deadline) do
    nonce = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    with {:ok, remaining} <- Budget.until(budget, deadline, :worker),
         {:ok, request, body} <-
           Protocol.request(action, binding, argument, context, remaining, nonce),
         {:ok, {status, bytes}} <- Transport.request(context, body, remaining, deadline),
         {:ok, value} <-
           Protocol.response(
             bytes,
             request,
             binding,
             argument,
             System.system_time(:millisecond),
             status
           ),
         {:ok, _} <- Budget.until(budget, deadline, :worker),
         do: {:ok, value},
         else: (
           {:error, category} when is_atom(category) -> failure(category)
           _ -> failure(if(Operation.now() >= deadline, do: :expired, else: :transport))
         )
  end

  defp failure(category), do: Operation.error(category, :worker, :not_dispatched)
end
