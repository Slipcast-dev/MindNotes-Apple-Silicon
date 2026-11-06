/* Views: sidebar, toolbar, tabs, panes, find bar, dialogs. Port of Features/*.swift and Render/*.swift. */

// ---- Helpers ---------------------------------------------------------------

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
      else if (k === 'dataset') Object.assign(el.dataset, v);
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (k in el) el[k] = v;
      else el.setAttribute(k, v === true ? '' : v);
    }
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

const ICONS = {
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  download: '<path d="M12 4v11M7.5 10.5 12 15l4.5-4.5"/><path d="M5 19h14"/>',
  folderPlus: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 10.5v5M9.5 13h5"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  star: '<path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.5l6.1-.9z"/>',
  bookmark: '<path d="M6 3h12v18l-6-4-6 4z"/>',
  split: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v16"/>',
  rightPane: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4h7a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-7z" fill="currentColor"/>',
  sidebar: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  xCircle: '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path d="M9 9l6 6M15 9l-6 6" stroke="var(--bg)"/>',
  up: '<path d="m6 15 6-6 6 6"/>',
  down: '<path d="m6 9 6 6 6-6"/>',
  right: '<path d="m9 6 6 6-6 6"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"/>',
  docRich: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M9 13h6M9 17h4"/>',
  doc: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
  docPlain: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M9 12h6M9 15h6M9 18h4"/>',
  docSearch: '<path d="M13 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h4"/><path d="M13 3l5 5v2"/><circle cx="16" cy="16" r="3.5"/><path d="m21 21-2.5-2.5"/>',
  docPlus: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M12 11v6M9 14h6"/>',
  palette: '<circle cx="12" cy="12" r="9"/><circle cx="8" cy="10" r="1.2"/><circle cx="12" cy="7.5" r="1.2"/><circle cx="16" cy="10" r="1.2"/><path d="M12 21c-1.5 0-2-1-1.5-2s1-1.5 0-2.5-1.5-1.5-.5-2.5 2.5-.5 4-.5c1.5 0 3 0 3 1.5"/>',
  type: '<path d="M5 7V5h14v2M12 5v14M9 19h6"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/>',
  code: '<path d="M8 7l-5 5 5 5M16 7l5 5-5 5M14 4l-4 16"/>',
  braces: '<path d="M8 4c-2 0-3 1-3 3v2c0 1-1 3-2 3 1 0 2 2 2 3v2c0 2 1 3 3 3M16 4c2 0 3 1 3 3v2c0 1 1 3 2 3-1 0-2 2-2 3v2c0 2-1 3-3 3"/>',
  table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 4v16M15 4v16"/>',
  list: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9h.01M7 12h.01M7 15h.01M11 9h6M11 12h6M11 15h6"/>',
  warning: '<path d="M12 3 2 20h20z"/><path d="M12 10v4M12 17h.01"/>',
  undo: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
  tag: '<path d="M3 12V4h8l10 10-8 8z"/><path d="M7.5 8.5h.01"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  check: '<path d="m5 12 5 5 9-10"/>',
  refresh: '<path d="M20 11a8 8 0 0 0-14-4L4 9M4 4v5h5M4 13a8 8 0 0 0 14 4l2-2M20 20v-5h-5"/>',
};

function icon(name, size = 16, fill = false) {
  const span = document.createElement('span');
  span.className = 'ico';
  span.innerHTML = `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="${fill ? 'currentColor' : 'none'}" `
    + `stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICONS[name]}</svg>`;
  return span;
}

const typeIcon = (type, size = 15) => icon(TYPE_ICONS[type] || 'docPlain', size);
const $ = (id) => document.getElementById(id);

function relativeTime(iso) {
  const diff = (Date.parse(iso) - Date.now()) / 1000;
  const rtf = new Intl.RelativeTimeFormat(LANG === 'ru' ? 'ru' : 'en', { numeric: 'auto', style: 'short' });
  const units = [['year', 31536000], ['month', 2592000], ['day', 86400], ['hour', 3600], ['minute', 60]];
  for (const [unit, secs] of units) if (Math.abs(diff) >= secs) return rtf.format(Math.round(diff / secs), unit);
  return rtf.format(Math.round(diff), 'second');
}

/** Wraps every `#tag` inside `el` in a span (class `hashtag`: colored, clickable); text inside marks and syntax spans is covered. */
function paintTags(el, cls = 'hashtag') {
  if (!el.textContent.includes('#')) return;
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  const nodes = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) if (n.nodeValue.includes('#') && !n.parentElement.closest('.' + cls)) nodes.push(n);
  for (const node of nodes) {
    const found = Library.tagMatches(node.nodeValue);
    for (let k = found.length - 1; k >= 0; k--) {
      const { index, length, tag } = found[k];
      const mid = node.splitText(index);
      mid.splitText(length);
      const span = document.createElement('span');
      span.className = cls;
      span.dataset.tag = tag;
      mid.parentNode.insertBefore(span, mid);
      span.appendChild(mid);
    }
  }
}

const PROSE = ['markdown', 'text', 'rtf', 'tex'];

// ---- Notifications ---------------------------------------------------------------

/** A short message at the bottom of the window; it fades after a couple of seconds (a newer one replaces it). */
let toastTimer = null;
function notify(text, iconName = 'check') {
  const root = $('overlay-root');
  root.querySelectorAll('.toast').forEach((n) => n.remove());
  const el = h('div', { class: 'toast' }, icon(iconName, 16), h('span', null, text));
  root.append(el);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.classList.add('out'); setTimeout(() => el.remove(), 250); }, 2400);
}
App.notify = notify;

// ---- Context menus and popovers -------------------------------------------

const Menus = {
  el: null,

  close() {
    if (this.el) { this.el.remove(); this.el = null; }
  },

  build(items) {
    const menu = h('div', { class: 'menu' });
    for (const item of items) {
      if (item.separator) { menu.append(h('div', { class: 'sep' })); continue; }
      const row = h('div', {
        class: 'mi' + (item.disabled ? ' disabled' : '') + (item.danger ? ' danger' : ''),
        onclick: () => {
          if (item.disabled || item.submenu) return;
          Menus.close();
          item.action();
        },
      }, h('span', null, item.label), item.submenu ? icon('right', 12) : null);
      if (item.submenu) row.append(Object.assign(this.build(item.submenu), { className: 'menu sub' }));
      menu.append(row);
    }
    return menu;
  },

  show(x, y, items) {
    this.close();
    const menu = this.build(items);
    menu.classList.add('ctx');
    $('overlay-root').append(menu);
    const r = menu.getBoundingClientRect();
    menu.style.left = Math.max(4, Math.min(x, innerWidth - r.width - 4)) + 'px';
    menu.style.top = Math.max(4, Math.min(y, innerHeight - r.height - 4)) + 'px';
    this.el = menu;
  },

  at(event, items) {
    event.preventDefault();
    this.show(event.clientX, event.clientY, items);
  },

  below(anchor, items) {
    const r = anchor.getBoundingClientRect();
    this.show(r.left, r.bottom + 2, items);
  },
};

const Popover = {
  el: null,
  close() {
    if (this.el) { this.el.remove(); this.el = null; }
  },
  show(anchor, content) {
    this.close();
    const pop = h('div', { class: 'popover' }, content);
    $('overlay-root').append(pop);
    const a = anchor.getBoundingClientRect();
    const r = pop.getBoundingClientRect();
    pop.style.left = Math.max(8, Math.min(a.right - r.width, innerWidth - r.width - 8)) + 'px';
    pop.style.top = a.bottom + 6 + 'px';
    this.el = pop;
  },
};

document.addEventListener('mousedown', (e) => {
  if (Menus.el && !Menus.el.contains(e.target)) Menus.close();
  if (Popover.el && !Popover.el.contains(e.target) && !e.target.closest('[data-popover-anchor]')) Popover.close();
}, true);
window.addEventListener('blur', () => { Menus.close(); });

// ---- Render scheduling -----------------------------------------------------

const pendingParts = new Set();
let flushScheduled = false;

App.render = (parts) => {
  parts.forEach((p) => pendingParts.add(p));
  if (!flushScheduled) { flushScheduled = true; setTimeout(flush, 0); }
};

function flush() {
  flushScheduled = false;
  const has = (p) => pendingParts.has('all') || pendingParts.has(p);
  const sidebar = has('sidebar');
  const toolbar = has('toolbar') || has('main');
  const main = has('main');
  const tabs = !main && has('tabs');
  const dialogs = has('dialogs');
  pendingParts.clear();

  if (sidebar) renderSidebar();
  if (toolbar) renderToolbar();
  if (main) renderMain();
  else if (tabs) { renderTabs(); updatePaneFocus(); }
  if (dialogs) renderErrorDialog();
  if (main || toolbar) {
    const cur = App.current;
    document.title = cur ? `${cur.name} — Grizzly` : 'Grizzly';
  }
}

Library.onChange = () => App.render(['sidebar', 'toolbar']);

// ---- Toolbar ---------------------------------------------------------------

function renderToolbar() {
  const bar = $('toolbar');
  const noDocs = App.documents.length === 0;
  const btn = (name, title, onclick, extra = {}) => h('button', { class: 'tb', title, onclick, ...extra }, icon(name, 17));

  const bookmarkLines = Library.bookmarks((App.current || {}).libraryID);
  const bmBtn = h('button', {
    class: 'tb', title: t('Закладки'), disabled: !App.current, 'data-popover-anchor': '1',
    onclick: (e) => toggleBookmarksPopover(e.currentTarget),
  }, icon('bookmark', 17, bookmarkLines.length > 0));

  // Three zones: sidebar toggle and file name on the left, the mode switch exactly in the middle, tools on the right.
  bar.replaceChildren(
    h('div', { class: 'tb-left' },
      btn('sidebar', t('Боковая панель'), () => { App.ui.sidebarVisible = !App.ui.sidebarVisible; applySidebarVisibility(); }),
      h('div', { class: 'title' }, (App.current || {}).name || 'Grizzly')),
    h('div', { class: 'seg', title: t('Режим просмотра') },
      ...[['reading', 'Чтение'], ['source', 'Исходник'], ['edit', 'Правка']].map(([mode, label]) => h('button', {
        class: App.mode === mode ? 'on' : '', onclick: () => App.setMode(mode),
      }, t(label)))),
    h('div', { class: 'tb-right' },
      btn(App.isSplit ? 'rightPane' : 'split', t('Два файла рядом (⌘\\)'), () => App.toggleSplit(), { disabled: noDocs, class: 'tb' + (App.isSplit ? ' active' : '') }),
      btn('search', t('Найти (⌘F)'), () => App.showFind(), { disabled: noDocs }),
      bmBtn,
      h('button', { class: 'tb text', title: t('Уменьшить текст'), onclick: () => Prefs.resizeFont(-1) }, 'A−'),
      h('button', { class: 'tb text big', title: t('Увеличить текст'), onclick: () => Prefs.resizeFont(1) }, 'A+'),
      btn('gear', t('Настройки'), () => openSettings()),
      // Rightmost: the system emoji picker, for the text being edited.
      h('button', {
        class: 'tb text emoji-btn', title: t('Эмодзи и символы (Win+.)'), disabled: App.mode !== 'edit' || noDocs,
        onclick: () => { const ta = document.querySelector('textarea.editor-text'); if (ta) { ta.focus(); window.api.showEmojiPanel(); } },
      }, '😀')),
  );
  if ($('side-actions')) renderSideActions();
}

