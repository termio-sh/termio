"use client";

import { useSyncExternalStore } from "react";
import { MeshGradient } from "@paper-design/shaders-react";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

// A slow, restrained aurora via Paper Shaders (WebGL): the stage behind the
// hero window, and the App Store panel render target (app/aurora-bg). Deep
// navy → indigo → violet over near-black, drifting almost imperceptibly. The
// frosted texture comes from the grain layer on top (see `.grain-overlay`); the
// in-shader grain just keeps the gradient from banding. Motion is paused for
// users who prefer reduced motion.
const PALETTE = ["#070710", "#102a5e", "#1f63b0", "#2f8aa0", "#191636"];

const REDUCED_MOTION = "(prefers-reduced-motion: reduce)";

function subscribeNever() {
  return () => {};
}

function subscribeReducedMotion(onChange: () => void) {
  const query = window.matchMedia(REDUCED_MOTION);
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

export function HeroGradient({ className }: { className?: string }) {
  // False on the server and during hydration, true after: WebGL has no server render.
  const mounted = useSyncExternalStore(subscribeNever, () => true, () => false);
  const reduceMotion = useSyncExternalStore(
    subscribeReducedMotion,
    () => window.matchMedia(REDUCED_MOTION).matches,
    () => false,
  );
  // speed=0 cancels the shader's rAF loop entirely, so an offscreen aurora
  // (there are two on the page — hero and footer) costs nothing.
  const { ref, inView } = useInView<HTMLDivElement>();

  if (!mounted) return null;

  return (
    <MeshGradient
      ref={ref as React.Ref<never>}
      colors={PALETTE}
      speed={reduceMotion || !inView ? 0 : 0.3}
      distortion={0.55}
      swirl={0.22}
      grainOverlay={0.16}
      // The aurora is ultra-soft, so it doesn't need Retina resolution: 1x pixel
      // ratio capped at ~2MP quarters the per-frame fragment work vs. the
      // library defaults (minPixelRatio 2, ~8MP cap) with no visible difference
      // under the grain overlay.
      minPixelRatio={1}
      maxPixelCount={1920 * 1080}
      className={cn("h-full w-full", className)}
    />
  );
}
