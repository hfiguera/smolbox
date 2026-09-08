// Progressive enhancement only. Copy actions are never sent to analytics.
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
