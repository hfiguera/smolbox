defmodule SmolBox.Store.BackendBindings do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.{Error, Validation}

  def bind(worker, current, requested, evidence) do
    cond do
      not valid?(worker, requested) -> error(:validation)
      evidence not in [:empty, requested] -> error(:identity_conflict)
      current == requested -> {:ok, requested}
      evidence != :empty and current != nil -> error(:identity_conflict)
      true -> {:ok, requested}
    end
  end

  def evidence(records, worker),
    do:
      Enum.reduce(records, :empty, fn record, current ->
        if record.worker_id == worker, do: merge(current, record_binding(record)), else: current
      end)

  def merge(:empty, binding), do: binding
  def merge(binding, :empty), do: binding
  def merge(binding, binding), do: binding
  def merge(_first, _second), do: :conflict

  def record_binding(%{backend_assignment: %Assignment{binding: binding}}), do: binding

  def record_binding(%{backend_assignment: %SmolBox.Kubernetes.Assignment{binding: binding}}),
    do: binding

  def record_binding(%SmolBox.Volume{native_authority: %{binding: binding}}), do: binding

  def record_binding(%SmolBox.ManagedMachine{native_mounts: [%{binding: binding} | _]}),
    do: binding

  def record_binding(%{backend_assignment: nil}), do: :http
  def record_binding(%SmolBox.Volume{native_authority: nil}), do: :http
  def record_binding(_record), do: :conflict

  def valid?(worker, :http), do: Validation.identifier?(worker)

  def valid?(worker, %Binding{} = binding),
    do: Binding.valid?(binding) and binding.target_id == worker

  def valid?(worker, %SmolBox.Kubernetes.Binding{} = binding),
    do: SmolBox.Kubernetes.Binding.valid?(binding) and binding.target_id == worker

  def valid?(_worker, _binding), do: false

  def allocation({worker, name, capacity}, binding) when binding in [nil, :http],
    do: {:ok, worker, name, capacity, nil}

  def allocation({worker, name, capacity, %Assignment{} = assignment}, binding) do
    if Assignment.valid?(assignment) and assignment.binding == binding and
         assignment.binding.target_id == worker and assignment.creation["name"] == name,
       do: {:ok, worker, name, capacity, assignment},
       else: error(:identity_conflict)
  end

  def allocation({worker, name, capacity, %SmolBox.Kubernetes.Assignment{} = assignment}, binding) do
    if SmolBox.Kubernetes.Assignment.valid?(assignment) and assignment.binding == binding and
         assignment.binding.target_id == worker and assignment.pod_name == name,
       do: {:ok, worker, name, capacity, assignment},
       else: error(:identity_conflict)
  end

  def allocation(_allocation, _binding), do: error(:identity_conflict)

  def http(binding) when binding in [nil, :http], do: :ok
  def http(_binding), do: error(:unsupported_capability)

  def volume(binding, %SmolBox.Volume{native_authority: nil}), do: http(binding)

  def volume(binding, %SmolBox.Volume{worker_id: worker, native_authority: %{binding: requested}}),
      do:
        if(valid?(worker, requested) and binding == requested,
          do: :ok,
          else: error(:identity_conflict)
        )

  def volume(_, _), do: error(:validation)

  def mounts(binding, %{native_mounts: []}), do: http(binding)

  def mounts(binding, %{volume_worker_id: worker, native_mounts: [%{binding: expected} | _]}),
    do:
      if(valid?(worker, expected) and binding == expected,
        do: :ok,
        else: error(:identity_conflict)
      )

  def mounts(_, _), do: error(:validation)

  def unbound(evidence) when evidence in [:empty, :http], do: :ok
  def unbound(_evidence), do: error(:identity_conflict)

  def worker(allocation) when is_tuple(allocation) and tuple_size(allocation) in [3, 4],
    do: elem(allocation, 0)

  def worker(_allocation), do: nil

  def available?(bindings, worker, %Binding{generation: generation}),
    do:
      Enum.all?(bindings, fn
        {other, %Binding{generation: ^generation}} -> other == worker
        _other -> true
      end)

  def available?(_bindings, _worker, :http), do: true

  def available?(bindings, worker, %SmolBox.Kubernetes.Binding{} = binding),
    do:
      Enum.all?(bindings, fn {other, existing} ->
        other == worker or not aliases?(existing, binding)
      end)

  def available?(_bindings, _worker, _invalid), do: false

  def aliases?(%SmolBox.Kubernetes.Binding{} = left, %SmolBox.Kubernetes.Binding{} = right),
    do:
      left.cluster_anchor_uid == right.cluster_anchor_uid and
        (left.namespace_uid == right.namespace_uid or left.node_uid == right.node_uid)

  def aliases?(%Binding{generation: generation}, %Binding{generation: generation}), do: true
  def aliases?(_, _), do: false
  defp error(category), do: {:error, %Error{category: category, operation: :reservation}}
end
