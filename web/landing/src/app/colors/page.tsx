"use client";

import { useSyncExternalStore } from "react";
import { Dithering } from "@paper-design/shaders-react";

// A scratch gallery to pick the hero shader color — renders the REAL Dithering
// shader in both hero contexts: a LIGHT canvas (near-white base, softened accent)
// and a DARK canvas (near-black base, bright accent — the original cinematic look).
// Open /colors, pick the winner by eye, tell me the name/hex + light-or-dark, and
// I'll wire it into hero-gradient.tsx. Not linked from the site.

type Option = {
  name: string;
  back: string;
  front: string;
};

// LIGHT canvas: a faintly-tinted off-white base with a softened accent over it.
const LIGHT_OPTIONS: Option[] = [
  { name: "Violet", back: "#f5f4f9", front: "#c79cf0" },
  { name: "Lavender", back: "#f7f0fa", front: "#d59bec" },
  { name: "Periwinkle", back: "#eff1fb", front: "#a9b8f2" },
  { name: "Sky", back: "#eef4fb", front: "#7fb6ec" },
  { name: "Cyan", back: "#eef7fa", front: "#79d0e8" },
  { name: "Teal", back: "#eef8f6", front: "#66c9b8" },
  { name: "Mint", back: "#eef8f0", front: "#7fd69a" },
  { name: "Amber", back: "#faf6ee", front: "#f0c07f" },
  { name: "Coral", back: "#faf1ee", front: "#f0a487" },
  { name: "Rose", back: "#faf0f3", front: "#f09bb4" },
  { name: "Pink", back: "#faeef6", front: "#ec93cf" },
  { name: "Slate", back: "#f4f5f7", front: "#9aa3b2" },
];

// DARK canvas: a near-black base (faintly tinted toward the hue) with a bright,
// luminous accent — the original cinematic "glow" look, minus the amber lock-in.
const DARK_OPTIONS: Option[] = [
  { name: "Amber (original)", back: "#0a0a0c", front: "#ff8a3d" },
  { name: "Gold", back: "#0b0a08", front: "#ffcf5c" },
  { name: "Coral", back: "#0c0908", front: "#ff7a5c" },
  { name: "Rose", back: "#0c090a", front: "#ff6f9c" },
  { name: "Pink", back: "#0c080b", front: "#f06fd0" },
  { name: "Fuchsia", back: "#0b080c", front: "#d96fe5" },
  { name: "Violet", back: "#0a080d", front: "#a97bff" },
  { name: "Indigo", back: "#08090e", front: "#7c8cff" },
  { name: "Blue", back: "#08090d", front: "#4aa3ff" },
  { name: "Sky", back: "#08090c", front: "#5cb8ff" },
  { name: "Cyan", back: "#08090b", front: "#37d0ee" },
  { name: "Teal", back: "#080b0b", front: "#34d3b8" },
  { name: "Mint", back: "#080b0a", front: "#5ce0b0" },
  { name: "Green", back: "#080b09", front: "#46d16a" },
  { name: "Lime", back: "#090b07", front: "#b6e35a" },
];

function Tile({ opt, dark }: { opt: Option; dark: boolean }) {
  return (
    <div
      className={
        (dark ? "dark " : "") +
        "relative isolate flex h-72 flex-col overflow-hidden rounded-2xl border border-border"
      }
      style={{ backgroundColor: opt.back }}
    >
      <Dithering
        colorBack={opt.back}
        colorFront={opt.front}
        shape="warp"
        type="4x4"
        pxSize={3}
        scale={0.9}
        speed={0.7}
        offsetY={-0.35}
        className={
          "pointer-events-none absolute inset-0 -z-10 h-full w-full " +
          (dark ? "opacity-50" : "opacity-60")
        }
      />
      {/* Same radial scrim the real hero uses — light on light, dark on dark. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 -z-10"
        style={{
          backgroundImage: dark
            ? "radial-gradient(58% 56% at 50% 40%, rgba(8,8,10,0.82), rgba(8,8,10,0.35) 60%, transparent 100%)"
            : "radial-gradient(58% 56% at 50% 40%, rgba(255,255,255,0.9), rgba(255,255,255,0.5) 60%, transparent 100%)",
        }}
      />
      <div className="relative flex flex-1 flex-col items-center justify-center px-4 text-center">
        <h2 className="text-2xl font-semibold tracking-[-0.02em] text-foreground">
          Orchestrate your fleet.
        </h2>
        <p className="mt-2 text-sm text-muted-foreground">
          One native Mac window for every agent.
        </p>
      </div>
      <div
        className="relative flex items-center justify-between border-t border-border px-4 py-2 text-xs"
        style={{
          backgroundColor: dark
            ? "rgba(0,0,0,0.35)"
            : "rgba(255,255,255,0.7)",
        }}
      >
        <span className="font-semibold text-foreground">{opt.name}</span>
        <span className="font-mono text-muted-foreground">
          {opt.front} · {opt.back}
        </span>
      </div>
    </div>
  );
}

export default function ColorsPage() {
  // False on the server and during hydration, true after: WebGL has no server render.
  const mounted = useSyncExternalStore(
    () => () => {},
    () => true,
    () => false,
  );
  if (!mounted) return null;

  return (
    <main className="mx-auto w-full max-w-6xl px-5 py-16 sm:px-8">
      <h1 className="text-3xl font-semibold tracking-[-0.02em] text-foreground">
        Hero shader — pick a color
      </h1>
      <p className="mt-2 text-muted-foreground">
        The real Dithering shader in both hero contexts. Tell me the name (or hex)
        you like — and whether it&apos;s from the light or dark set — and I&apos;ll
        wire it in.
      </p>

      <h2 className="mt-12 text-xl font-semibold text-foreground">
        Dark canvas · bright color
      </h2>
      <p className="mt-1 text-sm text-muted-foreground">
        Near-black base with a luminous accent — the original cinematic glow.
      </p>
      <div className="mt-6 grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
        {DARK_OPTIONS.map((opt) => (
          <Tile key={"d-" + opt.name} opt={opt} dark />
        ))}
      </div>

      <h2 className="mt-16 text-xl font-semibold text-foreground">
        Light canvas · soft color
      </h2>
      <p className="mt-1 text-sm text-muted-foreground">
        Near-white base with a frosted, softened accent.
      </p>
      <div className="mt-6 grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
        {LIGHT_OPTIONS.map((opt) => (
          <Tile key={"l-" + opt.name} opt={opt} dark={false} />
        ))}
      </div>
    </main>
  );
}
