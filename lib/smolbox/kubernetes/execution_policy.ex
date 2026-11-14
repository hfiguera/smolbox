defmodule SmolBox.Kubernetes.ExecutionPolicy do
  @moduledoc false
  alias SmolBox.Command

  alias SmolBox.Kubernetes.{Config, GuestHelper}

  # Zero retention is an explicit disposable Kubernetes policy, never a change
  # to the positive retention contract of HTTP or Embedded executions.
  def required?(%{spec: spec}), do: required?(spec)
  def required?(%{retention_ms: 0}), do: true
  def required?(_), do: false

  def supported?(
        %{
          artifact: %{"kind" => "oci"},
          retention_ms: 0,
          command: %Command{background: false, stdin: nil, user: nil},
          profile: profile
        } = spec
      ),
      do:
        Map.get(spec, :volumes, []) == [] and Map.get(spec, :ports, []) == [] and
          Map.get(spec, :workload) == nil and not Map.get(spec, :checkpointable, false) and
          not Map.get(spec, :branch_static_egress, false) and
          Config.profile?(profile) and GuestHelper.command?(spec.command) and
          GuestHelper.paths?(Map.get(spec, :inputs, [])) and
          GuestHelper.paths?(Map.get(spec, :outputs, []))

  def supported?(_), do: false
end
