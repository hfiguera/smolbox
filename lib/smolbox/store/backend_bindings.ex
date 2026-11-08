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
  def record_binding(_record), do: :http

  def valid?(worker, :http), do: Validation.identifier?(worker)

  def valid?(worker, %Binding{} = binding),
    do: Binding.valid?(binding) and binding.target_id == worker

  def valid?(_worker, _binding), do: false

  def allocation({worker, name, capacity}, binding) when binding in [nil, :http],
    do: {:ok, worker, name, capacity, nil}

  def allocation({worker, name, capacity, %Assignment{} = assignment}, binding) do
    if Assignment.valid?(assignment) and assignment.binding == binding and
         assignment.binding.target_id == worker and assignment.creation["name"] == name,
       do: {:ok, worker, name, capacity, assignment},
       else: error(:identity_conflict)
  end

  def allocation(_allocation, _binding), do: error(:identity_conflict)

  def http(binding) when binding in [nil, :http], do: :ok
  def http(_binding), do: error(:unsupported_capability)

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
  def available?(_bindings, _worker, _invalid), do: false
  defp error(category), do: {:error, %Error{category: category, operation: :reservation}}
end
