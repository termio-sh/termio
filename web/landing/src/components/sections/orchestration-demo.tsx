"use client";

import { useEffect, useRef, useState } from "react";
import { useInView } from "@/lib/use-in-view";
import { AgentIcon } from "@/components/agent-icons";

// The orchestration section's animated demo: a hub-and-spoke graph (claude
// supervising five worker sessions) synced beat-for-beat to a terminal that
// types itself. One state machine drives both — as each worker becomes active
// the LEFT graph lights that node and pulses its beam, while the RIGHT terminal
// types that worker's command and prints its result. Together they narrate one
// ship-a-feature pipeline: plan → build → review → secure-tag → feedback. Falls
// back to a static done-state summary for SSR, screen readers, and reduced
// motion.

type TranscriptLine = {
  text?: string;
  prompt?: boolean;
  // Output color semantics: plain (undefined) = neutral status text,
  // "done" = completion sky, matching the done dot on the left. needs-you
  // moments stay neutral in the transcript — only the left status dot goes
  // amber (colored text read as noise in the code pane).
  tone?: "done";
  blank?: boolean;
  id?: number; // stable key so a freshly-pushed line animates in exactly once
};

type Status = "idle" | "working" | "needs-you" | "done";

type Pulse = {
  id: number;
  dir: "out" | "back";
  color: string;
  y: number;
};

type Frame = {
  lines: TranscriptLine[];
  typing: string | null;
  statuses: Status[]; // index-aligned with WORKERS
  pulse: Pulse | null;
};

// Section palette — three hue families and nothing else: slate for neutrals
// (window ink, idle/working), sky for "done", amber for "needs-you"; the pill
// bases are aurora-tinted blue-greys (#d8e4ee/#c8d7e5) so they sit between the
// dark pane and the slate-900 labels. Each status hue has two steps: a bright
// one for the dark pane (beam pulses, transcript text) and a solid -500 for
// the dots on the light pills. No green anywhere.
const ACTIVE = "#e2e8f0"; // slate-200 — packet traveling the beam
const AMBER = "#fbbf24"; // amber-400 — needs-you on dark (beam)
const SKY = "#7dd3fc"; // sky-300 — done on dark (beam + transcript text)

// The five workers, in pipeline order (index = story order = top-to-bottom in
// the graph). Each drives one stage of shipping a change; the middle worker
// (y=170) gets the straight beam. `name` keys the real brand logo.
// Sessions are addressed by termio://session/<uuid> links since 8b38709 (the
// <agent>@<id> handle is gone); `id` is the first uuid segment of each demo
// session's link — bare ids are valid CLI targets, and short enough that the
// longest transcript line stays under ~70 chars (the right pane clips longer).
type Worker = { name: string; id: string; y: number };

const WORKERS: readonly Worker[] = [
  { name: "Claude Code", id: "9b3e11d0", y: 40 },
  { name: "Codex", id: "7c1f2a4e", y: 105 },
  { name: "DeepSeek", id: "5a77c0e2", y: 170 },
  { name: "Grok", id: "d4e6b209", y: 235 },
  { name: "Kimi", id: "3f8a2c11", y: 300 },
];

// One story beat per worker. `interaction` (codex only) shows a needs-you round
// trip: the agent asks, claude answers, the agent resumes.
type Beat = {
  worker: number;
  cmd: string;
  started: string;
  interaction?: { needsYou: string; answer: string; sent: string };
  done: string;
};

