defmodule SmolBox.Kubernetes.LabNodeEvidence.Context do
  @moduledoc false
  alias SmolBox.Kubernetes.Shape
  alias SmolBox.Validation

  @enforce_keys [:ssh_host, :inspector_sha256, :history_sha256]
  @derive {Inspect, only: [:ssh_host]}
  defstruct @enforce_keys ++ [ssh_executable: "/usr/bin/ssh"]

  def validate(%__MODULE__{} = value) do
    if Validation.struct_shape?(value, __MODULE__) and Shape.dns_name?(value.ssh_host) and
         not String.starts_with?(value.ssh_host, "-") and
         Shape.absolute_path?(value.ssh_executable) and
         Validation.digest?(value.inspector_sha256) and Validation.digest?(value.history_sha256),
       do: :ok,
       else: :error
  end

  def validate(_), do: :error
end
