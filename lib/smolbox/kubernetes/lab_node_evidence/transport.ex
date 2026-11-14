defmodule SmolBox.Kubernetes.LabNodeEvidence.Transport do
  @moduledoc false
  alias SmolBox.Kubernetes.FramedPort

  @command "~/smolbox-kubernetes-lab/lab.sh ssh sudo /usr/bin/python3 /usr/local/lib/smolbox-kubernetes/node-history/node_inspector.py inspect"
  @max 65_536

  def request(context, body, budget) when byte_size(body) in 1..@max do
    if byte_size(body) + 8 <= budget.max_request_bytes,
      do:
        FramedPort.exchange(
          context.ssh_executable,
          arguments(context.ssh_host),
          "SBH1",
          body,
          budget,
          30_000
        ),
      else: :error
  end

  def request(_, _, _), do: :error

  defp arguments(host),
    do: [
      "-T",
      "-o",
      "BatchMode=yes",
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "ForwardAgent=no",
      "-o",
      "ClearAllForwardings=yes",
      "-o",
      "ConnectTimeout=5",
      "-o",
      "ServerAliveInterval=5",
      "-o",
      "ServerAliveCountMax=1",
      host,
      @command
    ]
end
