"use client";

import {
  ClaudeCode,
  Codex,
  Antigravity,
  Amp,
  OpenCode,
  GithubCopilot,
  Cursor,
  Kimi,
  Grok,
  DeepSeek,
} from "@lobehub/icons";
import { cn } from "@/lib/utils";

// Real brand glyphs for every supported agent, keyed by the names in
// `supportedAgents`. Each lobehub icon is a compound component: the default
// export is the monochrome (`.Mono`) mark (renders in `currentColor`, our
// default so the logos stay legible on the near-black canvas), and `.Color` is
// the full brand-color mark. Pass `color` to opt into `.Color`; brands with no
// color variant (e.g. Grok — xAI's mark is monochrome by design) fall back to
// the mono mark, which is already their brand look.
//
// Two agents have no icon in the set, and rather than draw a logo for someone
// else's product they get the character each already prints for itself: Pi's π,
// and the diagonal hatch Crush rules its banner with.
type GlyphProps = { size?: number };
type BrandIcon = React.ComponentType<GlyphProps> & {
  Color?: React.ComponentType<GlyphProps>;
};

const brandByAgent: Record<string, BrandIcon> = {
  "Claude Code": ClaudeCode,
  Codex: Codex,
  Antigravity: Antigravity,
  Amp: Amp,
  OpenCode: OpenCode,
  Copilot: GithubCopilot,
  Cursor: Cursor,
  Kimi: Kimi,
  Grok: Grok,
  DeepSeek: DeepSeek,
};

// Kimi's color mark draws its K in white, which vanishes on a light page; its
// mono mark already is the brand look.
const monoOnly = new Set(["Kimi"]);

const glyphByAgent: Record<string, string> = {
  Pi: "π",
  Crush: "╱╱",
};

function TextGlyph({ size = 20, text }: GlyphProps & { text: string }) {
  return (
    <span
      aria-hidden="true"
      className="inline-flex items-center justify-center font-mono font-semibold leading-none"
      style={{
        width: size,
        height: size,
        fontSize: (size * 0.95) / Math.max(1, text.length * 0.8),
      }}
    >
      {text}
    </span>
  );
}

export function AgentIcon({
  name,
  size = 20,
  className,
  color = false,
}: {
  name: string;
  size?: number;
  className?: string;
  /** Render the brand's full-color mark instead of the monochrome one. */
  color?: boolean;
}) {
  const Brand = brandByAgent[name];
  const Glyph =
    Brand && (color && !monoOnly.has(name) ? (Brand.Color ?? Brand) : Brand);
  return (
    <span className={cn("inline-flex shrink-0", className)} aria-hidden="true">
      {Glyph ? (
        <Glyph size={size} />
      ) : (
        <TextGlyph size={size} text={glyphByAgent[name] ?? name.slice(0, 1)} />
      )}
    </span>
  );
}
