/* Library store and application state. Port of LibraryStore.swift and AppState.swift.
   The library keeps references to files (their paths); folders only group those references. */

/** Characters a tag may contain: letters, digits, marks, `_`, `-` and emoji (so #🍕 and #идея💡 are tags). */
const TAG_BODY = '\\p{L}\\p{N}\\p{M}_\\-\\p{Extended_Pictographic}\\u200D\\uFE0F';

const PROSE_TYPES = ['markdown', 'text', 'rtf', 'tex'];

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
const byName = (a, b) => collator.compare(a.name, b.name);

const Library = {
  RECENT_LIMIT: 20,
  HISTORY_STORED: 200,
  data: { files: [], folders: [], history: [], tags: [] },
  missing: new Set(),
  caseInsensitive: false,
  onChange: () => {},
  saveTimer: null,

  async load(caseInsensitive) {
    this.caseInsensitive = caseInsensitive;
    try {
      const raw = await window.api.loadLibrary();
      if (raw) {
        const parsed = JSON.parse(raw);
        this.data = {
          files: (parsed.files || []).map((f) => ({
            id: f.id, path: f.path, name: f.name || baseName(f.path), folderID: f.folderID || null,
            isFavorite: !!f.isFavorite, lastOpened: f.lastOpened || null, bookmarks: f.bookmarks || [],
            tags: Array.isArray(f.tags) ? f.tags.filter((x) => typeof x === 'string') : [],
            inlineTags: Array.isArray(f.inlineTags) ? f.inlineTags.filter((x) => typeof x === 'string') : [],
          })),
          folders: (parsed.folders || []).map((f) => ({ id: f.id, name: f.name, isExpanded: f.isExpanded !== false, sourcePath: f.sourcePath || null })),
          // The history lives apart from the files, so removing a file from the sidebar keeps its record.
          history: (parsed.history || []).filter((h) => h && h.path && h.date).map((h) => ({ path: h.path, name: h.name || baseName(h.path), date: h.date })),
          tags: Array.isArray(parsed.tags) ? parsed.tags.filter((x) => typeof x === 'string') : [],
        };
        if (!parsed.history) {
          this.data.history = this.data.files.filter((f) => f.lastOpened)
            .map((f) => ({ path: f.path, name: f.name, date: f.lastOpened }));
        }
      }
    } catch { /* a damaged library starts empty */ }
    await this.refreshMissing();
  },

  save() {
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => window.api.saveLibrary(JSON.stringify(this.data, null, 1)), 150);
  },

  mutate(change) {
    change(this.data);
    this.save();
    this.onChange();
  },

  // Queries

  get folders() { return [...this.data.folders].sort(byName); },
  file(id) { return this.data.files.find((f) => f.id === id) || null; },
  filesIn(folderID) { return this.data.files.filter((f) => (f.folderID || null) === (folderID || null)).sort(byName); },
  /** Opened files, newest first, whether or not they are still in the library. */
  get recents() {
    return [...this.data.history].sort((a, b) => b.date.localeCompare(a.date)).slice(0, this.RECENT_LIMIT);
  },
  fileByPath(path) {
    const same = (a, b) => (this.caseInsensitive ? a.toLowerCase() === b.toLowerCase() : a === b);
    return this.data.files.find((f) => same(f.path, path)) || null;
  },
  get favorites() { return this.data.files.filter((f) => f.isFavorite).sort(byName); },
  folderExists(name) { return this.data.folders.some((f) => f.name.toLowerCase() === name.toLowerCase()); },
  isMissing(id) { return this.missing.has(id); },
  bookmarks(id) { const f = id && this.file(id); return f ? f.bookmarks : []; },

  // Files

  add(path) {
    const same = (a, b) => (this.caseInsensitive ? a.toLowerCase() === b.toLowerCase() : a === b);
    const existing = this.data.files.find((f) => same(f.path, path));
    if (existing) return existing;
    const entry = {
      id: crypto.randomUUID(), path, name: baseName(path), folderID: null,
      isFavorite: false, lastOpened: null, bookmarks: [], tags: [], inlineTags: [],
    };
    this.mutate((d) => d.files.push(entry));
    return entry;
  },

  async refreshMissing() {
    const paths = this.data.files.map((f) => f.path);
    const times = paths.length ? await window.api.mtimes(paths) : {};
    this.missing = new Set(this.data.files.filter((f) => times[f.path] == null).map((f) => f.id));
    this.onChange();
  },

  setMissing(id, value) {
    if (value) this.missing.add(id); else this.missing.delete(id);
    this.onChange();
  },

  /** Puts a file at the top of the history (once per path). */
  recordOpened(path) {
    const same = (a, b) => (this.caseInsensitive ? a.toLowerCase() === b.toLowerCase() : a === b);
    const now = new Date().toISOString();
    this.mutate((d) => {
      d.history = d.history.filter((h) => !same(h.path, path));
      d.history.push({ path, name: baseName(path), date: now });
      if (d.history.length > this.HISTORY_STORED) {
        d.history = d.history.sort((a, b) => b.date.localeCompare(a.date)).slice(0, this.HISTORY_STORED);
      }
      const f = d.files.find((x) => same(x.path, path));
      if (f) f.lastOpened = now;
    });
  },
  removeFromHistory(path) { this.mutate((d) => { d.history = d.history.filter((h) => h.path !== path); }); },
  clearRecents() { this.mutate((d) => { d.history = []; d.files.forEach((f) => { f.lastOpened = null; }); }); },
  toggleFavorite(id) {
    this.mutate((d) => { const f = d.files.find((x) => x.id === id); if (f) f.isFavorite = !f.isFavorite; });
  },

  toggleBookmark(id, line) {
    if (!id) return;
    this.mutate((d) => {
      const f = d.files.find((x) => x.id === id);
      if (!f) return;
      const at = f.bookmarks.indexOf(line);
      if (at >= 0) f.bookmarks.splice(at, 1);
      else { f.bookmarks.push(line); f.bookmarks.sort((a, b) => a - b); }
    });
  },

  /** Removes the reference only; the file on disk is never touched. */
  remove(id) {
    this.mutate((d) => { d.files = d.files.filter((f) => f.id !== id); });
    this.missing.delete(id);
  },

  move(fileID, folderID) {
    this.mutate((d) => {
      const f = d.files.find((x) => x.id === fileID);
      if (!f || (f.folderID || null) === (folderID || null)) return;
      f.folderID = folderID || null;
      const folder = folderID && d.folders.find((x) => x.id === folderID);
      if (folder) folder.isExpanded = true;
    });
  },

  // Tags

  /** Tag text as stored: trimmed, without a leading "#". */
  cleanTag(raw) { return String(raw || '').trim().replace(/^#+/, '').trim(); },
  sameTag(a, b) { return a.toLowerCase() === b.toLowerCase(); },
  /** Every known tag, alphabetically: the ones created by the user plus any a file still carries. */
  get allTags() {
    const seen = new Set();
    const out = [];
    for (const tag of [...this.data.tags, ...this.data.files.flatMap((f) => [...f.tags, ...f.inlineTags])]) {
      if (!seen.has(tag.toLowerCase())) { seen.add(tag.toLowerCase()); out.push(tag); }
    }
    return out.sort((a, b) => collator.compare(a, b));
  },
/** Files that carry every one of the tags (several selected tags narrow the list down, as in Apple Notes). */
  filesWithAllTags(tags) {
    if (!tags.length) return [];
    return this.data.files.filter((f) => tags.every((tag) => [...f.tags, ...f.inlineTags].some((x) => this.sameTag(x, tag)))).sort(byName);
  },
  /** One specific `#tag` as a regular expression (same boundaries as extractTags). */
  tagRegex(tag, flags = 'giu') {
    return new RegExp('(?<![\\p{L}\\p{N}_#&/=:])#' + tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?![' + TAG_BODY + '])', flags);
  },
  countTag(tag, text) { return (String(text).match(this.tagRegex(tag)) || []).length; },
  /** `#old` becomes `#new`; with next == null the tag is removed from the text (with the space after it). */
  replaceTag(old, next, text) {
    const re = this.tagRegex(old);
    if (next != null) return String(text).replace(re, '#' + next);
    return String(text).replace(new RegExp(re.source + ' ?', 'giu'), '');
  },
  /** Where the `#tags` are in a text, for coloring them: [{index, length, tag}] (length includes the `#`). */
  tagMatches(text) {
    const out = [];
    for (const m of String(text).matchAll(new RegExp('(?<![\\p{L}\\p{N}_#&/=:])#([' + TAG_BODY + ']+)', 'gu'))) {
      const tag = m[1].replace(/[-_]+$/g, '');
      if (tag) out.push({ index: m.index, length: tag.length + 1, tag });
    }
    return out;
  },
  filesWithTag(tag) { return this.data.files.filter((f) => [...f.tags, ...f.inlineTags].some((x) => this.sameTag(x, tag))).sort(byName); },
  /** True for tags set by hand and for #hashtags written in the file's text. */
  hasTag(fileID, tag) { const f = this.file(fileID); return !!f && [...f.tags, ...f.inlineTags].some((x) => this.sameTag(x, tag)); },
  /** `#word` tags in prose: a hash right before a letter or digit, not part of a word, link or entity. */
  extractTags(text) {
    const seen = new Set();
    const out = [];
    for (const m of String(text).matchAll(new RegExp('(?<![\\p{L}\\p{N}_#&/=:])#([' + TAG_BODY + ']+)', 'gu'))) {
      const tag = m[1].replace(/^[-_]+|[-_]+$/g, '');
      if (tag && !seen.has(tag.toLowerCase())) { seen.add(tag.toLowerCase()); out.push(tag); }
    }
    return out;
  },
  setInlineTags(id, tags) {
    const f = this.file(id);
    if (!f || JSON.stringify(f.inlineTags) === JSON.stringify(tags)) return;
    this.mutate((d) => { d.files.find((x) => x.id === id).inlineTags = tags; });
  },
  /** Reads every prose file of the library once at launch, so tags written in the texts show up in the sidebar. */
  async scanInlineTags() {
    for (const f of [...this.data.files]) {
      if (!['markdown', 'text', 'rtf', 'tex'].includes(fileTypeOf(f.path))) continue;
      const res = await window.api.readFile(f.path);
      if (res.ok && res.text.length < 2000000) this.setInlineTags(f.id, this.extractTags(res.text));
    }
  },
  /** Creates a tag and returns its stored spelling; an existing tag is returned as it is. Null for an empty name. */
  createTag(raw) {
    const tag = this.cleanTag(raw);
    if (!tag) return null;
    const existing = this.allTags.find((x) => this.sameTag(x, tag));
    if (existing) return existing;
    this.mutate((d) => d.tags.push(tag));
    return tag;
  },
  toggleTag(fileID, tag) {
    this.mutate((d) => {
      const f = d.files.find((x) => x.id === fileID);
      if (!f) return;
      const at = f.tags.findIndex((x) => this.sameTag(x, tag));
      if (at >= 0) f.tags.splice(at, 1); else f.tags.push(tag);
    });
  },
  renameTag(old, raw) {
    const next = this.cleanTag(raw);
    if (!next) return;
    const swap = (list) => {
      const out = [];
      for (const x of list) {
        const v = this.sameTag(x, old) ? next : x;
        if (!out.some((y) => this.sameTag(y, v))) out.push(v);
      }
      return out;
    };
    this.mutate((d) => { d.tags = swap(d.tags); d.files.forEach((f) => { f.tags = swap(f.tags); f.inlineTags = swap(f.inlineTags); }); });
  },
  deleteTag(tag) {
    this.mutate((d) => {
      d.tags = d.tags.filter((x) => !this.sameTag(x, tag));
      d.files.forEach((f) => { f.tags = f.tags.filter((x) => !this.sameTag(x, tag)); f.inlineTags = f.inlineTags.filter((x) => !this.sameTag(x, tag)); });
    });
  },

  // Folders

  createFolder(name) {
    const folder = { id: crypto.randomUUID(), name, isExpanded: true };
    this.mutate((d) => d.folders.push(folder));
    return folder;
  },
  /** Finds or creates the library folder that mirrors a directory on disk. */
  folderForDirectory(dir) {
    const same = (a, b) => (this.caseInsensitive ? a.toLowerCase() === b.toLowerCase() : a === b);
    const existing = this.data.folders.find((f) => f.sourcePath && same(f.sourcePath, dir));
    if (existing) return existing;
    let name = baseName(dir) || dir;
    const base = name;
    for (let n = 2; this.folderExists(name); n++) name = `${base} (${n})`;
    const folder = { id: crypto.randomUUID(), name, isExpanded: true, sourcePath: dir };
    this.mutate((d) => d.folders.push(folder));
    return folder;
  },
  renameFolder(id, name) { this.mutate((d) => { const f = d.folders.find((x) => x.id === id); if (f) f.name = name; }); },
  setExpanded(id, expanded) { this.mutate((d) => { const f = d.folders.find((x) => x.id === id); if (f) f.isExpanded = expanded; }); },
  /** Files from the deleted folder go back to the root of the library. */
  deleteFolder(id) {
    this.mutate((d) => {
      d.files.forEach((f) => { if (f.folderID === id) f.folderID = null; });
      d.folders = d.folders.filter((f) => f.id !== id);
    });
  },
};

// ---- Application state -----------------------------------------------------

const App = {
  documents: [], // open tabs, in order; both panes pick their document from this list
  selection: null, // document id in the left (or only) pane
  rightSelection: null, // document id in the right pane while split view is on
  isSplit: false,
  focusedPane: 'left',
  selectedFileID: null, // library entry highlighted in the sidebar; follows the focused pane
  mode: 'reading', // reading | source | edit
  errorMessage: null,
  changedOnDisk: new Set(),
  drafts: new Map(), // document id -> edited text that differs from the file
  saving: new Set(),

  isFindVisible: false,
  findQuery: '',
  matches: [],
  matchIndex: 0,
  findFocusToken: 0,
  scrollTarget: null, // {unit, token}: asks the target pane to scroll a row into view

  ui: {
    sidebarVisible: true,
    sidebarSection: 'files',
    settingsOpen: false,
  },
  notify: () => {}, // set by the UI: notify(text, iconName)
  render: () => {}, // set by the UI: render(['sidebar', 'main', ...])

  docID(pane) { return pane === 'left' ? this.selection : this.rightSelection; },
  doc(pane) { const id = this.docID(pane); return this.documents.find((d) => d.id === id) || null; },
  get current() { return this.doc(this.isSplit ? this.focusedPane : 'left'); },
  get currentMatch() { return this.matches[this.matchIndex] || null; },

  // Opening

  /** Opens files from disk (dialog, drag and drop, command line) and adds them to the library. */
  async open(paths, inRight = false) {
    for (const path of paths) {
      const entry = Library.add(path);
      await this.show(entry.id, path, inRight ? 'right' : null);
    }
  },

  /** Mirrors a directory into the library: supported files become entries, subdirectories become folders. */
  async importFolder(root, rootID = null) {
    const files = await window.api.scanDir(root);
    if (!files) return false;
    const rootFolder = rootID ? Library.data.folders.find((f) => f.id === rootID) : Library.folderForDirectory(root);
    for (const { path, dir } of files) {
      const folder = dir === root ? rootFolder : Library.folderForDirectory(dir);
      const entry = Library.add(path);
      if (!entry.folderID) Library.move(entry.id, folder.id);
    }
    return true;
  },

  /** Opens files and folders from disk; a folder is added to the sidebar with its files. */
  async openPaths(paths, inRight = false) {
    const files = [];
    for (const p of paths) if (!(await this.importFolder(p))) files.push(p);
    if (files.length) await this.open(files, inRight);
  },

  /** Opens a file that is already in the library (sidebar click). */
  async openLibraryFile(id, inRight = false) {
    const entry = id && Library.file(id);
    if (!entry) return;
    const pane = inRight ? 'right' : (this.isSplit ? this.focusedPane : 'left');

    const existing = this.documents.find((d) => d.libraryID === id);
    if (existing) {
      if (this.docID(pane) !== existing.id || this.focusedPane !== pane) this.assign(existing.id, pane);
      return;
    }
    await this.show(id, entry.path, pane, true);
  },

  /** Opens a file from the history. It is shown in a tab without being added back to the sidebar. */
  async openHistory(entry, inRight = false) {
    const pane = inRight ? 'right' : (this.isSplit ? this.focusedPane : 'left');
    const known = Library.fileByPath(entry.path);
    await this.show(known ? known.id : null, entry.path, pane, false);
  },

  async show(libraryID, path, pane, fromLibrary = false) {
    const target = pane || (this.isSplit ? this.focusedPane : 'left');
    const existing = this.documents.find((d) => (libraryID ? d.libraryID === libraryID : !d.libraryID && d.path === path));
    if (existing) {
      this.assign(existing.id, target);
      Library.recordOpened(path);
      return;
    }
    const loaded = await window.api.readFile(path);
    if (!loaded.ok) {
      const name = baseName(path);
      if (loaded.code === 'ENOENT') {
        if (libraryID) Library.setMissing(libraryID, true);
        this.fail(fromLibrary ? t('Файл «%@» не найден. Возможно, он перемещён или удалён.', name) : t('Не удалось открыть «%@».', name));
      } else {
        this.fail(t('Не удалось открыть «%@».', name));
      }
      return;
    }
    if (libraryID) Library.setMissing(libraryID, false);
    const doc = makeDocument(path, loaded);
    doc.libraryID = libraryID;
    this.noteTags(doc);
    this.documents.push(doc);
    this.assign(doc.id, target);
    Library.recordOpened(path);
  },

/** Hashtags written in a document become tags of its library file. */
  noteTags(doc) {
    clearTimeout(this.tagTimers.get(doc.id));
    if (doc.libraryID && PROSE_TYPES.includes(doc.type)) Library.setInlineTags(doc.libraryID, Library.extractTags(doc.lines.join('\n')));
  },

  fail(message) { this.errorMessage = message; this.render(['dialogs']); },

  // File watching

  /** Polls open files once a second; a changed file shows a banner or reloads itself. */
  startWatching() {
    setInterval(() => this.checkFiles(), 1000);
  },

  async checkFiles() {
    const docs = this.documents.filter((d) => !this.changedOnDisk.has(d.id) && !this.saving.has(d.id));
    if (!docs.length) return;
    const times = await window.api.mtimes(docs.map((d) => d.path));
    for (const stale of docs) {
      const doc = this.documents.find((d) => d.id === stale.id);
      if (!doc || this.saving.has(doc.id)) continue;
      const now = times[doc.path];
      if (now == null || now === doc.modified) continue;
      // Never replace text the user is editing; offer the banner instead.
      if (Prefs.values.autoReload && !this.isDirty(doc)) await this.reload(doc.id);
      else { this.changedOnDisk.add(doc.id); this.render(['main']); }
    }
  },

  /** Re-reads a document from disk, keeping its tab, library entry and bookmarks. */
  async reload(id) {
    const i = this.documents.findIndex((d) => d.id === id);
    if (i < 0) return;
    const old = this.documents[i];
    const loaded = await window.api.readFile(old.path);
    this.changedOnDisk.delete(id);
    if (!loaded.ok) { this.fail(t('Не удалось обновить «%@».', old.name)); return; }
    this.drafts.delete(id);
    this.syncDirty();
    const fresh = makeDocument(old.path, loaded);
    fresh.id = old.id;
    fresh.libraryID = old.libraryID;
    this.noteTags(fresh);
    this.documents[i] = fresh;
    this.recomputeMatches(false);
    this.render(['main']);
  },

  /** User-initiated reload: asks first when it would throw away unsaved edits. */
  async refresh(id) {
    if (await this.confirmDiscard([id])) { await this.reload(id); this.notify(t('Файл обновлён с диска.'), 'refresh'); }
  },

  /** Hides the banner until the file changes again. */
  async ignoreChange(id) {
    const doc = this.documents.find((d) => d.id === id);
    if (!doc) return;
    const times = await window.api.mtimes([doc.path]);
    doc.modified = times[doc.path];
    this.changedOnDisk.delete(id);
    this.render(['main']);
  },

  // Editing

  baseText(doc) { return doc.lines.join('\n'); },
  textFor(doc) { return this.drafts.has(doc.id) ? this.drafts.get(doc.id) : this.baseText(doc); },
  isDirty(doc) { return !!doc && this.drafts.has(doc.id); },

  setDraft(doc, text) {
    if (text === this.baseText(doc)) this.drafts.delete(doc.id); else this.drafts.set(doc.id, text);
    this.syncDirty();
    // Hits move while the text is typed; recount them without jumping to the current one.
    if (this.isFindVisible && this.mode === 'edit' && this.findQuery) this.recomputeMatches(false, false);
    this.scheduleTagRefresh(doc, text);
  },

  tagTimers: new Map(),

  /** Tags typed into the text show up in the sidebar after a short pause, without saving the file.
   *  (A pause rather than every key press: "#р", "#ра", "#раб" must not become three tags.) */
  scheduleTagRefresh(doc, text) {
    if (!doc.libraryID || !PROSE_TYPES.includes(doc.type)) return;
    clearTimeout(this.tagTimers.get(doc.id));
    this.tagTimers.set(doc.id, setTimeout(() => {
      this.tagTimers.delete(doc.id);
      Library.setInlineTags(doc.libraryID, Library.extractTags(text));
    }, 600));
  },

  discardDraft(id) {
    this.drafts.delete(id);
    const doc = this.documents.find((d) => d.id === id);
    if (doc) this.noteTags(doc);
    this.syncDirty();
    this.render(['main']);
  },

  /** Tells the main process whether closing the window would lose edits. */
  syncDirty() {
    window.api.setDirty(this.drafts.size > 0);
    this.render(['tabs']);
  },

  /** Writes the edited text to the file in its original encoding, then re-reads it. */
  async save(id) {
    const doc = this.documents.find((d) => d.id === id);
    if (!doc || !this.isDirty(doc)) return true;
    this.saving.add(id);
    try {
      let text = this.drafts.get(id);
      if (doc.text.includes('\r\n')) text = text.replace(/\n/g, '\r\n');
      let result = await window.api.writeFile(doc.path, text, doc.encoding);
      if (!result.ok && result.code === 'EENCODE' && doc.encoding !== 'UTF-8') {
        // Emoji and other characters outside an 8-bit encoding: offer UTF-8 instead of losing them.
        if (!(await window.api.confirmUtf8(doc.name, doc.encoding))) return false;
        result = await window.api.writeFile(doc.path, text, 'UTF-8');
      }
      if (!result.ok) {
        this.fail(t('Не удалось сохранить «%@».', doc.name));
        return false;
      }
      await this.reload(id);
      const saved = !this.isDirty(doc);
      if (saved) {
        this.notify(t('Сохранено: %@', doc.name), 'check');
        if (doc.type === 'rtf') this.notify(t('Файл RTF сохранён без форматирования.'), 'info');
      }
      return saved;
    } finally {
      this.saving.delete(id);
    }
  },

  /** Saves a copy of the document (with unsaved edits) in a chosen format and place. */
  async saveAs(id) {
    const doc = this.documents.find((d) => d.id === id);
    if (!doc) return;
    let text = this.textFor(doc);
    if (doc.text.includes('\r\n')) text = text.replace(/\n/g, '\r\n');
    const dir = doc.path.replace(/[\\/][^\\/]*$/, '');
    const result = await window.api.saveAs(doc.name, text, doc.encoding, dir);
    if (!result.ok && result.code !== 'ECANCEL') this.fail(t('Не удалось сохранить «%@».', doc.name));
    else if (result.ok) this.notify(t('Копия сохранена: %@', baseName(result.path)), 'download');
  },

  /** Asks about every unsaved document among `ids`; false means the user cancelled. */
  async confirmDiscard(ids) {
    for (const id of ids) {
      const doc = this.documents.find((d) => d.id === id);
      if (!this.isDirty(doc)) continue;
      const choice = await window.api.confirmSave(doc.name);
      if (choice === 'cancel') return false;
      if (choice === 'save' && !(await this.save(id))) return false;
      if (choice === 'discard') this.noteTags(doc); // the edits are dropped: tags go back to the file's text
    }
    return true;
  },

  // Find and bookmarks

  showFind() {
    this.isFindVisible = true;
    this.findFocusToken++;
    this.recomputeMatches(false);
    this.render(['main']);
  },

  hideFind() {
    this.isFindVisible = false;
    this.matches = [];
    this.matchIndex = 0;
    this.render(['main']);
  },

  setQuery(query) {
    this.findQuery = query;
    this.recomputeMatches(true);
    this.render(['main']);
  },

  /** Hits are counted in the focused pane's document; every pane paints the same query. */
  recomputeMatches(reset, reveal = true) {
    const doc = this.current;
    if (!this.isFindVisible || !this.findQuery || !doc) {
      this.matches = [];
      this.matchIndex = 0;
      return;
    }
    // The editor is searched as it is right now, unsaved changes included.
    this.matches = this.mode === 'edit'
      ? Searcher.matchesInLines(this.findQuery, this.textFor(doc).split('\n'))
      : Searcher.matches(this.findQuery, doc, this.mode);
    this.matchIndex = reset ? 0 : Math.min(this.matchIndex, Math.max(0, this.matches.length - 1));
    if (reveal) this.revealCurrentMatch();
  },

  stepMatch(delta) {
    if (!this.isFindVisible) { this.showFind(); return; }
    if (!this.matches.length) return;
    this.matchIndex = (this.matchIndex + delta + this.matches.length) % this.matches.length;
    this.revealCurrentMatch();
    this.render(['main']);
  },

  revealCurrentMatch() {
    const m = this.currentMatch;
    if (m) this.scrollTarget = { unit: m.unit, token: Math.random(), match: true };
  },

  /** Jumps to a bookmarked line (0-based) in the source view. */
  goToLine(line) {
    this.mode = 'source';
    this.recomputeMatches(false);
    this.scrollTarget = { unit: line, token: Math.random(), match: false };
    this.render(['toolbar', 'main']);
  },

  setMode(mode) {
    if (this.mode === mode) return;
    this.mode = mode;
    this.recomputeMatches(false);
    this.render(['toolbar', 'main']);
  },

  // Tabs and panes

  assign(docID, pane) {
    if (pane === 'right') { this.isSplit = true; this.rightSelection = docID; } else { this.selection = docID; }
    this.focusedPane = pane;
    this.selectedFileID = (this.documents.find((d) => d.id === docID) || {}).libraryID || null;
    this.recomputeMatches(true);
    this.render(['all']);
  },

  selectTab(id, inRight = false) {
    this.assign(id, inRight ? 'right' : (this.isSplit ? this.focusedPane : 'left'));
  },

  focus(pane) {
    if (!this.isSplit || this.focusedPane === pane) return;
    this.focusedPane = pane;
    this.selectedFileID = (this.current || {}).libraryID || null;
    this.recomputeMatches(true);
    this.render(['sidebar', 'toolbar', 'main']);
  },

  toggleSplit() {
    this.isSplit = !this.isSplit;
    if (this.isSplit) {
      if (!this.rightSelection || !this.doc('right')) {
        this.rightSelection = (this.documents.find((d) => d.id !== this.selection) || {}).id || null;
      }
    } else {
      this.focusedPane = 'left';
      this.selectedFileID = (this.current || {}).libraryID || null;
    }
    this.recomputeMatches(true);
    this.render(['all']);
  },

  cycleTab(delta) {
    if (this.documents.length < 2) return;
    const pane = this.isSplit ? this.focusedPane : 'left';
    const index = Math.max(0, this.documents.findIndex((d) => d.id === this.docID(pane)));
    const next = (index + delta + this.documents.length) % this.documents.length;
    this.assign(this.documents[next].id, pane);
  },

  async close(id) {
    if (!(await this.confirmDiscard([id]))) return false;
    const i = this.documents.findIndex((d) => d.id === id);
    if (i < 0) return true;
    this.documents.splice(i, 1);
    this.changedOnDisk.delete(id);
    this.drafts.delete(id);
    this.syncDirty();
    const neighbour = (this.documents[i] || this.documents[this.documents.length - 1] || {}).id || null;
    if (this.selection === id) this.selection = neighbour;
    if (this.rightSelection === id) this.rightSelection = neighbour;
    if (!this.documents.length) { this.isSplit = false; this.focusedPane = 'left'; }
    this.selectedFileID = (this.current || {}).libraryID || null;
    this.recomputeMatches(true);
    this.render(['all']);
    return true;
  },

  async closeOthers(keeping) {
    if (!(await this.confirmDiscard(this.documents.filter((d) => d.id !== keeping).map((d) => d.id)))) return;
    for (const id of [...this.drafts.keys()]) if (id !== keeping) this.drafts.delete(id);
    this.syncDirty();
    this.documents = this.documents.filter((d) => d.id === keeping);
    this.selection = keeping;
    this.rightSelection = null;
    this.isSplit = false;
    this.focusedPane = 'left';
    this.changedOnDisk.clear();
    this.selectedFileID = (this.current || {}).libraryID || null;
    this.recomputeMatches(true);
    this.render(['all']);
  },

  /** Removes a file from the library (the file on disk stays) and closes it if open. */
  async removeFromLibrary(id) {
    const doc = this.documents.find((d) => d.libraryID === id);
    if (doc && !(await this.close(doc.id))) return;
    Library.remove(id);
  },
};
