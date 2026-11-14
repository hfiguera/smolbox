defmodule SmolBox.Kubernetes.LabNodeEvidence do
  @moduledoc """
  Node evidence for the dedicated single-VM K3s development lab only.

  The host must already have noninteractive, verified SSH access to `ssh_host`.
  That host runs the project's fixed guest SSH wrapper. The guest administrator
  separately installs the pinned inspector and transaction journal against an
  empty baseline. Callbacks cannot install/reset it or mutate runtime machines.

  Inspector/history source hashes are explicit host approvals. SSH configuration
  and credentials stay outside durable execution authority. There is no shell
  command, arbitrary inspector path, agent forwarding or lifecycle fallback.
  """
  @behaviour SmolBox.Kubernetes.NodeEvidence
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.{Binding, CleanupProof, Observation, Operation, Receipt, Shape}
  alias SmolBox.Kubernetes.LabNodeEvidence.{Context, Projection, Transport}
  alias SmolBox.Validation

  def new(options),
    do:
      Validation.construct(
        Context,
        options,
        [:ssh_host, :inspector_sha256, :history_sha256],
        [:ssh_executable]
      )

  @impl true
  def check(binding, budget, context) do
    with {:ok, value} <- request(:check, binding, %{}, budget, context),
         true <- Shape.exact_keys?(value, ~w(epoch complete_history idle)),
         true <-
           Shape.uid?(value["epoch"]) and value["complete_history"] == true and
             is_boolean(value["idle"]),
         do:
           {:ok, %{observer_epoch: value["epoch"], complete_history: true, idle: value["idle"]}},
         else: (_ -> unavailable())
  end

  @impl true
  def capture(binding, pod_uid, budget, context) do
    with true <- Shape.uid?(pod_uid),
         {:ok, value} <- request(:capture, binding, %{pod_uid: pod_uid}, budget, context),
         {:ok, observation} <- Projection.observation(value),
         true <-
           Observation.dispatchable?(
             observation,
             binding,
             pod_uid,
             System.system_time(:millisecond)
           ),
         do: {:ok, observation},
         else: (_ -> unavailable())
  end

  @impl true
  def cleanup(binding, receipt, budget, context) do
    with true <-
           Receipt.valid?(receipt) and receipt.phase == :ready and receipt.binding == binding,
         {:ok, value} <-
           request(:cleanup, binding, %{receipt: receipt_json(receipt)}, budget, context),
         {:ok, proof} <- Projection.cleanup(value, receipt),
         true <- CleanupProof.matches?(proof, receipt),
         true <- proof.observed_at_ms <= System.system_time(:millisecond),
         do: {:ok, proof},
         else: (_ -> unavailable())
  end

  defp request(action, binding, fields, budget, context) do
    with :ok <- Context.validate(context),
         true <- Binding.valid?(binding) and Budget.valid?(budget),
         {:ok, bytes} <-
           Jason.encode(
             Map.merge(fields, %{
               version: 1,
               action: action,
               binding: Map.from_struct(binding)
             })
           ),
         {:ok, response} when is_map(response) <- Transport.request(context, bytes, budget),
         true <-
           response["ok"] == true and response["version"] == 1 and
             response["action"] == Atom.to_string(action),
         true <-
           response["inspector_sha256"] == context.inspector_sha256 and
             response["history_sha256"] == context.history_sha256 and
             Validation.integer?(response["journal_watermark"], 0, 4096) and
             Validation.digest?(response["journal_hash"]),
         do: {:ok, response["value"]},
         else: (_ -> unavailable())
  end

  defp receipt_json(receipt),
    do:
      receipt
      |> Map.from_struct()
      |> Map.put(:binding, Map.from_struct(receipt.binding))
      |> Map.put(:observation, Map.from_struct(receipt.observation))

  defp unavailable,
    do: Operation.error(:identity_conflict, :worker, :not_dispatched)
end
