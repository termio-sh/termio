// The affordance for held remote images: a small bar, parented to <body> so it is never
// inside the editable tree. It appears only when the open document actually has held
// images, and goes away once they are let in.
import { remoteImages } from "./remote-images.js";

export function installRemoteNotice() {
  if (globalThis.__domdRemoteNoticeInstalled) return;
  globalThis.__domdRemoteNoticeInstalled = true;

  const bar = document.createElement("div");
  bar.className = "domd-remote-notice";
  const label = document.createElement("span");
  label.className = "domd-remote-label";
  const button = document.createElement("button");
  button.className = "domd-remote-load";
  button.type = "button";
  button.textContent = "Load Images";
  bar.append(label, button);
  document.body.appendChild(bar);

  const render = () => {
    const { held, unlocked } = remoteImages();
    const show = held > 0 && !unlocked;
    bar.classList.toggle("visible", show);
    if (!show) return;
    label.textContent = held === 1
      ? "1 image from the web isn’t loaded."
      : `${held} images from the web aren’t loaded.`;
  };

  button.addEventListener("click", () => {
    globalThis.termioDomd?.allowRemoteImages?.();
  });
  remoteImages().observe(render);
  render();
}
