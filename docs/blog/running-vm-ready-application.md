The machine says `running`. The page will not load.

If you have spent time with development servers, that probably sounds familiar.
You have one positive signal and one very unhelpful browser tab. Did the program
start? Is it still loading? Did you reach the wrong port?

In the [previous article][workspace], we built a workspace that keeps its files
across commands and controller restarts. This time, we will give that machine a
small HTTP service and ask a more specific question: **can the application do
what we need right now?**

We will start it successfully, deliberately break its startup command, and
compare a configured workload with a background launch. The examples use
SmolBox 0.2.0 and smolvm 1.17.0.

## Two observations, two questions

A machine observation tells us about the VM. A readiness request tells us about
the application through the path we intend to use.

Those observations can disagree without either being wrong. Our test service
will listen immediately but return HTTP 503 while it warms up. Later, it will
return HTTP 200 with an identifier we expect. In the broken case, the startup
executable will not exist at all. The VM can still report `running`.

<figure class="readiness-figure" id="readiness-lab" aria-labelledby="readiness-caption">
  <div class="readiness-controls" hidden>
    <div class="readiness-cases" role="group" aria-label="Startup scenario">
      <button type="button" data-case="healthy" aria-pressed="true">Working application</button>
      <button type="button" data-case="broken" aria-pressed="false">Missing executable</button>
    </div>
  </div>
  <div class="readiness-stage" data-phase="ready">
    <p class="readiness-headline">Ask the application.</p>
    <p class="readiness-detail">The expected HTTP response supplies evidence the VM state cannot.</p>
    <div class="readiness-lanes" aria-hidden="true">
      <div class="readiness-lane"><span>Machine</span><div class="readiness-rail"><i class="readiness-signal machine-signal"></i></div><strong class="readiness-vm">Running</strong></div>
      <div class="readiness-lane"><span>Application</span><div class="readiness-rail"><i class="readiness-signal app-signal"></i></div><strong class="readiness-app">Responding</strong></div>
    </div>
    <div class="readiness-exchange">
      <div><span class="readiness-label">From the controller</span><code>GET /ready</code></div>
      <svg class="readiness-wire" viewBox="0 0 200 54" aria-hidden="true"><path class="readiness-wire-base" d="M4 16 H186 l-7 -6 m7 6 l-7 6 M196 40 H14 l7 -6 m-7 6 l7 6"/><path class="readiness-outgoing" d="M4 16 H186"/><path class="readiness-incoming" d="M196 40 H14"/></svg>
      <div><span class="readiness-label">Application response</span><strong class="readiness-response">200 + expected identity</strong></div>
    </div>
    <p class="readiness-explanation">A running VM and a matching application response answer different questions.</p>
  </div>
  <div class="readiness-controls readiness-playback" hidden>
    <button type="button" class="readiness-play">Play comparison</button>
    <button type="button" class="readiness-next">Next step</button>
    <span class="readiness-step" aria-live="polite" aria-atomic="true">Step 1 of 4</span>
  </div>
  <figcaption id="readiness-caption">Explore a working startup and a missing executable. This is an explanatory animation based on the checks below, not a recording or a timing measurement. Both cases can report a running VM. Only the working application returns the expected readiness response.</figcaption>
</figure>


The request in the animation travels from the controller through the mapped
host port to the guest application. That choice matters. A check made only
inside the guest would not exercise the mapping your caller depends on.

## Give the machine a job

The [complete example](../../media/running-vm-ready-application/readiness.exs)
contains a small Python HTTP server. It uses only Python's standard library.
On `/ready`, it returns 503 for the first six seconds, then 200 with this shape:

```elixir
%{"service" => "readiness-demo", "instance" => instance_id}
```

The delay makes the transition visible. A real service should base readiness on
the work it needs to accept requests, such as loading a model or opening a
required database connection. Sleeping six seconds is a teaching device, not a
readiness strategy.

We give the machine its startup command through `SmolBox.Workload`:

