defmodule SmolBox.Kubernetes.Observation do
  @moduledoc false
  alias SmolBox.Kubernetes.{Binding, Shape}
  alias SmolBox.Validation

  @enforce_keys [
    :binding_generation,
    :pod_uid,
    :sandbox_ids,
    :processes,
    :interfaces,
    :observer_epoch,
    :observed_at_ms,
    :guard_sha256,
    :guard_template_sha256,
    :complete_history,
    :isolated
  ]
  @derive {Inspect, only: [:pod_uid, :observed_at_ms]}
  defstruct @enforce_keys ++ [version: 1]
  @type t :: %__MODULE__{}

  def valid?(%__MODULE__{} = value),
    do:
      Validation.struct_shape?(value, __MODULE__) and value.version == 1 and
        identity?(value) and guard?(value) and
        processes?(value.processes, value.sandbox_ids) and
        interfaces?(value.interfaces, value.processes)

  def valid?(_value), do: false

  def matches?(value, binding, pod_uid),
    do:
      valid?(value) and Binding.valid?(binding) and value.pod_uid == pod_uid and
        value.binding_generation == binding.generation and
        value.guard_sha256 == binding.runtime_identity["guard_sha256"] and
        value.guard_template_sha256 == binding.runtime_identity["guard_template_sha256"] and
        Enum.all?(value.processes, &(&1.exe_sha256 == binding.runtime_identity["shim_sha256"]))

  def fresh?(value, now, max_age_ms \\ 5000),
    do:
      valid?(value) and Validation.timestamp?(now) and is_integer(max_age_ms) and max_age_ms > 0 and
        value.observed_at_ms <= now and now - value.observed_at_ms <= max_age_ms

  # Ownership can still be recorded when isolation is unavailable so that an
  # owned VM can be deleted. Application I/O requires this stronger predicate.
  def dispatchable?(value, binding, pod_uid, now),
    do:
      matches?(value, binding, pod_uid) and fresh?(value, now) and
        value.complete_history and value.isolated

  def vm_directory(sandbox_id),
    do: :crypto.hash(:sha256, sandbox_id) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp identity?(value),
    do:
      Validation.digest?(value.binding_generation) and Shape.uid?(value.pod_uid) and
        Shape.unique_list?(value.sandbox_ids, 16, &Validation.digest?/1) and
        value.sandbox_ids != [] and value.sandbox_ids == Enum.sort(value.sandbox_ids) and
        Shape.uid?(value.observer_epoch) and Validation.timestamp?(value.observed_at_ms)

  defp guard?(value),
    do:
      Validation.digest?(value.guard_sha256) and Validation.digest?(value.guard_template_sha256) and
        is_boolean(value.complete_history) and is_boolean(value.isolated)

  defp processes?(processes, ids),
    do:
      Shape.unique_list?(processes, 16, &process?(&1, ids)) and processes != [] and
        length(processes) == MapSet.size(MapSet.new(processes, & &1.sandbox_id)) and
        length(processes) == MapSet.size(MapSet.new(processes, & &1.pid))

  defp process?(value, ids),
    do:
      Shape.exact_keys?(value, [:sandbox_id, :vm_directory, :pid, :start_ticks, :exe_sha256, :kvm]) and
        value.sandbox_id in ids and value.vm_directory == vm_directory(value.sandbox_id) and
        Validation.integer?(value.pid, 1, 4_194_304) and
        Validation.integer?(value.start_ticks, 1, 9_223_372_036_854_775_807) and
        Validation.digest?(value.exe_sha256) and
        value.kvm == ["anon_inode:kvm-vcpu:0", "anon_inode:kvm-vcpu:1", "anon_inode:kvm-vm"]

  defp interfaces?(interfaces, processes),
    do:
      Shape.unique_list?(interfaces, 16, &interface?/1) and
        Enum.sort(Enum.map(interfaces, & &1.sandbox_id)) ==
          Enum.sort(Enum.map(processes, & &1.sandbox_id)) and
        length(interfaces) == MapSet.size(MapSet.new(interfaces, & &1.name)) and
        length(interfaces) == MapSet.size(MapSet.new(interfaces, & &1.ifindex))

  defp interface?(value),
    do:
      Shape.exact_keys?(value, [:sandbox_id, :name, :ifindex]) and
        Validation.digest?(value.sandbox_id) and is_binary(value.name) and
        Regex.match?(~r/\Aveth[0-9a-f]{1,11}\z/, value.name) and
        Validation.integer?(value.ifindex, 1, 2_147_483_647)
end
