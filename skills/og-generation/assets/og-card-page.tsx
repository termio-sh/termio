"use client";

/* eslint-disable @next/next/no-img-element */
import { AgentIcon } from "@/components/agent-icons";
import { HeroGradient } from "@/components/hero-gradient";

const AGENTS = ["Claude Code", "Codex", "OpenCode", "Amp", "Kimi", "Pi"];

// Temporary render target for the static OG card (public/og.webp): screenshot
// http://localhost:3000/og-card at 2400×1260 with headless Chrome, then delete
// this route. It reuses the hero's real WebGL aurora + grain so the card
// matches the live site exactly. Not linked from anywhere.
export default function OgCardPage() {
  return (
    <main
      className="relative overflow-hidden bg-background text-foreground"
      style={{ width: 2400, height: 1260 }}
    >
      {/* Keep the Next dev-tools badge out of the capture. */}
      <style>{`nextjs-portal { display: none; }`}</style>
      <HeroGradient className="absolute inset-0" />
      <div
        aria-hidden="true"
        className="grain-overlay pointer-events-none absolute -inset-[6%]"
      />

      <div
        className="absolute flex items-center"
        style={{ left: 128, top: 112, gap: 28 }}
      >
        <img
          src="/logo.png"
          alt=""
          style={{ width: 88, height: 88, borderRadius: 20 }}
        />
        <span style={{ fontSize: 60, fontWeight: 600, letterSpacing: "-0.01em" }}>
          Termio
        </span>
      </div>

      <div className="absolute" style={{ left: 128, top: 380, width: 1080 }}>
        <h1
          style={{
            fontSize: 128,
            fontWeight: 640,
            lineHeight: 1.06,
            letterSpacing: "-0.022em",
          }}
        >
          Orchestrate your fleet&nbsp;of&nbsp;agents
        </h1>
        <p
          style={{
            marginTop: 56,
            fontSize: 46,
            fontWeight: 500,
            lineHeight: 1.35,
            letterSpacing: "-0.005em",
            color: "#c6c6d2",
          }}
        >
          Terminal-first Agentic Development Environment, built for
          AI&nbsp;builders.
        </p>
      </div>

      <div
        className="absolute flex flex-wrap items-center"
        style={{ left: 128, bottom: 112, width: 1080, gap: "24px 30px" }}
      >
        {AGENTS.map((name) => (
          <span
            key={name}
            className="flex items-center"
            style={{
              gap: 12,
              fontSize: 30,
              fontWeight: 600,
              color: "#e8e8ee",
              letterSpacing: "0.01em",
            }}
          >
            <AgentIcon name={name} size={34} className="text-[#e8e8ee]" />
            {name}
          </span>
        ))}
      </div>

      <div
        className="absolute overflow-hidden"
        style={{
          left: 1240,
          top: 150,
          width: 1560,
          borderRadius: 28,
          border: "2px solid rgba(255, 255, 255, 0.18)",
          boxShadow: "0 60px 160px rgba(0, 0, 0, 0.7)",
          background: "#0c0c0f",
        }}
      >
        <img
          src="/screenshots/hero1.png"
          alt=""
          style={{ display: "block", width: "100%" }}
        />
      </div>
    </main>
  );
}