function toggleBookmarksPopover(anchor) {
  if (Popover.el) { Popover.close(); return; }
  const doc = App.current;
  if (!doc) return;

  const content = h('div', { class: 'bookmarks' });
  const fill = () => {
    const lines = Library.bookmarks(doc.libraryID);
    content.replaceChildren(h('div', { class: 'pop-title' }, t('Закладки')));
    if (!lines.length) {
      content.append(h('div', { class: 'muted' }, t('Пока нет закладок. В режиме «Исходник» нажмите на номер строки, чтобы поставить закладку.')));
      return;
    }
    const list = h('div', { class: 'bm-list' });
    for (const line of lines) {
      const preview = doc.lines[line - 1] ?? '';
      list.append(h('div', { class: 'bm-row' },
        h('button', {
          class: 'bm-go',
          onclick: () => { Popover.close(); App.goToLine(line - 1); },
        }, h('span', { class: 'bm-num' }, line),
        h('span', { class: 'bm-text' }, preview.trim() ? preview : t('(пустая строка)'))),
        h('button', {
          class: 'bm-del', title: t('Убрать закладку'),
          onclick: () => { Library.toggleBookmark(doc.libraryID, line); syncBookmarks(); fill(); },
        }, icon('xCircle', 15))));
    }
    content.append(list);
  };
  fill();
  Popover.show(anchor, content);
}

/** Repaints bookmark markers in the source view without rebuilding it. */
function syncBookmarks() {
  document.querySelectorAll('.pane').forEach((paneEl) => {
    const doc = App.doc(paneEl.dataset.pane);
    if (!doc) return;
    const set = new Set(Library.bookmarks(doc.libraryID));
    paneEl.querySelectorAll('.gutter').forEach((g) => {
      const on = set.has(Number(g.dataset.line));
      g.classList.toggle('bookmarked', on);
      g.title = on ? t('Убрать закладку') : t('Поставить закладку');
    });
  });
  renderToolbar();
}

// ---- Sidebar ---------------------------------------------------------------

const SidebarUI = {
  query: '',
  tags: [], // selected tags: the list shows the files that carry all of them
  isNaming: false,
  newName: '',
  nameError: null,
  pendingMove: null,
  renamingID: null,
  renameText: '',
  targetedFolder: null,
  focusName: false,
};

const SECTIONS = [
  { id: 'files', icon: 'folder', title: () => t('Файлы') },
  { id: 'recent', icon: 'clock', title: () => t('Недавние') },
  { id: 'favorites', icon: 'star', title: () => t('Избранное') },
];

function buildSidebarFrame() {
  const side = $('sidebar');
  side.replaceChildren(
    h('div', { class: 'side-seg', id: 'side-seg' }),
    h('div', { class: 'filter' },
      icon('search', 14),
      h('input', {
        id: 'filter-input', type: 'text', placeholder: t('Поиск файлов'), spellcheck: false,
        oninput: (e) => { SidebarUI.query = e.target.value; renderSidebarList(); renderFilterClear(); },
      }),
      h('button', { id: 'filter-clear', class: 'plain', hidden: true, onclick: () => {
        SidebarUI.query = ''; $('filter-input').value = ''; renderSidebarList(); renderFilterClear();
      } }, icon('xCircle', 14))),
    h('div', { class: 'side-actions', id: 'side-actions' }),
    h('div', { id: 'side-list', class: 'side-list' }),
    h('div', { id: 'tag-panel', class: 'tag-panel' }),
  );
  const list = $('side-list');
  list.addEventListener('dragover', (e) => {
    if (App.ui.sidebarSection === 'files' && e.dataTransfer.types.includes('application/x-grizzly-file')) e.preventDefault();
  });
  list.addEventListener('drop', (e) => {
    const id = e.dataTransfer.getData('application/x-grizzly-file');
    if (id && App.ui.sidebarSection === 'files' && !e.defaultPrevented) { e.preventDefault(); dropFile(id, null); }
  });
}

function renderFilterClear() { $('filter-clear').hidden = !SidebarUI.query; }

/** One row of equal buttons for the file actions (new, open, new folder, save as). */
function renderSideActions() {
  const noDocs = App.documents.length === 0;
  const b = (name, title, onclick, disabled) => h('button', { class: 'sq', title, onclick, disabled: !!disabled }, icon(name, 17));
  $('side-actions').replaceChildren(
    b('docPlus', t('Новый файл (⌘N)'), () => runCommand('newFile')),
    b('folder', t('Открыть файл (⌘O)'), () => openFiles()),
    b('folderPlus', t('Новая папка'), () => { App.ui.sidebarSection = 'files'; SidebarUI.pendingMove = null; App.render(['sidebar']); beginNaming(); }),
    b('download', t('Сохранить как… (Ctrl+Shift+S)'), () => runCommand('saveAs'), noDocs));
}

function renderSidebar() {
  renderSideActions();
  const seg = $('side-seg');
  seg.replaceChildren(...SECTIONS.map((s) => h('button', {
    class: App.ui.sidebarSection === s.id ? 'on' : '', title: s.title(),
    onclick: () => { App.ui.sidebarSection = s.id; SidebarUI.tags = []; cancelNaming(); App.render(['sidebar']); },
  }, icon(s.icon, 17))));
  renderSidebarList();
  renderTagPanel();
}

// ---- Tags ----------------------------------------------------------------------

/** A small text question as an in-app dialog (Electron has no prompt()). Resolves to the text, or null when cancelled. */
function askText(title, initial, confirmLabel) {
  return new Promise((resolve) => {
    const root = $('overlay-root');
    const done = (value) => { back.remove(); resolve(value); };
    const input = h('input', {
      class: 'text-input', type: 'text', value: initial || '', spellcheck: false,
      onkeydown: (e) => {
        if (e.key === 'Enter') done(input.value.trim() || null);
        else if (e.key === 'Escape') { e.stopPropagation(); done(null); }
      },
    });
    const back = h('div', { class: 'modal-back modal-ask', onmousedown: (e) => { if (e.target === e.currentTarget) done(null); } },
      h('div', { class: 'dialog small' },
        h('div', { class: 'dialog-title' }, title),
        h('div', { class: 'dialog-body' }, input),
        h('div', { class: 'dialog-actions' },
          h('button', { class: 'btn', onclick: () => done(null) }, t('Отмена')),
          h('button', { class: 'btn primary', onclick: () => done(input.value.trim() || null) }, confirmLabel))));
    root.append(back);
    input.focus();
    input.select();
  });
}

const isSelectedTag = (tag) => SidebarUI.tags.some((x) => Library.sameTag(x, tag));

function toggleTagSelection(tag) {
  SidebarUI.tags = isSelectedTag(tag) ? SidebarUI.tags.filter((x) => !Library.sameTag(x, tag)) : [...SidebarUI.tags, tag];
  App.render(['sidebar']);
}

/** A click on a #tag inside a document: the sidebar lists the files with that tag. */
function showTag(tag) {
  SidebarUI.tags = [tag];
  App.ui.sidebarSection = 'files';
  App.ui.sidebarVisible = true;
  applySidebarVisibility();
  App.render(['sidebar']);
}

/** A yes / no question as an in-app dialog. Resolves to true when confirmed. */
function askConfirm(title, body, confirmLabel) {
  return new Promise((resolve) => {
    const done = (v) => { back.remove(); resolve(v); };
    const back = h('div', { class: 'modal-back modal-ask', onmousedown: (e) => { if (e.target === e.currentTarget) done(false); } },
      h('div', { class: 'dialog small' },
        h('div', { class: 'dialog-title' }, title),
        h('div', { class: 'dialog-body' }, body),
        h('div', { class: 'dialog-actions btn-row' },
          h('button', { class: 'btn', onclick: () => done(false) }, t('Отмена')),
          h('button', { class: 'btn primary', onclick: () => done(true) }, confirmLabel))));
    $('overlay-root').append(back);
  });
}

async function newTag(forFile) {
  const name = await askText(t('Новый тег'), '', t('Создать'));
  const tag = name && Library.createTag(name);
  if (!tag) return;
  if (forFile && !Library.hasTag(forFile, tag)) Library.toggleTag(forFile, tag);
  else if (!forFile) { SidebarUI.tags = [tag]; App.render(['sidebar']); }
  notify(t('Тег создан: #%@', tag), 'tag');
}

/** Rewrites `#old` in the text of the files that use it (RTF is left out). Returns the names that could not be changed. */
async function rewriteTag(old, next) {
  const skipped = [];
  for (const file of Library.data.files.filter((f) => f.inlineTags.some((x) => Library.sameTag(x, old)) && fileTypeOf(f.path) !== 'rtf')) {
    const doc = App.documents.find((d) => d.libraryID === file.id);
    if (doc && App.isDirty(doc)) { skipped.push(file.name); continue; }
    const loaded = await window.api.readFile(file.path);
    if (!loaded.ok) { skipped.push(file.name); continue; }
    const updated = Library.replaceTag(old, next, loaded.text);
    if (updated === loaded.text) continue;
    const res = await window.api.writeFile(file.path, updated, loaded.encoding);
    if (!res.ok) { skipped.push(file.name); continue; }
    if (doc) await App.reload(doc.id); else Library.setInlineTags(file.id, Library.extractTags(updated));
  }
  if (skipped.length) App.fail(t('Не удалось изменить файлы: %@. Сохраните или отмените правки в них и повторите.', skipped.join(', ')));
}

const filesWithTagText = (tag) => Library.data.files.filter((f) => f.inlineTags.some((x) => Library.sameTag(x, tag)) && fileTypeOf(f.path) !== 'rtf').length;

async function renameTag(tag) {
  const name = await askText(t('Переименовать тег'), tag, t('Переименовать'));
  const next = name && Library.cleanTag(name);
  if (!next || next === tag) return;
  const n = filesWithTagText(tag);
  if (n && !(await askConfirm(t('Переименовать #%@ в #%@?', tag, next), t('Тег записан в тексте файлов (%lld). Он будет изменён и там.', n), t('Переименовать')))) return;
  await rewriteTag(tag, next);
  Library.renameTag(tag, next);
  SidebarUI.tags = SidebarUI.tags.map((x) => (Library.sameTag(x, tag) ? next : x));
  App.render(['sidebar']);
  notify(t('Тег переименован: #%@', next), 'tag');
}

