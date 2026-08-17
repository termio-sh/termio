// Runs before the page paints: reads the reader's saved docs appearance and puts
// it on <html> as `data-docs-theme`, which the docs styles key on. Without it a
// reader who picked Dark on a light system would see one white frame on every
// load — React can only set the attribute after hydration.
//
// A plain inline <script>, not next/script: `beforeInteractive` pushes the source
// into Next's `__next_s` queue, which the runtime replays around hydration —
// far too late to prevent the flash. This one executes the instant the parser
// reaches it, in <head>, before any body markup exists.
//
// It belongs to the root layout for the same reason. React warns when a <script>
// is rendered inside a component that re-renders on the client — which is what a
// nested docs layout does on every client navigation — while the root layout's
// document shell is emitted once and never re-rendered.
//
// Deliberately tiny, dependency-free, and it must not throw: Safari in private
// mode makes localStorage access throw, and an exception here would land before
// anything else on the page runs.
const SCRIPT = `try{var t=localStorage.getItem("termio-docs-theme");if(t==="light"||t==="dark")document.documentElement.dataset.docsTheme=t;}catch(e){}`;

export function DocsThemeScript() {
  // eslint-disable-next-line @next/next/no-before-interactive-script-outside-document
  return <script dangerouslySetInnerHTML={{ __html: SCRIPT }} />;
}
