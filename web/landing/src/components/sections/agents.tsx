import Link from "next/link";
import { Reveal } from "@/components/reveal";
import { Section } from "@/components/section-label";
import { AgentIcon } from "@/components/agent-icons";
import { supportedAgents } from "@/lib/site";

const cardClass =
  "flex items-center gap-3 rounded-xl border border-border bg-card p-3 transition-colors hover:bg-accent sm:gap-4 sm:p-5";

// After VS Code's extension grid: a short heading on the left, and one card
// per agent on the right, each naming the command it runs. The last card is
// the way out for an agent Termio has no manifest for.
export function Agents() {
  return (
    <Section id="agents">
      <div className="grid items-center gap-10 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)] lg:gap-16">
        <Reveal>
          <h2 className="text-balance text-4xl font-medium tracking-tight sm:text-5xl">
            Bring your agents.
          </h2>
          <p className="mt-5 max-w-sm text-pretty text-lg text-muted-foreground">
            Termio sets up status hooks for each one. Any other CLI runs too.
          </p>
        </Reveal>
        <Reveal delayMs={80}>
          <ul className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            {supportedAgents.map((agent) => (
              <li key={agent.name}>
                <a
                  href={agent.href}
                  target="_blank"
                  rel="noreferrer"
                  className={cardClass}
                >
                  <AgentIcon name={agent.name} size={28} color />
                  <span className="min-w-0">
                    <span className="block truncate font-medium text-foreground">
                      {agent.name}
                    </span>
                    <span className="block truncate font-mono text-xs text-muted-foreground">
                      {agent.command}
                    </span>
                  </span>
                </a>
              </li>
            ))}
            <li>
              <Link href="/docs/custom-agents" className={cardClass}>
                <span
                  aria-hidden="true"
                  className="inline-flex size-7 shrink-0 items-center justify-center rounded-lg border border-dashed border-foreground/30 text-lg text-muted-foreground"
                >
                  +
                </span>
                <span className="min-w-0">
                  <span className="block truncate font-medium text-foreground">
                    Your own
                  </span>
                  <span className="block truncate text-xs text-muted-foreground">
                    Add any CLI →
                  </span>
                </span>
              </Link>
            </li>
          </ul>
        </Reveal>
      </div>
    </Section>
  );
}
