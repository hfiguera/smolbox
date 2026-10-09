You already have an image with the tools you need. The next useful step is to run
something with it.

Earlier SmolBox examples began with a prepared file on the worker. That is useful
when you control the whole machine image, but it leaves a question for anyone
whose environments already live in a registry: **can I start there?**

Yes. Approve an image, create a retained machine from it, and submit commands from
Elixir. You do not need to copy a `.smolmachine` file onto every worker first.

We will use a public Alpine image to turn a tiny orders file into a report. A
second command will read and verify the result from the same machine. Then a
separate Elixir invocation will delete that machine and check that its reservation
has been released.

The example uses **SmolBox 0.4.1, smolvm 1.22.0 and Linux x86_64**. Registry sources
arrived in 0.3.0. The [complete script][script] and [validation receipt][receipt]
accompany this article.

## Start with the environment you already have

There are two useful registry paths. Choose according to what you have prepared.

| Your starting point | SmolBox source | What you approve |
| --- | --- | --- |
| An OCI image containing your tools and dependencies | `Source.oci/1` | Registry, repository, platform manifest digest and architecture |
| A prepared `.smolmachine` distributed through a registry | `Source.registry/1` | Registry manifest identity, architecture and the prepared file’s content digest |

Use OCI when your team already builds images or an existing public image supplies
the tools you need. Use a registry artifact when you want to distribute a prepared
machine environment. Both routes create a machine with its own durable identity
and an explicit lifetime.

The two digests for a prepared artifact identify different objects: the registry
manifest and the `.smolmachine` file. Neither route is a way to resume a running
process. For that distinction, see [exports, checkpoints and branches][reuse].

Our report only needs a shell and `awk`, so Alpine is enough. No package installation,
application server or additional download is needed after the environment starts.

## Pin what you mean to run

A tag is convenient for discovery. An approved digest names the image you actually
intend to use.

```elixir
{:ok, source} = SmolBox.Source.oci(
  id: "alpine-report",
  reference: "docker.io/library/alpine@sha256:3c81aa9a3d770b316568f4499e30461a5cd3fbd7180bd89e28e34894c7845832",
  architecture: "x86_64"
)
```

This is the **Linux AMD64 platform manifest**, not the image index that groups
multiple architectures. The walkthrough uses SmolBox’s `x86_64` architecture name.
If you choose another image, resolve its tag, select the intended platform and
review that content before approving it. The source constructor does not do that
registry inspection for you.

**A digest fixes the starting image. It does not freeze your inputs, external
services or commands.** Installing packages from a changing repository later can
still produce a different environment. A pinned image also needs to be updated
when your security or maintenance policy calls for a new one.

The worker configuration registers this source with `sources: [source]`. The
machine specification then uses `Source.artifact(source)` and the approved
resource profile. A caller cannot substitute another repository or manifest under
that approval.

<figure class="registry-figure" id="registry-journey" aria-labelledby="registry-caption">
  <div class="registry-controls" hidden>
    <button type="button" class="registry-play">Play walkthrough</button>
    <button type="button" class="registry-next">Next step</button>
    <span class="registry-progress" role="status" aria-live="polite" aria-atomic="true">Step 1 of 4. Approve the starting image.</span>
  </div>
  <div class="registry-scene" data-step="0">
    <p class="registry-headline">Approve the starting image.</p>
    <div class="registry-source"><span>Registry image · Linux AMD64</span><strong>alpine@sha256:3c81…5832</strong><small>Fixed source identity throughout this walkthrough</small></div>
    <div class="registry-route"><svg viewBox="0 0 40 56" aria-hidden="true"><path d="M20 2v46m-7-7 7 7 7-7"/></svg><span class="registry-route-label">Explicit source and network approval</span></div>
    <div class="registry-target"><div class="registry-target-header"><strong class="registry-machine">No machine yet</strong><span class="registry-state">Approved source</span></div><pre class="registry-output">Image identity is known.
The report has not run.</pre></div>
    <p class="registry-detail">The registry supplies the starting environment. It does not supply a successful result for your workload.</p>
  </div>
  <figcaption id="registry-caption">Follow the source, the machine and the result separately. This is an explanatory model, not a live worker or a timing measurement.</figcaption>
</figure>

## Approve the route to the registry

