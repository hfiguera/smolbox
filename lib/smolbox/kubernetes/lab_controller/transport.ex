defmodule SmolBox.Kubernetes.LabController.Transport do
  @moduledoc false
  alias SmolBox.Kubernetes.FramedPort
  # Compile-time asset: a fresh dependency build may not have linked priv yet.
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @path Path.expand("../../../../priv/kubernetes/controller_guard_v1.py", __DIR__)
  @external_resource @path
  @source File.read!(@path)

  def request(context, action, binding, owner, budget) do
    body =
      Jason.encode!(%{
        version: 1,
        action: action,
        directory: context.directory,
        binding_generation: binding.generation,
        owner: owner,
        pid: String.to_integer(System.pid()),
        timeout_ms: min(3000, budget.timeout_ms)
      })

    if byte_size(body) <= 8192 and
         byte_size(body) + byte_size(@source) + 8 <= budget.max_request_bytes,
       do:
         FramedPort.exchange(
           context.python_executable,
           ["-I", "-S", "-u", "-c", @source],
           "SBG1",
           body,
           budget,
           3000
         ),
       else: :error
  end
end
