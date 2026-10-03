// Progressive enhancement only. Copy actions are never sent to analytics.
// Playback is reader initiated. Pause motion when the figure leaves view.
const motionVideos = document.querySelectorAll(".motion-video");
motionVideos.forEach((video) => {
  if (video.hasAttribute("data-native-controls")) return;
  const controls = document.createElement("div");
  controls.className = "motion-controls";
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "Play animation";
  const duration = document.createElement("span");
  duration.textContent = "9 seconds · no audio";
  button.addEventListener("click", async () => {
    if (!video.paused) return video.pause();
    if (video.ended) video.currentTime = 0;
    try {
      await video.play();
    } catch {
      video.controls = true;
      button.textContent = "Try playback again";
    }
  });
  video.addEventListener("play", () => { button.textContent = "Pause animation"; });
  video.addEventListener("pause", () => {
    button.textContent = video.ended ? "Replay animation" : "Play animation";
  });
  video.addEventListener("ended", () => { button.textContent = "Replay animation"; });
  controls.append(button, duration);
  video.after(controls);
  video.controls = false;
});
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(({ target, isIntersecting }) => {
      if (!isIntersecting) target.pause();
    });
  });
  motionVideos.forEach((video) => observer.observe(video));
}
document.addEventListener("visibilitychange", () => {
  if (document.hidden) motionVideos.forEach((video) => video.pause());
});
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
reducedMotion.addEventListener("change", () => {
  if (reducedMotion.matches) motionVideos.forEach((video) => video.pause());
});
document.querySelectorAll(".prose pre").forEach((block) => {
  const code = block.querySelector("code");
  if (!code || !navigator.clipboard) return;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-code";
  button.textContent = "Copy";
  button.setAttribute("aria-label", "Copy code example");
  const status = document.createElement("span");
  status.className = "sr-only";
  status.setAttribute("role", "status");
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(code.textContent);
      button.textContent = "Copied";
      status.textContent = "Code copied to clipboard.";
    } catch {
      button.textContent = "Select code";
      const range = document.createRange();
      range.selectNodeContents(code);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = "Clipboard unavailable. Code selected; use your browser’s copy command.";
    }
    window.setTimeout(() => { button.textContent = "Copy"; status.textContent = ""; }, 2500);
  });
  block.append(button, status);
});
// The diagram is explanatory, not a request to a live worker.
document.querySelectorAll('.readiness-figure').forEach((figure) => {
  const stage = figure.querySelector('.readiness-stage');
  const play = figure.querySelector('.readiness-play');
  const next = figure.querySelector('.readiness-next');
  const stepLabel = figure.querySelector('.readiness-step');
  const cases = figure.querySelectorAll('[data-case]');
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const common = [
    ['boot', 'Start with a machine.', 'The controller requests a VM start. No application response has been observed.', 'Starting', 'Not checked', 'Not checked', 'A successful create request gives us a machine identity. It says nothing yet about the application.'],
    ['running', 'The VM is running.', 'That is useful evidence. It is not an application readiness check.', 'Running', 'Not checked', 'Not checked', 'The VM can report running even when its startup executable does not exist. Now ask the application.']
  ];
  const sequences = {
    healthy: [...common,
      ['warm', 'Listening. Still warming up.', 'The application accepts HTTP but is not ready to do its job.', 'Running', 'Warming up', '503', 'The demo deliberately waits before becoming ready. An open port, or even an HTTP response, is not enough.'],
      ['ready', 'Now we have an answer.', 'The readiness endpoint returns the expected status and instance identity.', 'Running', 'Responding', '200 + expected identity', 'This observation supports using the service now. It is not a promise that the next request will succeed.']
    ],
    broken: [...common,
      ['broken', 'The executable is missing.', 'The startup attempt failed. The VM can remain running.', 'Running', 'Launch failed', 'No valid response', 'Read boot diagnostics, then inspect the approved command and image. A failed probe alone does not identify the cause.'],
      ['broken', 'Waiting does not fix startup.', 'The readiness attempts finish without the expected application response.', 'Running', 'Launch failed', 'Not ready', 'Keep the machine state and readiness result separate. Diagnose the failure before choosing an explicit next action.']
    ]
  };
  let scenario = 'healthy';
  let step = 0;
  let timer;
  let frame;
  function pause() {
    clearTimeout(timer);
    cancelAnimationFrame(frame);
    timer = undefined;
    stage.classList.remove('is-moving');
    play.textContent = step === 3 ? 'Replay' : 'Play comparison';
  }
  function render() {
    const [phase, headline, detail, vm, app, response, explanation] = sequences[scenario][step];
    stage.dataset.phase = phase;
    for (const [selector, value] of Object.entries({'.readiness-headline': headline, '.readiness-detail': detail, '.readiness-vm': vm, '.readiness-app': app, '.readiness-response': response, '.readiness-explanation': explanation})) {
      figure.querySelector(selector).textContent = value;
    }
    stepLabel.textContent = `Step ${step + 1} of 4. ${headline}`;
    next.textContent = step === 3 ? 'Back to start' : 'Next step';
    if (!timer) play.textContent = step === 3 ? 'Replay' : 'Play comparison';
    stage.classList.remove('is-moving');
    cancelAnimationFrame(frame);
    if (!reduced.matches && step >= 2) frame = requestAnimationFrame(() => {
      if (stage.dataset.phase === phase) stage.classList.add('is-moving');
    });
  }
  function advance() {
    step += 1;
    render();
    if (step === 3) {
      timer = setTimeout(pause, 2600);
    } else {
      timer = setTimeout(advance, 3000);
    }
  }
  play.addEventListener('click', () => {
    if (timer) return pause();
    if (step === 3) step = 0;
    render();
    play.textContent = 'Pause';
    timer = setTimeout(advance, 3000);
  });
  next.addEventListener('click', () => { pause(); step = (step + 1) % 4; render(); });
  cases.forEach((button) => button.addEventListener('click', () => {
    pause(); scenario = button.dataset.case; step = 0;
    cases.forEach((item) => item.setAttribute('aria-pressed', String(item === button)));
    render();
  }));
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  reduced.addEventListener('change', pause);
  if ('IntersectionObserver' in window) new IntersectionObserver((entries) => {
    if (!entries[0].isIntersecting) pause();
  }).observe(figure);
  figure.querySelectorAll('.readiness-controls').forEach((el) => { el.hidden = false; });
  render();
});