// Output lines use the sessions-watch text shape: link  [status]  detail.
const BEATS: readonly Beat[] = [
  {
    worker: 0,
    cmd: 'termio sessions spawn "plan the auth refactor" --agent claude',
    started: "termio://session/9b3e11d0  [working]  planning",
    done: "termio://session/9b3e11d0  [done]  7 steps -> PLAN.md",
  },
  {
    worker: 1,
    cmd: 'termio sessions spawn "implement PLAN.md" --agent codex',
    started: "termio://session/7c1f2a4e  [working]  building",
    interaction: {
      needsYou: "termio://session/7c1f2a4e  [needs-you]  Run pnpm test? (y/n)",
      answer: 'termio sessions send 7c1f2a4e "y"',
      sent: "sent to termio://session/7c1f2a4e",
    },
    done: "termio://session/7c1f2a4e  [done]  +412 -128, tests pass",
  },
  {
    worker: 2,
    cmd: 'termio sessions spawn "review the diff" --agent deepseek',
    started: "termio://session/5a77c0e2  [working]  reviewing",
    done: "termio://session/5a77c0e2  [done]  2 nits, 0 blockers",
  },
  {
    worker: 3,
    cmd: 'termio sessions spawn "security scan, then tag v0.22.0" --agent grok',
    started: "termio://session/d4e6b209  [working]  scanning",
    done: "termio://session/d4e6b209  [done]  clean, tagged v0.22.0",
  },
  {
    worker: 4,
    cmd: 'termio sessions spawn "summarize the week\'s feedback" --agent kimi',
    started: "termio://session/3f8a2c11  [working]  gathering",
    done: "termio://session/3f8a2c11  [done]  5 themes -> FEEDBACK.md",
  },
];

// Static fallback / screen-reader copy: the whole pipeline in its done state.
const DONE_SUMMARY: readonly TranscriptLine[] = BEATS.map((b) => ({
  tone: "done" as const,
  text: b.done,
}));

const STATIC_FRAME: Frame = {
  lines: [...DONE_SUMMARY],
  typing: null,
  statuses: WORKERS.map(() => "done"),
  pulse: null,
};

// Beam from the hub's right edge (104,170) to a worker's left edge (184,y), and
// the reverse. The middle worker (y=170) gets a straight line.
const beamPath = (y: number) =>
  y === 170 ? "M104 170 L 184 170" : `M104 170 C 142 170, 142 ${y}, 184 ${y}`;
const beamPathBack = (y: number) =>
  y === 170 ? "M184 170 L 104 170" : `M184 ${y} C 142 ${y}, 142 170, 104 170`;

// Per-status pill styling for the worker nodes.
// Borderless light pills: status reads through a small colored dot inside the
// pill (plus the idle dimming) — the same status language as Termio's own
// sidebar. Glows/box-shadows around foreignObject content clip into hard
// blocks in some browsers, so no halo at all.
const STATUS_DOT: Record<Status, string> = {
  idle: "#cbd5e1", // slate-300
  working: "#64748b", // slate-500
  "needs-you": "#f59e0b", // amber-500
  done: "#0ea5e9", // sky-500
};

const MAX_LINES = 8; // rolling transcript window (fits the reserved height)

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

