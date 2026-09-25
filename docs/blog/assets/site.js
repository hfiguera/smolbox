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
