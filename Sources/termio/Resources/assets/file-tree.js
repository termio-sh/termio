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
          diverged = true;
          post({ type: 'move', paths: draggedPaths.map(plain), directory: target.directoryPath ? plain(target.directoryPath) : '' });
        },
      } : false,
      gitStatus: gitStatus(),
      renderRowDecoration: decoration,
      unsafeCSS: '[data-termio-drop-target] { background: var(--trees-selected-bg-override); border-radius: var(--trees-border-radius-override); }',
      onSelectionChange: (selected) => {
        if (revealing || selected.length !== 1) return;
        const path = selected[0];
        post({ type: 'select', path: plain(path), directory: isFolder(path) });
        if (!isFolder(path)) {
          openedByThisClick = path;
          setTimeout(() => { if (openedByThisClick === path) openedByThisClick = null; }, 0);
          post({ type: 'open', path: plain(path) });
        }
      },
    });
    tree.subscribe(requestUnlistedFolders);
    tree.render({ fileTreeContainer: host });
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
      if (diverged) {
        const open = expandedFolders();
        entries = next;
        tree.resetPaths([...next.keys()], { initialExpandedPaths: open });
        diverged = false;
      } else {
        patch(next);
        entries = next;
      }
      tree.setGitStatus(gitStatus());
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
        for (const selected of tree.getSelectedPaths()) itemAt(selected)?.deselect();
        item.select();
        tree.scrollToPath(target, { offset: 'center' });
      } finally {
        revealing = false;
      }
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

  host.addEventListener('click', (event) => {
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
    if (writable) post({ type: 'dragStart', path: plain(row.dataset.itemPath) });
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
