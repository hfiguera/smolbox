defmodule Workspace.Sample do
  @moduledoc "Self-contained immutable startup program; never overwrites retained project files."
  def startup do
    ~S"""
    import os, pathlib, http.server, functools
    root = pathlib.Path('/app/project'); root.mkdir(parents=True, exist_ok=True)
    pathlib.Path('/home/dev/.config').mkdir(parents=True, exist_ok=True)
    index = root / 'index.html'
    if not index.exists():
        index.write_text('<!doctype html><meta charset="utf-8"><title>My SmolBox workspace</title><style>body{font:20px sans-serif;margin:12vh auto;max-width:40em;padding:2em;background:#f5f3eb;color:#252620}h1{font-size:3em}code{background:#e6e4d9;padding:.2em}</style><h1>Your machine. Still here.</h1><p>This page is served from <code>/app/project/index.html</code> inside your persistent SmolBox machine.</p><p>Edit the file from a command or terminal, then refresh. Your changes survive controller restarts and machine stop/start.</p>')
    with (root / 'starts.txt').open('a') as f:
        f.write(os.environ['WORKSPACE_NAME'] + '\n'); f.flush(); os.fsync(f.fileno())
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
    http.server.ThreadingHTTPServer(('0.0.0.0', 8000), handler).serve_forever()
    """
  end

  def commands do
    [
      {"Inspect the workspace", "pwd; ls -lah; cat starts.txt", "foreground", 30},
      {"Create a 2 MiB artifact",
       "python3 -c \"from pathlib import Path; Path('artifact.bin').write_bytes(bytes(range(256))*8192); print('Wrote 2 MiB to /app/project/artifact.bin')\"",
       "foreground", 30},
      {"Start background work",
       "python3 -c \"import pathlib,time; p=pathlib.Path('background.txt'); p.open('a').write('launched\\n'); time.sleep(300)\"",
       "background", 30},
      {"Run beyond five minutes",
       "python3 -c \"import time; print('Starting a 305-second job', flush=True); time.sleep(305); print('Complete')\"",
       "foreground", 330}
    ]
  end
end