async function deleteTag(tag) {
  const n = filesWithTagText(tag);
  if (!(await askConfirm(t('Удалить тег #%@?', tag),
    n ? t('Тег будет убран из списка и из текста файлов (%lld).', n) : t('Тег будет убран из списка и у всех файлов.'), t('Удалить тег')))) return;
  await rewriteTag(tag, null);
  Library.deleteTag(tag);
  SidebarUI.tags = SidebarUI.tags.filter((x) => !Library.sameTag(x, tag));
  App.render(['sidebar']);
  notify(t('Тег удалён: #%@', tag), 'tag');
}

/** Bottom of the sidebar, like the tag browser in Apple Notes: "All Tags" plus a chip per tag; several selected tags
 *  show the files that carry all of them. Tags are the #words written in the files. */
function renderTagPanel() {
  const panel = $('tag-panel');
  if (!panel) return;
  const tags = Library.allTags;
  const chip = (label, on, count, onclick, tag) => h('button', {
    class: 'chip' + (on ? ' on' : ''), onclick,
    oncontextmenu: tag ? (e) => Menus.at(e, [
      { label: t('Переименовать…'), action: () => renameTag(tag) },
      { label: t('Удалить тег'), danger: true, action: () => deleteTag(tag) },
    ]) : null,
  }, h('span', { class: 'ellipsis' }, label), count == null ? null : h('span', { class: 'chip-count' }, count));
  panel.replaceChildren(
    h('div', { class: 'tag-head' }, icon('tag', 13), h('span', { class: 'grow' }, t('Теги')),
      h('button', { class: 'plain tag-add', title: t('Новый тег'), onclick: () => newTag(null) }, icon('plus', 14))),
    tags.length
      ? h('div', { class: 'chips' },
        chip(t('Все теги'), !SidebarUI.tags.length, null, () => { SidebarUI.tags = []; App.render(['sidebar']); }, null),
        tags.map((tag) => chip('#' + tag, isSelectedTag(tag), Library.filesWithTag(tag).length, () => toggleTagSelection(tag), tag)))
      : h('div', { class: 'small muted' }, t('Напишите #тег в тексте файла, и он появится здесь. Или создайте тег кнопкой +.')));
}

/** By the beginning of the name or of any word in it; "#word" searches the tags the same way. */
function matchesQuery(file) {
  const q = SidebarUI.query.trim();
  if (!q) return true;
  if (q.startsWith('#')) {
    const tag = Library.cleanTag(q);
    return tag ? file.tags.some((x) => Searcher.nameMatches(x, tag)) : file.tags.length > 0;
  }
  return Searcher.nameMatches(file.name, q);
}
const filtered = (files) => files.filter(matchesQuery);

function renderSidebarList() {
  const list = $('side-list');
  const scroll = list.scrollTop;
  const section = App.ui.sidebarSection;
  const frag = document.createDocumentFragment();

  if (SidebarUI.tags.length) {
    // All files that carry every selected tag, wherever they live in the library.
    const files = Library.filesWithAllTags(SidebarUI.tags);
    frag.append(h('div', { class: 'sec-head' }, h('span', { class: 'ellipsis' }, t('Теги: %@', SidebarUI.tags.map((x) => '#' + x).join(' '))),
      h('button', { class: 'plain link', onclick: () => { SidebarUI.tags = []; App.render(['sidebar']); } }, t('Сбросить'))));
    filtered(files).forEach((f) => frag.append(fileRow(f)));
    if (!files.length) frag.append(hint('tag', t('Нет файлов со всеми выбранными тегами.')));
  } else if (section === 'files') {
    const head = h('div', { class: 'sec-head' }, h('span', null, t('Файлы')),
      h('span'));
    frag.append(head);
    if (SidebarUI.isNaming) frag.append(nameField());
    // A folder stays when its name matches (then all its files show) or when some file inside matches.
    const folders = SidebarUI.query
      ? Library.folders.filter((f) => Searcher.nameMatches(f.name, SidebarUI.query) || filtered(Library.filesIn(f.id)).length)
      : Library.folders;
    folders.forEach((f) => frag.append(folderRow(f)));
    filtered(Library.filesIn(null)).forEach((f) => frag.append(fileRow(f)));
    if (!Library.folders.length && !Library.filesIn(null).length && !SidebarUI.isNaming) {
      frag.append(hint('docPlus', t('Откройте файл (⌘O) или перетащите его в окно.')));
    }
  } else if (section === 'recent') {
    const items = Library.recents.filter((e) => Searcher.nameMatches(e.name, SidebarUI.query));
    if (items.length) {
      frag.append(h('div', { class: 'sec-head' }, h('span', null, t('Недавно открытые')),
        h('button', { class: 'plain link', onclick: () => Library.clearRecents() }, t('Очистить'))));
      items.forEach((e) => frag.append(historyRow(e)));
    }
    if (!Library.recents.length) frag.append(hint('clock', t('Здесь появятся файлы, которые вы открывали.')));
  } else {
    const items = filtered(Library.favorites);
    if (items.length) {
      frag.append(h('div', { class: 'sec-head' }, h('span', null, t('Избранное'))));
      items.forEach((f) => frag.append(fileRow(f)));
    }
    if (!Library.favorites.length) frag.append(hint('star', t('Добавьте файл в избранное через контекстное меню.')));
  }

  list.replaceChildren(frag);
  list.scrollTop = scroll;
  if (SidebarUI.focusName) {
    SidebarUI.focusName = false;
    const input = list.querySelector('input.inline-name');
    if (input) { input.focus(); input.setSelectionRange(input.value.length, input.value.length); }
  }
}

const hint = (iconName, text) => h('div', { class: 'hint' }, icon(iconName, 26), h('div', null, text));

function nameField() {
  return h('div', { class: 'name-field' },
    h('div', { class: 'name-row' }, icon('folder', 15),
      h('input', {
        class: 'inline-name', type: 'text', value: SidebarUI.newName, placeholder: t('Название папки'), spellcheck: false,
        oninput: (e) => { SidebarUI.newName = e.target.value; },
        onkeydown: (e) => {
          if (e.key === 'Enter') commitNew();
          else if (e.key === 'Escape') { SidebarUI.newName = ''; cancelNaming(); App.render(['sidebar']); }
        },
        onblur: () => { if (SidebarUI.isNaming && !SidebarUI.nameError) commitNew(); },
      })),
    SidebarUI.nameError ? h('div', { class: 'name-error' }, SidebarUI.nameError) : null);
}

function beginNaming() {
  SidebarUI.newName = '';
  SidebarUI.nameError = null;
  SidebarUI.isNaming = true;
  SidebarUI.focusName = true;
  App.ui.sidebarSection = 'files';
  App.render(['sidebar']);
}

function cancelNaming() {
  SidebarUI.isNaming = false;
  SidebarUI.newName = '';
  SidebarUI.nameError = null;
  SidebarUI.pendingMove = null;
}

function commitNew() {
  if (!SidebarUI.isNaming) return;
  const name = SidebarUI.newName.trim();
  if (!name) { cancelNaming(); App.render(['sidebar']); return; }
  if (Library.folderExists(name)) {
    SidebarUI.nameError = t('Папка с таким именем уже есть.');
    SidebarUI.focusName = true;
    App.render(['sidebar']);
    return;
  }
  const folder = Library.createFolder(name);
  if (SidebarUI.pendingMove) Library.move(SidebarUI.pendingMove, folder.id);
  cancelNaming();
  App.render(['sidebar']);
}

function commitRename(folder) {
  const name = SidebarUI.renameText.trim();
  if (name && name !== folder.name && !Library.folderExists(name)) Library.renameFolder(folder.id, name);
  SidebarUI.renamingID = null;
  App.render(['sidebar']);
}

function dropFile(fileID, folderID) {
  if (Library.file(fileID)) Library.move(fileID, folderID);
}

function folderRow(folder) {
  const all = Library.filesIn(folder.id);
  const files = SidebarUI.query && Searcher.nameMatches(folder.name, SidebarUI.query) ? all : filtered(all);
  const wrap = h('div', { class: 'folder' });
  const expanded = folder.isExpanded;

  let head;
  if (SidebarUI.renamingID === folder.id) {
    head = h('div', { class: 'folder-head' }, icon(expanded ? 'down' : 'right', 12), icon('folder', 15),
      h('input', {
        class: 'inline-name', type: 'text', value: SidebarUI.renameText, spellcheck: false,
        oninput: (e) => { SidebarUI.renameText = e.target.value; },
        onkeydown: (e) => {
          if (e.key === 'Enter') commitRename(folder);
          else if (e.key === 'Escape') { SidebarUI.renamingID = null; App.render(['sidebar']); }
        },
        onblur: () => { if (SidebarUI.renamingID === folder.id) commitRename(folder); },
      }));
    SidebarUI.focusName = true;
  } else {
    head = h('div', {
      class: 'folder-head' + (SidebarUI.targetedFolder === folder.id ? ' targeted' : ''),
      onclick: () => Library.setExpanded(folder.id, !folder.isExpanded),
      oncontextmenu: (e) => Menus.at(e, [
        { label: t('Переименовать'), action: () => { SidebarUI.renameText = folder.name; SidebarUI.renamingID = folder.id; App.render(['sidebar']); } },
        ...(folder.sourcePath ? [
          { label: t('Показать в проводнике'), action: () => window.api.reveal(folder.sourcePath) },
          { label: t('Обновить из папки'), action: () => App.importFolder(folder.sourcePath, folder.id) },
        ] : []),
        { label: t('Удалить папку'), danger: true, action: () => Library.deleteFolder(folder.id) },
      ]),
      ondragover: (e) => {
        if (!e.dataTransfer.types.includes('application/x-grizzly-file')) return;
        e.preventDefault();
        e.currentTarget.classList.add('targeted');
      },
      ondragleave: (e) => e.currentTarget.classList.remove('targeted'),
      ondrop: (e) => {
        const id = e.dataTransfer.getData('application/x-grizzly-file');
        if (!id) return;
        e.preventDefault();
        e.stopPropagation();
        dropFile(id, folder.id);
      },
    }, icon(expanded ? 'down' : 'right', 12), icon('folder', 15),
    h('span', { class: 'grow ellipsis' }, folder.name), h('span', { class: 'count' }, files.length));
  }
  wrap.append(head);
  if (expanded) {
    const body = h('div', { class: 'folder-body' }, files.map((f) => fileRow(f)));
    if (!files.length && !SidebarUI.query) body.append(h('div', { class: 'muted small pad' }, t('Пусто. Перетащите сюда файл.')));
    wrap.append(body);
  }
  return wrap;
}

function fileRow(file, showsDate = false) {
  const missing = Library.isMissing(file.id);
  return h('div', {
    class: 'file' + (App.selectedFileID === file.id ? ' selected' : '') + (missing ? ' missing' : ''),
    draggable: true,
    title: file.path,
    ondragstart: (e) => {
      e.dataTransfer.setData('application/x-grizzly-file', file.id);
      e.dataTransfer.effectAllowed = 'move';
    },
    onclick: (e) => {
      App.selectedFileID = file.id;
      App.openLibraryFile(file.id, e.altKey);
      document.querySelectorAll('.file.selected').forEach((n) => n.classList.remove('selected'));
      e.currentTarget.classList.add('selected');
    },
    oncontextmenu: (e) => Menus.at(e, fileMenu(file)),
  },
  missing ? icon('warning', 15) : typeIcon(file.type, 15),
  h('span', { class: 'grow ellipsis' }, file.name),
  showsDate && file.lastOpened ? h('span', { class: 'small muted' }, relativeTime(file.lastOpened)) : null,
  file.isFavorite ? h('span', { class: 'fav' }, icon('star', 12, true)) : null);
}

