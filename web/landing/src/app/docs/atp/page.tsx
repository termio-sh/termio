import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { SiteFooter } from "@/components/site-footer";
import { SectionLabel } from "@/components/section-label";
import { Reveal } from "@/components/reveal";

export const metadata: Metadata = {
  title: "Agent Terminal Protocol",
  description:
    "The Agent Terminal Protocol (ATP) is how Termio hosts any agent CLI: one JSON manifest declaring how to launch it, how it reports status, and how to resume its exact conversation.",
  alternates: {
    canonical: "/docs/atp",
  },
  openGraph: {
    title: "Agent Terminal Protocol — Termio",
    description:
      "One JSON manifest per agent: launch, live status, exact resume. The agent's own TUI stays in a real terminal.",
    url: "/docs/atp",
  },
};

// A spec code block: monospace, hairline border, horizontally scrollable on
// small screens. Content is a plain string so the JSON reads exactly as the
// file on disk would.
function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="overflow-x-auto rounded-xl border border-border bg-white/[0.03] p-5 font-mono text-[13px] leading-relaxed text-foreground/90">
      <code>{children}</code>
    </pre>
  );
}

// A two-column field reference row: name (mono) on the left, description on the
// right, separated by hairlines like the changelog ledger.
function FieldRow({ name, children }: { name: string; children: React.ReactNode }) {
  return (
    <div className="grid gap-1 border-t border-border py-4 first:border-t-0 sm:grid-cols-[200px_minmax(0,1fr)] sm:gap-6">
      <code className="font-mono text-[13px] text-foreground">{name}</code>
      <p className="text-sm leading-relaxed text-muted-foreground">{children}</p>
    </div>
  );
}

function SectionHeading({ children }: { children: React.ReactNode }) {
  return (
    <h2 className="mt-16 text-2xl font-medium tracking-tight text-foreground">
      {children}
    </h2>
  );
}

const exampleManifest = `{
  "id": "grok",
  "name": "Grok",
  "command": "grok",
  "permissionBypassFlag": "--yolo",
  "icon": { "vector": "grok" },
  "install": "https://x.ai/cli",
  "resume": {
    "create": "--session-id {id}",
    "resume": "--resume {id}",
    "storeRoot": "~/.grok/sessions",
    "storeMatch": "dir:{id}"
  },
  "titleStatus": {
    "attention": ["Action Required"]
  },
  "hooks": {
    "type": "json",
    "file": "~/.grok/hooks/termio.json",
    "dialect": "grok",
    "events": [
      { "on": "UserPromptSubmit", "state": "working" },
      { "on": "PreToolUse", "state": "working" },
      { "on": "PostToolUse", "state": "working" },
      { "on": "Stop", "state": "done" }
    ]
  }
}`;

const discoverExample = `"resume": {
  "resume": "resume {id}",
  "discover": {
    "root": "~/.codex/sessions",
    "format": "jsonl",
    "id": "payload.id",
    "cwd": "payload.cwd"
  }
}`;

