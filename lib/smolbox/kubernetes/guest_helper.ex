defmodule SmolBox.Kubernetes.GuestHelper do
  @moduledoc false
  alias SmolBox.{Command, GuestPaths}

  # This is a compile-time source input, embedded in the BEAM below. A fresh
  # dependency build with MIX_BUILD_PATH may not have linked its priv directory.
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @path Path.expand("../../../priv/kubernetes/guest_helper_v1.py", __DIR__)
  @external_resource @path
  @source File.read!(@path)
  @max_header 1_048_576
  @ack <<"SBK1", 0::32>>

  def argv, do: ["python3", "-I", "-S", "-u", "-c", @source]
  def sha256, do: :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)
  def ack, do: @ack

  def command?(command), do: match?({:ok, _}, encode(command))

  def encode(%Command{stdin: nil, user: nil, background: false} = command) do
    with :ok <- Command.validate(command),
         true <- GuestPaths.allowed?(nil, :workdir, command.workdir),
         {:ok, header} <-
           Jason.encode(%{
             "version" => 1,
             "operation" => "exec",
             "argv" => command.argv,
             "env" => Enum.map(command.env, &Tuple.to_list/1),
             "workdir" => command.workdir,
             "data_bytes" => 0
           }),
         true <- byte_size(header) <= @max_header,
         do: {:ok, <<"SBK1", byte_size(header)::32, header::binary>>},
         else: (_ -> :error)
  end

  def encode(_), do: :error
end
