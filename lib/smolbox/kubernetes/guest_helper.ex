defmodule SmolBox.Kubernetes.GuestHelper do
  @moduledoc false
  alias SmolBox.{Command, Files, GuestPaths, Validation}

  # This is a compile-time source input, embedded in the BEAM below. A fresh
  # dependency build with MIX_BUILD_PATH may not have linked its priv directory.
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @path Path.expand("../../../priv/kubernetes/guest_helper_v1.py", __DIR__)
  @external_resource @path
  @source File.read!(@path)
  # Both files are compile-time inputs embedded into the BEAM. No Python tool
  # or already-linked application priv directory is required on the build host.
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @loader_path Path.expand("../../../priv/kubernetes/guest_loader_v1.py", __DIR__)
  @external_resource @loader_path
  @loader @loader_path
          |> File.read!()
          |> String.replace("__HELPER_BYTES__", Integer.to_string(byte_size(@source)))
          |> String.replace(
            "__HELPER_SHA256__",
            :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)
          )
  @max_header 1_048_576
  @ack <<"SBK1", 0::32>>

  def argv, do: ["python3", "-I", "-S", "-u", "-c", @loader]
  def sha256, do: :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)
  def loader_sha256, do: :crypto.hash(:sha256, @loader) |> Base.encode16(case: :lower)
  def ack, do: @ack

  def command?(command), do: match?({:ok, _}, encode(command))

  def paths?(entries),
    do:
      Validation.list?(entries, 32) and
        Enum.all?(entries, &(is_map(&1) and file_path?(Map.get(&1, "path"))))

  def file_path?(path) do
    if Files.validate_path(path) == :ok and path != "/workspace" do
      parts = path |> String.split("/") |> Enum.drop(2)
      Validation.list?(parts, 64) and Enum.all?(parts, &(byte_size(&1) <= 255))
    else
      false
    end
  end

  def upload(path, bytes, digest, timeout),
    do:
      frame(
        %{
          version: 1,
          operation: "upload",
          path: path,
          data_bytes: byte_size(bytes),
          sha256: digest,
          timeout_ms: timeout
        },
        bytes
      )

  def download(path, max, timeout),
    do:
      frame(
        %{
          version: 1,
          operation: "download",
          path: path,
          data_bytes: 0,
          max_bytes: max,
          timeout_ms: timeout
        },
        <<>>
      )

  def encode(%Command{stdin: nil, user: nil, background: false} = command) do
    with :ok <- Command.validate(command),
         true <- GuestPaths.allowed?(nil, :workdir, command.workdir),
         do:
           frame(
             %{
               "version" => 1,
               "operation" => "exec",
               "argv" => command.argv,
               "env" => Enum.map(command.env, &Tuple.to_list/1),
               "workdir" => command.workdir,
               "data_bytes" => 0
             },
             <<>>
           ),
         else: (_ -> :error)
  end

  def encode(_), do: :error

  defp frame(control, data) do
    with {:ok, header} <- Jason.encode(control),
         true <- byte_size(header) <= @max_header,
         true <- byte_size(@source) <= 65_536,
         do:
           {:ok,
            <<"SBP1", byte_size(@source)::32, @source::binary, "SBK1", byte_size(header)::32,
              header::binary, data::binary>>},
         else: (_ -> :error)
  end
end
