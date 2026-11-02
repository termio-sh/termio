// The Files pane's half of the bridge to @pierre/trees (`FileTreeWebView.swift`).
//
// Swift owns the data: it sends every row the device has listed, and this side
// turns that into the library's path set. The library owns the interaction:
// selection, keyboard, expansion, drag inside the tree. What leaves the page is
// a short message naming a path, never a DOM detail.
//
// Paths cross the bridge relative to the checkout root and without a trailing
// slash; `d` says which ones are folders. The library spells a folder `src/`.
(() => {
  const post = (message) => window.webkit.messageHandlers.fileTree.postMessage(message);
  const host = document.getElementById('tree');

  let tree = null;
  let root = '';
  let writable = false;
  // Tree path → the entry Swift sent for it, as of the last `apply`.
  let entries = new Map();
  // Folders shown but never listed. Expanding one is the only way the tree asks
  // the device for its contents, and the library has no expand callback, so its
  // state is read back on every change.
  let unlisted = new Set();
  // Set when the library moved rows on its own (a drag inside the tree), so its
  // path set no longer matches `entries` and the next `apply` must replace it.
  let diverged = false;
  // The file the last selection change opened. A click on a row that is already
  // selected changes no selection, so the click opens it instead, unless the
  // same click already did through the selection.
  let openedByThisClick = null;
  let revealing = false;
  let dropRow = null;
  // Every folder's names across a move inside the tree, as [old] or [old, new]:
  // the disk move may still fail. Which ones are open is read when the
  // listing lands, so a folder closed meanwhile stays closed.
  let namesAcrossMove = [];
  // Set from the last press, pointer or key: with shift, cmd or ctrl held it
  // edits the selection and opens nothing.
  let modifiedInput = false;
  // Set while an arrow key is handled. The library moves focus, not selection,
  // and the old tree opened the file the keyboard walked onto.
  let walking = false;
  let lastFocused = null;
  // The selection Swift was last told, as a tree path, or null for none.
  let toldSelection = null;

  const treePath = (entry) => (entry.d ? entry.p + '/' : entry.p);
  const plain = (path) => (path.endsWith('/') ? path.slice(0, -1) : path);
  const isFolder = (path) => path.endsWith('/');
  // The library may name a folder with or without its trailing slash.
  const itemAt = (path) => tree?.getItem(path) ?? tree?.getItem(isFolder(path) ? plain(path) : path + '/') ?? null;
  const entryAt = (path) => entries.get(path) ?? entries.get(path + '/');

  function decoration({ item }) {
    const entry = entryAt(item.path);
    if (!entry) return null;
    if (entry.l) return { text: '…' };
    if (entry.n) return { text: String(entry.c ?? ''), title: entry.n };
    if (entry.s) return { text: '↗', title: entry.s };
    if (entry.x) return { text: '–', title: entry.x };
    return null;
  }

  function gitStatus() {
    const statuses = [];
    for (const [path, entry] of entries) {
      if (entry.i) statuses.push({ path, status: 'ignored' });
    }
    return statuses;
  }

  function expandedFolders() {
    if (!tree) return [];
    const open = [];
    for (const [path, entry] of entries) {
      if (entry.d && itemAt(path)?.isExpanded?.()) open.push(path);
    }
    return open;
  }

  function create(paths) {
    tree = new PierreTrees.FileTree({
      paths,
      itemHeight: 22,
      overscan: 12,
      initialExpansion: 'closed',
      dragAndDrop: writable ? {
        onDropComplete: ({ draggedPaths, target }) => {
          namesAcrossMove = foldersAcross(draggedPaths, target.directoryPath ?? '');
          diverged = true;
          post({ type: 'move', paths: draggedPaths.map(plain), directory: target.directoryPath ? plain(target.directoryPath) : '' });
        },
        // The library refuses a move onto a name that exists. The disk move
        // gives the file a numbered name instead, so Swift still gets it; the
        // rows were not moved, and the next listing adds the new one.
        onDropError: (_message, { draggedPaths, target }) => {
          post({ type: 'move', paths: draggedPaths.map(plain), directory: target?.directoryPath ? plain(target.directoryPath) : '' });
        },
      } : false,
      gitStatus: gitStatus(),
      renderRowDecoration: decoration,
      unsafeCSS: '[data-termio-drop-target] { background: var(--trees-selected-bg-override); border-radius: var(--trees-border-radius-override); }',
      onSelectionChange: (selected) => {
        if (revealing) return;
        const kept = keptSelection(selected);
        if (kept !== toldSelection) tellSelection(kept);
        const path = selected.length === 1 && !modifiedInput ? selected[0] : null;
        if (path != null && !isFolder(path)) {
          openedByThisClick = path;
          setTimeout(() => { if (openedByThisClick === path) openedByThisClick = null; }, 0);
          post({ type: 'open', path: plain(path) });
        }
      },
    });
    tree.subscribe(requestUnlistedFolders);
    tree.subscribe(followKeyboardFocus);
    tree.render({ fileTreeContainer: host });
  }

  // Swift holds one path. Of several selected rows it keeps the one it has, if
  // still selected, else the focused one, else the last.
  function keptSelection(selected) {
    if (selected.length === 0) return null;
    if (toldSelection != null && selected.includes(toldSelection)) return toldSelection;
    const focused = tree.getFocusedPath();
    return selected.includes(focused) ? focused : selected[selected.length - 1];
  }

  function tellSelection(path) {
    toldSelection = path;
    post({ type: 'select', path: path == null ? null : plain(path), directory: path != null && isFolder(path) });
  }

  const parentOf = (path) => {
    const cut = plain(path).lastIndexOf('/');
    return cut < 0 ? '' : path.slice(0, cut + 1);
  };

  // Open with every folder above it open too. The library keeps a hidden
  // folder's flag, and opening it again would open its parents with it.
  function visiblyOpen(path) {
    for (let folder = path; folder !== ''; folder = parentOf(folder)) {
      if (!itemAt(folder)?.isExpanded?.()) return false;
    }
    return true;
  }

  // The library has already moved the rows, so a folder is found under its new
  // name; `entries` still holds the old ones. A folder inside a moved one that
  // the device has not listed yet stays closed: its rows only arrive after the
  // move, and opening it then would undo what was done since.
  function foldersAcross(draggedPaths, directory) {
    const names = [];
    for (const [path, entry] of entries) {
      if (!entry.d) continue;
      const moved = draggedPaths.find((dragged) => path === dragged || (isFolder(dragged) && path.startsWith(dragged)));
      if (moved == null) {
        names.push([path]);
        continue;
      }
      const name = plain(moved).split('/').pop() + (isFolder(moved) ? '/' : '');
      names.push([path, directory + name + path.slice(moved.length)]);
    }
    return names;
  }

  function followKeyboardFocus() {
    const focused = tree.getFocusedPath();
    if (focused === lastFocused) return;
    lastFocused = focused;
    if (!walking || focused == null) return;
    const selected = tree.getSelectedPaths();
    if (selected.length === 1 && selected[0] === focused) return;
    // Also makes it the anchor a later shift-click extends from; see the
    // vendor README for why this one call is patched in.
    tree.selectOnlyPath(focused);
  }

  function requestUnlistedFolders() {
    if (!tree || unlisted.size === 0) return;
    for (const path of unlisted) {
      if (itemAt(path)?.isExpanded?.()) {
        unlisted.delete(path);
        post({ type: 'expand', path: plain(path) });
      }
    }
  }

  // Brings the library's path set to `next` one change at a time, so expansion,
  // selection and scroll survive a listing landing. A change the library refuses
  // (a path it already made while it moved rows itself) is skipped; the set that
  // results is what the device listed either way.
  function patch(next) {
    const removed = [];
    for (const path of entries.keys()) {
      if (!next.has(path)) removed.push(path);
    }
    // A folder's removal takes its rows with it.
    removed.sort((a, b) => a.length - b.length);
    const gone = [];
    for (const path of removed) {
      if (gone.some((folder) => path.startsWith(folder))) continue;
      try { tree.remove(path, { recursive: isFolder(path) }); } catch (_) {}
      if (isFolder(path)) gone.push(path);
    }
    for (const path of next.keys()) {
      if (entries.has(path)) continue;
      try { tree.add(path); } catch (_) {}
    }
  }

  window.termioTree = {
    configure(options) {
      root = options.root;
      writable = options.writable;
    },

    apply({ rows }) {
      const next = new Map();
      for (const row of rows) next.set(treePath(row), row);
      unlisted = new Set([...next].filter(([, row]) => row.d && !row.o).map(([path]) => path));
      if (!tree) {
        entries = next;
        create([...next.keys()]);
        return;
      }
      const moved = diverged;
      if (diverged) {
        entries = next;
        // Read before the reset, while the library still holds the moved rows.
        const open = namesAcrossMove.filter((names) => visiblyOpen(names[names.length - 1])).flat();
        tree.resetPaths([...next.keys()], { initialExpandedPaths: open.filter((path) => next.has(path)) });
        namesAcrossMove = [];
        diverged = false;
      } else {
        patch(next);
        entries = next;
      }
      tree.setGitStatus(gitStatus());
      // A change to a row's decoration alone (loading, a note) touches no path
      // the library tracks, so it would not redraw on its own.
      tree.render({ fileTreeContainer: host });
      // Swift dropped the selection the library reported mid-move, for a path it
      // had not listed yet; a row removed from under the selection reports none.
      const kept = keptSelection(tree.getSelectedPaths());
      if (moved ? kept != null : kept !== toldSelection) tellSelection(kept);
      requestUnlistedFolders();
    },

    setStyle(variables) {
      for (const [name, value] of Object.entries(variables)) host.style.setProperty(name, value);
    },

    expand(path) {
      const item = itemAt(path + '/');
      if (item && !item.isExpanded()) item.expand();
    },

    // Selects and scrolls to a row without opening it: the caller already did.
    reveal(path) {
      if (!tree) return false;
      const target = entries.has(path) ? path : path + '/';
      const item = itemAt(target);
      if (!item) return false;
      revealing = true;
      try {
        tree.selectOnlyPath(target);
        tree.scrollToPath(target, { offset: 'center' });
      } finally {
        revealing = false;
      }
      // Swift records the revealed row itself.
      toldSelection = target;
      return true;
    },

    clearSelection() {
      if (!tree) return;
      revealing = true;
      try {
        for (const selected of tree.getSelectedPaths()) itemAt(selected)?.deselect();
      } finally {
        revealing = false;
      }
      toldSelection = null;
    },

    collapseAll() {
      for (const path of expandedFolders()) itemAt(path)?.collapse();
    },

    endDrop() { markDropRow(null); },
  };

  function rowAt(event) {
    for (const node of event.composedPath()) {
      if (node instanceof HTMLElement && node.dataset && node.dataset.itemPath != null) return node;
    }
    return null;
  }

  host.addEventListener('pointerdown', (event) => {
    modifiedInput = event.shiftKey || event.metaKey || event.ctrlKey;
  }, true);

  host.addEventListener('click', (event) => {
    if (modifiedInput) return;
    const row = rowAt(event);
    if (!row || row.dataset.itemType !== 'file') return;
    const path = row.dataset.itemPath;
    if (openedByThisClick === path) return;
    post({ type: 'open', path: plain(path) });
  });

  host.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    const row = rowAt(event);
    post({
      type: 'menu',
      path: row ? plain(row.dataset.itemPath) : null,
      directory: row ? row.dataset.itemType === 'folder' : true,
      x: event.clientX,
      y: event.clientY,
    });
  });

  const walkingKeys = new Set(['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown']);
  host.addEventListener('keydown', (event) => {
    modifiedInput = event.shiftKey || event.metaKey || event.ctrlKey;
    if (!walkingKeys.has(event.key) || event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return;
    walking = true;
    setTimeout(() => { walking = false; }, 0);
  }, true);

  host.addEventListener('keydown', (event) => {
    if (event.key !== ' ' || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.composedPath().some((node) => node instanceof HTMLInputElement)) return;
    event.preventDefault();
    event.stopPropagation();
    post({ type: 'quickLook' });
  }, true);

  // A row dragged out of the tree must carry its file URL, which is what the
  // terminal and the Finder take. The library's own data is a bare path, and a
  // page can't put a file URL on the pasteboard, so Swift writes it.
  let draggingRow = false;
  host.addEventListener('dragstart', (event) => {
    const row = rowAt(event);
    if (!row) return;
    draggingRow = true;
    // The library drags the whole selection when the pressed row is in it.
    const pressed = row.dataset.itemPath;
    const selected = tree?.getSelectedPaths() ?? [];
    const dragged = selected.includes(pressed) ? selected : [pressed];
    if (writable) post({ type: 'dragStart', paths: dragged.map(plain) });
  }, true);
  host.addEventListener('dragend', () => { draggingRow = false; }, true);

  // A drag from outside the page: the Finder, another app. Its files are read
  // natively; this side only says which folder is under the pointer. A row's
  // own drag also carries a file once Swift adds it, so it is told apart here.
  function isExternal(event) {
    return !draggingRow && [...(event.dataTransfer?.types ?? [])].includes('Files');
  }

  function markDropRow(row) {
    if (dropRow === row) return;
    dropRow?.removeAttribute('data-termio-drop-target');
    dropRow = row;
    dropRow?.setAttribute('data-termio-drop-target', 'true');
  }

  host.addEventListener('dragover', (event) => {
    if (!writable || !isExternal(event)) return;
    event.preventDefault();
    const row = rowAt(event);
    let directory = '';
    let folderRow = null;
    if (row && row.dataset.itemType === 'folder') {
      directory = plain(row.dataset.itemPath);
      folderRow = row;
    } else if (row && row.dataset.itemParentPath) {
      directory = plain(row.dataset.itemParentPath);
    }
    markDropRow(folderRow);
    post({ type: 'dropTarget', directory });
  }, true);

  host.addEventListener('dragleave', (event) => {
    if (event.relatedTarget == null) markDropRow(null);
  }, true);
})();