function historyRow(entry) {
  const known = Library.fileByPath(entry.path);
  const missing = !!known && Library.isMissing(known.id);
  return h('div', {
    class: 'file' + (missing ? ' missing' : ''),
    title: entry.path,
    onclick: (e) => App.openHistory(entry, e.altKey),
    oncontextmenu: (e) => Menus.at(e, [
      { label: t('Открыть'), action: () => App.openHistory(entry) },
      { label: t('Открыть справа'), action: () => App.openHistory(entry, true) },
      { label: t('Показать в проводнике'), action: () => window.api.reveal(entry.path) },
      { separator: true },
      { label: t('Убрать из истории'), danger: true, action: () => Library.removeFromHistory(entry.path) },
    ]),
  },
  missing ? icon('warning', 15) : typeIcon(fileTypeOf(entry.path), 15),
  h('span', { class: 'grow ellipsis' }, entry.name),
  h('span', { class: 'small muted' }, relativeTime(entry.date)));
}

function fileMenu(file) {
  return [
    { label: t('Открыть'), action: () => App.openLibraryFile(file.id) },
    { label: t('Открыть справа'), action: () => App.openLibraryFile(file.id, true) },
    { label: t('Быстрый просмотр'), action: () => quickLook(file.id) },
    { label: file.isFavorite ? t('Убрать из избранного') : t('Добавить в избранное'), action: () => { Library.toggleFavorite(file.id); notify(file.isFavorite ? t('Убрано из избранного.') : t('Добавлено в избранное.'), 'star'); } },
    {
      label: t('Теги'),
      submenu: [
        ...Library.allTags.map((tag) => ({ label: (Library.hasTag(file.id, tag) ? '✓ ' : '    ') + '#' + tag, action: () => { notify(Library.hasTag(file.id, tag) ? t('Тег #%@ убран.', tag) : t('Тег #%@ добавлен.', tag), 'tag'); Library.toggleTag(file.id, tag); } })),
        ...(Library.allTags.length ? [{ separator: true }] : []),
        { label: t('Новый тег…'), action: () => newTag(file.id) },
      ],
    },
    {
      label: t('Переместить в…'),
      submenu: [
        ...Library.folders.map((f) => ({ label: f.name, disabled: file.folderID === f.id, action: () => Library.move(file.id, f.id) })),
        ...(file.folderID ? [{ separator: true }, { label: t('Вне папки'), action: () => Library.move(file.id, null) }] : []),
        { separator: true },
        { label: t('Новая папка…'), action: () => { SidebarUI.pendingMove = file.id; beginNaming(); } },
      ],
    },
    { separator: true },
    { label: t('Показать в проводнике'), action: () => window.api.reveal(file.path) },
    { label: t('Убрать из библиотеки'), danger: true, action: () => App.removeFromLibrary(file.id) },
  ];
}

function applySidebarVisibility() {
  document.body.classList.toggle('no-sidebar', !App.ui.sidebarVisible);
}

function initResizer() {
  const saved = Number(localStorage.getItem('grizzly.sidebarW') || localStorage.getItem('mdreader.sidebarW'));
  setSidebarWidth(saved >= 190 && saved <= 420 ? saved : 240);
  const bar = $('resizer');
  bar.addEventListener('pointerdown', (e) => {
    bar.setPointerCapture(e.pointerId);
    const move = (ev) => setSidebarWidth(Math.min(420, Math.max(190, ev.clientX)));
    const up = () => {
      bar.removeEventListener('pointermove', move);
      bar.removeEventListener('pointerup', up);
      try { localStorage.setItem('grizzly.sidebarW', String(parseInt(getComputedStyle(document.documentElement).getPropertyValue('--sidebar-w'), 10))); } catch { /* ignore */ }
    };
    bar.addEventListener('pointermove', move);
    bar.addEventListener('pointerup', up);
  });
}

function setSidebarWidth(px) { document.documentElement.style.setProperty('--sidebar-w', px + 'px'); }

// ---- Main area: tabs, find bar, panes -------------------------------------

const scrollMemory = new Map();
let lastScrollToken = null;
let lastFindFocusToken = 0;
let findBarEl = null;
let findDebounce = null;

function buildMainFrame() {
  const input = h('input', {
    id: 'find-input', type: 'text', placeholder: t('Найти в документе'), spellcheck: false,
    oninput: (e) => {
      clearTimeout(findDebounce);
      const value = e.target.value;
      findDebounce = setTimeout(() => App.setQuery(value), 60);
    },
    onkeydown: (e) => {
      if (e.key === 'Enter') { clearTimeout(findDebounce); App.findQuery === e.target.value || (App.findQuery = e.target.value, App.recomputeMatches(true)); App.stepMatch(e.shiftKey ? -1 : 1); }
      else if (e.key === 'Escape') App.hideFind();
    },
  });
  findBarEl = h('div', { id: 'findbar', hidden: true },
    icon('search', 15), input,
    h('span', { id: 'find-count' }),
    h('button', { class: 'plain', title: t('Предыдущее совпадение (⌘⇧G)'), onclick: () => App.stepMatch(-1) }, icon('up', 16)),
    h('button', { class: 'plain', title: t('Следующее совпадение (⌘G)'), onclick: () => App.stepMatch(1) }, icon('down', 16)),
    h('button', { class: 'plain link', onclick: () => App.hideFind() }, t('Готово')));

  $('main').replaceChildren(
    h('div', { id: 'empty', hidden: true }),
    h('div', { id: 'tabs' }),
    findBarEl,
    h('div', { id: 'panes' }));

  // Links inside rendered Markdown open in the default browser.
  if ($('main').dataset.linksBound) return;
  $('main').dataset.linksBound = '1';
  $('main').addEventListener('click', (e) => {
    const tag = e.target.closest('.hashtag');
    if (tag && !window.getSelection().toString()) { showTag(tag.dataset.tag); return; }
    const a = e.target.closest('a[data-url]');
    if (!a) return;
    e.preventDefault();
    window.api.openExternal(a.dataset.url);
  });
}

function renderMain() {
  const empty = App.documents.length === 0;
  $('empty').hidden = !empty;
  $('tabs').hidden = empty;
  $('panes').hidden = empty;
  if (empty) {
    renderEmpty();
    findBarEl.hidden = true;
    return;
  }
  renderTabs();
  renderFind();
  renderPanes();
}

function renderEmpty() {
  $('empty').replaceChildren(
    h('div', { class: 'empty-card' },
      icon('docSearch', 46),
      h('div', { class: 'empty-title' }, t('Откройте файл')),
      h('div', { class: 'muted center pre' }, t('Перетащите Markdown или текстовый файл в окно\nили нажмите ⌘O.')),
      h('button', { class: 'btn', onclick: () => openFiles() }, t('Открыть…'))));
}

function renderFind() {
  findBarEl.hidden = !App.isFindVisible;
  if (!App.isFindVisible) return;
  const input = $('find-input');
  if (document.activeElement !== input && input.value !== App.findQuery) input.value = App.findQuery;
  const count = $('find-count');
  if (!App.findQuery) count.textContent = '';
  else if (!App.matches.length) count.textContent = t('Нет совпадений');
  else count.textContent = t('%d из %d', App.matchIndex + 1, App.matches.length);
  if (App.findFocusToken !== lastFindFocusToken) {
    lastFindFocusToken = App.findFocusToken;
    input.focus();
    input.select();
  }
}

function renderTabs() {
  const bar = $('tabs');
  const scroll = bar.scrollLeft;
  bar.replaceChildren(...App.documents.map(tabItem));
  bar.scrollLeft = scroll;
}

function tabItem(doc) {
  const isLeft = App.selection === doc.id;
  const isRight = App.isSplit && App.rightSelection === doc.id;
  const isFocused = !!App.current && App.current.id === doc.id;
  return h('div', {
    class: 'tab' + (isFocused ? ' focused' : isLeft || isRight ? ' shown' : ''),
    title: doc.path,
    onclick: (e) => App.selectTab(doc.id, e.altKey),
    onauxclick: (e) => { if (e.button === 1) App.close(doc.id); },
    oncontextmenu: (e) => Menus.at(e, [
      { label: t('Открыть справа'), action: () => App.selectTab(doc.id, true) },
      { separator: true },
      { label: t('Закрыть'), action: () => App.close(doc.id) },
      { label: t('Закрыть остальные'), disabled: App.documents.length < 2, action: () => App.closeOthers(doc.id) },
    ]),
  },
  typeIcon(doc.type, 14),
  h('span', { class: 'tab-name ellipsis' }, doc.name),
  App.isDirty(doc) ? h('span', { class: 'tab-dirty', title: t('Есть несохранённые изменения.') }, '●') : null,
  isRight ? h('span', { class: 'tab-right', title: t('Показан в правой панели') }, icon('rightPane', 12)) : null,
  h('button', {
    class: 'tab-close plain', title: t('Закрыть вкладку'),
    onclick: (e) => { e.stopPropagation(); App.close(doc.id); },
  }, icon('x', 11)));
}

function renderPanes() {
  const panes = $('panes');
  rememberEditors();
  // Remember where each pane was scrolled before it is rebuilt.
  panes.querySelectorAll('.scroll').forEach((s) => { if (s.dataset.key) scrollMemory.set(s.dataset.key, s.scrollTop); });

  const target = App.scrollTarget;
  const fresh = target && target.token !== lastScrollToken;
  const els = [buildPane('left', fresh ? target : null)];
  if (App.isSplit) els.push(h('div', { class: 'pane-divider' }), buildPane('right', fresh ? target : null));
  panes.replaceChildren(...els);

  for (const paneEl of panes.querySelectorAll('.pane')) {
    const scroller = paneEl.querySelector('.scroll');
    if (!scroller) continue;
    const saved = scrollMemory.get(scroller.dataset.key);
    if (saved != null) scroller.scrollTop = saved;
  }

  if (fresh) {
    lastScrollToken = target.token;
    const pane = App.isSplit ? App.focusedPane : 'left';
    const scroller = panes.querySelector(`.pane[data-pane="${pane}"] .scroll`);
    const area = panes.querySelector(`.pane[data-pane="${pane}"] textarea.editor-text`);
    const mark = area && area.parentElement.querySelector('.editor-back mark.current');
    if (mark) {
      area.scrollTop = Math.max(0, mark.offsetTop - area.clientHeight / 2);
      area.parentElement.querySelector('.editor-back').scrollTop = area.scrollTop;
    }
    if (scroller) {
      const el = (target.match && scroller.querySelector('mark.current')) || scroller.querySelector(`[data-unit="${target.unit}"]`);
      if (el) el.scrollIntoView({ block: 'center' });
    }
  }
}

