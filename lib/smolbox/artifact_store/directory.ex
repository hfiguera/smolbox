defmodule SmolBox.ArtifactStore.Directory do
  @moduledoc """
  Small host-owned local artifact adapter for examples and development.

  The root must already exist with mode 0700, on a trusted local filesystem.
  Only trusted host code may modify it or its ancestors. Guest bytes never select
  a path: identities are hashed into filenames, and output blobs are addressed by
  SHA-256. Atomic hard-link installation refuses to replace a different receipt.
  Files are synced before installation. This is not an object-storage service or
  a claim of crash durability for arbitrary filesystems; the host owns filesystem
  durability, disk quotas, backup, and removal of unreferenced blobs/temp files.

  `seed/4` registers an approved input. `read_output/4` retrieves a stored output.
  Each read is bounded to one MiB. Output replacement requires a distinct execution
  identity. No archive extraction, globbing, URLs, or guest-selected host paths are
  supported. The adapter must not share its root with untrusted host processes.
  """
  @behaviour SmolBox.ArtifactStore
  import Bitwise
  alias SmolBox.{Error, Files, Validation}

  @enforce_keys [:root]
  @derive {Inspect, only: []}
  defstruct [:root]
  @type t :: %__MODULE__{root: String.t()}
  @max 1_048_576

  @doc """
  Configure an absolute existing private directory with mode `0700`.

  The directory is not created by this call. Pass the returned context as
  `{SmolBox.ArtifactStore.Directory, context}` in the runtime's `:artifact_store`
  option. This adapter is not a process and needs no supervisor child.
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(root) when is_binary(root) do
    with true <- Path.type(root) == :absolute,
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(root),
         true <- band(mode, 0o777) == 0o700 do
      {:ok, %__MODULE__{root: root}}
    else
      _invalid -> error(:validation)
    end
  end

  def new(_root), do: error(:validation)

  @doc """
  Store approved input bytes under a scope and opaque source reference.

  Bytes must fit within 1 MiB. The source reference is used as `"source"` in an
  input manifest; it is not a filename. Repeating identical bytes succeeds;
  different bytes under the same reference return an identity conflict.
  """
  @spec seed(t(), String.t(), String.t(), binary()) :: :ok | {:error, Error.t()}
  def seed(store, scope, reference, bytes) when is_binary(bytes),
    do: save(store, {:input, scope, reference}, bytes, Files.sha256(bytes))

  def seed(_store, _scope, _reference, _bytes), do: error(:validation)

  @impl SmolBox.ArtifactStore
  def read(store, scope, reference, max), do: load(store, {:input, scope, reference}, max)

  @impl SmolBox.ArtifactStore
  def put(store, {scope, id}, destination, bytes, digest),
    do: save(store, {:output, scope, id, destination}, bytes, digest)

  @doc """
  Read a collected output using its execution handle and manifest destination.

  `max` is a positive byte limit up to 1 MiB. This reads host artifact storage and
  remains usable after VM cleanup. `:not_found` means no receipt/blob was found;
  check the execution's collection state before expecting an output.
  """
  @spec read_output(t(), {String.t(), String.t()}, String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, Error.t()}
  def read_output(store, {scope, id}, destination, max),
    do: load(store, {:output, scope, id, destination}, max)

  defp save(store, key, bytes, digest) do
    with :ok <- validate_key(key),
         true <- is_binary(bytes) and byte_size(bytes) <= @max and Files.sha256(bytes) == digest,
         {:ok, _store} <- new(store.root),
         :ok <- install(store, digest <> ".blob", bytes),
         :ok <- install(store, receipt(key), digest) do
      :ok
    else
      false -> error(:validation)
      {:error, %Error{}} = error -> error
    end
  end

  defp load(store, key, max) do
    with :ok <- validate_key(key),
         true <- Validation.integer?(max, 1, @max),
         {:ok, _store} <- new(store.root),
         {:ok, digest} <- bounded_read(Path.join(store.root, receipt(key)), 64),
         true <- Validation.digest?(digest),
         {:ok, bytes} <- bounded_read(Path.join(store.root, digest <> ".blob"), max),
         true <- Files.sha256(bytes) == digest do
      {:ok, bytes}
    else
      false -> error(:validation)
      {:error, %Error{}} = error -> error
    end
  end

  defp install(store, name, bytes) do
    temporary =
      Path.join(
        store.root,
        ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    destination = Path.join(store.root, name)

    case File.mkdir(temporary) do
      :ok -> install_temporary(temporary, destination, bytes)
      _failed -> error(:store)
    end
  end

  defp install_temporary(temporary, destination, bytes) do
    write_and_link(temporary, destination, bytes)
  after
    File.rm_rf(temporary)
  end

  defp write_and_link(temporary, destination, bytes) do
    file = Path.join(temporary, "bytes")

    with :ok <- File.chmod(temporary, 0o700),
         :ok <- File.write(file, bytes, [:binary, :exclusive, :sync]),
         :ok <- File.chmod(file, 0o600) do
      case File.ln(file, destination) do
        :ok -> :ok
        {:error, :eexist} -> compare_existing(destination, bytes)
        _failed -> error(:store)
      end
    else
      _failed -> error(:store)
    end
  end

  defp compare_existing(destination, bytes) do
    case bounded_read(destination, max(byte_size(bytes), 1)) do
      {:ok, ^bytes} -> :ok
      _different -> error(:identity_conflict)
    end
  end

  defp bounded_read(file, max) do
    with {:ok, %{type: :regular, size: size}} when size <= max <- File.lstat(file),
         {:ok, handle} <- File.open(file, [:read, :binary]) do
      try do
        case IO.binread(handle, max + 1) do
          :eof -> {:ok, ""}
          bytes when is_binary(bytes) and byte_size(bytes) <= max -> {:ok, bytes}
          _invalid -> error(:output_limit)
        end
      after
        File.close(handle)
      end
    else
      {:error, :enoent} -> error(:not_found)
      _invalid -> error(:validation)
    end
  end

  defp receipt(key), do: Files.sha256(:erlang.term_to_binary(key)) <> ".ref"

  defp validate_key(key) do
    [_kind | identifiers] = Tuple.to_list(key)
    if Enum.all?(identifiers, &Validation.identifier?/1), do: :ok, else: error(:validation)
  end

  defp error(category), do: {:error, %Error{category: category, operation: :artifact_store}}
end
