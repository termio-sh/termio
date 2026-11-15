// The page's half of `PRDiffWebView`: every changed file of a pull request in one
// @pierre/diffs `CodeView` (see Git/PierreDiffs/README.md). The list virtualizes, so
// only the diffs on screen exist in the DOM, and the scroll runs in WebKit, not on
// the app's main thread. Swift sends the files and the look; the page asks Swift
// for a file's text at the PR head when a reader expands hidden context.
(() => {
  'use strict';
  const Diffs = window.PierreDiffs;
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.prDiff;
  const post = (message) => (bridge ? bridge.postMessage(message) : Promise.resolve(null));

  const root = document.getElementById('root');
  let viewer = null;
  let pool = null;
  let look = null;
  /** The input each item was built from, by item id. */
  const files = new Map();
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
   * A GitHub file patch is hunks only; the parser wants the git headers in front, and reads
   * a file's status from them. A tab or newline in a path would end the header line early,
   * so the header carries a flattened path and `item` puts the real names back.
   */
  function patchText(file) {
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

  function item(file, collapsed) {
    let fileDiff = null;
    try {
      const parsed = Diffs.parsePatchFiles(patchText(file), { cacheKeyPrefix: generation + ':' + file.id });
      fileDiff = parsed[0] && parsed[0].files[0];
    } catch (error) {
      post({ type: 'log', message: 'parse ' + file.path + ': ' + String(error) });
    }
    if (!fileDiff) return null;
    fileDiff.name = file.path;
    if (file.oldPath && file.oldPath !== file.path) fileDiff.prevName = file.oldPath;
    return { id: file.id, type: 'diff', fileDiff, collapsed, version: generation };
  }

  /**
   * Both sides of a changed file, for expanding context. Only the head is fetched:
   * the base is the head with the patch taken back out.
   */
  async function loadDiffFiles(fileDiff) {
    const file = files.get(fileDiff.name);
    if (!file || !file.patch) throw new Error('unknown file ' + fileDiff.name);
    const text = await post({ type: 'fileText', path: file.path });
    if (typeof text !== 'string') throw new Error('no text for ' + file.path);
    const reversed = Diffs.reversePatch(Diffs.parsePatch(patchText(file))[0]);
    const base = Diffs.applyPatch(text, reversed);
    if (base === false) throw new Error('patch does not reverse onto ' + file.path);
    return {
      oldFile: { name: file.oldPath || file.path, contents: base },
      newFile: { name: file.path, contents: text },
    };
  }

  /** The fold toggle at the front of each header; `context.item` is the item it heads. */
  function chevron(fileDiff, context) {
    const id = context && context.item && context.item.id;
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = context && context.item && context.item.collapsed ? '\u25B8' : '\u25BE';
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
    return {
      theme: themes(),
      themeType: look.scheme,
      diffStyle: 'unified',
      overflow: 'wrap',
      stickyHeaders: true,
      preferredHighlighter: 'highlights',
      hunkSeparators: 'line-info',
      lineDiffType: 'word',
      layout: { paddingTop: 10, paddingBottom: 10, gap: 10 },
      loadDiffFiles,
      renderHeaderPrefix: chevron,
      renderHeaderFilenameSuffix: note,
      unsafeCSS: look.css,
    };
  }

  function applyLook() {
    for (const [name, value] of Object.entries(look.variables)) root.style.setProperty(name, value);
    document.documentElement.style.background = look.variables['--diffs-bg'] || 'transparent';
    document.documentElement.style.colorScheme = look.scheme;
  }

  window.termioDiffs = {
    /** Replaces the whole list: a new pull request, or new files for this one. */
    load(payload) {
      look = payload.look;
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
      // A refresh keeps the files the reader folded shut.
      const folded = (id) => Boolean(viewer.getItem(id) && viewer.getItem(id).collapsed);
      viewer.setItems(payload.files.map((file) => item(file, folded(file.id))).filter(Boolean));
    },
    /** The theme, font, or color scheme changed. */
    setLook(next) {
      look = next;
      applyLook();
      if (!viewer) return;
      viewer.setOptions(options());
      if (pool) pool.setRenderOptions({ theme: themes() });
      viewer.onThemeChange();
    },
  };

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') post({ type: 'close' });
  });
  window.addEventListener('error', (event) => post({ type: 'log', message: String(event.message) }));
  post({ type: 'ready' });
})();