function updatePaneFocus() {
  document.querySelectorAll('.pane').forEach((p) => {
    const header = p.querySelector('.pane-header');
    if (header) header.classList.toggle('focused', App.focusedPane === p.dataset.pane);
  });
}

function buildPane(pane, target) {
  const doc = App.doc(pane);
  const el = h('div', { class: 'pane', dataset: { pane }, onpointerdown: () => App.focus(pane) });
  if (App.isSplit) el.append(paneHeader(pane, doc));
  if (doc) {
    if (App.changedOnDisk.has(doc.id)) el.append(changedBanner(doc));
    el.append(buildContent(doc, pane, target), statusBar(doc));
  } else {
    el.append(placeholder(pane));
  }
  return el;
}

function paneHeader(pane, doc) {
  const trigger = h('button', {
    class: 'pane-pick',
    onclick: (e) => Menus.below(e.currentTarget, [
      ...App.documents.map((d) => ({ label: d.name, action: () => App.assign(d.id, pane) })),
      { separator: true },
      { label: t('Открыть файл…'), action: () => { App.focus(pane); openFiles(); } },
    ]),
  }, doc ? typeIcon(doc.type, 14) : icon('doc', 14), h('span', { class: 'ellipsis' }, doc ? doc.name : t('Выберите файл')), icon('down', 12));
  return h('div', { class: 'pane-header' + (App.focusedPane === pane ? ' focused' : '') },
    trigger, h('span', { class: 'grow' }),
    pane === 'right' ? h('button', { class: 'plain', title: t('Закрыть правую панель'), onclick: () => App.toggleSplit() }, icon('x', 14)) : null);
}

function changedBanner(doc) {
  return h('div', { class: 'banner' },
    icon('refresh', 16), h('span', { class: 'grow' }, t('Файл изменён на диске.')),
    h('button', { class: 'plain link', onclick: () => App.refresh(doc.id) }, t('Обновить  ⌘R')),
    h('button', { class: 'plain link', onclick: () => App.ignoreChange(doc.id) }, t('Не сейчас')));
}

function placeholder(pane) {
  return h('div', { class: 'placeholder' },
    icon('rightPane', 32),
    h('div', null, t('Выберите файл для этой панели')),
    h('div', { class: 'small muted center' }, t('Откройте его из списка слева с зажатым ⌥ или выберите во вкладках.')),
    h('button', { class: 'btn', onclick: () => { App.focus(pane); openFiles(); } }, t('Открыть файл…')));
}

function statusBar(doc) {
  return h('div', { class: 'status' },
    h('span', null, `${TYPE_TITLES[doc.type]} · ${doc.encoding}`),
    h('span', null, t('%lld строк · %lld слов', doc.lines.length, doc.wordCount)));
}

// ---- Content ----------------------------------------------------------------

/** Every pane paints the query; only the focused one marks the current hit. */
function highlightFor(pane) {
  if (!App.isFindVisible || !App.findQuery) return null;
  const isTarget = !App.isSplit || App.focusedPane === pane;
  return { query: App.findQuery, current: isTarget ? App.currentMatch : null };
}

const FIRST_CHUNK = 2500;
const CHUNK = 1500;

/** Appends rows to `parent`: the first batch at once, the rest in the background. */
function fillRows(parent, scroller, total, makeRow, upTo) {
  let next = 0;
  const batch = (limit) => {
    const frag = document.createDocumentFragment();
    for (; next < Math.min(total, limit); next++) frag.append(makeRow(next));
    parent.append(frag);
  };
  batch(Math.max(FIRST_CHUNK, upTo + 1));
  const wanted = scrollMemory.get(scroller.dataset.key);
  const more = () => {
    if (next >= total || !scroller.isConnected) return;
    batch(next + CHUNK);
    if (wanted != null && scroller.scrollTop < wanted) scroller.scrollTop = wanted;
    setTimeout(more, 0);
  };
  if (next < total) setTimeout(more, 0);
}

function buildContent(doc, pane, target) {
  const size = Prefs.values.fontSize;
  if (App.mode === 'edit') return editorView(doc, pane, size - 2);
  const hl = highlightFor(pane);
  const scroller = h('div', { class: 'scroll', dataset: { key: `${doc.id}:${App.mode}` } });
  const upTo = target ? target.unit : 0;
  const isTargetPane = !App.isSplit || App.focusedPane === pane;
  const unitHint = isTargetPane ? upTo : 0;

  if (App.mode === 'source') {
    scroller.append(sourceView(doc, scroller, size - 2, hl, unitHint));
  } else if (doc.csv) {
    scroller.append(csvView(doc, scroller, size - 1, hl, unitHint));
  } else if (doc.type === 'markdown') {
    scroller.append(h('div', { class: 'reading' }, markdownView(doc.blocks, size, hl)));
  } else {
    const wrap = h('div', { class: 'reading plain-text' });
    const mono = Syntax.hasHighlighting(doc.type);
    wrap.style.fontFamily = mono ? 'var(--mono-font)' : 'var(--reading-font)';
    wrap.style.fontSize = size + 'px';
    wrap.style.lineHeight = '1.55';
    scroller.append(wrap);
    fillRows(wrap, scroller, doc.lines.length, (i) => {
      const row = h('div', { class: 'line', dataset: { unit: i } });
      if (doc.lines[i]) Syntax.render(doc.lines[i], doc.type, row, doc.syntaxStates.length ? doc.syntaxStates[i] : 0);
      else row.append(' ');
      Searcher.paint(row, hl, i, 0);
      if (PROSE.includes(doc.type)) paintTags(row);
      return row;
    }, unitHint);
  }
  return scroller;
}

/** Plain-text editor. The draft lives in App.drafts, so re-rendering the pane never loses typed text. */
const editorMemory = new Map(); // document id -> {start, end, top, focused}

function rememberEditors() {
  document.querySelectorAll('textarea.editor-text').forEach((ta) => {
    editorMemory.set(ta.dataset.doc, {
      start: ta.selectionStart, end: ta.selectionEnd, top: ta.scrollTop, focused: document.activeElement === ta,
    });
  });
}

// Spelling is checked in prose (PROSE_TYPES); in source code and data files every identifier would be an "error".

/** Undo / redo stacks per document: the browser merges a whole run of typing into one step, so the editor keeps its own. */
const editorHistory = new Map(); // document id -> {undo, redo, last, sel, kind, space, time}
function historyFor(doc, value) {
  let hst = editorHistory.get(doc.id);
  if (!hst) { hst = { undo: [], redo: [], kind: 0, space: false, time: 0, before: [0, 0] }; editorHistory.set(doc.id, hst); }
  hst.last = value;
  return hst;
}

function editorView(doc, pane, size) {
  const area = h('textarea', {
    class: 'editor-text', dataset: { doc: doc.id }, wrap: 'soft', 'aria-label': doc.name,
    spellcheck: Prefs.values.spellCheck && PROSE_TYPES.includes(doc.type),
  });
  area.style.fontSize = size + 'px';
  area.value = App.textFor(doc);
  // Find hits are painted on a copy of the text behind the (transparent) textarea.
  const back = h('div', { class: 'editor-back', 'aria-hidden': 'true' });
  back.style.fontSize = size + 'px';
  const paintBack = () => {
    const hl = highlightFor(pane);
    const prose = PROSE.includes(doc.type);
    const text = area.value;
    back.replaceChildren();
    const inner = h('div', { class: 'editor-back-inner' });
    back.append(inner);
    if (!hl && !(prose && text.includes('#'))) { inner.append(text + '\n'); return; }
    text.split('\n').forEach((line, i) => {
      const row = h('span', { class: 'eb-line' }, line);
      if (hl) Searcher.paint(row, hl, i, 0);
      if (prose) paintTags(row, 'tag-back');
      inner.append(row, '\n');
    });
  };
  const syncScroll = () => { back.scrollTop = area.scrollTop; };

  // Undo and Save, in the same style as the other buttons; saving and similar events are announced by notifications.
  const revert = h('button', {
    class: 'btn sm', title: t('Отменить последний шаг (⌘Z)'),
    onclick: () => undo(),
  }, icon('undo', 14), t('Отменить'));
  const save = h('button', { class: 'btn sm', title: t('Сохранить (⌘S)'), onclick: () => App.save(doc.id) }, icon('download', 14), t('Сохранить'));
  const bar = h('div', { class: 'edit-bar' }, h('span', { class: 'grow' }), revert, save);
  const hst = historyFor(doc, area.value);
  const sync = () => { revert.disabled = !hst.undo.length; save.disabled = !App.isDirty(doc); };
  // A new step starts at every word, after a pause, when switching between typing and deleting, and for paste or Return.
  const recordStep = () => {
    const before = hst.last;
    if (area.value === before) return;
    // What changed, read from the text itself: the common start and end of the old and new text.
    let prefix = 0;
    while (prefix < before.length && prefix < area.value.length && before[prefix] === area.value[prefix]) prefix++;
    let suffix = 0;
    while (suffix < before.length - prefix && suffix < area.value.length - prefix
      && before[before.length - 1 - suffix] === area.value[area.value.length - 1 - suffix]) suffix++;
    const removed = before.length - prefix - suffix;
    const added = area.value.length - prefix - suffix;
    const data = area.value.slice(prefix, prefix + added);
    const isSpace = added === 1 && /[ \t]/.test(data);
    const kind = added === 1 && removed === 0 && data !== '\n' ? 1 : (added === 0 && removed > 0 ? 2 : 3);
    const now = Date.now();
    const fresh = kind !== hst.kind || kind === 3 || (kind === 1 && hst.space && !isSpace) || now - hst.time > 1000 || !hst.undo.length;
    if (fresh) { hst.undo.push({ value: before, start: prefix + removed, end: prefix + removed }); if (hst.undo.length > 500) hst.undo.shift(); }
    hst.redo.length = 0;
    hst.kind = kind; hst.space = isSpace; hst.time = now; hst.last = area.value;
  };
  const applyHistory = (from, to) => {
    const snap = from.pop();
    if (!snap) return;
    to.push({ value: area.value, start: area.selectionStart, end: area.selectionEnd });
    area.value = snap.value;
    area.setSelectionRange(snap.start, snap.end);
    hst.last = area.value; hst.kind = 0; hst.time = 0;
    App.setDraft(doc, area.value);
    sync(); paintBack(); renderFind();
    area.focus();
  };
  const undo = () => applyHistory(hst.undo, hst.redo);
  const redo = () => applyHistory(hst.redo, hst.undo);
  sync();

  // Typing `#` or `#wo` lists the known tags under the caret; Up / Down choose, Enter or Tab inserts, Esc closes.
  const suggest = h('div', { class: 'tag-suggest', hidden: true });
  let items = [];
  let chosen = 0;
  let from = 0;
  const closeSuggest = () => { suggest.hidden = true; items = []; };
  const paintSuggest = () => suggest.replaceChildren(...items.map((tag, i) => h('div', {
    class: 'ts-item' + (i === chosen ? ' on' : ''),
    onmousedown: (e) => { e.preventDefault(); chosen = i; acceptSuggest(); },
  }, '#' + tag)));
  const acceptSuggest = () => {
    if (!items.length) return;
    const tag = items[chosen];
    area.setSelectionRange(from, area.selectionStart);
    document.execCommand('insertText', false, tag);
    closeSuggest();
  };
  const updateSuggest = (ev) => {
    if (!PROSE.includes(doc.type) || /^delete/.test((ev && ev.inputType) || 'x') || area.selectionStart !== area.selectionEnd) { closeSuggest(); return; }
    const pos = area.selectionStart;
    const m = new RegExp('(?<![\\p{L}\\p{N}_#&/=:])#([' + TAG_BODY + ']*)$', 'u').exec(area.value.slice(0, pos));
    if (!m) { closeSuggest(); return; }
    const typed = m[1].toLowerCase();
    items = [...new Set([...Library.allTags, ...Library.extractTags(area.value)])]
      .filter((x) => x.toLowerCase().startsWith(typed) && x.toLowerCase() !== typed)
      .sort((a, b) => collator.compare(a, b)).slice(0, 8);
    if (!items.length) { closeSuggest(); return; }
    from = pos - typed.length;
    chosen = 0;
    paintSuggest();
    suggest.hidden = false;
    // The caret position is read from the copy of the text behind the textarea (one character before the caret).
    const walker = document.createTreeWalker(back, NodeFilter.SHOW_TEXT);
    let seen = 0;
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (seen + n.nodeValue.length >= pos) {
        const range = document.createRange();
        range.setStart(n, Math.max(0, pos - seen - 1));
        range.setEnd(n, pos - seen);
        const r = range.getBoundingClientRect();
        suggest.style.left = Math.min(r.right, innerWidth - 220) + 'px';
        suggest.style.top = Math.min(r.bottom + 2, innerHeight - 200) + 'px';
        break;
      }
      seen += n.nodeValue.length;
    }
  };

  area.addEventListener('input', (e) => {
    recordStep();
    App.setDraft(doc, area.value);
    sync();
    paintBack();
    if (App.isFindVisible && App.findQuery) renderFind();
    updateSuggest(e);
  });
  area.addEventListener('blur', closeSuggest);
  area.addEventListener('keydown', (e) => {
    if (suggest.hidden) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      chosen = (chosen + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      paintSuggest();
    } else if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); e.stopImmediatePropagation(); acceptSuggest(); }
    else if (e.key === 'Escape') { e.stopPropagation(); closeSuggest(); }
  }, true);
  area.addEventListener('scroll', syncScroll);
  area.addEventListener('keydown', (e) => {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && !e.altKey && e.key.toLowerCase() === 'z') { e.preventDefault(); if (e.shiftKey) redo(); else undo(); return; }
    if (mod && !e.altKey && !e.shiftKey && e.key.toLowerCase() === 'y') { e.preventDefault(); redo(); return; }
    if (e.key === 'Tab' && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey) {
      e.preventDefault();
      document.execCommand('insertText', false, '\t');
    }
  });
  area.addEventListener('pointerdown', () => App.focus(pane));

  const saved = editorMemory.get(doc.id);
  if (saved) {
    // The textarea is not in the document yet; restore once it is.
    setTimeout(() => {
      if (!area.isConnected) return;
      area.setSelectionRange(saved.start, saved.end);
      area.scrollTop = saved.top;
      syncScroll();
      if (saved.focused) area.focus();
    }, 0);
  } else if (!App.isSplit || App.focusedPane === pane) {
    setTimeout(() => { if (area.isConnected) area.focus(); }, 0);
  }
  paintBack();
  return h('div', { class: 'editor' }, bar, h('div', { class: 'editor-wrap' }, back, area, suggest));
}

