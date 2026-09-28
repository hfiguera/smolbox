defmodule WorkspaceWeb.SavedStatePanel do
  @moduledoc false
  use Phoenix.Component
  alias Workspace.SavedState

  attr(:result, :any, required: true)
  attr(:busy, :boolean, required: true)
  attr(:notice, :string, default: nil)

  def panel(assigns) do
    assigns =
      assign(
        assigns,
        :data,
        case assigns.result do
          {:ok, s} -> s
          _ -> nil
        end
      )

    ~H"""
    <section id="saved-state" class="workspace saved-state" aria-labelledby="saved-title">
      <header class="saved-heading">
        <div>
          <h2 id="saved-title">A safe place to try something different.</h2>
          <p>
            Prepare an original, save its state, then change a branch. Read both to see what stayed yours.
          </p>
        </div>
        <a
          class="text-link"
          href="https://hexdocs.pm/smolbox/0.3.0/managed-branches.html"
          target="_blank"
          rel="noopener noreferrer"
        >
          How saved state works
        </a>
      </header>
      <p class="saved-boundary">
        Separate from your everyday workspace. An offline bare VM, fixed sample commands, no web service or terminal. The checkpoint saves disk and RAM; the branch copies the running original, not the checkpoint.
      </p>
      <div :if={@notice} class="notice saved-notice" role="status">{@notice}</div>
      <div :if={match?({:error, _}, @result)} class="saved-content" role="alert">
        Saved state is unavailable. Keep its identities and reservations; a failed read does not mean it was deleted.
      </div>
      <div :if={@result == {:ok, nil}} class="saved-content">
        <h3>Enable this walkthrough on Linux</h3>
        <p>
          The existing workspace keeps working. To add this one, stop the app and approve an idle bare seed captured with smolvm 1.19.0. The README explains the seed profile and host storage checks.
        </p>
        <pre class="output">mix workspace.saved_state.setup --seed /private/idle.smolcheckpoint \
    --sha256 VERIFIED_DIGEST --approve-idle</pre>
        <p>
          Requires room for 4 slots, 4 CPUs, 4096 MiB and 32 GiB of reservations across both examples. No machine is created by setup.
        </p>
      </div>
      <div :if={@data} class="saved-content">
        <ol class="saved-steps" aria-label="Saved state walkthrough">
          <li><strong>Prepare</strong><span>{preparation_state(@data)}</span></li>
          <li><strong>Save checkpoint</strong><span>{capture_state(@data.capture)}</span></li>
          <li><strong>Create branch</strong><span>{branch_state(@data.child)}</span></li>
          <li><strong>Change and compare</strong><span>{comparison_state(@data)}</span></li>
        </ol>
        <div class="saved-actions">
          <.action
            :for={{key, label, confirmation} <- steps()}
            :if={SavedState.allowed?(@data, key)}
            key={key}
            label={label}
            confirmation={confirmation}
            busy={@busy}
          />
        </div>
        <p :if={uncertain?(@data)} class="field-error" role="alert">
          This walkthrough needs operator recovery. Preserve the source, child and capture identities below. Unknown work is never replayed; a stopped VM does not fence a request already sent.
        </p>
        <div class="saved-comparison" aria-label="Original and branch command results">
          <article>
            <h3>Original</h3>
            <p>{read_caption(@data.commands["read-original"], "Preparation output")}</p>
            <code>{@data.source_id}</code>
            <pre class="output">{command_output(@data.commands["read-original"] || @data.commands["prepare"])}</pre>
            <span class="subtle">
              {result_label(@data.commands["read-original"] || @data.commands["prepare"])}
            </span>
          </article>
          <article>
            <h3>Branch</h3>
            <p>{read_caption(@data.commands["read-branch"], "Branch change output")}</p>
            <code>{@data.child_id}</code>
            <pre class="output">{command_output(@data.commands["read-branch"] || @data.commands["change"])}</pre>
            <span class="subtle">
              {result_label(@data.commands["read-branch"] || @data.commands["change"])}
            </span>
          </article>
        </div>
        <p :if={comparison_state(@data) == "Both reads complete"} class="saved-verdict">
          Both reads completed after the branch change. Compare the actual output above; the original should still say basil and lemon.
        </p>
        <section class="saved-retention" aria-labelledby="retention-title">
          <h3 id="retention-title">What stays, and until when</h3>
          <dl>
            <div>
              <dt>Original VM</dt>
              <dd>
                {machine_state(@data.source)}. Retained until explicit deletion; branch dependencies must be retired first.
              </dd>
            </div>
            <div>
              <dt>Branch VM</dt>
              <dd>{machine_state(@data.child)}. Deleting it does not release its source backing.</dd>
            </div>
            <div>
              <dt>Checkpoint artifact</dt>
              <dd>
                {capture_state(@data.capture)}. Disk reservation stays until all copies are removed and release is confirmed.
              </dd>
            </div>
            <div>
              <dt>Branch backing</dt>
              <dd>
                {branch_state(@data.child)}. Extra allowance stays after child deletion until host cleanup is confirmed.
              </dd>
            </div>
            <div>
              <dt>Worker reservations</dt>
              <dd>
                {usage(@data.usage)}. Includes your everyday workspace. These are accounting budgets, not measured host usage.
              </dd>
            </div>
          </dl>
          <details id="saved-capture-evidence">
            <summary>Machine identities and checkpoint file</summary>
            <p :if={@data.source}>Original worker name: <code>{@data.source.machine_name}</code></p>
            <p :if={@data.child}>Branch worker name: <code>{@data.child.machine_name}</code></p>
            <p :if={@data.capture}>
              Capture <code>prepared-v1</code> belongs to <code>{@data.source_id}</code>.
            </p>
            <p :if={@data.capture && @data.capture.result}>
              <code>{@data.capture.result.path}</code>
              <br />SHA-256 <code>{@data.capture.result.sha256}</code>
            </p>
            <p>
              Preserve the seed, database, keys and retained files across app restarts. The seed has its own host-managed lifetime.
            </p>
          </details>
        </section>
        <details class="saved-cleanup" id="saved-cleanup">
          <summary>Finish and clean up</summary>
          <p>
            Delete the child, confirm its requests are quiescent, then delete the original. Inspect the worker and remove owned backing before releasing its allowance. The everyday workspace stays untouched. Checkpoint deletion is a separate, confirmed choice below.
          </p>
          <p>
            Only confirm host cleanup after following the README procedure. A successful delete response or an empty machine list is not sufficient evidence.
          </p>
          <div class="saved-actions">
            <.action
              :for={{key, label, confirmation} <- cleanup()}
              :if={SavedState.allowed?(@data, key)}
              key={key}
              label={label}
              confirmation={confirmation}
              busy={@busy}
            />
          </div>
          <.capture_cleanup
            :if={SavedState.allowed?(@data, "release-capture")}
            files={@data.capture_files}
            finished={SavedState.cleanup_finished?(@data)}
            keep={SavedState.allowed?(@data, "keep-capture")}
            notice={@notice}
            busy={@busy}
          />
          <p :if={@data.capture && @data.capture.released_at_ms} role="status">
            Checkpoint reservation released. Walkthrough history is preserved.
          </p>
          <p>
            History remains after cleanup. This bounded walkthrough uses one original, one checkpoint and one branch per configuration; refreshing never starts a new run.
          </p>
        </details>
      </div>
    </section>
    """
  end

  defp capture_cleanup(assigns) do
    assigns = assign(assigns, :ready, Enum.map(assigns.files, & &1.state) == [:absent, :absent])

    ~H"""
    <section class="saved-capture-cleanup" aria-labelledby="capture-cleanup-title">
      <h3 id="capture-cleanup-title">Finish with your checkpoint</h3>
      <p :if={!@finished}>
        Finish deleting the VMs and releasing their backing above, then choose whether to keep or
        delete the checkpoint. It stays retained until you explicitly delete it.
      </p>
      <p :if={@finished && !@ready} id="capture-cleanup-status">
        Your VMs are cleaned up. Keep the checkpoint for later, or delete its recorded files here.
        Keeping it also keeps its disk reservation.
      </p>
      <p :if={@ready} id="capture-cleanup-status">
        Both recorded paths are absent. Confirm that no copies remain elsewhere to release the reservation.
      </p>
      <p :if={@notice} class="notice" role="status">{@notice}</p>
      <div :if={@keep} class="saved-actions">
        <.action key="keep-capture" label="Keep checkpoint" confirmation={nil} busy={@busy} />
      </div>
      <details :if={@finished && !@ready} id="saved-delete-checkpoint">
        <summary>Delete checkpoint…</summary>
        <p>
          This permanently deletes the checkpoint and any partial file listed below, then releases
          its reservation. You will no longer be able to restore this saved state. The seed and other
          captures stay untouched.
        </p>
        <.action
          key="delete-capture"
          label="Delete checkpoint and release reservation"
          confirmation="Delete this checkpoint permanently. I verified no restore or other consumer needs it, no delayed work can write these files, and no copies remain elsewhere."
          busy={@busy}
        />
      </details>
      <ul class="saved-capture-files">
        <li :for={file <- @files}>
          <strong>{file_status(file.state)}</strong>
          <code>{file.path}</code>
        </li>
      </ul>
      <p>File status updates automatically. Copies outside these paths require manual cleanup.</p>
      <.action
        :if={@ready}
        key="release-capture"
        label="Release checkpoint reservation"
        confirmation="I removed all checkpoint copies and partial files, including any copies elsewhere."
        busy={@busy}
      />
    </section>
    """
  end

  defp file_status(:present), do: "Still on disk"
  defp file_status(:absent), do: "Absent"
  defp file_status(:unavailable), do: "Cannot check this path; verify host access"

  defp action(assigns) do
    ~H"""
    <form phx-submit="saved-state" id={"saved-#{@key}"}>
      <input type="hidden" name="action" value={@key} />
      <label :if={@confirmation} class="saved-confirm">
        <input type="checkbox" name="confirmed" value="true" required disabled={@busy} />
        <span>{@confirmation}</span>
      </label>
      <button
        class={
          if @key in ~w(delete-child delete-source delete-capture), do: "danger", else: "primary"
        }
        disabled={@busy}
        phx-disable-with="Recording…"
      >
        {@label}
      </button>
    </form>
    """
  end

  defp steps,
    do: [
      {"create", "Create saved state workspace", nil},
      {"start", "Start original", nil},
      {"prepare", "Prepare sample files", nil},
      {"capture", "Save checkpoint",
       "I verified the original is idle, with no user workloads or credentials waiting to resume."},
      {"confirm-capture", "Confirm capture finished",
       "I verified capture requests and helper work are quiescent and worker staging is cleaned. A completed download alone is not enough."},
      {"branch", "Create branch", "I verified the original is still idle and safe to copy."},
      {"change", "Change branch recipe", nil},
      {"compare", "Read both machines", nil}
    ]

  defp cleanup,
    do: [
      {"delete-child", "Delete branch VM", "Delete this branch and its guest files permanently."},
      {"retire-child", "Retire branch dependency",
       "I verified the deleted child's earlier requests are quiescent."},
      {"delete-source", "Delete original VM",
       "Delete the original and its guest files permanently. The checkpoint remains retained."},
      {"release-backing", "Release backing allowance",
       "I verified all owned source generations, snapshots and temporary worker backing are removed, with no delayed requests remaining."}
    ]

  defp preparation_state(s) do
    if SavedState.success?(s.commands["prepare"]),
      do: "Sample prepared",
      else: machine_state(s.source)
  end

  defp read_caption(nil, fallback), do: fallback <> ". Disk recipe, then RAM note."

  defp read_caption(_, _),
    do: "Comparison read after the branch change. Disk recipe, then RAM note."

  defp machine_state(nil), do: "Not created"
  defp machine_state(m), do: human(m.state)
  defp branch_state(nil), do: "No branch"
  defp branch_state(%{branch: b}), do: human(b.state)
  defp capture_state(nil), do: "Not saved"
  defp capture_state(%{released_at_ms: at}) when not is_nil(at), do: "Reservation released"
  defp capture_state(c), do: human(c.state)
  defp human(state), do: state |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp comparison_state(s),
    do:
      if(
        SavedState.success?(s.commands["read-original"]) and
          SavedState.success?(s.commands["read-branch"]),
        do: "Both reads complete",
        else: "Awaiting both reads"
      )

  defp command_output(nil), do: "No command result yet."
  defp command_output(e), do: SavedState.output(e) || "No output recorded."
  defp result_label(nil), do: "No request submitted"
  defp result_label(e), do: "#{human(e.state)} · request #{e.id}"

  defp usage({:ok, u}),
    do: "#{u.slots} slots · #{u.cpus} CPUs · #{u.memory_mb} MiB · #{u.disk_gb} GiB"

  defp usage(_), do: "Unavailable; do not assume capacity is free"

  defp uncertain?(s),
    do:
      Enum.any?(
        [s.source, s.child, s.capture | Map.values(s.commands)],
        &match?(%{state: state} when state in [:unknown, :missing, :conflict], &1)
      )
end
