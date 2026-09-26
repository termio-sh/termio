// Full-screen viewer for images and diagrams, ported from `viewerScript` in
// Sources/termio/Editor/MarkdownReaderRenderer.swift. Its four decisions are kept:
// the overlay is the page's own background and opaque (full screen means the document
// steps aside, not a web-style dimmed modal), it opens and closes in one frame with no
// transition, it closes on a click anywhere or Escape, and a vector fills the pane while
// a raster is never enlarged past its natural size.
//
// ONE deliberate difference from the reader. The reader opens on CLICK because its page
// is read-only. This face is contenteditable, where a click has to keep meaning "put the
// caret here" — so the affordance is the hover zoom chip the reader already uses for
// diagrams, extended to images as well.
//
// The chip is a single element parented to <body>, never into the editable tree: it is
// positioned over whichever node is hovered. Injecting per-node buttons into the document
// would put view chrome inside the model's DOM, where the kernel reads text back.

const ZOOMABLE = ".DOMD-Img, .domd-diagram svg, .domd-html-rendered img";

/// Hugeicons "arrow-expand-01", the glyph the reader's chip uses.
function expandIcon() {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", "M16.4999 3.26621C17.3443 3.25421 20.1408 2.67328 20.7337 "
    + "3.26621C21.3266 3.85913 20.7457 6.65559 20.7337 7.5M20.5059 3.49097L13.5021 "
    + "10.4961 M3.26636 16.5001C3.25436 17.3445 2.67343 20.141 3.26636 20.7339C3.85928 "
    + "21.3268 6.65574 20.7459 7.50015 20.7339M10.502 13.4976L3.49824 20.5027");
  svg.appendChild(path);
  return svg;
}

/// Tells the host whether the overlay is up. Escape has claimants on both sides of the
/// web view boundary and `stopPropagation` only reaches the DOM ones: the editor's own
/// Escape is AppKit's `cancelOperation:`, which an unhandled key reaches through the
/// responder chain, not through this document. So the host is told, and it consumes the
/// keystroke on its side instead of guessing.
function report(post, state) {
  try { post?.({ type: "viewer", state }); } catch { /* no host — the browser harness */ }
}

export function installViewer(post) {
  if (globalThis.__domdViewerInstalled) return;
  globalThis.__domdViewerInstalled = true;

  const lightbox = document.createElement("div");
  lightbox.className = "domd-lightbox";
  const stage = document.createElement("div");
  stage.className = "domd-lightbox-stage";
  lightbox.appendChild(stage);
  document.body.appendChild(lightbox);

  const chip = document.createElement("button");
  chip.className = "domd-zoom";
  chip.type = "button";
  chip.setAttribute("aria-label", "Full Screen");
  chip.appendChild(expandIcon());
  document.body.appendChild(chip);

  let target = null;          // the node the chip currently belongs to
  let isDiagram = false;
  let scale = 1, panX = 0, panY = 0, dragging = null;

  const applyTransform = () => {
    const content = stage.firstElementChild;
    if (!content) return;
    content.style.transform = `translate(${panX}px, ${panY}px) scale(${scale})`;
  };

  const close = () => {
    const wasOpen = lightbox.classList.contains("open");
    lightbox.classList.remove("open");
    stage.replaceChildren();
    document.documentElement.classList.remove("domd-lightbox-open");
    scale = 1; panX = 0; panY = 0; dragging = null;
    if (wasOpen) report(post, "closed");
  };

  const open = (node, diagram) => {
    const copy = node.cloneNode(true);
    if (diagram) {
      // Mermaid pins its own width/height; the lightbox sizes the copy instead.
      copy.removeAttribute("style");
      copy.removeAttribute("width");
      copy.removeAttribute("height");
    }
    scale = 1; panX = 0; panY = 0;
    stage.replaceChildren(copy);
    stage.classList.toggle("is-diagram", !!diagram);
    lightbox.classList.add("open");
    document.documentElement.classList.add("domd-lightbox-open");
    applyTransform();
    report(post, "open");
  };

  const hideChip = () => { chip.classList.remove("visible"); target = null; };

  // A diagram sits in its own panel, and the chip belongs on that panel's corner
  // rather than on the drawing: anchored to the svg it landed inside the graph, over
  // the last node's label, where it is both unreadable and in the way. An image has
  // no panel, so it keeps its own corner.
  const chipAnchor = (node) => node.closest(".domd-mermaid") ?? node;

  const placeChip = (node) => {
    // The size guard reads the node, not the panel: a thumbnail in a wide block is
    // still too small to be worth a chip.
    const box = node.getBoundingClientRect();
    if (box.width < 48 || box.height < 48) return hideChip();
    const anchor = chipAnchor(node).getBoundingClientRect();
    chip.style.top = `${Math.round(anchor.top + 6)}px`;
    chip.style.left = `${Math.round(anchor.right - 32)}px`;
    chip.classList.add("visible");
  };

  document.addEventListener("pointerover", (event) => {
    if (lightbox.classList.contains("open")) return;
    const node = event.target instanceof Element ? event.target.closest(ZOOMABLE) : null;
    if (!node) {
      if (!(event.target instanceof Element) || !event.target.closest(".domd-zoom")) hideChip();
      return;
    }
    target = node;
    isDiagram = node.tagName.toLowerCase() === "svg";
    placeChip(node);
  });
  // A scroll moves the node out from under the chip; the chip is not anchored to it.
  addEventListener("scroll", hideChip, true);

  chip.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (target) open(target, isDiagram);
    hideChip();
  });

  lightbox.addEventListener("click", close);

  // Escape has three claimants: this viewer, the editor's own handling, and the host.
  // The viewer takes it ONLY while open, and stops propagation so the flip out of the
  // face or the overlay's own close never fires on the same keystroke. Capture phase,
  // so it is decided before the editor sees the key at all.
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    if (!lightbox.classList.contains("open")) return;   // not ours — let it through
    event.preventDefault();
    event.stopPropagation();
    close();
  }, true);

  // Wheel-zoom and drag-pan, diagrams only. A sequence diagram legible at 1200px is
  // unreadable fitted into a 900px pane, and SVG zooms losslessly; a raster past 100%
  // is just enlarged pixels, which reads as a bug.
  lightbox.addEventListener("wheel", (event) => {
    if (!stage.classList.contains("is-diagram")) return;
    event.preventDefault();
    const next = scale * (event.deltaY < 0 ? 1.1 : 1 / 1.1);
    scale = Math.min(8, Math.max(1, next));
    if (scale === 1) { panX = 0; panY = 0; }
    applyTransform();
  }, { passive: false });

  lightbox.addEventListener("pointerdown", (event) => {
    if (!stage.classList.contains("is-diagram") || scale === 1) return;
    dragging = { x: event.clientX - panX, y: event.clientY - panY };
    lightbox.setPointerCapture(event.pointerId);
  });
  lightbox.addEventListener("pointermove", (event) => {
    if (!dragging) return;
    panX = event.clientX - dragging.x;
    panY = event.clientY - dragging.y;
    applyTransform();
  });
  const endDrag = (event) => {
    if (!dragging) return;
    dragging = null;
    // A drag must not also read as the click that closes the overlay.
    event.stopPropagation();
  };
  lightbox.addEventListener("pointerup", endDrag);
  lightbox.addEventListener("pointercancel", endDrag);

  globalThis.termioDomdViewer = {
    isOpen: () => lightbox.classList.contains("open"),
    open: (node, diagram) => open(node, diagram),
    close,
  };
}
