defmodule SmolBox.Kubernetes.NodeAuthority.Transport do
  @moduledoc false
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.FramedPort

  @command "smolbox-node-authority-v1"
  @options [
    "BatchMode=yes",
    "StrictHostKeyChecking=yes",
    "IdentitiesOnly=yes",
    "IdentityFile=none",
    "IdentityAgent=none",
    "PreferredAuthentications=publickey",
    "PasswordAuthentication=no",
    "KbdInteractiveAuthentication=no",
    "HostbasedAuthentication=no",
    "GSSAPIAuthentication=no",
    "NumberOfPasswordPrompts=0",
    "GlobalKnownHostsFile=/dev/null",
    "KnownHostsCommand=none",
    "UpdateHostKeys=no",
    "VerifyHostKeyDNS=no",
    "ForwardAgent=no",
    "ForwardX11=no",
    "ClearAllForwardings=yes",
    "PermitLocalCommand=no",
    "ProxyCommand=none",
    "ProxyJump=none",
    "ControlMaster=no",
    "ControlPath=none",
    "ControlPersist=no",
    "ConnectTimeout=5",
    "ServerAliveInterval=5",
    "ServerAliveCountMax=1"
  ]

  def request(context, body, budget, deadline) do
    with {:ok, remaining} <- Budget.until(budget, deadline, :worker),
         true <- byte_size(body) + 8 <= remaining.max_request_bytes do
      FramedPort.exchange_raw(
        context.ssh_executable,
        arguments(context),
        "SBA1",
        body,
        remaining,
        30_000,
        deadline
      )
    else
      _ -> :error
    end
  end

  defp arguments(context),
    do:
      ["-F", "/dev/null", "-T"] ++
        Enum.flat_map(@options, &["-o", &1]) ++
        [
          "-o",
          "UserKnownHostsFile=" <> context.known_hosts_file,
          "-l",
          context.ssh_user,
          "-p",
          Integer.to_string(context.ssh_port),
          "-i",
          context.identity_file,
          "--",
          context.ssh_host,
          @command
        ]
end
