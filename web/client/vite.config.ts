/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The same build is served at `/` (Caddy `handle_path` strips the mount) and at
// `/termio/` (Tailscale Serve publishes the prefix without stripping), so every
// asset URL has to be relative to whatever prefix served index.html. An
// absolute `/assets/…` is a build-config bug that only shows up behind Serve.
export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    target: "es2022",
    // The GET jail has no `.map` MIME entry, and source maps describe the
    // client to anyone who asks. They are not emitted into the deployed tree.
    sourcemap: false,
    // Nothing is inlined as a data: URI. The Wasm is fetched as
    // `application/wasm` and the font as `font/woff2`; base64 into the bundle
    // is the Restty failure this design rejects by name.
    assetsInlineLimit: 0,
    modulePreload: { polyfill: false },
  },
  test: {
    // Node by default; a file that needs a DOM opts in with
    // `// @vitest-environment jsdom` at the top. Protocol and codec tests must
    // stay in the plain realm so `ArrayBuffer` identity is not jsdom's.
    environment: "node",
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
  },
});
