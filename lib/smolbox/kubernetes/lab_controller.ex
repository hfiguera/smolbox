defmodule SmolBox.Kubernetes.LabController do
  @moduledoc """
  Same-host controller authority for the manual Kubernetes development lab.

  A private local directory retains the full bounded owner history. A new owner
  is refused while the prior BEAM PID/birth is alive, even when its store lease
  expired. The helper never accesses a store or Kubernetes. The runtime must
  authenticate the complete corpus and activate a new, empty domain separately.
  """
  alias SmolBox.Backend.Budget
  alias SmolBox.{Error, Validation}
  alias SmolBox.Kubernetes.{Binding, Shape}
  alias SmolBox.Kubernetes.LabController.{Context, Transport}

  def new(options),
    do: Validation.construct(Context, options, [:directory, :python_executable], [])

  def acquire(binding, owner, budget, %Context{} = context) do
    with {:ok, grant} <- request(context, :acquire, binding, owner, budget),
         next = %Context{
           context
           | owner: owner,
             domain_id: grant["domain_id"],
             generation: grant["generation"],
             known_owners: grant["known_owners"],
             enrolled: grant["enrolled"]
         },
         :ok <- Context.validate(next),
         do: {:ok, next},
         else: (_ -> unavailable())
  end

  def acquire(_, _, _, _), do: unavailable()

  def check(binding, budget, %Context{} = context) do
    with {:ok, grant} <- request(context, :check, binding, context.owner, budget),
         true <- same?(context, grant) and (not context.enrolled or grant["enrolled"]),
         do: :ok,
         else: (_ -> unavailable())
  end

  def check(_, _, _), do: unavailable()

  def activate(binding, budget, %Context{} = context) do
    with {:ok, grant} <- request(context, :activate, binding, context.owner, budget),
         true <- same?(context, grant) and grant["enrolled"] == true,
         do: {:ok, %{context | enrolled: true}},
         else: (_ -> unavailable())
  end

  def activate(_, _, _), do: unavailable()

  defp same?(context, grant),
    do:
      context.domain_id == grant["domain_id"] and context.generation == grant["generation"] and
        context.known_owners == grant["known_owners"] and context.owner == grant["owner"]

  defp request(context, action, binding, owner, budget) do
    with :ok <- Context.validate(context),
         true <- Binding.valid?(binding) and Budget.valid?(budget),
         true <- Validation.identifier?(owner),
         {:ok, %{"ok" => true, "grant" => grant}} <-
           Transport.request(context, action, binding, owner, budget),
         true <- grant?(grant, binding, owner),
         do: {:ok, grant},
         else: (_ -> unavailable())
  end

  defp grant?(value, binding, owner),
    do:
      Shape.exact_keys?(
        value,
        ~w(version binding_generation domain_id generation owner known_owners host_id boot_id pid birth enrolled)
      ) and
        value["version"] == 1 and value["binding_generation"] == binding.generation and
        value["owner"] == owner and
        host_grant?(value)

  defp host_grant?(value),
    do:
      value["pid"] == String.to_integer(System.pid()) and is_boolean(value["enrolled"]) and
        Shape.uid?(value["domain_id"]) and Shape.uid?(value["boot_id"]) and
        Validation.text?(value["host_id"], 128) and Validation.text?(value["birth"], 128)

  defp unavailable,
    do:
      {:error,
       %Error{category: :identity_conflict, operation: :reconcile, evidence: :not_dispatched}}
end
