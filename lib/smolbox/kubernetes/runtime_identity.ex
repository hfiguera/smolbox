defmodule SmolBox.Kubernetes.RuntimeIdentity do
  @moduledoc false
  alias SmolBox.Kubernetes.Shape
  alias SmolBox.Validation

  @digests ~w(archive_sha256 shim_sha256 libkrun_sha256 kernel_sha256 rootfs_sha256
              guard_sha256 guard_template_sha256)
  @versions ~w(smolvm_version k3s_version containerd_version)

  def valid?(value),
    do:
      Shape.exact_keys?(value, @digests ++ @versions) and
        Enum.all?(@digests, &Validation.digest?(value[&1])) and
        value["smolvm_version"] == "1.34.0" and value["k3s_version"] == "v1.35.10+k3s1" and
        value["containerd_version"] == "2.2.10-k3s1"
end
