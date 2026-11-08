defmodule SmolBox.Embedded.Bridge do
  @moduledoc """
  Asynchronous native-operation contract shared by embedded bridges.

  Port is the first implementation. A later Rustler bridge must preserve this
  contract using the same engine and domain authority. Bridges are selected at
  runtime; selecting a bridge never changes durable assignment identity.

  The supervised owner admits a bounded request and monitors its observer. A
  returned handle acknowledges bridge admission only. The observer receives
  `{:smolbox_embedded, handle, event}` messages. Native acceptance, output, and
  terminal completion remain separate events. Acceptance never proves dispatch,
  a running guest, command exit, or file completion.

  The observer acknowledges decoded output bytes after consumption. The owner
  bounds subscriptions, queues, and outstanding credit independently of native
  limits. Observer death initiates cancellation and finite draining of that
  request. A cancellation acknowledgment never confirms guest termination.

  A healthy channel delivers exactly one terminal event per accepted request.
  Channel loss delivers a redacted error with conservative dispatch evidence;
  it does not invent a native terminal, replay a request, or release an unknown
  reservation. Only operation evidence can resolve an uncertain outcome.

  The caller must monitor the owner before submission. Unexpected owner death
  cannot deliver an event from that owner; its monitor resolves the call once,
  conservatively, without replay through a replacement owner. A fresh owner
  admits inspections only until the controller has fenced its durable domain
  binding, reconciled retained records, and explicitly activated mutations.

  Quiescence fences new mutations before waiting for accepted requests to finish
  draining. A known busy reply proves neither quiescence nor permission to
  dispatch more work. Callers may wait only within their captured deadline on
  the same pinned owner and epoch; uncertain replies and changed identity stay
  fenced. Waiting for quiescence never replays the native operation.

  A completed scan may be retained across an explicit original ready-result
  recovery only after its validated completion and fresh source/child observations
  commit atomically. Reactivation still requires the same healthy owner, epoch
  and worker lease generation within the original deadline. Material publication,
  partial/uncertain results and incomplete scans cannot establish readiness.

  A terminal event carries the actual native outcome plus an optional bridge
  error that disqualifies completion, such as an exceeded response budget. This
  error never replaces a real observed exit. Known unsent failures use
  `:bridge_error`; observation loss uses `:channel_lost`, without fabricating a
  native terminal. Upload chunks and output acknowledgments have independent
  bounded admission. Explicit shutdown stops admission and requests scoped native
  shutdown; it does not confirm deletion or release reservations.

  Request and terminal maps are normalized native DTOs private to the embedded
  backend. Erlang handles, Port packets, and Rustler resources are operational
  values and must never enter durable store records.

  `health/1` reports status, target ID, domain generation and the approved package
  identity and manifest digest. Consumers validate these against the assigned
  target using the original monitored owner PID before submission. Health does
  not discover machine inventory or establish ownership of an assigned machine.

  Managed callers capture the owner PID and epoch before writing durable intent.
  `submit/5` checks the supplied epoch atomically at owner admission, closing the
  health-to-submit race when that same owner has restarted its helper. `activate/3`
  similarly binds completed reconciliation to its inspected channel. Stale epochs
  are rejected before allocating a request ID or queue space. Pins and epochs
  remain operational; they do not change receipts, assignment identity or store
  fencing. The unfenced arities support explicit low-level development probes;
  managed dispatch and recovery must use the fenced callbacks.
  """
  alias SmolBox.Backend.Budget
  alias SmolBox.Embedded.Config
  alias SmolBox.Error

  @type server :: GenServer.server()
  @type handle :: reference()
  @type request :: map()
  @type terminal :: map()
  @type event ::
          :accepted
          | :terminal_opened
          | {:output, :stdout | :stderr | :file | :log | :terminal, binary()}
          | {:terminal, terminal(), Error.t() | nil}
          | {:bridge_error, Error.t()}
          | {:channel_lost, Error.t()}

  @callback start_link(Config.t(), keyword()) :: GenServer.on_start()
  @callback submit(server(), request(), Budget.t(), observer :: pid()) ::
              {:ok, handle()} | {:error, Error.t()}
  @callback submit(server(), request(), Budget.t(), observer :: pid(), epoch :: String.t()) ::
              {:ok, handle()} | {:error, Error.t()}
  @callback acknowledge(server(), handle(), decoded_bytes :: pos_integer()) ::
              :ok | {:error, Error.t()}
  @callback cancel(server(), handle()) :: :ok | {:error, Error.t()}
  @callback upload(server(), handle(), binary()) :: :ok | {:error, Error.t()}
  # Controls are ordered, epoch-bound to the opaque handle, and admitted only
  # from the terminal observer. Input admission does not prove guest consumption.
  @callback terminal_control(server(), handle(), map()) :: :ok | {:error, Error.t()}
  @callback activate(server(), binding :: map()) :: :ok | {:error, Error.t()}
  @callback activate(server(), binding :: map(), epoch :: String.t()) :: :ok | {:error, Error.t()}
  @callback quiesce(server(), epoch :: String.t()) :: :ok | {:error, Error.t()}
  # Same-owner branch controls share one captured operation deadline. Bridges
  # supporting them must bound quiescence and activation by the remaining time.
  @callback activate(server(), map(), String.t(), pos_integer()) :: :ok | {:error, Error.t()}
  @callback quiesce(server(), String.t(), pos_integer()) :: :ok | {:error, Error.t()}
  @callback shutdown(server()) :: :ok | {:error, Error.t()}
  @callback health(server()) :: {:ok, map()} | {:error, Error.t()}
  # Interactive adapters use finite call budgets from one absolute deadline.
  # Legacy non-interactive bridges may omit these variants; a bridge advertising
  # terminals must implement them with the same caller/observer identity checks.
  @callback health(server(), pos_integer()) :: {:ok, map()} | {:error, Error.t()}
  # Cached nonsecret destination identity/caps and optional conversion grant,
  # selected under a pinned epoch. Missing grants preserve legacy bare behavior.
  # Bridges advertising exports must implement this without filesystem/network I/O.
  @callback export_approval(server(), String.t(), String.t(), pos_integer()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback submit(server(), request(), Budget.t(), pid(), String.t(), pos_integer()) ::
              {:ok, handle()} | {:error, Error.t()}
  @callback terminal_control(server(), handle(), map(), pos_integer()) ::
              :ok | {:error, Error.t()}
  @callback acknowledge(server(), handle(), pos_integer(), pos_integer()) ::
              :ok | {:error, Error.t()}
  @callback cancel(server(), handle(), pos_integer()) :: :ok | {:error, Error.t()}
  @optional_callbacks activate: 4,
                      quiesce: 3,
                      health: 2,
                      submit: 6,
                      terminal_control: 4,
                      acknowledge: 4,
                      cancel: 3,
                      export_approval: 4
end