Pulling an OCI image requires more than permission to reach the registry’s main
hostname. Authentication and content downloads can use different destinations.
Even this public image uses the registry’s anonymous token exchange.

The tested profile permits:

```elixir
{:ok, network} = SmolBox.NetworkPolicy.new(
  hosts: ["docker.io", "docker.com", "cloudflarestorage.com"]
)
```

Each entry also permits its subdomains. These are deliberately broad domain
approvals for this Docker Hub example, not a universal registry configuration.
Review the destinations for your own registry and content delivery service.
SmolBox rejects offline OCI creation; it does not silently expand the allowlist
to make a pull succeed. This profile also remains the machine’s network policy
while commands run.

There is another boundary: **guest network policy does not control the worker
host’s traffic**. Registry metadata is resolved on the host. In smolvm 1.22.0,
eligible OCI creation can also use a shared image seed and a temporary builder.
This walkthrough explicitly sets `SMOLVM_IMAGE_SEEDS=0` on its dedicated worker,
so it demonstrates creation without that shared seed path. Host egress controls
still belong to the operator.

Prepared registry artifacts take a different route: the worker host downloads
the artifact, so the resulting guest can remain offline. If you need an offline
workload, that may be the better starting point. It does not make the host offline.

## Run the report

Run this on a Linux x86_64 host with smolvm 1.22.0 installed, working VM support,
Elixir/OTP from the repository’s `.tool-versions`, and PostgreSQL. The example
reserves one CPU, 1,024 MiB including host overhead, and 30 GiB of machine disk
capacity. Allow additional host space for downloads and caches. These are admission
budgets, not measurements of physical disk use.

### Prepare the worker and store

Use a separate checkout of the release. The durable host example supplies the
PostgreSQL adapter, migrations and lifecycle helpers; **no Python artifact or
other prepared `.smolmachine` is required for this walkthrough**.

```sh
git clone --branch v0.4.1 --depth 1 https://github.com/hfiguera/smolbox.git smolbox-registry-demo
cd smolbox-registry-demo
mix deps.get
cd examples/durable_host
mix deps.get
```

Use a fresh PostgreSQL database. Set `DATABASE_URL` to its connection URL before
running Mix tasks in this directory. For example, with a local PostgreSQL role
matching your login and permission to create databases:

```sh
createdb smolbox_registry_blog
export DATABASE_URL="postgresql://$USER@127.0.0.1/smolbox_registry_blog"
```

Create a private directory for this run. Keep its path, both keys, the database,
and the identity variables between phases. Do not regenerate them when you return
for cleanup.

```sh
umask 077
export STATE="$(mktemp -d)"
mkdir -p "$STATE/worker" "$STATE/objects"
openssl rand -out "$STATE/encryption.key" 32
openssl rand -out "$STATE/fingerprint.key" 32
export SMOLBOX_WORKER_SOCKET="$STATE/worker.sock"
export SMOLBOX_ENCRYPTION_KEY_FILE="$STATE/encryption.key"
export SMOLBOX_FINGERPRINT_KEY_FILE="$STATE/fingerprint.key"
export SMOLBOX_ARTIFACT_DIR="$STATE/objects"
export SMOLBOX_STORE_PARTITION=registry-blog
export SMOLBOX_EXECUTION_ID=report-one
printf 'Keep this state directory: %s\n' "$STATE"

SMOLVM_DATA_DIR="$STATE/worker" SMOLVM_IMAGE_SEEDS=0 \
  smolvm serve start -l "unix://$SMOLBOX_WORKER_SOCKET" \
  > "$STATE/worker.log" 2>&1 &
export WORKER_PID=$!
```

This starts a dedicated worker with a local Unix socket. Wait for that socket to
appear and check `worker.log` if startup fails. Keep the commands in the same shell;
if you open another, restore the same environment first.

### Download, verify and run

The checksum below identifies the exact script used for the recorded Linux run.
The download URL can change; the checksum pins the bytes this walkthrough expects.
Inspect the script before running it. The chained commands stop if the download or
verification fails.

```sh
curl --fail --location \
  https://hfiguera.github.io/smolbox/media/from-registry-image-to-working-environment/registry-report.exs \
  --output registry-report.exs &&
printf '%s  %s\n' \
  1432e9581b13a370bfa30927c97e27cb6cc1a1057d12a6fc479bc17194d1c093 \
  registry-report.exs | sha256sum --check - &&
mix ecto.migrate &&
mix run registry-report.exs prepare
```

