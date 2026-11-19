// Runs before the page paints: reads the reader's saved docs appearance and puts
// it on <html> as `data-theme`, which the docs styles key on. Without it a
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
// nested layout does on every client navigation — while the root layout's
// document shell is emitted once and never re-rendered.
//
// Deliberately tiny, dependency-free, and it must not throw: Safari in private
// mode makes localStorage access throw, and an exception here would land before
// anything else on the page runs.
//
// It also keeps the browser bar in step. Each layout declares its theme-color
// tags keyed to the OS appearance, with its own colours (the docs' light is
// white). For an explicit choice the matching tag's media becomes "all" and the
// other's "not all"; System restores the original. Next can add the tags after
// this script runs, and the switch changes `data-theme` later, so an observer
// on <head> and on the attribute re-applies it.
//
// The choice used to be the docs' alone, under "termio-docs-theme"; a reader who
// set it there keeps it until they next pick one.
const SCRIPT = `try{var t=localStorage.getItem("termio-theme")||localStorage.getItem("termio-docs-theme");if(t==="light"||t==="dark")document.documentElement.dataset.theme=t;}catch(e){}try{var r=document.documentElement,s=function(){var t=r.dataset.theme;document.querySelectorAll('meta[name="theme-color"]').forEach(function(m){if(m.dataset.media===undefined)m.dataset.media=m.media;var o=m.dataset.media;m.media=t&&o?(o.indexOf(t)>-1?"all":"not all"):o})};s();var o=new MutationObserver(s);o.observe(document.head,{childList:true});o.observe(r,{attributes:true,attributeFilter:["data-theme"]})}catch(e){}`;

export function ThemeScript() {
  return <script dangerouslySetInnerHTML={{ __html: SCRIPT }} />;
}
