defmodule SmolBox.CI.Util do
  @moduledoc false
  alias SmolBox.CI.Child

  def ensure!(true, _message), do: :ok
  def ensure!(_, message), do: raise(ArgumentError, message)

  def json!(file), do: file |> File.read!() |> JSON.decode!()

  def write_json!(file, data) do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, [JSON.encode!(data), "\n"], [:exclusive])
  end

  def digest(file) do
    file
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  def temporary(prefix) do
    name = prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    directory = Path.join(System.tmp_dir!(), name)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    directory
  end

  def command!(arguments, options \\ []) do
    {output, report} = Child.execute(arguments, options)

    ensure!(
      report.status == "passed",
      "maintainer command failed (#{report.failure || report.exit_code})"
    )

    output
  end

  def options!(arguments, switches, required) do
    {options, rest, invalid} = OptionParser.parse(arguments, strict: switches)
    ensure!(invalid == [], "unknown or invalid command option")
    Enum.each(required, &ensure!(Keyword.has_key?(options, &1), "missing --#{&1}"))
    {options, rest}
  end

  def platform do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, :linux} -> "linux"
      _ -> raise ArgumentError, "unsupported maintainer platform"
    end
  end

  def private_file!(file, limit) do
    info = File.lstat!(file)
    uid = command!(["id", "-u"]) |> String.trim() |> String.to_integer()

    ensure!(
      Path.type(file) == :absolute and info.type == :regular and info.uid == uid,
      "expected an absolute owned regular file"
    )

    ensure!(
      Bitwise.band(info.mode, 0o077) == 0 and info.size <= limit,
      "private file permissions or size are invalid"
    )

    File.open!(file, [:read, :binary], fn stream ->
      bytes = IO.binread(stream, limit + 1)
      ensure!(is_binary(bytes) and byte_size(bytes) <= limit, "private file exceeded its bound")
      bytes
    end)
  end
end