```elixir
{:ok, workload} =
  SmolBox.Workload.new(
    entrypoint: ["python"],
    cmd: ["-c", server_program],
    env: [{"INSTANCE", instance_id}],
    workdir: "/",
    restart: :never
  )
```

Here, `server_program` is the Python source in the downloadable example. The
approved image must already contain the executable and any dependencies it
needs. Arguments are passed directly; there is no implicit shell.

Attach the workload and a TCP mapping when creating the managed machine:

```elixir
{:ok, spec} =
  SmolBox.ManagedMachineSpec.new(
    scope: "readiness-blog",
    id: instance_id,
    artifact: approved_artifact,
    profile: approved_profile,
    workload: workload,
    ports: [%SmolBox.PortMapping{host: 18080, guest: 8000}]
  )
```

The server binds to `0.0.0.0:8000` **inside the guest**. The worker's host binding
is configured separately; this walkthrough uses a dedicated worker with the
mapped service accessible on host loopback. If the controller is elsewhere, the
probe URL and access controls must match that deployment.

The complete script supplies the runtime, approved artifact and profile, creates
the machine, starts it, and waits for its running observation. Then it asks the
application.

## Check the answer you actually need

A listening port is only a start. For this example, success means HTTP 200 **and**
the expected service and instance identifiers:

```elixir
case Req.get(url,
       retry: false,
       redirect: false,
       finch: [
         receive_timeout: 500,
         pool_timeout: 500,
         conn_opts: [transport_opts: [timeout: 500]]
       ],
       decode_body: false
     ) do
  {:ok, %{status: 200, body: body}} ->
    case Jason.decode(body) do
      {:ok, %{"service" => "readiness-demo", "instance" => ^instance_id}} -> :ready
      _ -> :unexpected_response
    end

  {:ok, %{status: status}} ->
    {:http_status, status}

  {:error, _reason} ->
    :unreachable
end
```

Checking the body avoids accepting a generic 200 page from an unrelated service.
The identifier is a fixture check, not authentication. A remote deployment still
needs appropriate transport security and access controls.

We disable redirects and automatic retries so each recorded attempt is one
explicit request to the configured endpoint. The helper makes at most 40 attempts
with a short pause between them. Its connection, pool and receive waits are
bounded separately; the whole sequence is not a strict single wall clock deadline.
Choose those limits for your application and network. Do not block a LiveView
callback while waiting; run the observation in a supervised task and report its
result back to the UI.

Once a response matches, we have evidence that this service was ready **at that
moment**. We still need to handle a failure on the next request. Readiness is an
observation, not a guarantee about the future.

## Now break startup

Replace the entrypoint with a path that does not exist:

```elixir
{:ok, workload} =
  SmolBox.Workload.new(entrypoint: ["/missing-readiness-app"], cmd: [])
```

Use a new machine identity for this case. The creation specification is immutable;
changing a workload under the same identity should conflict, not quietly replace
what that identity means.

This is the revealing part of the experiment. smolvm 1.17.0 can finish starting
the VM even when the application launch fails. The machine reports `running`,
but our bounded readiness check never receives the expected response.

A failed probe does not, by itself, tell us why. A wrong port, wrong bind address,
slow startup and a missing executable can all make the service unavailable to
this caller. The deliberate missing path gives this experiment a known cause.

Start with the machine's console diagnostics:

```elixir
{:ok, %SmolBox.LogResult{source: :console, lines: lines}} =
  SmolBox.Machines.logs(runtime, handle, tail: 20)
```

These are boot and agent diagnostics. **They are not the application's stdout
and stderr.** Upstream 1.17.0 discards those startup streams, and some launch
errors appear only in the worker's host logs. An empty console is not proof of
successful startup either.

For our known missing executable, the script submits a separate foreground
diagnostic command that tries the same path. That command produces an observable
exit code and stderr. This is a new execution, not recovered output from the
original startup attempt. Do this only when repeating the command is safe; an
installer or a command that writes data could have side effects.

Our working service writes its request log to `/workspace/service.log`. That is
an explicit application choice. A real application can do the same, with bounded
logs and an appropriate collection policy. SmolBox's console API does not turn
those files into an application log stream.

