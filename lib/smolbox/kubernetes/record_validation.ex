defmodule SmolBox.Kubernetes.RecordValidation do
  @moduledoc false
  alias SmolBox.Kubernetes.{Assignment, Identity}

  def valid?(assignment, record),
    do:
      Assignment.record_matches?(assignment, record) and
        owned?(record.created_machine, assignment)

  defp owned?(nil, _assignment), do: true

  defp owned?(%{__struct__: SmolBox.Machine, backend_identity: identity}, assignment),
    do: Identity.matches?(identity, assignment)

  defp owned?(_machine, _assignment), do: false
end
