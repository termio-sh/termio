// The page's half of `DiffWebView`: diffs drawn by @pierre/diffs `CodeView` (see
// Git/PierreDiffs/README.md). It has two shapes. A stack is every changed file of a
// pull request in one scroll, each under its own header. A single is one file with no
// header, for the diff overlay, which draws the header itself.
//
// The list virtualizes, so only the lines on screen exist in the DOM, and the scroll
// runs in WebKit, not on the app's main thread. Swift sends the files and the look; the
// page asks Swift for a file's full text when a reader expands hidden context.
(() => {
  'use strict';
  const Diffs = window.PierreDiffs;
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.termioDiffs;
  const post = (message) => (bridge ? bridge.postMessage(message) : Promise.resolve(null));

  const root = document.getElementById('root');
  let viewer = null;
  let pool = null;
  let look = null;
  /** One file with no header, not a stack of files. */
  let single = false;
  /** The input each item was built from, by item id. */
  const files = new Map();
  /** Every item on the page, in order. */
  let itemIds = [];
  /** The library's renderer for each item that is on screen, by item id. */
  const instances = new Map();
  /**
   * The one source of item versions, for loads and folds alike. `CodeView` drops an update
   * whose version matches the item it holds, so a version is never handed out twice.
   */
  let revision = 0;
  let generation = 0;

  function workerPool() {
    if (pool || !window.__pierreDiffsWorker) return pool;
    const url = URL.createObjectURL(new Blob([window.__pierreDiffsWorker], { type: 'text/javascript' }));
    try {
      pool = Diffs.getOrCreateWorkerPoolSingleton({
        poolOptions: { workerFactory: () => new Worker(url), poolSize: 2 },
        highlighterOptions: { preferredHighlighter: 'highlights', theme: themes() },
      });
    } catch (error) {
      post({ type: 'log', message: 'worker pool: ' + String(error) });
      pool = null;
    }
    return pool;
  }

  function themes() {
    return { light: 'pierre-light', dark: 'pierre-dark' };
  }

  /**
   * `git diff` output goes to the parser as it is. A GitHub file patch is hunks only; the
   * parser wants the git headers in front, and reads a file's status from them. A tab or
   * newline in a path would end the header line early, so the header carries a flattened
   * path and `item` puts the real names back.
   */
  function patchText(file) {
    if (file.patch.startsWith('diff --git ')) return file.patch;
    const flat = (path) => path.replace(/[\t\r\n]/g, ' ');
    const path = flat(file.path);
    const oldPath = flat(file.oldPath || file.path);
    let head = 'diff --git a/' + oldPath + ' b/' + path + '\n';
    if (file.status === 'added') head += 'new file mode 100644\n';
    if (file.status === 'deleted') head += 'deleted file mode 100644\n';
    if (oldPath !== path) {
      head += 'similarity index ' + (file.patch ? '90' : '100') + '%\n';
      head += 'rename from ' + oldPath + '\nrename to ' + path + '\n';
    }
    if (!file.patch) return head;
    const from = file.status === 'added' ? '/dev/null' : 'a/' + oldPath;
    const to = file.status === 'deleted' ? '/dev/null' : 'b/' + path;
    return head + '--- ' + from + '\n+++ ' + to + '\n' + file.patch + (file.patch.endsWith('\n') ? '' : '\n');
  }

  /**
   * The items one file draws as. Nearly always one. A path that changes type, as a symlink
   * replaced by a regular file, is two diffs in git's output: the old one deleted, the new
   * one added.
   */
  function items(file) {
    let parsed = [];
    try {
      const patches = Diffs.parsePatchFiles(patchText(file), { cacheKeyPrefix: generation + ':' + file.id });
      parsed = patches.flatMap((patch) => patch.files);
    } catch (error) {
      post({ type: 'log', message: 'parse ' + file.path + ': ' + String(error) });
    }
    return parsed.map((fileDiff, index) => {
      // A path cannot hold a NUL, so the extra ids never collide with a file's.
      const id = index === 0 ? file.id : file.id + '\u0000' + index;
      fileDiff.name = file.path;
      if (file.oldPath && file.oldPath !== file.path) fileDiff.prevName = file.oldPath;
      const held = viewer && viewer.getItem(id);
      // A refresh keeps the files the reader folded shut.
      return { id, type: 'diff', fileDiff, collapsed: Boolean(held && held.collapsed), version: generation };
    });
  }

  /**
   * Both sides of a changed file, for expanding context. Swift answers with both sides
   * when it has them. When it has only the new side, the old side is the new one with
   * the patch taken back out.
   */
  async function loadDiffFiles(fileDiff) {
    const file = files.get(fileDiff.name);
    if (!file || !file.patch) throw new Error('unknown file ' + fileDiff.name);
    const reply = await post({ type: 'fileText', path: file.path });
    const text = typeof reply === 'string' ? reply : reply && reply.new;
    if (typeof text !== 'string') throw new Error('no text for ' + file.path);
    const newFile = { name: file.path, contents: text };
    if (fileDiff.type === 'rename-pure') return { oldFile: null, newFile };
    let base = reply && reply.old;
    if (typeof base !== 'string') {
      const reversed = Diffs.reversePatch(Diffs.parsePatch(patchText(file))[0]);
      base = Diffs.applyPatch(text, reversed);
      if (base === false) throw new Error('patch does not reverse onto ' + file.path);
    }
    if (!agrees(fileDiff, base, text)) {
      // The diff on screen is out of date. Swift reads it again.
      post({ type: 'stale' });
      throw new Error(file.path + ' changed since its diff was read');
    }
    return { oldFile: { name: file.oldPath || file.path, contents: base }, newFile };
  }

  /**
   * Whether the two files hold the lines the diff shows, at the line numbers it shows them.
   * The library keeps the hunks and swaps in the files' lines, so files read after another
   * edit, or cut short, would put other text under the same hunks.
   */
  function agrees(fileDiff, oldText, newText) {
    const bare = (line) => (line === undefined ? undefined : line.replace(/\r?\n$/, ''));
    const oldLines = oldText.split('\n');
    const newLines = newText.split('\n');
    const same = (shown, index, lines, number, count) => {
      for (let offset = 0; offset < count; offset++) {
        const line = lines[number - 1 + offset];
        if (line === undefined || bare(shown[index + offset]) !== line.replace(/\r$/, '')) return false;
      }
      return true;
    };
    for (const hunk of fileDiff.hunks) {
      let oldNumber = hunk.deletionStart;
      let newNumber = hunk.additionStart;
      for (const content of hunk.hunkContent) {
        const context = content.type === 'context';
        const deletions = context ? content.lines : content.deletions;
        const additions = context ? content.lines : content.additions;
        if (!same(fileDiff.deletionLines, content.deletionLineIndex, oldLines, oldNumber, deletions)) return false;
        if (!same(fileDiff.additionLines, content.additionLineIndex, newLines, newNumber, additions)) return false;
        oldNumber += deletions;
        newNumber += additions;
      }
    }
    return true;
  }

  /** The fold toggle at the front of each header; `context.item` is the item it heads. */
  function chevron(fileDiff, context) {
    const id = context && context.item && context.item.id;
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = context && context.item && context.item.collapsed ? '▸' : '▾';
    button.setAttribute('style', 'all:unset;cursor:default;width:14px;text-align:center;opacity:.6');
    button.addEventListener('click', (event) => {
      event.stopPropagation();
      const latest = id && viewer && viewer.getItem(id);
      if (!latest) return;
      viewer.updateItem({ ...latest, collapsed: !latest.collapsed, version: ++revision });
    });
    return button;
  }

  /** Why a file shows no lines, beside its name: binary, or too large for the API's patch. */
  function note(fileDiff, context) {
    const file = context && context.item && files.get(context.item.id);
    if (!file || !file.note) return undefined;
    const span = document.createElement('span');
    span.textContent = file.note;
    span.setAttribute('style', 'margin-left:8px;opacity:.6;font-weight:normal');
    return span;
  }

  function options() {
    const split = single && look.style === 'split';
    return {
      theme: themes(),
      themeType: look.scheme,
      diffStyle: split ? 'split' : 'unified',
      // Two columns stay row for row only while no line wraps.
      overflow: split ? 'scroll' : 'wrap',
      stickyHeaders: !single,
      disableFileHeader: single,
      preferredHighlighter: 'highlights',
      hunkSeparators: single ? 'line-info-basic' : 'line-info',
      diffIndicators: single ? 'none' : 'bars',
      // One step of a band's reveal, the same count the native diff used.
      expansionLineCount: single ? 20 : 100,
      lineDiffType: 'word',
      layout: single ? { paddingTop: 0, paddingBottom: 0, gap: 0 } : { paddingTop: 10, paddingBottom: 10, gap: 10 },
      // The list places rows it has not drawn yet by these heights, so they follow the CSS.
      itemMetrics: single
        ? { lineHeight: look.lineHeight, hunkSeparatorHeight: look.lineHeight + 10, spacing: 0, paddingTop: 8, paddingBottom: 8 }
        : undefined,
      loadDiffFiles,
      renderHeaderPrefix: chevron,
      renderHeaderFilenameSuffix: note,
      onPostRender: (node, instance, phase, context) => {
        const id = context && context.item && context.item.id;
        if (id && phase === 'unmount') instances.delete(id);
        else if (id) instances.set(id, instance);
        if (single && id && phase !== 'unmount') watch(node, id);
        scheduleFindPaint();
      },
      unsafeCSS: look.css + findCSS + (single ? overlayCSS() : ''),
    };
  }

  /**
   * The gutter's columns. Both are as wide as the longest line number, and a file that is
   * all additions or all deletions has no numbers for the other side, so that column goes.
   */
  function sizeGutter() {
    if (!single || !viewer) return;
    let longest = 1;
    let old = false;
    let fresh = false;
    for (const id of itemIds) {
      const diff = (viewer.getItem(id) || {}).fileDiff;
      if (!diff) continue;
      if (!diff.isPartial) longest = Math.max(longest, diff.additionLines.length, diff.deletionLines.length);
      for (const hunk of diff.hunks) {
        longest = Math.max(longest, hunk.additionStart + hunk.additionCount, hunk.deletionStart + hunk.deletionCount);
        old = old || hunk.deletionCount > 0;
        fresh = fresh || hunk.additionCount > 0;
      }
    }
    root.style.setProperty('--termio-digits', String(Math.max(2, String(longest).length)));
    if (old) root.style.removeProperty('--termio-old-column');
    else root.style.setProperty('--termio-old-column', 'none');
    if (fresh) root.style.removeProperty('--termio-new-column');
    else root.style.setProperty('--termio-new-column', 'none');
  }

  function applyLook() {
    for (const [name, value] of Object.entries(look.variables)) root.style.setProperty(name, value);
    document.documentElement.style.background = look.variables['--diffs-bg'] || 'transparent';
    document.documentElement.style.colorScheme = look.scheme;
  }

  // The overlay's look. One file in the diff overlay keeps the look it had as a native
  // view, GitHub Desktop's: an old and a new number column, a sign column, washes mixed
  // from the pane's background, and flat bands that name the lines they hide. The library
  // draws the rows; this CSS and `decorate` restyle them.

  function overlayCSS() {
    const dark = look.scheme === 'dark';
    // A dark background swallows a tint that is plenty on a light one.
    const wash = dark ? 20 : 12;
    const emphasis = dark ? 26 : 20;
    const ink = dark ? '#fff' : '#000';
    const mix = (base, tint, amount) => 'color-mix(in oklab, ' + base + ', ' + tint + ' ' + amount + '%)';
    const glyph = (path) => "url('data:image/svg+xml;utf8," + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22" fill="none" '
      + 'stroke="black" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">' + path + '</svg>') + "')";
    const dots = (y) => [7.5, 9.9, 12.3, 14.7].map((x) => '<rect x="' + x + '" y="' + y + '" width="1.2" height="1.2" fill="black" stroke="none"/>').join('');
    const up = glyph('<path d="M11 11.8V6.8M8.5 9.2 11 6.8l2.5 2.4"/>' + dots(14.2));
    const down = glyph('<path d="M11 10.2v5M8.5 12.8 11 15.2l2.5-2.4"/>' + dots(6.6));
    const all = glyph('<path d="M11 2.9v5M8.5 5.5 11 7.9l2.5-2.4M11 19.1v-5M8.5 16.5 11 14.1l2.5 2.4"/>' + dots(10.4));
    return `
    :host {
      --termio-addition: ${dark ? '#5ecc71' : '#0dbe4e'};
      --termio-deletion: ${dark ? '#ff6762' : '#ff2e3f'};
      --termio-addition-wash: ${mix('var(--diffs-bg)', 'var(--termio-addition)', wash)};
      --termio-deletion-wash: ${mix('var(--diffs-bg)', 'var(--termio-deletion)', wash)};
      --termio-addition-gutter: ${mix('var(--diffs-bg)', 'var(--termio-addition)', wash * 1.6)};
      --termio-deletion-gutter: ${mix('var(--diffs-bg)', 'var(--termio-deletion)', wash * 1.6)};
      --termio-addition-emphasis: ${mix('var(--termio-addition-wash)', 'var(--termio-addition)', emphasis)};
      --termio-deletion-emphasis: ${mix('var(--termio-deletion-wash)', 'var(--termio-deletion)', emphasis)};
      --termio-band: ${mix('var(--diffs-bg)', ink, 5)};
      --termio-band-control: ${mix('var(--diffs-bg)', ink, 11)};
      --termio-column: calc(var(--termio-digits, 2) * 1ch);
    }
    [data-line], [data-no-newline] { padding-inline: 11px; background-color: var(--diffs-bg); }
    [data-line][data-line-type=change-addition], [data-no-newline][data-line-type=change-addition] { background-color: var(--termio-addition-wash); }
    [data-line][data-line-type=change-deletion], [data-no-newline][data-line-type=change-deletion] { background-color: var(--termio-deletion-wash); }
    [data-line-type=change-addition] [data-diff-span] { background-color: var(--termio-addition-emphasis); border-radius: 0; }
    [data-line-type=change-deletion] [data-diff-span] { background-color: var(--termio-deletion-emphasis); border-radius: 0; }

    [data-gutter] [data-column-number], [data-gutter] [data-gutter-buffer] {
      display: flex; gap: 8px; padding: 0 2px 0 8px; border-right: 0;
      background-color: var(--diffs-bg); color: var(--termio-number-ink);
      font-family: -apple-system, system-ui, sans-serif; font-variant-numeric: tabular-nums;
      font-size: var(--termio-number-size);
    }
    [data-gutter] [data-column-number][data-line-type=change-addition] { background-color: var(--termio-addition-gutter); color: var(--termio-number-ink); }
    [data-gutter] [data-column-number][data-line-type=change-deletion] { background-color: var(--termio-deletion-gutter); color: var(--termio-number-ink); }
    [data-line-number-content] { min-width: var(--termio-column); text-align: right; }
    [data-column-number]::after {
      content: ""; display: block; width: 12px; text-align: left;
      font-family: var(--diffs-font-family); font-size: var(--diffs-font-size); font-variant-numeric: normal;
    }
    [data-column-number][data-line-type=change-addition]::after { content: "+"; color: var(--termio-addition-sign); }
    [data-column-number][data-line-type=change-deletion]::after { content: "\\2212"; color: var(--termio-deletion-sign); }
    [data-unified] [data-column-number]::before {
      content: attr(data-old); display: var(--termio-old-column, block);
      min-width: var(--termio-column); text-align: right;
    }
    [data-unified] [data-column-number][data-line-type=change-addition]::before { content: ""; }
    [data-unified] [data-column-number][data-line-type=change-deletion]::before { content: attr(data-column-number); }
    [data-unified] [data-column-number] [data-line-number-content] { display: var(--termio-new-column, inline-block); }
    [data-unified] [data-column-number][data-line-type=change-deletion] [data-line-number-content] { visibility: hidden; }

    [data-separator=line-info-basic] {
      height: calc(var(--diffs-line-height) + 10px); margin-block: 0;
      background-color: var(--termio-band); font-family: var(--diffs-font-family);
    }
    [data-separator=line-info-basic] [data-separator-wrapper],
    [data-separator=line-info-basic][data-expand-index] [data-separator-wrapper] {
      display: flex; align-items: center; background-color: var(--termio-band);
      position: absolute; inset: 0; padding: 0; border-radius: 0;
    }
    [data-gutter] [data-separator=line-info-basic] [data-separator-wrapper] { justify-content: center; gap: 2px; }
    [data-gutter] [data-separator-content], [data-content] [data-expand-button] { display: none; }
    [data-content] [data-separator-content] {
      display: flex; background: none; padding: 0 11px; height: 100%;
      color: var(--termio-band-ink); border-radius: 0;
    }
    [data-expand-index] [data-separator-content]:hover { text-decoration: none; }
    /* The label fills the band, so a click anywhere on the band opens it. */
    [data-unmodified-lines] { white-space: pre; flex: auto; align-self: stretch; display: flex; align-items: center; cursor: pointer; }
    /* The side of a split diff with no line for a row stays blank. */
    [data-content-buffer] { background-image: none; background-color: var(--diffs-bg); }
    [data-gutter] [data-expand-button] {
      flex: none; align-self: center; width: 22px; min-width: 0; height: 22px;
      border: 0; border-radius: 4px; background: none; color: var(--termio-number-ink);
    }
    [data-gutter] [data-expand-button]:hover { background-color: var(--termio-band-control); color: var(--diffs-fg); }
    [data-gutter] [data-expand-button][data-expand-all-button] { display: none; }
    [data-expand-button] [data-icon] { display: none; }
    [data-gutter] [data-expand-button]::before {
      content: ""; width: 22px; height: 22px; background-color: currentColor;
      -webkit-mask: ${all} center / 22px 22px no-repeat;
    }
    /* The library names a button by the end of the band it opens. The arrow points the
       way the reveal walks, which is the other way. */
    [data-gutter] [data-expand-button][data-expand-up]::before { -webkit-mask-image: ${down}; }
    [data-gutter] [data-expand-button][data-expand-down]::before { -webkit-mask-image: ${up}; }
    /* The code never scrolls down inside itself, so it holds no room for a scroller. */
    [data-code] { scrollbar-gutter: auto; }
    `;
  }

  /** The item each watched shadow tree draws, by tree. */
  const watched = new WeakMap();

  /** Restyles the rows of one item's shadow tree now, and again whenever the library redraws them. */
  function watch(node, id) {
    const tree = node && node.shadowRoot;
    if (!tree) return;
    const known = watched.has(tree);
    watched.set(tree, id);
    decorate(tree);
    if (known) return;
    new MutationObserver(() => decorate(tree)).observe(tree, { childList: true, subtree: true });
  }

  function decorate(tree) {
    // An unchanged row carries its new number in the gutter. Its old number is on the code row.
    for (const code of tree.querySelectorAll('[data-code][data-unified]')) {
      const numbers = code.querySelectorAll('[data-gutter] > [data-column-number][data-line-type^=context]:not([data-old])');
      if (numbers.length === 0) continue;
      const old = new Map();
      for (const line of code.querySelectorAll('[data-content] > [data-line][data-alt-line]')) {
        old.set(line.getAttribute('data-line-index'), line.getAttribute('data-alt-line'));
      }
      for (const number of numbers) number.setAttribute('data-old', old.get(number.getAttribute('data-line-index')) || '');
    }
    const labels = [...tree.querySelectorAll('[data-content] > [data-separator] [data-unmodified-lines]')];
    // The new file's column first: the old file's column copies its labels.
    labels.sort((a, b) => Boolean(a.closest('[data-deletions]')) - Boolean(b.closest('[data-deletions]')));
    for (const label of labels) {
      if (label.textContent === label.getAttribute('data-termio-label')) continue;
      const text = bandLabel(label);
      label.setAttribute('data-termio-label', text);
      label.textContent = text;
    }
  }

  /**
   * What a band says: the lines it hides, and git's heading for the hunk under it. A line
   * range tells the reader what they jump over. A count only describes the control.
   */
  function bandLabel(label) {
    const band = label.closest('[data-separator]');
    // Both columns of a split diff name the band by the new file's lines.
    const column = band.closest('[data-deletions]');
    const twin = column && column.parentNode.querySelector(
      '[data-additions] [data-content] > [data-separator][data-expand-index="' + band.getAttribute('data-expand-index') + '"] [data-termio-label]');
    if (twin) return twin.getAttribute('data-termio-label');
    const count = parseInt(label.textContent, 10);
    const numbered = (row) => (row && row.hasAttribute('data-line') && row.getAttribute('data-line-type') !== 'change-deletion'
      ? Number(row.getAttribute('data-line')) : null);
    const below = numbered(band.nextElementSibling);
    const above = numbered(band.previousElementSibling);
    let range = '';
    if (Number.isFinite(count) && count > 0 && (below !== null || above !== null)) {
      const first = below !== null ? below - count : above + 1;
      range = count === 1 ? String(first) : first + '–' + (first + count - 1);
    }
    const id = watched.get(band.getRootNode());
    const entry = id && viewer && viewer.getItem(id);
    const hunk = entry && entry.fileDiff && entry.fileDiff.hunks[Number(band.getAttribute('data-expand-index'))];
    const heading = hunk && hunk.hunkContext ? hunk.hunkContext.trim() : '';
    return [range, heading].filter(Boolean).join('   ') || label.textContent;
  }

  // Find. The matches are counted from the diff itself, because the lines off screen are
  // not in the DOM. The paint runs over the lines that are, after every render.
  //
  // Until a reader expands a band the page holds only the lines of the patch, so find covers
  // those. Expanding one loads the whole file, and from then on find covers the whole file:
  // a match inside a band that is still shut opens the band when the reader steps to it.

  const findCSS = `
    ::highlight(termio-find) { background-color: rgba(255, 204, 0, 0.35); }
    ::highlight(termio-find-focused) { background-color: rgba(255, 204, 0, 0.7); }
  `;
  let findPattern = null;
  /** Which of Swift's searches the matches belong to. It goes back with every count. */
  let findSerial = null;
  /** Every match, in reading order. */
  let findMatches = [];
  let findFocused = null;
  let findPaintQueued = false;
  /** The items whose whole file the matches were last counted from. */
  const hydrated = new Set();
  /** The bands find has opened, as item id and band index, so each opens once. */
  const revealed = new Set();

  function pattern(spec) {
    if (!spec || !spec.query) return null;
    const escaped = spec.regex ? spec.query : spec.query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const body = spec.wholeWord ? '(?<![\\p{L}\\p{N}_])(?:' + escaped + ')(?![\\p{L}\\p{N}_])' : escaped;
    try {
      return new RegExp(body, spec.caseSensitive ? 'gu' : 'giu');
    } catch (error) {
      // A regular expression that is still half typed matches nothing.
      return null;
    }
  }

  function spans(text) {
    // `matchAll` steps past an empty match by a whole character. A hand-rolled step of one
    // code unit lands inside a surrogate pair and never ends.
    const found = [];
    for (const match of text.matchAll(findPattern)) {
      if (match[0].length > 0) found.push([match.index, match.index + match[0].length]);
    }
    return found;
  }

  function collectMatches() {
    findMatches = [];
    hydrated.clear();
    if (!viewer) return;
    for (const id of itemIds) {
      const entry = viewer.getItem(id);
      const diff = entry && entry.fileDiff;
      if (!diff) continue;
      const whole = !diff.isPartial;
      if (whole) hydrated.add(id);
      if (!findPattern) continue;
      const scan = (side, lines, index, number, count, band) => {
        for (let offset = 0; offset < count; offset++) {
          const text = (lines[index + offset] || '').replace(/\r?\n$/, '');
          for (const [start, end] of spans(text)) {
            findMatches.push({ id, side, line: number + offset, start, end, band });
          }
        }
      };
      // The unchanged lines between two hunks, which a band hides. `band` is the index the
      // library opens it by: the hunk below it, or one past the last hunk for the file's end.
      const between = (from, to, band) => {
        if (whole && to > from) scan('additions', diff.additionLines, from - 1, from, to - from, band);
      };
      let shown = 1;
      diff.hunks.forEach((hunk, index) => {
        let oldNumber = hunk.deletionStart;
        let newNumber = hunk.additionStart;
        // A hunk that adds nothing names the line above it, not its own first line.
        const first = hunk.additionCount > 0 ? newNumber : newNumber + 1;
        between(shown, first, index);
        for (const content of hunk.hunkContent) {
          if (content.type === 'context') {
            // An unchanged line shows in both columns of a split diff. It counts once.
            scan('additions', diff.additionLines, content.additionLineIndex, newNumber, content.lines);
            oldNumber += content.lines;
            newNumber += content.lines;
          } else {
            scan('deletions', diff.deletionLines, content.deletionLineIndex, oldNumber, content.deletions);
            scan('additions', diff.additionLines, content.additionLineIndex, newNumber, content.additions);
            oldNumber += content.deletions;
            newNumber += content.additions;
          }
        }
        shown = hunk.additionCount > 0 ? newNumber : first;
      });
      if (diff.hunks.length > 0) between(shown, diff.additionLines.length + 1, diff.hunks.length);
    }
  }

  /** Opens the band a match sits in, so the line exists to scroll to. */
  function reveal(match) {
    if (match.band === undefined) return;
    const key = match.id + '\u0000' + match.band;
    const instance = instances.get(match.id);
    if (revealed.has(key) || !instance || typeof instance.expandHunk !== 'function') return;
    revealed.add(key);
    instance.expandHunk(match.band, 'both', Number.MAX_SAFE_INTEGER);
  }

  /** A band was expanded for the first time, so the whole file is there to search now. */
  function recountIfHydrated() {
    if (!findPattern || !viewer) return;
    const grew = itemIds.some((id) => {
      const entry = viewer.getItem(id);
      return entry && entry.fileDiff && !entry.fileDiff.isPartial && !hydrated.has(id);
    });
    if (!grew) return;
    // The new matches land in between the old ones, so the focused one has a new index.
    const held = findFocused;
    collectMatches();
    const index = held ? findMatches.findIndex((match) => match.id === held.id
      && match.side === held.side && match.line === held.line && match.start === held.start) : -1;
    findFocused = index < 0 ? null : findMatches[index];
    post({ type: 'findCount', serial: findSerial, count: findMatches.length, index: Math.max(index, 0) });
  }

  function scheduleFindPaint() {
    if (findPaintQueued || !window.Highlight) return;
    findPaintQueued = true;
    // A timer, not an animation frame: the paint has to run while the pane is covered too.
    setTimeout(() => {
      findPaintQueued = false;
      sizeGutter();
      recountIfHydrated();
      paintFind();
    }, 30);
  }

  /** The range for characters `start` to `end` of a line element's text. */
  function textRange(line, start, end) {
    const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    let offset = 0;
    let open = false;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const length = node.data.length;
      if (!open && start < offset + length) {
        range.setStart(node, start - offset);
        open = true;
      }
      if (open && end <= offset + length) {
        range.setEnd(node, end - offset);
        return range;
      }
      offset += length;
    }
    return null;
  }

  function paintFind() {
    CSS.highlights.delete('termio-find');
    CSS.highlights.delete('termio-find-focused');
    if (!findPattern) return;
    const all = new Highlight();
    const focused = new Highlight();
    for (const host of root.querySelectorAll('diffs-container')) {
      if (!host.shadowRoot) continue;
      for (const line of host.shadowRoot.querySelectorAll('[data-line]')) {
        const type = line.getAttribute('data-line-type') || '';
        const old = type === 'change-deletion' || Boolean(line.closest('[data-deletions]'));
        const number = Number(line.getAttribute('data-line'));
        const text = line.textContent.replace(/\r?\n$/, '');
        for (const [start, end] of spans(text)) {
          const range = textRange(line, start, end);
          if (!range) continue;
          const isFocused = findFocused
            && findFocused.line === number && findFocused.start === start
            && (findFocused.side === 'deletions') === old;
          (isFocused ? focused : all).add(range);
        }
      }
    }
    CSS.highlights.set('termio-find', all);
    CSS.highlights.set('termio-find-focused', focused);
  }

  // Keys. The overlay owns the walk between files and the close; the page owns the scroll.

  function onKey(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === 'Escape') {
      post({ type: 'close' });
      return;
    }
    if (!single || event.shiftKey) return;
    const line = parseFloat(getComputedStyle(root).getPropertyValue('--diffs-line-height')) || 18;
    const page = root.clientHeight * 0.9;
    const scroll = { ArrowDown: line * 3, ArrowUp: -line * 3, PageDown: page, PageUp: -page, ' ': page }[event.key];
    if (scroll !== undefined) root.scrollBy(0, scroll);
    else if (event.key === 'Home') root.scrollTo(0, 0);
    else if (event.key === 'End') root.scrollTo(0, root.scrollHeight);
    else if (event.key === 'ArrowLeft') post({ type: 'walk', delta: -1 });
    else if (event.key === 'ArrowRight') post({ type: 'walk', delta: 1 });
    else return;
    event.preventDefault();
  }

  window.termioDiffs = {
    /** Replaces the whole list: a new pull request, new files for this one, or another file. */
    load(payload) {
      look = payload.look;
      single = Boolean(payload.single);
      applyLook();
      generation = ++revision;
      files.clear();
      for (const file of payload.files) files.set(file.id, file);
      if (!viewer) {
        viewer = new Diffs.CodeView(options(), workerPool() || undefined);
        viewer.setup(root);
      } else {
        viewer.setOptions(options());
      }
      const next = payload.files.flatMap(items);
      itemIds = next.map((entry) => entry.id);
      instances.clear();
      revealed.clear();
      hydrated.clear();
      viewer.setItems(next);
      sizeGutter();
      if (single) root.scrollTo(0, 0);
      collectMatches();
      scheduleFindPaint();
    },
    /** The theme, font, color scheme, or column count changed. */
    setLook(next) {
      look = next;
      applyLook();
      if (!viewer) return;
      viewer.setOptions(options());
      if (pool) pool.setRenderOptions({ theme: themes() });
      viewer.onThemeChange();
    },
    /**
     * Searches for `spec.query` and brings match `spec.index` into view. Returns how many
     * matches there are. A null spec clears the search.
     */
    find(spec) {
      findPattern = pattern(spec);
      findSerial = spec ? spec.serial : null;
      collectMatches();
      findFocused = (spec && findMatches[spec.index]) || null;
      if (findFocused && viewer) {
        reveal(findFocused);
        viewer.scrollTo({
          type: 'line', id: findFocused.id, lineNumber: findFocused.line,
          side: findFocused.side, align: 'center',
        });
      }
      scheduleFindPaint();
      return findMatches.length;
    },
  };

  document.addEventListener('keydown', onKey);
  root.addEventListener('scroll', scheduleFindPaint, { passive: true });
  document.addEventListener('selectionchange', () => {
    post({ type: 'selection', text: String(document.getSelection() || '') });
  });
  window.addEventListener('error', (event) => post({ type: 'log', message: String(event.message) }));
  post({ type: 'ready' });
})();