// A bounded teaching model. No sockets, worker requests or command replay.
document.querySelectorAll('.disconnect-figure').forEach((figure) => {
  const stage = figure.querySelector('.disconnect-stage');
  const play = figure.querySelector('.disconnect-play');
  const next = figure.querySelector('.disconnect-next');
  const status = figure.querySelector('.disconnect-step');
  const choices = figure.querySelectorAll('[data-disconnect-case]');
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const connected = ['connected', 'One session. Two connections.', 'The browser receives output through an application process that owns the worker connection.', 'Connected', 'Owns the stream', 'Shell responding', 'Output', 'PTY stream', 'running · no exit recorded', 'The program has produced output. We have not observed how it ends.'];
  const scenarios = {
    browser: [connected,
      ['detached', 'The browser disappears.', 'In this scenario, the application owner and worker connection remain alive.', 'Disconnected', 'Keeps the stream', 'No exit observed', 'Connection lost', 'PTY attached', 'running · no exit recorded', 'The view is gone. The application has not received an exit result.'],
      ['waiting', 'Keep a place for the returning view.', 'The workspace example allows 30 seconds after its LiveView owner disappears.', 'May return', 'Bounded grace period', 'No exit observed', 'Waiting for view', 'PTY attached', 'running · limits still apply', 'This window is an application policy. An idle deadline, output limit or lost worker connection can still end it.'],
      ['resumed', 'The existing stream returns.', 'A new browser consumer reaches the same surviving owner. No new shell is opened.', 'Connected again', 'Same session owner', 'Output returns', 'Output resumes', 'Same PTY stream', 'running · no exit recorded', 'Reconnection restores the view in this scenario. It does not supply an exit result or replay command input.']
    ],
    worker: [connected,
      ['lost', 'The worker connection drops.', 'No trustworthy exit notification arrives before the terminal stream is lost.', 'Shows disconnect', 'Loses the stream', 'Unknown', 'Status update', 'Connection lost', 'unknown · exit not observed', 'The worker attempts to kill its direct PTY child. We cannot infer that every descendant stopped.'],
      ['recovered', 'Recover the record, not the socket.', 'A controller can recover durable identity and saved evidence after a restart.', 'Shows the record', 'Recovers identity', 'Unknown', 'Inspect identity', 'No live stream', 'unknown · same execution ID', 'The record contains no terminal transcript. Attaching cannot recreate the lost guest session.'],
      ['blocked', 'More work waits for resolution.', 'A possibly dispatched terminal with an unknown outcome keeps the machine slot occupied.', 'Needs attention', 'Holds the slot', 'Unknown', 'Recovery status', 'No live stream', 'unknown · new commands blocked', 'Drain old requests, verify ownership and establish safe machine state before explicit resolution. A new ID is not recovery.']
    ],
    exit: [connected,
      ['exiting', 'Ask the shell to exit.', 'The owner sends exit 7 as input. Sending bytes does not yet prove the guest consumed them.', 'Sends input', 'Forwards bytes', 'Awaiting exit', 'exit 7', 'Input sent', 'running · no exit recorded', 'A successful input call is not an exit receipt. Continue consuming events.'],
      ['observed', 'An exit notification arrives.', 'In this scenario, the owner receives a trustworthy exit status of 7.', 'Sees exit 7', 'Saves the outcome', 'Exited (7)', 'Exit event', 'Exit observed', 'completed · exited · code 7', 'Completed means the outcome is known. Exit code 7 is not program success, and live delivery can precede the durable write.'],
      ['released', 'The next command can begin.', 'After the result is saved and the slot is released, the retained machine is available.', 'May start new work', 'Slot released', 'Exited (7)', 'Saved result', 'Session ended', 'completed · active_execution: nil', 'The shell ended. The machine and its files remain; background descendants need their own lifecycle.']
    ]
  };
  const fields = ['phase', '.disconnect-headline', '.disconnect-detail', '.disconnect-browser', '.disconnect-controller', '.disconnect-guest', '.browser-link-label', '.worker-link-label', '.disconnect-evidence', '.disconnect-explanation'];
  let selected = 'browser';
  let step = 0;
  let timer;
  let frame;
  function pause() {
    clearTimeout(timer);
    cancelAnimationFrame(frame);
    timer = undefined;
    stage.classList.remove('is-moving');
    play.textContent = step === 3 ? 'Replay scenario' : 'Play scenario';
  }
  function render() {
    const values = scenarios[selected][step];
    stage.dataset.phase = values[0];
    fields.slice(1).forEach((selector, i) => { figure.querySelector(selector).textContent = values[i + 1]; });
    status.textContent = `Step ${step + 1} of 4. ${values[1]}`;
    next.textContent = step === 3 ? 'Back to start' : 'Next step';
    stage.classList.remove('is-moving');
    cancelAnimationFrame(frame);
    if (!reduced.matches) frame = requestAnimationFrame(() => stage.classList.add('is-moving'));
    if (!timer) play.textContent = step === 3 ? 'Replay scenario' : 'Play scenario';
  }
  function advance() {
    step += 1;
    render();
    timer = setTimeout(step === 3 ? pause : advance, 4200);
  }
  play.addEventListener('click', () => {
    if (timer) return pause();
    if (step === 3) step = 0;
    render();
    play.textContent = 'Pause';
    timer = setTimeout(advance, 4200);
  });
  next.addEventListener('click', () => { pause(); step = (step + 1) % 4; render(); });
  choices.forEach((button) => button.addEventListener('click', () => {
    pause(); selected = button.dataset.disconnectCase; step = 0;
    choices.forEach((choice) => choice.setAttribute('aria-pressed', String(choice === button)));
    render();
  }));
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  reduced.addEventListener('change', pause);
  if ('IntersectionObserver' in window) new IntersectionObserver((entries) => {
    if (!entries[0].isIntersecting) pause();
  }).observe(figure);
  render();
  // Initial load stays still, including for readers who permit motion.
  cancelAnimationFrame(frame);
  figure.querySelectorAll('.disconnect-controls').forEach((controls) => { controls.hidden = false; });
});