function sourceView(doc, scroller, size, hl, upTo) {
  const marked = new Set(Library.bookmarks(doc.libraryID));
  const showNumbers = Prefs.values.showLineNumbers;
  const box = h('div', { class: 'source' + (showNumbers ? '' : ' no-gutter') });
  box.style.fontSize = size + 'px';
  fillRows(box, scroller, doc.lines.length, (i) => {
    const code = h('div', { class: 'code' });
    if (doc.lines[i]) Syntax.render(doc.lines[i], doc.type, code, doc.syntaxStates.length ? doc.syntaxStates[i] : 0);
    else code.append('​');
    if (doc.type === 'markdown' && doc.lines[i].startsWith('#')) code.classList.add('md-head');
    Searcher.paint(code, hl, i, 0);
    if (PROSE.includes(doc.type)) paintTags(code);
    const row = h('div', { class: 'row', dataset: { unit: i } });
    if (showNumbers) {
      const n = i + 1;
      row.append(h('div', {
        class: 'gutter' + (marked.has(n) ? ' bookmarked' : ''),
        dataset: { line: n },
        title: marked.has(n) ? t('Убрать закладку') : t('Поставить закладку'),
        onclick: () => { Library.toggleBookmark(doc.libraryID, n); syncBookmarks(); notify(marked.has(n) ? t('Закладка убрана.') : t('Закладка добавлена: строка %lld.', n), 'bookmark'); },
      }, h('span', null, n)));
    }
    row.append(code);
    return row;
  }, upTo);
  return box;
}

function csvView(doc, scroller, size, hl, upTo) {
  const table = doc.csv;
  const charWidth = size * 0.62;
  const box = h('div', { class: 'csv' });
  box.style.fontSize = size + 'px';
  const q = hl ? hl.query : '';
  fillRows(box, scroller, table.rows.length, (index) => {
    const row = table.rows[index];
    const hits = q ? Searcher.ranges(q, row.line).map((r) => r[1]) : [];
    const el = h('div', { class: 'csv-row' + (index === 0 ? ' head' : index % 2 === 0 ? ' alt' : ''), dataset: { unit: index } });
    table.widths.forEach((width, col) => {
      const text = col < row.cells.length ? row.cells[col] : '';
      const offset = col < row.starts.length ? hits.filter((e) => e <= row.starts[col]).length : 0;
      const cell = h('div', { class: 'csv-cell' }, text || ' ');
      cell.style.width = width * charWidth + 8 + 'px';
      Searcher.paint(cell, hl, index, offset);
      el.append(cell);
    });
    return el;
  }, upTo);
  return box;
}

function markdownView(blocks, size, hl) {
  const box = h('div', { class: 'md' });
  box.style.fontSize = size + 'px';
  box.style.setProperty('--gap', size * 0.9 + 'px');
  const hs = Prefs.values.headingSpacing;
  const query = hl ? hl.query : '';

  const inline = (parent, text, unit, offset) => {
    inlineToDom(parseInline(text), parent);
    Searcher.paint(parent, hl, unit, offset);
    paintTags(parent);
    return parent;
  };

  blocks.forEach((block, unit) => {
    const offsets = Searcher.offsets(block, query);
    const wrap = h('div', { class: 'blk ' + block.type, dataset: { unit } });
    switch (block.type) {
      case 'heading': {
        const scale = [1.9, 1.55, 1.3, 1.15, 1.05, 1.0][block.level - 1];
        wrap.style.fontSize = size * scale + 'px';
        wrap.style.paddingTop = size * (block.level <= 2 ? 0.5 : 0.25) * hs + 'px';
        wrap.style.paddingBottom = size * 0.15 * hs + 'px';
        inline(wrap, block.text, unit, offsets[0]);
        break;
      }
      case 'paragraph': inline(wrap, block.text, unit, offsets[0]); break;
      case 'bullets':
      case 'numbered':
        block.items.forEach((item, i) => {
          wrap.append(h('div', { class: 'li' },
            h('span', { class: 'marker' }, block.type === 'bullets' ? '•' : `${i + 1}.`),
            inline(h('span', { class: 'li-text' }), item, unit, offsets[i])));
        });
        break;
      case 'code': {
        const lang = fenceType(block.lang);
        const pre = h('pre', null, lang ? null : (block.code || ' '));
        if (lang) Syntax.renderBlock(block.code || ' ', lang, pre);
        Searcher.paint(pre, hl, unit, offsets[0]);
        paintTags(pre);
        wrap.append(pre);
        break;
      }
      case 'quote':
        wrap.append(h('div', { class: 'bar' }), inline(h('div', { class: 'quote-text' }), block.text, unit, offsets[0]));
        break;
      case 'rule': wrap.append(h('hr')); break;
      case 'table': {
        // Cell order matches Searcher.segments: header first, then rows left to right.
        const rowStarts = block.rows.map((_, r) => block.header.length + block.rows.slice(0, r).reduce((n, row) => n + row.length, 0));
        const head = h('tr', null, block.header.map((c, i) => inline(h('th'), c, unit, offsets[i])));
        const body = block.rows.map((row, r) => h('tr', null, row.map((c, i) => inline(h('td'), c, unit, offsets[rowStarts[r] + i]))));
        wrap.append(h('table', null, h('thead', null, head), h('tbody', null, body)));
        break;
      }
    }
    box.append(wrap);
  });
  return box;
}

// ---- Dialogs ----------------------------------------------------------------

function renderErrorDialog() {
  const root = $('overlay-root');
  root.querySelectorAll('.modal-error').forEach((n) => n.remove());
  if (!App.errorMessage) return;
  const close = () => { App.errorMessage = null; renderErrorDialog(); };
  root.append(h('div', { class: 'modal-back modal-error', onmousedown: (e) => { if (e.target === e.currentTarget) close(); } },
    h('div', { class: 'dialog small' },
      h('div', { class: 'dialog-title' }, t('Ошибка')),
      h('div', { class: 'dialog-body' }, App.errorMessage),
      h('div', { class: 'dialog-actions' }, h('button', { class: 'btn primary', autofocus: true, onclick: close }, 'OK')))));
}

// ---- Quick look: preview a file without opening it -----------------------------

const PREVIEW_LIMIT = 200000;

function closeQuickLook() { document.querySelectorAll('.modal-preview').forEach((n) => n.remove()); }

async function quickLook(id) {
  const file = Library.file(id);
  if (!file) return;
  closeQuickLook();
  const res = await window.api.readFile(file.path);
  if (!res.ok) { Library.setMissing(id, true); App.errorMessage = t('Не удалось открыть «%@».').replace('%@', file.name); renderErrorDialog(); return; }
  const text = res.text.length > PREVIEW_LIMIT ? res.text.slice(0, PREVIEW_LIMIT) + '\n…' : res.text;
  $('overlay-root').append(h('div', { class: 'modal-back modal-preview', onmousedown: (e) => { if (e.target === e.currentTarget) closeQuickLook(); } },
    h('div', { class: 'dialog preview' },
      h('div', { class: 'dialog-head' }, h('div', { class: 'dialog-title ellipsis' }, file.name),
        h('button', { class: 'plain', onclick: closeQuickLook }, icon('x', 16))),
      h('pre', { class: 'preview-body' }, text))));
}

