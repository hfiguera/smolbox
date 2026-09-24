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
