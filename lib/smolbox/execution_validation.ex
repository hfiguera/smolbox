defmodule SmolBox.ExecutionValidation do
  @moduledoc false

  alias SmolBox.{Error, Execution, Machine, MachineSpec, Validation}

  @spec metadata?(map()) :: boolean()
  def metadata?(record) do
    Validation.struct_shape?(record, Execution) and deadlines?(record) and
      reservation?(record) and machine?(record.created_machine, record) and
      artifacts?(record.artifacts, record.spec) and error?(record.last_error) and
      history?(record.errors)
  end

  defp deadlines?(record) do
    deadlines = record.deadlines

    is_map(deadlines) and map_size(deadlines) <= 5 and
      deadlines[:queue] == record.accepted_at_ms + record.spec.queue_ms and
      Enum.all?(deadlines, fn {stage, timestamp} ->
        stage in [:queue, :preparation, :execution, :collection, :cleanup] and
          Execution.timestamp?(timestamp) and timestamp >= record.accepted_at_ms
      end)
  end

  defp reservation?(%{worker_id: nil} = record) do
    record.reservation == nil and record.machine_name == nil and record.worker_generation == nil and
      record.created_machine == nil and record.state in [:accepted, :cancelled, :expired, :failed]
  end

  defp reservation?(record) do
    profile = record.spec.profile

    expected = %{
      cpus: profile.cpus,
      memory_mb: profile.memory_mb + profile.host_overhead_mb,
      disk_gb: profile.storage_gb + profile.overlay_gb,
      slots: 1
    }

    (record.reservation == expected or (record.reservation == nil and record.cleanup == :complete)) and
      Validation.identifier?(record.worker_id) and MachineSpec.valid_name?(record.machine_name) and
      Validation.integer?(record.worker_generation, 1, 9_007_199_254_740_991)
  end

  defp machine?(nil, _record), do: true

  defp machine?(%Machine{} = machine, record) do
    profile = record.spec.profile

    Validation.struct_shape?(machine, Machine) and machine.name == record.machine_name and
      machine.state in [:created, :running, :stopped] and
      Validation.integer?(machine.created_at, 0, 253_402_300_799) and
      machine.cpus == profile.cpus and machine.memory_mb == profile.memory_mb and
      machine.storage_gb == profile.storage_gb and machine.overlay_gb == profile.overlay_gb
  end

  defp machine?(_machine, _record), do: false

  defp artifacts?(artifacts, spec) do
    Validation.list?(artifacts, 32) and Enum.all?(artifacts, &artifact?(&1, spec.outputs)) and
      length(artifacts) == MapSet.size(MapSet.new(artifacts, & &1["path"]))
  end

  defp artifact?(
         %{"path" => path, "destination" => destination, "size" => size, "sha256" => digest} =
           artifact,
         outputs
       ) do
    declaration = Enum.find(outputs, &(&1["path"] == path and &1["destination"] == destination))

    map_size(artifact) == 4 and Validation.digest?(digest) and
      declaration != nil and Validation.integer?(size, 0, declaration["max_bytes"])
  end

  defp artifact?(_artifact, _outputs), do: false

  defp error?(nil), do: true

  defp error?(%Error{} = error) do
    Validation.struct_shape?(error, Error) and error.__exception__ == true and
      error.category in [
        :validation,
        :unsupported_capability,
        :authentication,
        :admission_exhausted,
        :expired,
        :transport,
        :protocol,
        :output_limit,
        :identity_conflict,
        :not_found,
        :store,
        :unknown,
        :cleanup,
        :stale_claim,
        :stale_version
      ] and
      error.operation in [
        :command,
        :worker,
        :machine_spec,
        :guest_path,
        :exec,
        :exec_stream,
        :execution_spec,
        :manifest,
        :profile,
        :identity,
        :machine,
        :client,
        :create,
        :list,
        :inspect,
        :start,
        :stop,
        :delete,
        :exec_options,
        :upload,
        :download,
        :machine_name,
        :request_size,
        :transport,
        :execution_state,
        :store,
        :claim,
        :reservation,
        :codec,
        :submit,
        :cancel,
        :reconcile,
        :cleanup,
        :artifact_store,
        :runtime
      ] and
      error.evidence in [
        :not_dispatched,
        :dispatch_uncertain,
        :running_observed,
        :exited,
        :termination_confirmed,
        :unknown
      ] and
      (is_nil(error.exit_code) or
         Validation.integer?(error.exit_code, -2_147_483_648, 2_147_483_647))
  end

  defp error?(_error), do: false

  defp history?(errors), do: Validation.list?(errors, 8) and Enum.all?(errors, &history_entry?/1)

  defp history_entry?(%{at_ms: at, error: error} = entry),
    do: map_size(entry) == 2 and Execution.timestamp?(at) and error?(error)

  defp history_entry?(_entry), do: false
end
