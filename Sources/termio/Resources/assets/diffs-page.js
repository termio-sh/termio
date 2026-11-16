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
      hunkSeparators: 'line-info',
      lineDiffType: 'word',
      layout: single ? { paddingTop: 0, paddingBottom: 0, gap: 0 } : { paddingTop: 10, paddingBottom: 10, gap: 10 },
      loadDiffFiles,
      renderHeaderPrefix: chevron,
      renderHeaderFilenameSuffix: note,
      onPostRender: (node, instance, phase, context) => {
        const id = context && context.item && context.item.id;
        if (id && phase === 'unmount') instances.delete(id);
        else if (id) instances.set(id, instance);
        scheduleFindPaint();
      },
      unsafeCSS: look.css + findCSS,
    };
  }

  function applyLook() {
    for (const [name, value] of Object.entries(look.variables)) root.style.setProperty(name, value);
    document.documentElement.style.background = look.variables['--diffs-bg'] || 'transparent';
    document.documentElement.style.colorScheme = look.scheme;
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
