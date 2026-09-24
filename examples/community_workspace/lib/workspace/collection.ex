defmodule Workspace.Collection do
  @moduledoc "Bounded guest snapshots keep ordinary file errors out of uncertain worker downloads."
  alias Workspace.Settings

  # Reserved, reusable staging file outside the project's HTTP document root.
  def path, do: "/home/dev/.config/.smolbox-collection"

  def command(source) do
    SmolBox.Command.new(
      ["python3", "-c", script(), source, path(), to_string(Settings.max_file_bytes())],
      workdir: "/app/project",
      timeout_secs: 30
    )
  end

  def script do
    ~S"""
    import os, stat, sys, tempfile
    source, destination, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
    fd, temporary = tempfile.mkstemp(prefix='.smolbox-collection-', dir=os.path.dirname(destination))
    code, message = 0, ''
    try:
        with os.fdopen(fd, 'wb') as snapshot:
            try:
                if source == destination:
                    raise ValueError('This path is reserved for file collection.')
                incoming = os.open(source, os.O_RDONLY | os.O_NONBLOCK)
                with os.fdopen(incoming, 'rb') as original:
                    if not stat.S_ISREG(os.fstat(original.fileno()).st_mode):
                        raise ValueError('Choose a regular file, not a directory or device.')
                    total = 0
                    while True:
                        chunk = original.read(min(65536, limit + 1 - total))
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > limit:
                            raise ValueError('File exceeds the 16 MiB collection limit.')
                        snapshot.write(chunk)
            except (OSError, ValueError) as error:
                code = 1
                message = 'File not collected: ' + str(error)
                snapshot.seek(0)
                snapshot.truncate()
            snapshot.flush()
            os.fsync(snapshot.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    if message:
        print(message, file=sys.stderr)
    sys.exit(code)
    """
  end
end
