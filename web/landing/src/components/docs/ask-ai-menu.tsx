"use client";

import { HugeiconsIcon } from "@hugeicons/react";
import {
  BubbleChatIcon,
  ArrowDown01Icon,
  ArrowUpRight01Icon,
} from "@hugeicons/core-free-icons";
import { Menu } from "@base-ui/react/menu";

// Hands the page to an assistant instead of an "Ask AI" chat panel. A panel means
// a hosted model, an API key, and a bill; this costs nothing, works for the reader
// who is already in a conversation with one of these, and points the assistant at
// the page's raw Markdown rather than a scrape of the rendered HTML.
export function AskAIMenu({
  labels,
}: {
  labels: {
    trigger: string;
    aria: string;
    claude: string;
    chatgpt: string;
    /** Already resolved against the page's Markdown URL by the server. */
    prompt: string;
  };
}) {
  const prompt = encodeURIComponent(labels.prompt);
  const destinations = [
    { name: labels.claude, href: `https://claude.ai/new?q=${prompt}` },
    {
      name: labels.chatgpt,
      href: `https://chatgpt.com/?hints=search&q=${prompt}`,
    },
  ];

  return (
    <Menu.Root>
      <Menu.Trigger
        aria-label={labels.aria}
        className="docs-page-action text-fd-muted-foreground"
      >
        <HugeiconsIcon icon={BubbleChatIcon} size={16} aria-hidden="true" />
        {labels.trigger}
        <HugeiconsIcon
          icon={ArrowDown01Icon}
          size={12}
          className="ml-auto opacity-70"
          aria-hidden="true"
        />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner
          sideOffset={6}
          align="start"
          collisionPadding={8}
          className="z-50"
        >
          <Menu.Popup className="w-[11rem] max-w-[var(--available-width)] max-h-[var(--available-height)] overflow-y-auto rounded-xl border border-fd-border bg-fd-popover p-1 text-fd-popover-foreground shadow-lg outline-none">
            {destinations.map((destination) => (
              <Menu.Item
                key={destination.name}
                className="flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-[13px] no-underline outline-none data-[highlighted]:bg-fd-accent data-[highlighted]:text-fd-accent-foreground"
                render={
                  // Menu.Item puts its children, the destination's name, inside this anchor.
                  // oxlint-disable-next-line jsx-a11y/control-has-associated-label
                  <a href={destination.href} target="_blank" rel="noreferrer" />
                }
              >
                {destination.name}
                <HugeiconsIcon
                  icon={ArrowUpRight01Icon}
                  size={12}
                  className="ml-auto opacity-50"
                  aria-hidden="true"
                />
              </Menu.Item>
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}