// A reader-controlled explanation of state and retention, not worker activity.
document.querySelectorAll('.reuse-figure').forEach((figure) => {
  const stage = figure.querySelector('.reuse-stage');
  const play = figure.querySelector('.reuse-play');
  const next = figure.querySelector('.reuse-next');
  const progress = figure.querySelector('.reuse-progress');
  const choices = figure.querySelectorAll('[data-reuse-mode]');
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const phases = ['Prepared state', 'Save or copy', 'Use the next machine', 'Account for cleanup'];
  const paths = {
    export: [
      ['The table is ready in two places.', 'The source has a serialized table on disk and an aggregate in RAM. An export will keep supported disk contents.', 'Preparation finished', 'Table loaded', 'Registry artifact', 'Disk, without RAM', 'Next machine', 'Not created yet', 'Not created', 'Not created', 'The source stays yours until explicit deletion. The artifact will have its own lifetime.'],
      ['Stop, then publish the disk state.', 'Preparation writes have finished. The stopped source can be exported to its approved registry destination.', 'Stopped for export', 'Not preserved', 'Published artifact', 'Disk, without RAM', 'Next machine', 'Not created yet', 'Not created', 'Not created', 'Publication and helper quiescence need confirmation. Publishing does not delete the source.'],
      ['Boot and load the saved table.', 'A new guest boots from the artifact and loads the table from disk. It avoids rebuilding the aggregate from raw readings.', 'Still retained', 'Not preserved', 'Registry artifact', 'Disk, without RAM', 'New boot', 'A new managed identity', 'Saved table', 'Loaded from disk', 'The guest has its own state. The registry artifact and host caches remain independently retained.'],
      ['The guests are gone. The artifact stays.', 'After explicit guest deletion, the published artifact can still supply another compatible machine.', 'Deleted explicitly', 'Gone', 'Registry artifact', 'Still published', 'Next machine', 'Deleted explicitly', 'Guest deleted', 'Gone', 'Registry deletion, copies and shared host caches are separate cleanup responsibilities. Guest deletion does not remove them.']
    ],
    checkpoint: [
      ['Keep a prepared memory state.', 'The original is running, idle and offline. Its approved bare guest contains both the saved table and the RAM aggregate.', 'Running and idle', 'Table loaded', 'Checkpoint file', 'Disk and RAM', 'Next machine', 'Not restored yet', 'Not created', 'Not created', 'The host must establish that the state is safe to capture, including processes and credentials in memory.'],
      ['Capture disk and memory together.', 'The worker briefly pauses the source during capture, then resumes it. The file is retained after complete bytes and quiescence are confirmed.', 'Resumed after capture', 'Table loaded', 'Saved checkpoint', 'Disk and RAM', 'Next machine', 'Not restored yet', 'Not created', 'Not created', 'The capture file has its own identity and disk allowance. Compatibility constraints travel with the saved state.'],
      ['Restore into an independent machine.', 'Explicit restore creates a new identity from the approved file. This guest starts with the captured table already in RAM.', 'Still retained', 'Table loaded', 'Saved checkpoint', 'Disk and RAM', 'Independent restore', 'A new managed identity', 'Restored table', 'Captured table', 'Changes in this guest do not modify the capture. A normal stop/start later does not restore this RAM again.'],
      ['The file outlives both machines.', 'Deleting the original and restored guest does not delete the captured file or release its retained artifact accounting.', 'Deleted explicitly', 'Gone', 'Saved checkpoint', 'Still retained', 'Restored machine', 'Deleted explicitly', 'Guest deleted', 'Gone', 'Remove complete, partial and extra capture copies when no consumer needs them, then explicitly release artifact accounting.']
    ],
    branch: [
      ['Use the running original as the source.', 'The prepared guest is idle, offline and on the worker that will create the child. Its disk and RAM are ready to copy.', 'Running and idle', 'Table loaded', 'Live source', 'Disk and RAM', 'Next machine', 'Not branched yet', 'Not created', 'Not created', 'Approve the child allocation and additional backing resources. A saved checkpoint is not required for this branch.'],
      ['Create a child on the same worker.', 'The branch inherits prepared disk and RAM from the running source. No reusable checkpoint file is created by this operation.', 'Running source', 'Table loaded', 'Source backing', 'Dependency retained', 'Live branch', 'Creation in progress', 'Inherited table', 'Inherited RAM', 'Creation excludes conflicting source work. Backing dependencies remain part of the managed lifecycle.'],
      ['Change the child. Keep the original.', 'The child is ready for its own commands. Its guest disk and RAM changes do not change the original or sibling guests.', 'Original unchanged', 'Original table', 'Source backing', 'Dependency retained', 'Running child', 'Its own managed identity', 'Child changes', 'Child changes', 'The source can run commands again, but source stop/start/delete waits for child dependencies to be retired.'],
      ['Deleting the child leaves a dependency.', 'Child deletion does not release its extra backing allowance. The original and backing still need deliberate management.', 'Still retained', 'Original table', 'Source backing', 'Still retained', 'Child machine', 'Deleted explicitly', 'Guest deleted', 'Gone', 'Retire the child dependency, delete the source, verify owned backing cleanup, then explicitly release the backing allowance.']
    ]
  };
  const fields = ['.reuse-headline', '.reuse-detail', '.reuse-source-status', '.reuse-source-ram', '.reuse-carrier', '.reuse-carried', '.reuse-target-name', '.reuse-target-status', '.reuse-target-disk', '.reuse-target-ram', '.reuse-retention'];
  let mode = 'export';
  let step = 0;
  let timer;
  let frame;
  function pause() {
    clearTimeout(timer);
    cancelAnimationFrame(frame);
    timer = undefined;
    stage.classList.remove('is-moving');
    play.textContent = step === 3 ? 'Replay path' : 'Play path';
  }
  function render(animate = true) {
    stage.dataset.mode = mode;
    stage.dataset.step = String(step);
    fields.forEach((selector, index) => { figure.querySelector(selector).textContent = paths[mode][step][index]; });
    figure.querySelector('.reuse-source-disk').textContent = step === 3 && mode !== 'branch' ? 'Guest deleted' : 'Saved table';
    progress.textContent = `Step ${step + 1} of 4. ${phases[step]}.`;
    next.textContent = step === 3 ? 'Back to start' : 'Next step';
    stage.classList.remove('is-moving');
    cancelAnimationFrame(frame);
    if (animate && !reduced.matches) frame = requestAnimationFrame(() => stage.classList.add('is-moving'));
    if (!timer) play.textContent = step === 3 ? 'Replay path' : 'Play path';
  }
  function advance() {
    step += 1;
    render();
    timer = setTimeout(step === 3 ? pause : advance, 4200);
  }
  play.addEventListener('click', () => {
    if (timer) return pause();
    if (step === 3) step = 0;
    render();
    play.textContent = 'Pause';
    timer = setTimeout(advance, 4200);
  });
  next.addEventListener('click', () => { pause(); step = (step + 1) % 4; render(); });
  choices.forEach((button) => button.addEventListener('click', () => {
    pause(); mode = button.dataset.reuseMode; step = 0;
    choices.forEach((choice) => choice.setAttribute('aria-pressed', String(choice === button)));
    render();
  }));
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  reduced.addEventListener('change', pause);
  if ('IntersectionObserver' in window) new IntersectionObserver((entries) => {
    if (!entries[0].isIntersecting) pause();
  }).observe(figure);
  render(false);
  figure.querySelector('.reuse-controls').hidden = false;
});

