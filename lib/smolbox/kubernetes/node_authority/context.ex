defmodule SmolBox.Kubernetes.NodeAuthority.Context do
  @moduledoc false
  alias SmolBox.Kubernetes.Shape
  alias SmolBox.Validation

  @enforce_keys [
    :ssh_host,
    :ssh_port,
    :ssh_user,
    :identity_file,
    :known_hosts_file,
    :authority_generation,
    :verifier_manifest_sha256
  ]
  @derive {Inspect, only: []}
  defstruct @enforce_keys ++ [ssh_executable: "/usr/bin/ssh"]

  def validate(%__MODULE__{} = context) do
    if Validation.struct_shape?(context, __MODULE__) and connection?(context) and
         Enum.all?(
           [context.identity_file, context.known_hosts_file, context.ssh_executable],
           &path?/1
         ) and
         Enum.all?(
           [context.authority_generation, context.verifier_manifest_sha256],
           &Validation.digest?/1
         ), do: :ok, else: :error
  end

  def validate(_), do: :error

  defp connection?(context),
    do:
      host?(context.ssh_host) and Validation.integer?(context.ssh_port, 1, 65_535) and
        user?(context.ssh_user)

  defp host?(value) do
    Validation.text?(value, 253) and value != "" and
      (Shape.dns_name?(value) or match?({:ok, _}, :inet.parse_address(String.to_charlist(value))))
  end

  defp user?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z_][a-z0-9_-]{0,31}\z/, value)

  # OpenSSH expands percent/tilde tokens and parses option values itself.
  # Require unambiguous absolute ASCII paths without those expansions, quotes,
  # whitespace or inherited-home interpretation. No filesystem lookup occurs.
  defp path?(value),
    do:
      Shape.absolute_path?(value) and value != "/" and
        Regex.match?(~r/\A\/[A-Za-z0-9._\/-]+\z/, value)
end