## A background PID answers a smaller question

There is another way to launch the same Python service: submit it as a command
with `background: true` after starting a machine without a workload.

```elixir
{:ok, command} =
  SmolBox.Command.new(["python", "-c", server_program],
    background: true,
    env: [{"INSTANCE", instance_id}]
  )
```

A confirmed launch returns `SmolBox.LaunchResult` with a typed PID. It does not
wait for `/ready`, supervise the process, or report its eventual exit. We run
exactly the same readiness check afterward.

The distinction becomes concrete after stopping and starting the VM:

| How the service was started | What an explicit VM stop/start does |
| --- | --- |
| Machine startup workload | Launches the configured workload again |
| Separate background command | Requires an explicit new launch of the service |

A controller restart is different from a VM restart. Reconnecting the controller
does not mean that it should launch another copy of an already running service.
Keep the original execution identity when resolving an uncertain request.

SmolBox currently accepts only `restart: :never` for workload configuration.
Automatic restart policies are rejected because upstream's VM restart supervisor
does not reliably relaunch the application. Explicit stop/start is a supported
lifecycle operation; automatic application supervision is not part of this API.

## Run the three cases

Use a dedicated smolvm 1.17.0 worker and the [durable host setup][durable]. You
need PostgreSQL with the example migrations applied, stable private keys and
configuration, an approved native Python image, and a free mapped host port.
The example uses the qualified 2 GiB storage and 2 GiB overlay profile, so the
worker needs the documented disk tools and a compatible image.

Clone the repository, complete that setup, then run these commands from
`examples/durable_host`:

```sh
export READINESS_PORT=18080
export SMOLBOX_STORE_PARTITION=readiness-demo

SMOLBOX_EXECUTION_ID=readiness-healthy-1 \
  mix run ../../docs/blog/media/running-vm-ready-application/readiness.exs healthy

SMOLBOX_EXECUTION_ID=readiness-broken-1 \
  mix run ../../docs/blog/media/running-vm-ready-application/readiness.exs broken

SMOLBOX_EXECUTION_ID=readiness-background-1 \
  mix run ../../docs/blog/media/running-vm-ready-application/readiness.exs background
```

The default probe URL is `http://127.0.0.1:18080/ready`; `READINESS_URL` overrides
it when the caller reaches the service through a different host address or
forwarding setup. The script lives in this repository and reuses its durable
example helpers. The smaller code blocks above show the relevant API calls;
they are excerpts, not independent scripts.

Each successful case explicitly deletes its own machine and verifies absence
and released reservations. On an unexpected failure, the durable records remain
for inspection. Preserve the database, keys, worker and original identity. Do not
rerun with a fresh identity to get around an unknown operation. The script also
provides a `delete` phase for an owned machine whose state permits deletion; it
does not bypass recovery guards. For a new completed demonstration, choose new
IDs because deleted identities retain their history.

Here is what the three live runs showed on a native macOS worker:

| Case | Observed result |
| --- | --- |
| Startup workload | HTTP 503 during warmup, then the expected 200 response. The service launched again after stop/start. |
| Missing executable | The VM stayed running. All eight probes failed, and the separate diagnostic command returned exit code 127. |
| Background command | A launch PID arrived before readiness. After stop/start, the service needed an explicit new launch. |

Both working cases rejected an incorrect instance identifier and preserved the
startup counter across stop/start. All three verified deletion and released
reservations. The [recorded results](../../media/running-vm-ready-application/validation.json)
include the probe observations and test setup. They are functional checks, not
performance measurements.

## Ask one more question before saying ready

A VM observation, a launch receipt and an application response are all useful.
They tell us different things.

When you show “Ready” in an interface, decide what that word promises to the
person about to use it. For this example, it means that the expected application
answered through the mapped port. For your application, it might mean that a
model is loaded, a project is indexed, or a required dependency can be reached.

Start with that promise. Then write the smallest check that actually tests it.

[workspace]: ../build-a-persistent-workspace/
[durable]: https://github.com/hfiguera/smolbox/tree/main/examples/durable_host