let settingsRefresh = null;

/** Switches the interface language on the fly: the main process rebuilds the menu, the renderer rebuilds its labels. */
async function changeLanguage(choice) {
  setLocale(await window.api.setLanguage(choice));
  languagePref = choice;
  document.title = 'Grizzly';
  $('overlay-root').querySelector('.modal-settings')?.remove();
  settingsRefresh = null;
  buildSidebarFrame();
  buildMainFrame();
  applySidebarVisibility();
  App.render(['all']);
  openSettings();
}

const SETTINGS_PANES = [
  ['appearance', 'Оформление', 'palette'],
  ['text', 'Текст', 'type'],
  ['syntax', 'Подсветка синтаксиса', 'code'],
  ['files', 'Файлы', 'doc'],
  ['language', 'Язык', 'globe'],
  ['updates', 'Обновления', 'refresh'],
];
let settingsPane = 'appearance';

const PROGRAMMING_TYPES = ['python', 'swift', 'cpp', 'csharp', 'javascript', 'typescript', 'css', 'php'];
const MARKUP_TYPES = ['json', 'yaml', 'config', 'xml', 'html', 'tex', 'log'];

function openSettings() {
  const root = $('overlay-root');
  if (root.querySelector('.modal-settings')) return;
  const P = Prefs.values;

  const close = () => {
    root.querySelector('.modal-settings')?.remove();
    settingsRefresh = null;
  };

  const card = (title, ...kids) => h('div', { class: 'card' }, h('div', { class: 'card-title' }, t(title)), ...kids);
  const row = (label, ...kids) => h('div', { class: 'srow' }, h('div', { class: 'slabel' }, t(label)), ...kids);

  const appearance = h('div', { class: 'seg wide' });
  const language = h('div', { class: 'seg wide' });
  const tiles = h('div', { class: 'tiles' });
  const sizeLabel = h('span', { class: 'val' });
  const spacingLabel = h('span', { class: 'val' });
  const previews = [h('div', { class: 'preview' }), h('div', { class: 'preview' })];
  const nav = h('div', { class: 'snav' });
  const body = h('div', { class: 'dialog-scroll' });

  const paintAppearance = () => appearance.replaceChildren(...[['system', 'Как в системе'], ['light', 'Светлая'], ['dark', 'Тёмная']].map(([id, label]) =>
    h('button', { class: Prefs.values.appearance === id ? 'on' : '', onclick: () => Prefs.set({ appearance: id }) }, t(label))));

  const paintLanguage = () => language.replaceChildren(...[['auto', t('Как в системе')], ['ru', 'Русский'], ['en', 'English']].map(([id, label]) =>
    h('button', { class: languagePref === id ? 'on' : '', onclick: () => changeLanguage(id) }, label)));

  const paintTiles = () => tiles.replaceChildren(...THEME_SETS.map((set) => {
    const th = themeVariant(set, Prefs.wantsDark);
    const tile = h('button', { class: 'tile' + (Prefs.values.themeID === set.id ? ' selected' : ''), onclick: () => Prefs.set({ themeID: set.id }) },
      h('div', { class: 'dots' }, [th.heading, th.key, th.string, th.keyword].map((c) => h('i', { style: { background: c } }))),
      h('div', { class: 'tile-name' }, set.name));
    tile.style.background = th.background;
    tile.style.color = th.text;
    return tile;
  }));

  const paintPreview = () => {
    const th = Prefs.theme;
    const size = Prefs.values.fontSize;
    const hsp = Prefs.values.headingSpacing;
    for (const preview of previews) {
      preview.style.background = th.background;
      preview.style.color = th.text;
      preview.style.fontFamily = Prefs.fontFamily;
      preview.replaceChildren(
        h('div', { style: { fontSize: size * 1.5 + 'px', fontWeight: 600, color: th.heading, paddingTop: size * 0.3 * hsp + 'px', paddingBottom: size * 0.2 * hsp + 'px' } }, t('Заголовок')),
        h('div', { style: { fontSize: size + 'px' } }, t('Так будет выглядеть обычный текст документа.')),
        h('div', { class: 'pv-code', style: { fontSize: size * 0.85 + 'px' } },
          Prefs.values.showLineNumbers ? h('span', { style: { color: th.gutter } }, '1') : null,
          h('span', { style: { color: th.key } }, '"key": '), h('span', { style: { color: th.string } }, '"value"')));
    }
    sizeLabel.textContent = `${Math.round(Prefs.values.fontSize)} pt`;
    spacingLabel.textContent = `×${Prefs.values.headingSpacing.toFixed(1)}`;
  };

  const fontSelect = h('select', { onchange: (e) => Prefs.set({ fontName: e.target.value }) },
    FONTS.map((f) => h('option', { value: f, selected: P.fontName === f }, f === SYSTEM_FONT ? t('Системный') : f)));
  const sizeInput = h('input', { type: 'range', min: 10, max: 28, step: 1, value: P.fontSize, oninput: (e) => Prefs.set({ fontSize: Number(e.target.value) }) });
  const spacingInput = h('input', { type: 'range', min: 0.5, max: 2.5, step: 0.1, value: P.headingSpacing, oninput: (e) => Prefs.set({ headingSpacing: Number(e.target.value) }) });
  const check = (label, key) => h('label', { class: 'check' },
    h('input', { type: 'checkbox', checked: P[key], onchange: (e) => Prefs.set({ [key]: e.target.checked }) }), h('span', null, t(label)));

  // Syntax highlighting: a master switch and one switch per language.
  const langChecks = (types) => h('div', { class: 'lang-grid' }, types.map((type) => h('label', { class: 'check' },
    h('input', {
      type: 'checkbox', checked: Syntax.isOn(type), disabled: Prefs.values.syntaxOn === false,
      onchange: (e) => {
        const off = new Set(Prefs.values.syntaxOff || []);
        if (e.target.checked) off.delete(type); else off.add(type);
        Prefs.set({ syntaxOff: [...off] });
      },
    }), h('span', null, TYPE_TITLES[type]))));
  const allBtn = (label, off) => h('button', {
    class: 'btn', disabled: Prefs.values.syntaxOn === false,
    onclick: () => Prefs.set({ syntaxOff: off ? [...PROGRAMMING_TYPES, ...MARKUP_TYPES] : [] }),
  }, t(label));

  const paneContent = {
    appearance: () => [card('Режим', appearance), card('Тема', tiles, h('div', { class: 'small muted' }, t('Dracula и Monokai всегда тёмные.'))), previews[0]],
    text: () => [
      card('Шрифт и размер', row('Шрифт', fontSelect), row('Размер', sizeInput, sizeLabel), row('Отступы заголовков', spacingInput, spacingLabel)),
      card('Исходник', check('Показывать номера строк', 'showLineNumbers')),
      card('Проверка текста',
        check('Проверять орфографию и грамматику в режиме правки', 'spellCheck'),
        h('div', { class: 'small muted' }, t('Русский и английский: ошибки подчёркиваются, исправление — в контекстном меню. Работает в Markdown, TXT, RTF и TeX; в исходном коде проверка выключена.'))),
      previews[1]],
    syntax: () => [
      card('Подсветка синтаксиса',
        check('Включить подсветку синтаксиса', 'syntaxOn'),
        h('div', { class: 'small muted' }, t('Цвета берутся из выбранной темы. Подсветка работает в режимах чтения, исходника и правки, а также в блоках кода Markdown.'))),
      card('Программирование', langChecks(PROGRAMMING_TYPES)),
      card('Разметка и данные', langChecks(MARKUP_TYPES)),
      h('div', { class: 'btn-row' }, allBtn('Включить все', false), allBtn('Выключить все', true))],
    files: () => [card('Обновление', check('Обновлять файл автоматически, когда он изменился на диске', 'autoReload'))],
    language: () => [card('Язык интерфейса', language, h('div', { class: 'small muted' }, t('Язык меняется сразу.')))],
    updates: () => [card('Обновления', ...updatesCard(), h('div', { class: 'small muted' }, t('Лицензия: © 2026 Slipcast-dev. Изменять и распространять Grizzly без письменного согласия автора запрещено.')))],
  };

  const paintNav = () => nav.replaceChildren(...SETTINGS_PANES.map(([id, label, ic]) => h('button', {
    class: 'snav-item' + (settingsPane === id ? ' on' : ''),
    onclick: () => { settingsPane = id; settingsRefresh(); },
  }, icon(ic, 17), h('span', { class: 'ellipsis' }, t(label)))));

  const paintBody = () => {
    const scrollTop = body.scrollTop;
    const current = SETTINGS_PANES.find(([id]) => id === settingsPane) || SETTINGS_PANES[0];
    body.replaceChildren(h('div', { class: 'pane-title' }, t(current[1])), ...paneContent[current[0]]());
    body.scrollTop = scrollTop;
  };

  settingsRefresh = () => {
    paintAppearance();
    paintLanguage();
    paintTiles();
    paintPreview();
    sizeInput.value = Prefs.values.fontSize;
    spacingInput.value = Prefs.values.headingSpacing;
    paintNav();
    paintBody();
  };
  settingsRefresh();

  root.append(h('div', { class: 'modal-back modal-settings', onmousedown: (e) => { if (e.target === e.currentTarget) close(); } },
    h('div', { class: 'dialog settings' },
      h('div', { class: 'dialog-head' }, h('div', { class: 'dialog-title' }, t('Настройки')),
        h('button', { class: 'plain', onclick: close }, icon('x', 16))),
      h('div', { class: 'settings-layout' }, nav, body))));
}

// ---- Updates ------------------------------------------------------------------

/** Where an update stands: idle | checking | upToDate | available | downloading | installing | failed. */
const Update = {
  phase: 'idle', version: null, notes: '', progress: 0, message: '',
  set(patch) { Object.assign(this, patch); updateViews.forEach((fn) => fn()); },
};
const updateViews = new Set();

async function checkForUpdates(silent) {
  if (['checking', 'downloading', 'installing'].includes(Update.phase)) return;
  Update.set({ phase: 'checking' });
  const res = await window.api.checkUpdate();
  if (!res.ok) {
    Update.set({ phase: silent ? 'idle' : 'failed', message: t('Не удалось проверить обновления. Проверьте подключение к интернету.') });
  } else if (res.available) {
    Update.set({ phase: 'available', version: res.version, notes: res.notes || '' });
    if (silent) openUpdateDialog();
  } else {
    Update.set({ phase: 'upToDate' });
  }
}

/** What is open right now: tabs, panes, mode and scroll positions, so the restarted app can put it back. */
function sessionSnapshot() {
  document.querySelectorAll('#panes .scroll').forEach((s) => { if (s.dataset.key) scrollMemory.set(s.dataset.key, s.scrollTop); });
  const index = (id) => App.documents.findIndex((d) => d.id === id);
  return {
    paths: App.documents.map((d) => d.path),
    scroll: App.documents.map((d) => scrollMemory.get(`${d.id}:${App.mode}`) || 0),
    left: index(App.selection),
    right: index(App.rightSelection),
    split: App.isSplit,
    mode: App.mode,
  };
}

