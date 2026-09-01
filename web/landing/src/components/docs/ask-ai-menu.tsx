"use client";

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
        className="inline-flex h-7 shrink-0 items-center gap-1.5 rounded-lg px-2 text-[12px] font-medium text-fd-muted-foreground transition-colors hover:bg-fd-accent hover:text-fd-accent-foreground data-[popup-open]:bg-fd-accent data-[popup-open]:text-fd-accent-foreground"
      >
        <SparkIcon className="h-3.5 w-3.5" />
        {labels.trigger}
        <ChevronIcon className="h-3 w-3 opacity-70" />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner sideOffset={6} align="end" className="z-50">
          <Menu.Popup className="min-w-[11rem] rounded-xl border border-fd-border bg-fd-popover p-1 text-fd-popover-foreground shadow-lg outline-none">
            {destinations.map((destination) => (
              <Menu.Item
                key={destination.name}
                className="flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-[13px] no-underline outline-none data-[highlighted]:bg-fd-accent data-[highlighted]:text-fd-accent-foreground"
                render={
                  <a
                    href={destination.href}
                    target="_blank"
                    rel="noreferrer"
                  />
                }
              >
                {destination.name}
                <ExternalIcon className="ml-auto h-3 w-3 opacity-50" />
              </Menu.Item>
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}

function SparkIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z" />
      <path d="M18 16.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z" />
    </svg>
  );
}

function ChevronIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

function ExternalIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="M7 17 17 7M9 7h8v8" />
    </svg>
  );
}