// The volume stays in place while its exclusive machine attachment changes.
document.querySelectorAll('.volume-figure').forEach((figure) => {
  const scene = figure.querySelector('.volume-scene');
  const play = figure.querySelector('.volume-play');
  const next = figure.querySelector('.volume-next');
  const progress = figure.querySelector('.volume-progress');
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const steps = [
    ['The first machine writes the file.', 'Original machine', 'Running · can read and write', 'Mounted at /mnt/volumes/data', '2 GiB reserved', 'original', 'Its own identity. Kept until explicit deletion.', 'The file lives on the volume. The machine’s other files and processes have their own lifetime.'],
    ['The machine is gone. The project stays.', 'Original deleted', 'Verified absent · attachment released', 'No machine attached', '2 GiB reserved', 'original', 'Retained, even with no machines left.', 'Deleting the machine releases its resources. The volume and its disk reservation remain.'],
    ['A new controller finds the same volume.', 'Controller restarted', 'Recovered from PostgreSQL', 'No machine attached', '2 GiB reserved', 'original', 'Same volume identity. Same worker directory.', 'The first Elixir process has exited. The next process recovers the record, without provisioning an empty replacement volume.'],
    ['A replacement reads, then changes the file.', 'Replacement machine', 'Running · can read and write', 'Mounted at /mnt/volumes/data', '2 GiB reserved', 'replacement', 'Same volume. A new value in the file.', 'The new machine first verifies “original”, then writes “replacement”. Its own disks start from the approved image.'],
    ['Read the project without changing it.', 'Read-only machine', 'Replacement deleted before this attachment', 'Read-only at /mnt/volumes/data', '2 GiB reserved', 'replacement', 'One exclusive attachment, even for reads.', 'This guest reads the updated file and cannot overwrite it. Read-only does not permit concurrent sharing.'],
    ['Now the data is deliberately removed.', 'All machines deleted', 'Verified absent · no attachment', 'Volume deleted explicitly', '0 GiB reserved', 'File deleted', 'Identity history remains in the store.', 'After the last machine is deleted, volume deletion removes its directory. The demo finishes with zero disk and slot reservations.']
  ];
  const selectors = ['.volume-headline', '.volume-machine-name', '.volume-machine-state', '.volume-mount-label', '.volume-reservation', '.volume-value', '.volume-retention', '.volume-detail'];
  let step = 0;
  let timer;
  let frame;
  function pause() {
    clearTimeout(timer);
    cancelAnimationFrame(frame);
    timer = undefined;
    scene.classList.remove('is-moving');
    play.textContent = step === steps.length - 1 ? 'Replay walkthrough' : 'Play walkthrough';
  }
  function render(animate = true) {
    scene.dataset.step = String(step);
    selectors.forEach((selector, i) => { figure.querySelector(selector).textContent = steps[step][i]; });
    progress.textContent = `Step ${step + 1} of ${steps.length}. ${steps[step][0]}`;
    next.textContent = step === steps.length - 1 ? 'Back to start' : 'Next step';
    scene.classList.remove('is-moving');
    cancelAnimationFrame(frame);
    if (animate && !reduced.matches) frame = requestAnimationFrame(() => scene.classList.add('is-moving'));
    if (!timer) play.textContent = step === steps.length - 1 ? 'Replay walkthrough' : 'Play walkthrough';
  }
  function advance() {
    step += 1;
    render();
    if (step === steps.length - 1) pause();
    else timer = setTimeout(advance, 5000);
  }
  play.addEventListener('click', () => {
    if (timer) return pause();
    if (step === steps.length - 1) step = 0;
    render();
    play.textContent = 'Pause';
    timer = setTimeout(advance, 5000);
  });
  next.addEventListener('click', () => { pause(); step = (step + 1) % steps.length; render(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  reduced.addEventListener('change', pause);
  if ('IntersectionObserver' in window) new IntersectionObserver((entries) => {
    if (!entries[0].isIntersecting) pause();
  }).observe(figure);
  render(false);
  figure.querySelector('.volume-controls').hidden = false;
});