/** Reopens what sessionSnapshot saved before the update restart. */
async function restoreSession(s) {
  if (!s || !Array.isArray(s.paths) || !s.paths.length) return;
  const ids = new Map();
  for (let i = 0; i < s.paths.length; i++) {
    const p = s.paths[i];
    if (typeof p !== 'string') continue;
    const known = Library.fileByPath(p);
    await App.show(known ? known.id : null, p, 'left', false);
    const doc = App.documents.find((d) => d.path === p);
    if (doc) ids.set(i, doc.id);
  }
  if (!App.documents.length) return;
  if (['reading', 'source', 'edit'].includes(s.mode)) App.mode = s.mode;
  const left = ids.get(s.left) || App.documents[0].id;
  const right = ids.get(s.right);
  App.selection = left;
  App.isSplit = !!s.split && !!right && right !== left;
  App.rightSelection = App.isSplit ? right : null;
  App.focusedPane = 'left';
  s.paths.forEach((_, i) => { if (ids.has(i) && s.scroll && s.scroll[i] > 0) scrollMemory.set(`${ids.get(i)}:${App.mode}`, s.scroll[i]); });
  App.render(['all']);
}

async function installUpdate() {
  Update.set({ phase: 'downloading', progress: 0 });
  const downloaded = await window.api.downloadUpdate();
  if (!downloaded.ok) {
    Update.set({ phase: 'failed', message: downloaded.code === 'ECHECKSUM'
      ? t('Контрольная сумма файла не совпала. Обновление не установлено.')
      : downloaded.code === 'ENETWORK'
        ? t('Не удалось скачать обновление. Проверьте подключение к интернету.')
        : t('Не удалось скачать обновление.') });
    return;
  }
  // Ask about unsaved edits before the app quits; the new version is started by a helper once it has exited.
  if (!(await App.confirmDiscard(App.documents.map((d) => d.id)))) { Update.set({ phase: 'available' }); return; }
  Update.set({ phase: 'installing' });
  await window.api.saveSession(sessionSnapshot());
  const applied = await window.api.applyUpdate();
  if (!applied.ok) {
    Update.set({ phase: 'failed', message: t('Скачанное обновление открыто в проводнике: запустите его вручную.') });
  }
}

/** The status block with its buttons: used in Settings and in the dialog shown after the check at launch. */
function updatesCard() {
  const box = h('div', { class: 'update-box' });
  const paint = () => {
    const U = Update;
    const busy = ['checking', 'downloading', 'installing'].includes(U.phase);
    const kids = [];
    if (U.phase === 'checking') kids.push(h('div', null, t('Проверяем обновления…')));
    if (U.phase === 'upToDate') kids.push(h('div', { class: 'ok' }, '✓ ' + t('У вас установлена последняя версия.')));
    if (U.phase === 'available') {
      kids.push(h('div', { class: 'update-title' }, t('Вышла новая версия %@', U.version)),
        h('div', { class: 'small muted' }, t('Установлена версия %@.', appVersion)),
        U.notes ? h('pre', { class: 'update-notes' }, U.notes) : null,
        h('div', { class: 'btn-row' },
          h('button', { class: 'btn primary', onclick: installUpdate }, t('Скачать и установить')),
          h('button', { class: 'btn', onclick: closeUpdateDialog }, t('Позже'))));
    }
    if (U.phase === 'downloading') {
      kids.push(h('div', null, t('Загрузка обновления… %lld%%', Math.round(U.progress * 100))),
        h('progress', { max: 1, value: U.progress }));
    }
    if (U.phase === 'installing') kids.push(h('div', null, t('Устанавливаем… Grizzly перезапустится.')));
    if (U.phase === 'failed') kids.push(h('div', { class: 'warn' }, U.message));
    box.replaceChildren(
      h('div', { class: 'srow' }, h('div', { class: 'slabel' }, t('Установленная версия')), h('span', null, appVersion)),
      h('div', { class: 'btn-row' }, h('button', { class: 'btn', disabled: busy, onclick: () => checkForUpdates(false) }, t('Проверить обновления'))),
      ...kids,
      h('div', { class: 'small muted' }, t('Grizzly проверяет GitHub при каждом запуске. Новая версия скачивается и устанавливается прямо из приложения.')));
  };
  paint();
  const view = () => { if (box.isConnected) paint(); else updateViews.delete(view); };
  updateViews.add(view);
  return [box];
}

function closeUpdateDialog() { document.querySelectorAll('.modal-update').forEach((n) => n.remove()); }

/** Shown over the window when the check at launch finds a newer version. */
function openUpdateDialog() {
  if (document.querySelector('.modal-update')) return;
  const box = h('div', { class: 'update-box' });
  const paint = () => {
    const U = Update;
    box.replaceChildren();
    if (U.phase === 'available') {
      box.append(h('div', { class: 'update-title' }, t('Вышла новая версия %@', U.version)),
        h('div', { class: 'small muted' }, t('Установлена версия %@.', appVersion)),
        U.notes ? h('pre', { class: 'update-notes' }, U.notes) : null,
        h('div', { class: 'dialog-actions' },
          h('button', { class: 'btn', onclick: closeUpdateDialog }, t('Позже')),
          h('button', { class: 'btn primary', onclick: installUpdate }, t('Скачать и установить'))));
    } else if (U.phase === 'downloading') {
      box.append(h('div', null, t('Загрузка обновления… %lld%%', Math.round(U.progress * 100))), h('progress', { max: 1, value: U.progress }));
    } else if (U.phase === 'installing') {
      box.append(h('div', null, t('Устанавливаем… Grizzly перезапустится.')));
    } else if (U.phase === 'failed') {
      box.append(h('div', { class: 'warn' }, U.message),
        h('div', { class: 'dialog-actions' }, h('button', { class: 'btn', onclick: closeUpdateDialog }, t('Закрыть'))));
    } else {
      closeUpdateDialog();
    }
  };
  paint();
  const view = () => { if (box.isConnected) paint(); else updateViews.delete(view); };
  updateViews.add(view);
  $('overlay-root').append(h('div', { class: 'modal-back modal-update' }, h('div', { class: 'dialog update' }, box)));
}

let appVersion = '';
function initUpdates(version) {
  appVersion = version;
  window.api.onUpdateProgress((p) => Update.set({ progress: p }));
}

// ---- Commands shared by menu, toolbar and boot ------------------------------

async function openFolders() {
  const dirs = await window.api.openFolderDialog();
  for (const d of dirs || []) await App.importFolder(d);
}

/** Creates a file (name, place and format are chosen in the save dialog) and opens it for editing. */
async function newFile() {
  const result = await window.api.newFile();
  if (!result.ok) {
    if (result.code !== 'ECANCEL') App.fail(t('Не удалось создать «%@».', result.name || ''));
    return;
  }
  await App.open([result.path]);
  App.setMode('edit');
}

async function openFiles() {
  const paths = await window.api.openDialog();
  if (paths && paths.length) App.open(paths);
}

/** The window is closing with unsaved edits: ask about every file (save / don't save / cancel), then really close. */
async function closeWindow() {
  if (await App.confirmDiscard(App.documents.map((d) => d.id))) await window.api.closeWindow();
}

function runCommand(action) {
  switch (action) {
    case 'open': openFiles(); break;
    case 'openFolder': openFolders(); break;
    case 'newFile': newFile(); break;
    case 'closeTab': if (App.current) App.close(App.current.id); break;
    case 'closeWindow': closeWindow(); break;
    case 'settings': openSettings(); break;
    case 'find': App.showFind(); break;
    case 'findNext': App.stepMatch(1); break;
    case 'findPrev': App.stepMatch(-1); break;
    case 'nextTab': App.cycleTab(1); break;
    case 'prevTab': App.cycleTab(-1); break;
    case 'split': if (App.documents.length) App.toggleSplit(); break;
    case 'modeReading': App.setMode('reading'); break;
    case 'modeSource': App.setMode('source'); break;
    case 'modeEdit': App.setMode('edit'); break;
    case 'saveAs': if (App.current) App.saveAs(App.current.id); break;
    case 'save': if (App.current) App.save(App.current.id); break;
    case 'reload': if (App.current) App.refresh(App.current.id); break;
    case 'fontUp': Prefs.resizeFont(1); break;
    case 'fontDown': Prefs.resizeFont(-1); break;
  }
}

function initDragAndDrop() {
  const hintEl = $('drop-hint');
  let depth = 0;
  const external = (e) => e.dataTransfer && Array.from(e.dataTransfer.types).includes('Files');
  window.addEventListener('dragenter', (e) => { if (external(e)) { depth++; hintEl.hidden = false; hintEl.textContent = t('Открыть'); } });
  window.addEventListener('dragleave', (e) => { if (external(e) && --depth <= 0) { depth = 0; hintEl.hidden = true; } });
  window.addEventListener('dragover', (e) => { if (external(e)) e.preventDefault(); });
  window.addEventListener('drop', (e) => {
    depth = 0;
    hintEl.hidden = true;
    if (!external(e)) return;
    e.preventDefault();
    const paths = Array.from(e.dataTransfer.files).map((f) => window.api.pathForFile(f)).filter(Boolean);
    if (paths.length) App.openPaths(paths);
  });
}

document.addEventListener('keydown', (e) => {
  // Select All outside of text fields selects the whole document text, not just the visible part of the page.
  if ((e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === 'a'
      && !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement && document.activeElement.tagName)) {
    const area = (document.querySelector('.pane-header.focused') || {}).parentElement?.querySelector('.scroll') || document.querySelector('.scroll');
    if (area) {
      e.preventDefault();
      const range = document.createRange();
      range.selectNodeContents(area);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }
    return;
  }
  if (e.key === ' ' && !e.ctrlKey && !e.metaKey && !e.altKey && !/^(INPUT|TEXTAREA|BUTTON)$/.test(document.activeElement && document.activeElement.tagName)) {
    if (document.querySelector('.modal-preview')) { e.preventDefault(); closeQuickLook(); return; }
    if (App.selectedFileID && !document.querySelector('.modal-back')) { e.preventDefault(); quickLook(App.selectedFileID); return; }
  }
  if (e.key !== 'Escape') return;
  if (document.querySelector('.modal-preview')) { closeQuickLook(); return; }
  if (Menus.el || Popover.el) { Menus.close(); Popover.close(); return; }
  const settings = document.querySelector('.modal-settings');
  if (settings) { settings.remove(); settingsRefresh = null; return; }
  if (App.errorMessage) { App.errorMessage = null; renderErrorDialog(); return; }
  if (App.isFindVisible) App.hideFind();
});

function buildUI() {
  buildSidebarFrame();
  buildMainFrame();
  initResizer();
  initDragAndDrop();
  applySidebarVisibility();
  Prefs.onChange(() => {
    applyTheme();
    if (settingsRefresh) settingsRefresh();
    App.render(['all']);
  });
}
