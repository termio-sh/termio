import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "./App";
import "./styles.css";

const root = document.getElementById("root");
if (!root) {
  throw new Error("index.html is missing #root");
}

// StrictMode stays on in development for the reason the design gives: it
// double-invokes effects, and a surface that leaks a socket or a Wasm terminal
// on a mount/unmount/mount cycle leaks one per session switch in production.
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
