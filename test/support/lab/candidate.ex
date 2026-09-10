defmodule SmolBox.LabCandidate do
  @moduledoc false

  def runtime_version, do: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.14.1")

  # The standard suites keep their existing behavior unless the dedicated Linux
  # campaign explicitly selects this owned deployment. Reset never touches the
  # controller store and cannot authorize replay of an accepted command.
  def reset do
    if System.get_env("SMOLBOX_LINUX_CANDIDATE") == "true" do
      {:unix, :linux} = :os.type()
      {"smolbox-nested\n", 0} = System.cmd("hostname", [])
      "/srv/sbq/run/api.sock" = System.fetch_env!("SMOLBOX_RUNTIME_SOCKET")

      case System.cmd(
             "sudo",
             [
               "-n",
               "bash",
               "/opt/smolbox/source/scripts/lab/candidate-control.sh",
               "start"
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _status} -> raise "candidate reset failed: #{output}"
      end
    end

    :ok
  end

  def endpoint_options(options) do
    # Cold nested boot under the one-CPU worker cap can exceed the ordinary
    # fixture's 15-second receive budget. Match the 60-second preparation budget;
    # individual timeout/cancellation scenarios still apply their own overrides.
    options =
      if System.get_env("SMOLBOX_LINUX_CANDIDATE") == "true" do
        Keyword.merge(options, operation_timeout_ms: 60_000, receive_timeout_ms: 55_000)
      else
        options
      end

    case System.get_env("SMOLBOX_RUNTIME_SOCKET") do
      nil -> options
      socket -> Keyword.put(options, :unix_socket, socket)
    end
  end

  def observation_ms(default) do
    if System.get_env("SMOLBOX_LINUX_CANDIDATE") == "true", do: 90_000, else: default
  end
end
