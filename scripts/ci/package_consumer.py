#!/usr/bin/env python3
"""Build and exercise a fresh production consumer of the actual Hex tarball.

Run under the desired Elixir/OTP toolchain. This never publishes the package or
contacts a worker. --minimum pins the four direct runtime dependencies to their
lowest declared versions; transitive dependencies are resolved and recorded.
--archive consumes an already built trusted SmolBox tarball without rebuilding it.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import subprocess
import tarfile
import tempfile


MINIMUM = {"req": "0.7.4", "jason": "1.4.0", "telemetry": "1.3.0", "nimble_options": "1.1.0"}
FORBIDDEN = {"credo", "ex_slop", "ex_dna", "credence", "dialyxir", "ex_doc", "mix_audit",
             "ecto", "ecto_sql", "postgrex", "stream_data", "plug", "bandit"}
PUBLIC = {"mix.exs", "README.md", "CHANGELOG.md", "LICENSE"}
PUBLIC_DOCS = {"docs/client.md", "docs/host-integration.md", "docs/recovery.md",
               "docs/resource-qualification.md", "docs/compatibility.md"}
LIMIT = 64 * 1024 * 1024

SMOKE = '''
defmodule Consumer.Transport do
  @behaviour SmolBox.Transport
  @impl true
  def request(_worker, %{method: :get, path: "/health"}) do
    send(self(), :fake_transport_called)
    {:ok, ~s({"status":"ok","version":"1.14.1","machines":{"total":0,"running":0}})}
  end
end

defmodule Consumer.Artifacts do
  @behaviour SmolBox.ArtifactStore
  @impl true
  def read(_, _, _, _), do: raise("unexpected artifact access")
  @impl true
  def put(_, _, _, _, _), do: raise("unexpected artifact access")
end

{:ok, _apps} = Application.ensure_all_started(:smolbox)
[] = Application.spec(:smolbox, :mod)
{:ok, endpoint} = SmolBox.Worker.new("consumer", "http://127.0.0.1:1", allow_insecure_loopback: true)
{:ok, client} = SmolBox.Client.new(endpoint, transport: Consumer.Transport)
{:ok, %{version: "1.14.1", total: 0, running: 0}} = SmolBox.Client.health(client)
receive do
  :fake_transport_called -> :ok
after
  100 -> raise "client did not exercise the supplied transport"
end

children = [
  {SmolBox.Store.Memory, name: Consumer.Store},
  {SmolBox, name: Consumer.Runtime, namespace: "consumer", mode: :ephemeral,
    store: {SmolBox.Store.Memory, Consumer.Store},
    artifact_store: {Consumer.Artifacts, nil},
    fingerprint_key: :crypto.strong_rand_bytes(32), workers: []}
]
{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
{:ok, []} = SmolBox.workers(Consumer.Runtime)
{:error, %{category: :not_found}} = SmolBox.fetch(Consumer.Runtime, "scope", "missing")
{:error, %{category: :not_found}} = SmolBox.cancel(Consumer.Runtime, "scope", "missing")
:ok = Supervisor.stop(supervisor)
nil = Process.whereis(Consumer.Runtime)
versions = Map.new([:req, :jason, :telemetry, :nimble_options], fn app ->
  {app, app |> Application.spec(:vsn) |> to_string()}
end)
File.write!("smoke.json", Jason.encode!(%{client: true, supervisor: true, versions: versions}))
'''


def run(arguments, directory, environment):
    print("Running " + " ".join(arguments), flush=True)
    subprocess.run(arguments, cwd=directory, env=environment, check=True, timeout=600)


def unpack(archive, destination):
    with tarfile.open(archive) as outer:
        members = outer.getmembers()
        assert len(members) == 4
        assert {m.name for m in members} == {"VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"}
        assert all(m.isfile() and 0 <= m.size <= LIMIT for m in members)
        compressed = outer.extractfile("contents.tar.gz").read(LIMIT + 1)
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
        contents = stream.read(LIMIT + 1)
    assert len(contents) <= LIMIT, "package exceeds qualification size limit"
    names = []
    with tarfile.open(fileobj=io.BytesIO(contents)) as inner:
        members = inner.getmembers()
        assert 1 <= len(members) <= 1024
        for member in members:
            path = PurePosixPath(member.name)
            assert not path.is_absolute() and ".." not in path.parts
            assert member.isfile(), f"unexpected link or directory: {member.name}"
            allowed = (member.name in PUBLIC or
                       (path.parts[0] == "lib" and path.suffix == ".ex") or
                       member.name in PUBLIC_DOCS or
                       (path.parts[:2] == ("docs", "evidence") and path.suffix == ".json"))
            assert allowed, f"unexpected package file: {member.name}"
            assert member.name not in names, "duplicate package path"
            names.append(member.name)
            target = destination.joinpath(*path.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as output:
                output.write(inner.extractfile(member).read())
    assert PUBLIC <= set(names)
    assert "lib/smolbox.ex" in names and "lib/smolbox/runtime.ex" in names
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minimum", action="store_true")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--package-output", type=Path)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2]
    assert not args.report.exists(), "report already exists; choose a new output"
    assert not args.package_output or not args.package_output.exists(), "package output exists"
    with tempfile.TemporaryDirectory(prefix="smolbox-consumer-") as temporary:
        root = Path(temporary)
        archive = root / "smolbox.tar"
        build_env = os.environ.copy()
        build_env["MIX_ENV"] = "dev"
        if args.archive:
            assert args.archive.is_file() and args.archive.stat().st_size <= LIMIT
            archive.write_bytes(args.archive.read_bytes())
        else:
            run(["mix", "hex.build", "--output", str(archive)], source, build_env)
        package = root / "package"
        package.mkdir()
        names = unpack(archive, package)
        fingerprints = {name: hashlib.sha256((package / name).read_bytes()).hexdigest() for name in names}
        consumer = root / "consumer"
        consumer.mkdir()
        overrides = ", ".join(f'{{:{name}, "== {version}", override: true}}'
                              for name, version in MINIMUM.items()) if args.minimum else ""
        dependencies = '[{:smolbox, path: "../package"}' + (", " + overrides if overrides else "") + "]"
        (consumer / "mix.exs").write_text(f'''defmodule Consumer.MixProject do
  use Mix.Project
  def project, do: [app: :consumer, version: "0.0.0", deps: {dependencies}]
end
''')
        (consumer / "smoke.exs").write_text(SMOKE)
        environment = os.environ.copy()
        environment.update(MIX_ENV="prod", MIX_DEPS_PATH=str(consumer / "deps"),
                           MIX_BUILD_PATH=str(consumer / "_build" / "prod"))
        run(["mix", "deps.get", "--only", "prod"], consumer, environment)
        run(["mix", "compile", "--warnings-as-errors"], consumer, environment)
        # Dependency compilation does not inherit the consumer's warning flag.
        # Compile the extracted SmolBox itself as the root project under WAE too.
        run(["mix", "compile", "--force", "--no-deps-check", "--warnings-as-errors"],
            package, environment)
        run(["mix", "run", "--no-compile", "smoke.exs"], consumer, environment)
        smoke = json.loads((consumer / "smoke.json").read_text())
        if args.minimum:
            assert smoke["versions"] == MINIMUM
        dependencies = sorted(p.name for p in (consumer / "deps").iterdir() if p.is_dir())
        assert not FORBIDDEN.intersection(dependencies), dependencies
        modules = sorted(p.name for p in (consumer / "_build/prod/lib/smolbox/ebin").glob("*.beam"))
        assert modules and all(name.startswith(("Elixir.SmolBox.", "Elixir.Inspect.SmolBox.",
                                               "Elixir.SmolBox.beam")) for name in modules), modules
        assert fingerprints == {name: hashlib.sha256((package / name).read_bytes()).hexdigest()
                                for name in names}, "consumer build changed package source"
        report = {"minimum": args.minimum, "smoke": smoke, "runtime_dependencies": dependencies,
                  "package_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                  "package_files": names, "package_modules": modules,
                  "package_file_sha256": fingerprints,
                  "platform": platform.system(), "architecture": platform.machine(),
                  "toolchain": subprocess.check_output(["elixir", "--version"],
                                                       env=environment, text=True, timeout=30).strip(),
                  "consumer_lockfile": (consumer / "mix.lock").read_text()}
        if args.package_output:
            args.package_output.parent.mkdir(parents=True, exist_ok=True)
            with args.package_output.open("xb") as output:
                output.write(archive.read_bytes())
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open("x") as output:
            json.dump(report, output, indent=2)
            output.write("\n")
        print(f"Package consumer passed; report: {args.report}", flush=True)


if __name__ == "__main__":
    main()