A successful integrity check prints `registry-report.exs: OK`. If it fails, stop
and check which script version you downloaded before proceeding.

The script registers the source, profile and worker before calling
`Machines.create/2`. It waits for the machine, starts it if needed, and checks the
running state. Receiving a handle alone would not prove that preparation succeeded.

The first command writes three rows to `/workspace/orders.csv` and uses `awk` to
produce `/workspace/report.txt`. A **different execution** reads that file:

```elixir
{:ok, command} = SmolBox.Command.new(["/bin/cat", "/workspace/report.txt"])

{:ok, execution_spec} = SmolBox.ExecutionSpec.new(
  scope: machine_spec.scope,
  id: machine_spec.id <> ":verify",
  artifact: machine_spec.artifact,
  profile: machine_spec.profile,
  command: command
)

{:ok, execution} = SmolBox.Machines.submit(runtime, machine_handle, execution_spec)

{:ok, %{state: :completed, result: %{exit_code: 0, stdout: "orders=3\nunits=9\n"}}} =
  SmolBox.await(runtime, execution, 120_000)
```

This excerpt shows the result check; the download includes the surrounding setup
and waiting logic. Success prints:

```text
Verified report:
orders=3
units=9
```

The second command read the report left by the first, exited successfully, and
returned exactly the bytes we expected. The environment is ready for your next
command.

The script then exits. **The machine and the report remain.** Commands have their
own identities; their completion does not delete the machine. Reusing these IDs
returns the existing work rather than requesting a fresh report. Use new identities
and deliberate capacity planning for a new experiment.

## Finish the machine’s lifetime

When you are done, run the separate cleanup phase with the same environment:

```sh
mix run registry-report.exs cleanup
```

It finds the recorded machine through PostgreSQL, checks its specification,
requests deletion, verifies worker absence, and confirms zero slot and disk
reservations for this dedicated example. Success prints:

```text
Verified cleanup: machine absent; slot and disk reservations released.
```

Deletion also removes the report on the machine’s own disk. Collect an artifact
first if you need to keep it, or give project files [their own volume][volumes].
Registry downloads and host caches have a separate lifetime; machine deletion is
not a cache purge. After successful cleanup, you can stop this dedicated worker
with `kill "$WORKER_PID"` and `wait "$WORKER_PID"`. Keep the database and keys until
you have finished inspecting the durable history.

If a phase fails or times out, retain the identity and evidence. The script does
not turn an uncertain response into a replacement machine or automatically replay
a possibly dispatched command. Follow the [managed recovery procedures][recovery]
before trying more work. Extending your caller’s wait does not extend the operation’s
deadline.

## Take it to your own registry

Start by replacing Alpine with an approved image that contains your real tools.
Then replace the report command and expected output with a useful check for your
project. Keep the separation: approve the environment, observe the machine, and
verify the workload’s result.

For private images, choose the source path before designing authentication.
Prepared registry artifacts support a `credential_ref` resolved by the host
application to a current identity token. SmolBox stores that reference, not the
token. OCI creation and machine image pulls do **not** expose the same per-request
token mechanism. Consult the [registry guide][registry] for supported upstream
configuration and target restrictions. Worker API credentials, registry access
and secrets used by your command solve different problems.

Also resist treating `Machines.pull_image/4` as an environment upgrade: it populates
an existing OCI machine’s image storage. It does not switch the running workload
or replace that machine’s guest root. Approve a new creation source when you want
a new environment.

The practical gain is small to describe and useful to repeat: **an approved image
in your registry can become a working environment under Elixir’s control, with a
result you check and a lifetime you choose.**

[script]: ../../media/from-registry-image-to-working-environment/registry-report.exs
[receipt]: ../../media/from-registry-image-to-working-environment/validation.json
[registry]: https://hexdocs.pm/smolbox/0.4.1/images-and-registry-artifacts.html
[recovery]: https://hexdocs.pm/smolbox/0.4.1/persistent-machines.html
[reuse]: ../exports-checkpoints-or-branches/
[volumes]: ../replace-the-machine-keep-the-project/