export function OrchestrationDemo() {
  const { ref, inView } = useInView<HTMLDivElement>("80px");
  const [frame, setFrame] = useState<Frame>(STATIC_FRAME);
  const pulseId = useRef(0);

  useEffect(() => {
    if (!inView) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    let cancelled = false;
    const patch = (p: Partial<Frame>) =>
      setFrame((f) => (cancelled ? f : { ...f, ...p }));
    const pulse = (dir: Pulse["dir"], color: string, y: number) =>
      patch({ pulse: { id: ++pulseId.current, dir, color, y } });

    const buf: TranscriptLine[] = [];
    let lineSeq = 0;
    const commit = () => patch({ lines: buf.slice(-MAX_LINES) });
    const push = (line: TranscriptLine) => {
      // Stable id so React keeps each rendered line and only the newly pushed
      // one mounts (and plays its fade-in) — buffer shifts never replay it.
      buf.push({ ...line, id: ++lineSeq });
      commit();
    };

    const type = async (cmd: string) => {
      // The command (input) is typed a little at a time, like a keystroke feed.
      // Small chunks keep it smooth without a re-render per character; kept
      // deliberately unhurried.
      for (let i = 0; i <= cmd.length; i += 2) {
        if (cancelled) return;
        patch({ typing: cmd.slice(0, i) });
        await sleep(34);
      }
      patch({ typing: null });
      push({ prompt: true, text: cmd });
    };

    const play = async () => {
      while (!cancelled) {
        buf.length = 0;
        const statuses: Status[] = WORKERS.map(() => "idle");
        patch({ lines: [], typing: null, statuses: [...statuses], pulse: null });
        await sleep(700);
        if (cancelled) return;

        for (let b = 0; b < BEATS.length; b++) {
          const beat = BEATS[b];
          const w = WORKERS[beat.worker];
          const last = b === BEATS.length - 1;

          // The worker comes alive: left node lights, beam pulses hub → worker,
          // right terminal types its command.
          statuses[beat.worker] = "working";
          patch({ statuses: [...statuses] });
          pulse("out", ACTIVE, w.y);
          await type(beat.cmd);
          if (cancelled) return;
          // The result arrives all at once (a whole line), after a short beat.
          await sleep(360);
          push({ text: beat.started });
          await sleep(beat.interaction ? 850 : 1500);
          if (cancelled) return;

          if (beat.interaction) {
            push({ text: beat.interaction.needsYou });
            statuses[beat.worker] = "needs-you";
            patch({ statuses: [...statuses] });
            pulse("back", AMBER, w.y);
            await sleep(1600);
            if (cancelled) return;
            // Blank separator so the answer command starts a fresh block, like
            // every other typed command.
            push({ blank: true });
            await type(beat.interaction.answer);
            if (cancelled) return;
            await sleep(320);
            push({ text: beat.interaction.sent });
            statuses[beat.worker] = "working";
            patch({ statuses: [...statuses] });
            pulse("out", ACTIVE, w.y);
            await sleep(1500);
            if (cancelled) return;
          }

          // Result streams back: node settles to done, beam pulses worker → hub.
          push({ tone: "done", text: beat.done });
          statuses[beat.worker] = "done";
          patch({ statuses: [...statuses] });
          pulse("back", SKY, w.y);
          push({ blank: true });
          await sleep(last ? 4200 : 1250);
        }
      }
    };

    void play();
    return () => {
      cancelled = true;
    };
  }, [inView]);

  const pulsePath = frame.pulse
    ? frame.pulse.dir === "back"
      ? beamPathBack(frame.pulse.y)
      : beamPath(frame.pulse.y)
    : null;

  return (
    // One surface with the section around it: the session graph (left) and the
    // live CLI transcript (right) sit directly on the parent's bg-card, with
    // only hairline dividers separating the panes.
    <div ref={ref} className="relative overflow-hidden">
      <div className="relative">
        {/* minmax(0,…) everywhere: a plain implicit column would take the
            transcript pre's min-content width (its longest unbreakable line),
            blowing the column wider than the card on phones — the graph pane
            then centers in that oversized column and clips at the card edge. */}
        <div className="relative grid grid-cols-[minmax(0,1fr)] lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]">
          {/* Left: the live session graph — claude code driving five workers,
              each a real brand logo. The active node lights and its beam pulses
              in sync with the command running on the right. */}
          <div
            aria-hidden="true"
            className="relative flex items-center justify-center overflow-hidden border-b border-white/[0.12] p-5 sm:p-6 lg:border-b-0 lg:border-r"
          >
            <svg viewBox="0 0 340 340" className="relative w-full max-w-[380px]" fill="none">
              {/* Static edges from the hub to each worker. */}
              {WORKERS.map((w) => (
                <path
                  key={`edge-${w.id}`}
                  d={beamPath(w.y)}
                  stroke="rgba(255,255,255,0.18)"
                  strokeWidth="1.5"
                />
              ))}
              {frame.pulse && pulsePath && (
                <path
                  key={frame.pulse.id}
                  d={pulsePath}
                  pathLength={100}
                  stroke={frame.pulse.color}
                  strokeWidth="2"
                  className="beam-pulse"
                />
              )}

              {/* Hub: the supervising claude-code session (real logo). */}
              <foreignObject x="0" y="148" width="120" height="44">
                {/* Pill bases are blue-grey (not paper white) so they read as
                    lit by the aurora rather than pasted over it; hub one step
                    brighter than the workers. */}
                <div className="flex h-11 items-center gap-2.5 rounded-full bg-[#d8e4ee] px-3.5">
                  {/* Mono-only marks (Grok, Kimi) draw in currentColor, so the
                      light pill needs a dark color context. */}
                  <AgentIcon name="Claude Code" size={24} color className="text-slate-900" />
                  <span className="font-sans text-[15px] font-medium text-slate-900">
                    claude
                  </span>
                </div>
              </foreignObject>

              {/* Worker sessions: real color logos, status shown by border/glow
                  as each lights up through the pipeline. */}
              {WORKERS.map((w, i) => {
                const status = frame.statuses[i] ?? "idle";
                return (
                  <foreignObject
                    key={w.id}
                    x="176"
                    y={w.y - 20}
                    width="164"
                    height="40"
                    style={{
                      opacity: status === "idle" ? 0.72 : 1,
                      transition: "opacity 0.5s ease",
                    }}
                  >
                    <div className="flex h-10 items-center gap-2 rounded-full bg-[#c8d7e5] px-3">
                      {/* Kimi's color mark is blue-on-white and washes out on
                          the light pill, so it uses the mono (currentColor)
                          variant instead. */}
                      <AgentIcon
                        name={w.name}
                        size={20}
                        color={w.name !== "Kimi"}
                        className="text-slate-900"
                      />
                      <span className="truncate font-sans text-[12px] font-medium text-slate-900">
                        {w.id}
                      </span>
                      <span
                        className="ml-auto h-2 w-2 shrink-0 rounded-full"
                        style={{
                          backgroundColor: STATUS_DOT[status],
                          transition: "background-color 0.4s ease",
                        }}
                      />
                    </div>
                  </foreignObject>
                );
              })}
            </svg>
          </div>

          {/* Right: the CLI transcript, floating directly on the glow. */}
          <div>
            {/* Screen-reader copy of the pipeline's outcome; the animated pane
                re-renders too often to be useful aloud. */}
            <pre className="sr-only">
              {DONE_SUMMARY.map((l) => `${l.text}\n`).join("")}
            </pre>

            {/* min-height reserves the rolling window's space so the window does
                not grow line by line while typing. Phones hard-wrap at the pane
                edge exactly like a real terminal (the JSON lines have no soft
                break points); from sm up lines stay unwrapped and can scroll. */}
            <pre
              aria-hidden="true"
              className="min-h-[340px] whitespace-pre-wrap break-all p-5 font-mono text-[13px] leading-relaxed sm:min-h-[320px] sm:whitespace-pre sm:break-normal sm:overflow-x-auto sm:p-6 sm:text-[14px]"
            >
              {frame.lines.map((line, i) =>
                line.blank ? (
                  <span key={line.id ?? i}>{"\n"}</span>
                ) : (
                  <span
                    key={line.id ?? i}
                    className={
                      // Output lines fade in on arrival; typed prompt lines
                      // are already animated by the typewriter, so they don't.
                      // Whitespace behavior inherits from the pre (wrap on
                      // phones, pre from sm up).
                      line.prompt ? "block" : "line-in block"
                    }
                  >
                    {line.prompt ? (
                      <>
                        <span className="select-none text-slate-400">$ </span>
                        <span className="text-slate-50">{line.text}</span>
                      </>
                    ) : (
                      <span
                        className={
                          line.tone === "done" ? "text-sky-300" : "text-slate-300"
                        }
                      >
                        {line.text}
                      </span>
                    )}
                  </span>
                ),
              )}
              {frame.typing !== null && (
                <span className="block">
                  <span className="select-none text-slate-400">$ </span>
                  <span className="text-slate-50">{frame.typing}</span>
                  <span className="demo-cursor text-slate-50/80">▋</span>
                </span>
              )}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}