export default function AtpPage() {
  return (
    <>
      <SiteNav />
      <main className="flex-1">
        <section className="scroll-mt-24">
          <div className="mx-auto w-full px-5 pb-32 pt-36 sm:px-8 sm:pb-40 sm:pt-44">
            <Reveal className="mx-auto mb-14 w-full max-w-[680px] text-center sm:mb-16">
              <SectionLabel accent="muted">Docs</SectionLabel>
              <h1 className="mt-4 text-balance text-4xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-5xl">
                Agent Terminal Protocol
              </h1>
              <p className="mx-auto mt-5 max-w-lg text-base leading-relaxed text-muted-foreground">
                ATP is how a terminal hosts an agent CLI: one JSON manifest
                declaring how to launch it, how it reports status, and how to
                resume its exact conversation.
              </p>
            </Reveal>

            <Reveal className="mx-auto w-full max-w-[640px]">
              <p className="text-base leading-relaxed text-muted-foreground">
                Editor protocols re-render your agent inside an editor pane. ATP
                takes the opposite bet: the agent&apos;s own TUI already is the
                interface, so it stays in a real terminal, and the protocol
                standardizes only the thin layer around it —{" "}
                <span className="text-foreground">launch</span>,{" "}
                <span className="text-foreground">live status</span>, and{" "}
                <span className="text-foreground">exact resume</span>. Every
                agent Termio ships is defined by this same manifest; there is no
                privileged internal API.
              </p>

              <SectionHeading>The manifest</SectionHeading>
              <p className="mt-4 text-base leading-relaxed text-muted-foreground">
                One JSON file per agent. This is Termio&apos;s bundled Grok
                manifest, verbatim:
              </p>
              <div className="mt-6">
                <CodeBlock>{exampleManifest}</CodeBlock>
              </div>

              <div className="mt-8">
                <FieldRow name="id">
                  Stable identifier. Sessions persist it, so it never changes
                  once shipped.
                </FieldRow>
                <FieldRow name="name">Display name in the picker and sidebar.</FieldRow>
                <FieldRow name="command">
                  The CLI to launch, resolved on your login shell&apos;s PATH.
                </FieldRow>
                <FieldRow name="permissionBypassFlag">
                  The vendor&apos;s skip-permissions flag, wired to a one-click
                  toggle. Optional.
                </FieldRow>
                <FieldRow name="icon">
                  <code className="font-mono text-[13px]">vector</code> (a
                  built-in brand mark), <code className="font-mono text-[13px]">path</code>{" "}
                  (your PNG/SVG file), or{" "}
                  <code className="font-mono text-[13px]">symbol</code> (an SF
                  Symbol), with an optional{" "}
                  <code className="font-mono text-[13px]">tint</code>.
                </FieldRow>
                <FieldRow name="install">
                  The vendor&apos;s install page, offered when the command
                  isn&apos;t found. Optional.
                </FieldRow>
                <FieldRow name="order">
                  Position in the agent picker. Optional; omitted manifests sort
                  last.
                </FieldRow>
              </div>

              <SectionHeading>Status</SectionHeading>
              <p className="mt-4 text-base leading-relaxed text-muted-foreground">
                A session is always in one of four states —{" "}
                <code className="font-mono text-[13px]">working</code>,{" "}
                <code className="font-mono text-[13px]">attention</code>{" "}
                (blocked on you),{" "}
                <code className="font-mono text-[13px]">done</code>, or{" "}
                <code className="font-mono text-[13px]">idle</code> — shown in
                the sidebar, the menu bar, and on your phone. The manifest
                declares how the agent reports them:
              </p>
              <div className="mt-8">
                <FieldRow name="hooks">
                  The precise channel: Termio installs the agent&apos;s own hook
                  configuration (JSON, TOML, or a plugin, per{" "}
                  <code className="font-mono text-[13px]">dialect</code>) so the
                  agent itself reports each{" "}
                  <code className="font-mono text-[13px]">on → state</code>{" "}
                  event. When hooks are declared they are the single source of
                  truth.
                </FieldRow>
                <FieldRow name="titleStatus">
                  Regex rules over the agent&apos;s live terminal title (OSC
                  0/2) — the in-band signal some agents broadcast. Coexists with
                  hooks and corrects a missed event the instant the title flips.
                </FieldRow>
                <FieldRow name="status">
                  Screen-classification regexes for agents with no hook system
                  at all. Ignored when hooks are declared.
                </FieldRow>
              </div>

              <SectionHeading>Resume</SectionHeading>
              <p className="mt-4 text-base leading-relaxed text-muted-foreground">
                Reopening a session relaunches the agent into the same
                conversation. Resume is exact-or-nothing: Termio either resumes
                the precise conversation a tab is bound to, or launches fresh —
                it never guesses. Two families, inferred from which fields are
                present:
              </p>
              <p className="mt-4 text-base leading-relaxed text-muted-foreground">
                <span className="text-foreground">Pinned id</span> — the CLI
                accepts a session id at launch.{" "}
                <code className="font-mono text-[13px]">create</code> starts a
                fresh conversation under a Termio-minted id and{" "}
                <code className="font-mono text-[13px]">resume</code> continues
                it; <code className="font-mono text-[13px]">storeRoot</code> +{" "}
                <code className="font-mono text-[13px]">storeMatch</code>{" "}
                describe the agent&apos;s on-disk session store so Termio can
                tell the two apart (creating a duplicate id errors, as does
                resuming a missing one).
              </p>
              <p className="mt-4 text-base leading-relaxed text-muted-foreground">
                <span className="text-foreground">Discovered id</span> — the
                agent mints the id itself.{" "}
                <code className="font-mono text-[13px]">discover</code>{" "}
                describes the mechanism, never an agent: where session records
                live, how a record is read (
                <code className="font-mono text-[13px]">jsonl</code> — the first
                line of a log that is itself the transcript, or{" "}
                <code className="font-mono text-[13px]">json</code> — a
                standalone metadata file), and key paths to the id and working
                directory. Termio recovers the id once, binds it to the tab, and
                resumes exactly from then on.
              </p>
              <div className="mt-6">
                <CodeBlock>{discoverExample}</CodeBlock>
              </div>

              <SectionHeading>Add your own agent</SectionHeading>
              <p className="mt-4 text-base leading-relaxed text-muted-foreground">
                Drop a manifest at{" "}
                <code className="font-mono text-[13px]">
                  ~/.termio/config/agents/&lt;id&gt;.json
                </code>{" "}
                and restart Termio — it appears in the picker alongside the
                built-ins, with the same status dots and resume behavior. A
                minimal manifest is just an id, a name, and a command; add
                status and resume as the CLI supports them.
              </p>
            </Reveal>
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
