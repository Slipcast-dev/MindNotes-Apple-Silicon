const { app, BrowserWindow, Menu, dialog, ipcMain, shell, nativeTheme, screen } = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const updater = require('./updater');

const EXTENSIONS = ['md', 'markdown', 'mdown', 'txt', 'text', 'json', 'yaml', 'yml', 'csv', 'tsv', 'log',
  'xml', 'html', 'htm', 'ini', 'conf', 'toml', 'tex', 'rtf',
  'py', 'pyw', 'swift', 'c', 'h', 'cpp', 'cc', 'cxx', 'hpp', 'hh', 'hxx', 'cs', 'js', 'mjs', 'cjs', 'jsx', 'ts', 'tsx', 'css', 'scss', 'php'];

// Portable build: keep settings and the library next to the .exe when that folder is writable.
// The app used to be called MD Reader: its data folders are renamed once so settings and the library carry over.
function migrate(from, to) {
  try { if (fs.existsSync(from) && !fs.existsSync(to)) fs.renameSync(from, to); } catch { /* start fresh */ }
}

(function pickDataDir() {
  const dir = process.env.PORTABLE_EXECUTABLE_DIR;
  if (!dir) {
    migrate(path.join(app.getPath('appData'), 'MD Reader'), path.join(app.getPath('appData'), 'Grizzly'));
    return;
  }
  migrate(path.join(dir, 'MDReaderData'), path.join(dir, 'GrizzlyData'));
  const data = path.join(dir, 'GrizzlyData');
  try {
    fs.mkdirSync(data, { recursive: true });
    fs.accessSync(data, fs.constants.W_OK);
    app.setPath('userData', data);
  } catch { /* read-only location: fall back to %APPDATA% */ }
})();

let STRINGS_EN = {};
try { STRINGS_EN = require('./strings-en.json'); } catch { /* English table is optional */ }

// Interface language: 'auto' follows the system (Russian on a Russian system, English otherwise), or 'ru' / 'en'.
const languagePath = () => path.join(app.getPath('userData'), 'language.json');
function loadLanguage() {
  try {
    const v = JSON.parse(fs.readFileSync(languagePath(), 'utf8')).language;
    return ['auto', 'ru', 'en'].includes(v) ? v : 'auto';
  } catch { return 'auto'; }
}
let languagePref = 'auto';
const resolveLocale = () => (languagePref === 'auto' ? (app.getLocale().toLowerCase().startsWith('ru') ? 'ru' : 'en') : languagePref);
const T = (key) => (resolveLocale() === 'ru' ? key : (STRINGS_EN[key] || key));

let win = null;
let forceClose = false;
let rendererReady = false;
let pendingFiles = [];

function filesFromArgv(argv) {
  const args = process.defaultApp ? argv.slice(2) : argv.slice(1);
  return args
    .filter((a) => !a.startsWith('-'))
    .map((a) => path.resolve(a))
    .filter((p) => { try { return fs.statSync(p).isFile(); } catch { return false; } });
}


function deliver(paths) {
  if (!paths.length) return;
  approve(paths);
  if (win && rendererReady) win.webContents.send('open-files', paths);
  else pendingFiles.push(...paths);
}

const statePath = () => path.join(app.getPath('userData'), 'window.json');

function loadBounds() {
  try { return JSON.parse(fs.readFileSync(statePath(), 'utf8')); } catch { return {}; }
}

/** Drops a saved position that is no longer on any screen (a disconnected monitor would leave the window unreachable). */
function visibleOnScreen(b) {
  if (typeof b.x !== 'number' || typeof b.y !== 'number') return false;
  const w = b.width || 1100;
  const h = b.height || 720;
  return screen.getAllDisplays().some(({ workArea: a }) =>
    b.x + w > a.x + 80 && b.x < a.x + a.width - 80 && b.y + 40 > a.y && b.y < a.y + a.height - 40);
}

function createWindow() {
  const saved = loadBounds();
  if (!visibleOnScreen(saved)) { delete saved.x; delete saved.y; }
  win = new BrowserWindow({
    width: saved.width || 1100,
    height: saved.height || 720,
    x: saved.x,
    y: saved.y,
    minWidth: 720,
    minHeight: 460,
    show: false,
    title: 'Grizzly',
    icon: path.join(__dirname, 'assets', 'icon.png'),
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#1e1f22' : '#ffffff',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
  });
  setupSpellcheck();
  // The page needs no camera, location, notifications and the like.
  win.webContents.session.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  win.webContents.session.setPermissionCheckHandler(() => false);
  if (app.isPackaged) win.webContents.on('devtools-opened', () => win.webContents.closeDevTools());
  if (saved.maximized) win.maximize();
  win.once('ready-to-show', () => win.show());
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  win.webContents.setWindowOpenHandler(({ url }) => { openExternal(url); return { action: 'deny' }; });
  // The window never leaves its own page: a stray file:// link or drop must not replace the UI (the trusted-sender check would then fail).
  const ownPage = require('url').pathToFileURL(path.join(__dirname, 'renderer', 'index.html')).href;
  win.webContents.on('will-navigate', (e, url) => {
    if (url === ownPage) return;
    e.preventDefault();
    if (!url.startsWith('file://')) openExternal(url);
  });

  const saveBounds = () => {
    if (!win || win.isDestroyed()) return;
    const maximized = win.isMaximized();
    const b = win.getNormalBounds();
    try { fs.writeFileSync(statePath(), JSON.stringify({ ...b, maximized })); } catch { /* ignore */ }
  };
  win.on('close', (e) => {
    if (hasUnsaved && !forceClose) {
      // The page asks about every unsaved file (save / don't save / cancel) and then calls app:closeWindow.
      e.preventDefault();
      win.webContents.send('menu', 'closeWindow');
      return;
    }
    saveBounds();
  });
  win.on('closed', () => { win = null; rendererReady = false; });
}

/** Russian and English spelling check in text fields, with suggestions in the context menu. */
function setupSpellcheck() {
  const ses = win.webContents.session;
  try {
    const wanted = ['ru', 'en-US'].filter((l) => ses.availableSpellCheckerLanguages.includes(l));
    if (wanted.length) ses.setSpellCheckerLanguages(wanted);
  } catch { /* the system spell checker decides */ }
  win.webContents.on('context-menu', (_e, params) => {
    if (!params.isEditable && !params.selectionText) return;
    const items = [];
    if (params.misspelledWord) {
      for (const word of params.dictionarySuggestions.slice(0, 5)) {
        items.push({ label: word, click: () => win.webContents.replaceMisspelling(word) });
      }
      if (!params.dictionarySuggestions.length) items.push({ label: T('Нет вариантов'), enabled: false });
      items.push({ label: T('Добавить в словарь'), click: () => ses.addWordToSpellCheckerDictionary(params.misspelledWord) },
        { type: 'separator' });
    }
    if (params.isEditable) items.push({ role: 'undo' }, { role: 'redo' }, { type: 'separator' }, { role: 'cut' });
    items.push({ role: 'copy' });
    if (params.isEditable) items.push({ role: 'paste' });
    items.push({ role: 'selectAll' });
    Menu.buildFromTemplate(items).popup({ window: win });
  });
}

function openExternal(url) {
  if (/^(https?:|mailto:)/i.test(url)) shell.openExternal(url);
}

function send(action) {
  if (win) win.webContents.send('menu', action);
}

function buildMenu() {
  const item = (label, action, accelerator, extra = {}) => ({
    label: T(label), accelerator, click: () => send(action), ...extra,
  });
  // Hidden twins give a second shortcut for the same command.
  const alias = (action, accelerator) => ({ label: action, accelerator, visible: false, click: () => send(action) });

  const template = [
    {
      label: T('Файл'),
      submenu: [
        item('Новый файл…', 'newFile', 'CmdOrCtrl+N'),
        item('Открыть…', 'open', 'CmdOrCtrl+O'),
        item('Добавить папку с диска…', 'openFolder', 'CmdOrCtrl+Shift+O'),
        item('Сохранить', 'save', 'CmdOrCtrl+S'),
        item('Сохранить как…', 'saveAs', 'CmdOrCtrl+Shift+S'),
        item('Закрыть вкладку', 'closeTab', 'CmdOrCtrl+W'),
        { type: 'separator' },
        item('Настройки…', 'settings', 'CmdOrCtrl+,'),
        { type: 'separator' },
        { label: T('Выход'), role: 'quit' },
      ],
    },
    {
      label: T('Правка'),
      submenu: [
        { role: 'undo' }, { role: 'redo' }, { type: 'separator' },
        { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' },
      ],
    },
    {
      label: T('Поиск'),
      submenu: [
        item('Найти…', 'find', 'CmdOrCtrl+F'),
        item('Найти далее', 'findNext', 'CmdOrCtrl+G'),
        item('Найти ранее', 'findPrev', 'CmdOrCtrl+Shift+G'),
        alias('findNext', 'F3'),
        alias('findPrev', 'Shift+F3'),
      ],
    },
    {
      label: T('Вкладки'),
      submenu: [
        item('Следующая вкладка', 'nextTab', 'CmdOrCtrl+Shift+]'),
        item('Предыдущая вкладка', 'prevTab', 'CmdOrCtrl+Shift+['),
        alias('nextTab', 'Ctrl+Tab'),
        alias('prevTab', 'Ctrl+Shift+Tab'),
        { type: 'separator' },
        item('Два файла рядом', 'split', 'CmdOrCtrl+\\'),
      ],
    },
    {
      label: T('Вид'),
      submenu: [
        item('Режим чтения', 'modeReading', 'CmdOrCtrl+Alt+1'),
        item('Исходник', 'modeSource', 'CmdOrCtrl+Alt+2'),
        item('Правка', 'modeEdit', 'CmdOrCtrl+Alt+3'),
        { type: 'separator' },
        item('Обновить файл', 'reload', 'CmdOrCtrl+R'),
        item('Крупнее', 'fontUp', 'CmdOrCtrl+Plus'),
        item('Мельче', 'fontDown', 'CmdOrCtrl+-'),
        alias('fontUp', 'CmdOrCtrl+='),
        { type: 'separator' },
        { role: 'togglefullscreen' },
        ...(app.isPackaged ? [] : [{ label: 'DevTools', accelerator: 'CmdOrCtrl+Shift+I', visible: false, role: 'toggleDevTools' }]),
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---- IPC ----------------------------------------------------------------

const decode = (buf, label) => new TextDecoder(label).decode(buf);

function rtfToText(src) {
  // Minimal RTF reader: keeps text, paragraphs, \'hh and \uN escapes, drops control words and hidden groups.
  const skip = new Set(['fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'header', 'footer', 'object', 'themedata',
    'colorschememapping', 'latentstyles', 'datastore', 'listtable', 'listoverridetable', 'rsidtbl', 'generator']);
  const cp = /\\ansicpg(\d+)/.exec(src);
  const codepage = cp ? 'windows-' + cp[1] : 'windows-1252';
  // One entry per open group: whether its text is ignored, and the \uc value in force.
  const stack = [{ ignored: false, uc: 1 }];
  let out = '';
  let i = 0;
  const hexBytes = [];
  const flushHex = () => {
    if (!hexBytes.length) return;
    try { out += decode(Uint8Array.from(hexBytes), codepage); } catch { out += decode(Uint8Array.from(hexBytes), 'windows-1252'); }
    hexBytes.length = 0;
  };
  while (i < src.length) {
    const c = src[i];
    const top = stack[stack.length - 1];
    if (c === '{') {
      flushHex();
      // {\*\dest ...} and known destinations are ignored as a whole.
      const rest = src.slice(i + 1, i + 40);
      const dest = /^\\([a-z]+)/.exec(rest);
      stack.push({ ignored: top.ignored || rest.startsWith('\\*') || !!(dest && skip.has(dest[1])), uc: top.uc });
      i++;
    } else if (c === '}') {
      flushHex();
      if (stack.length > 1) stack.pop();
      i++;
    } else if (c === '\\') {
      const n = src[i + 1];
      if (n === "'") {
        const byte = parseInt(src.substr(i + 2, 2), 16);
        if (!top.ignored && !Number.isNaN(byte)) hexBytes.push(byte);
        i += 4;
        continue;
      }
      flushHex();
      if (n === '\\' || n === '{' || n === '}') { if (!top.ignored) out += n; i += 2; continue; }
      if (n === '~') { if (!top.ignored) out += ' '; i += 2; continue; }
      if (n === '-' || n === '_' || n === '*') { i += 2; continue; }
      const m = /^\\([a-zA-Z]+)(-?\d+)? ?/.exec(src.slice(i, i + 40));
      if (!m) { i += 2; continue; }
      const word = m[1];
      const arg = m[2] === undefined ? undefined : parseInt(m[2], 10);
      i += m[0].length;
      if (top.ignored) continue;
      if (word === 'par' || word === 'line') out += '\n';
      else if (word === 'tab') out += '\t';
      else if (word === 'emdash') out += '—';
      else if (word === 'endash') out += '–';
      else if (word === 'bullet') out += '•';
      else if (word === 'lquote') out += '‘';
      else if (word === 'rquote') out += '’';
      else if (word === 'ldblquote') out += '“';
      else if (word === 'rdblquote') out += '”';
      else if (word === 'uc' && arg !== undefined) top.uc = arg;
      else if (word === 'u' && arg !== undefined) {
        out += String.fromCharCode(arg < 0 ? arg + 65536 : arg);
        i += top.uc; // skip the ANSI fallback characters
      }
    } else if (c === '\r' || c === '\n') {
      i++;
    } else {
      flushHex();
      if (!top.ignored) out += c;
      i++;
    }
  }
  flushHex();
  return out.replace(/\n{3,}/g, '\n\n').trim() + '\n';
}

/** Reads a file and decodes it: UTF-8 (BOM), UTF-16 (BOM), UTF-8, then Windows-1251. */
function readText(file) {
  if (fs.statSync(file).size > MAX_READ) throw Object.assign(new Error('file too large'), { code: 'EFBIG' });
  const buf = fs.readFileSync(file);
  if (path.extname(file).toLowerCase() === '.rtf') {
    return { text: rtfToText(buf.toString('latin1')), encoding: 'RTF' };
  }
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    return { text: decode(buf.subarray(3), 'utf-8'), encoding: 'UTF-8' };
  }
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) return { text: decode(buf.subarray(2), 'utf-16le'), encoding: 'UTF-16' };
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) return { text: decode(buf.subarray(2), 'utf-16be'), encoding: 'UTF-16' };
  try {
    return { text: new TextDecoder('utf-8', { fatal: true }).decode(buf), encoding: 'UTF-8' };
  } catch { /* not UTF-8 */ }
  return { text: decode(buf, 'windows-1251'), encoding: 'Windows-1251' };
}

/** IPC hardening: only our own page may call, and only with absolute paths to supported file types. */
function trusted(e) {
  try { return e.senderFrame.url.startsWith('file://') && e.senderFrame.url.endsWith('/renderer/index.html'); } catch { return false; }
}
function validPath(file) {
  return typeof file === 'string' && path.isAbsolute(file) && !file.includes('\0')
    && EXTENSIONS.includes(path.extname(file).slice(1).toLowerCase());
}
const refuse = { ok: false, code: 'EACCES' };

// Files the user brought in (dialogs, command line, folder scan, a successful read). Writes are limited to these.
const approved = new Set();
const approve = (list) => { for (const p of list) if (typeof p === 'string') approved.add(path.resolve(p)); };
const MAX_READ = 100 * 1024 * 1024;

ipcMain.handle('app:info', () => ({
  platform: process.platform,
  locale: resolveLocale(),
  language: languagePref,
  version: app.getVersion(),
  dataDir: app.getPath('userData'),
}));

ipcMain.handle('language:set', (e, language) => {
  if (!trusted(e) || !['auto', 'ru', 'en'].includes(language)) return resolveLocale();
  languagePref = language;
  try { fs.writeFileSync(languagePath(), JSON.stringify({ language })); } catch { /* not persisted this time */ }
  buildMenu();
  return resolveLocale();
});

ipcMain.on('renderer:ready', (e) => {
  if (!win || !trusted(e)) return;
  rendererReady = true;
  if (pendingFiles.length) { win.webContents.send('open-files', pendingFiles); pendingFiles = []; }
});

ipcMain.handle('dialog:open', async (e) => {
  if (!trusted(e)) return [];
  const result = await dialog.showOpenDialog(win, {
    properties: ['openFile', 'multiSelections'],
    filters: [
      { name: T('Файлы Grizzly'), extensions: EXTENSIONS },
      { name: T('Все файлы'), extensions: ['*'] },
    ],
  });
  if (!result.canceled) approve(result.filePaths);
  return result.canceled ? [] : result.filePaths;
});

ipcMain.handle('dialog:openFolder', async (e) => {
  if (!trusted(e)) return [];
  const result = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'multiSelections'] });
  return result.canceled ? [] : result.filePaths;
});

/** Supported files under a directory (subfolders included), grouped by their directory. Null if the path is not a directory. */
ipcMain.handle('fs:scanDir', (e, root) => {
  if (!trusted(e) || typeof root !== 'string' || !path.isAbsolute(root)) return null;
  try { if (!fs.statSync(root).isDirectory()) return null; } catch { return null; }
  const out = [];
  const walk = (dir, depth) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const ent of entries) {
      if (ent.name.startsWith('.')) continue;
      const full = path.join(dir, ent.name);
      if (ent.isDirectory()) { if (depth < 8) walk(full, depth + 1); }
      else if (ent.isFile() && EXTENSIONS.includes(path.extname(ent.name).slice(1).toLowerCase())) out.push({ path: full, dir });
    }
  };
  walk(root, 0);
  approve(out.map((f) => f.path));
  return out;
});

ipcMain.handle('file:read', (e, file) => {
  if (!trusted(e) || !validPath(file)) return refuse;
  try {
    const { text, encoding } = readText(file);
    approve([file]);
    return { ok: true, text, encoding, mtimeMs: fs.statSync(file).mtimeMs };
  } catch (err) {
    return { ok: false, code: err.code || 'EREAD' };
  }
});

/** Plain text as a minimal RTF document (the original formatting is not kept). */
function textToRtf(text) {
  let out = '{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Helvetica;}}\\f0\\fs24 ';
  for (const ch of text) {
    if (ch === '\\' || ch === '{' || ch === '}') out += '\\' + ch;
    else if (ch === '\n') out += '\\par\n';
    else if (ch === '\t') out += '\\tab ';
    else if (ch === '\r') continue;
    else if (ch.codePointAt(0) < 128) out += ch;
    else for (let i = 0; i < ch.length; i++) { const u = ch.charCodeAt(i); out += '\\u' + (u > 32767 ? u - 65536 : u) + '?'; }
  }
  return out + '}';
}

let cp1251 = null;
function encodeCp1251(text) {
  if (!cp1251) {
    cp1251 = new Map();
    const dec = new TextDecoder('windows-1251');
    for (let b = 0x80; b < 256; b++) cp1251.set(dec.decode(Uint8Array.of(b)), b);
  }
  const out = [];
  for (const ch of text) {
    const code = ch.codePointAt(0);
    const byte = code < 0x80 ? code : cp1251.get(ch);
    if (byte === undefined) throw Object.assign(new Error('unmappable character'), { code: 'EENCODE' });
    out.push(byte);
  }
  return Buffer.from(out);
}

/** Inverse of readText: writes the text back in the encoding the file was read with (a UTF-8 BOM is kept). */
function encodeText(text, encoding, file) {
  switch (encoding) {
    case 'UTF-16': return Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')]);
    case 'Windows-1251': return encodeCp1251(text);
    case 'RTF': return Buffer.from(textToRtf(text), 'latin1');
    case 'UTF-8': {
      let bom = false;
      try {
        const head = Buffer.alloc(3);
        const fd = fs.openSync(file, 'r');
        try { bom = fs.readSync(fd, head, 0, 3, 0) === 3 && head[0] === 0xef && head[1] === 0xbb && head[2] === 0xbf; } finally { fs.closeSync(fd); }
      } catch { /* a new or unreadable file has no BOM */ }
      return Buffer.concat([bom ? Buffer.from([0xef, 0xbb, 0xbf]) : Buffer.alloc(0), Buffer.from(text, 'utf8')]);
    }
  }
  throw Object.assign(new Error('unsupported encoding'), { code: 'EENCODE' });
}

ipcMain.handle('file:write', (e, file, text, encoding) => {
  if (!trusted(e) || !validPath(file) || !approved.has(path.resolve(file))) return refuse;
  try {
    fs.writeFileSync(file, encodeText(String(text), encoding, file));
    return { ok: true, mtimeMs: fs.statSync(file).mtimeMs };
  } catch (err) {
    return { ok: false, code: err.code || 'EWRITE' };
  }
});

const FORMATS = [
  ['Markdown', ['md', 'markdown', 'mdown']], ['Text', ['txt', 'text']], ['JSON', ['json']], ['YAML', ['yaml', 'yml']],
  ['CSV', ['csv']], ['TSV', ['tsv']], ['Log', ['log']], ['XML', ['xml']], ['HTML', ['html', 'htm']],
  ['Config', ['ini', 'conf', 'toml']], ['TeX', ['tex']], ['RTF', ['rtf']],
  ['Python', ['py', 'pyw']], ['Swift', ['swift']], ['C / C++', ['cpp', 'c', 'cc', 'cxx', 'h', 'hpp', 'hh', 'hxx']], ['C#', ['cs']],
  ['JavaScript', ['js', 'mjs', 'cjs', 'jsx']], ['TypeScript', ['ts', 'tsx']], ['CSS', ['css', 'scss']], ['PHP', ['php']],
];

/** Starter content for a newly created file. */
function templateFor(ext) {
  switch (ext) {
    case 'md': case 'markdown': case 'mdown': return '# \n\n';
    case 'json': return '{\n  \n}\n';
    case 'csv': return 'column1,column2\n';
    case 'tsv': return 'column1\tcolumn2\n';
    case 'html': case 'htm': return '<!DOCTYPE html>\n<html>\n<head>\n  <meta charset="utf-8">\n  <title></title>\n</head>\n<body>\n\n</body>\n</html>\n';
    case 'xml': return '<?xml version="1.0" encoding="UTF-8"?>\n';
    case 'tex': return '\\documentclass{article}\n\\begin{document}\n\n\\end{document}\n';
    case 'swift': return 'import Foundation\n\n';
    case 'c': return '#include <stdio.h>\n\nint main(void) {\n    return 0;\n}\n';
    case 'cpp': case 'cc': case 'cxx': return '#include <iostream>\n\nint main() {\n    return 0;\n}\n';
    case 'h': case 'hpp': case 'hh': case 'hxx': return '#pragma once\n';
    case 'cs': return 'using System;\n\nclass Program\n{\n    static void Main()\n    {\n    }\n}\n';
    case 'js': case 'mjs': case 'cjs': case 'jsx': return "'use strict';\n\n";
    case 'css': case 'scss': return 'body {\n}\n';
    case 'php': return '<?php\n\n';
    default: return '';
  }
}

/** New file: the user picks name, place and format; the file is written with a starter template. */
ipcMain.handle('dialog:newFile', async (e, dir) => {
  if (!trusted(e)) return refuse;
  const result = await dialog.showSaveDialog(win, {
    title: T('Новый файл'),
    defaultPath: path.join(typeof dir === 'string' && path.isAbsolute(dir) ? dir : app.getPath('documents'), T('Без названия')),
    filters: FORMATS.map(([label, exts]) => ({ name: `${label} (.${exts[0]})`, extensions: exts })),
  });
  if (result.canceled || !result.filePath) return { ok: false, code: 'ECANCEL' };
  let file = result.filePath;
  if (!EXTENSIONS.includes(path.extname(file).slice(1).toLowerCase())) {
    file += '.md';
    // The dialog already confirmed the name without the extension; the real target may be an existing file.
    if (fs.existsSync(file)) return { ok: false, code: 'EEXIST', name: path.basename(file) };
  }
  const ext = path.extname(file).slice(1).toLowerCase();
  try {
    fs.writeFileSync(file, encodeText(templateFor(ext), ext === 'rtf' ? 'RTF' : 'UTF-8', file));
    approve([file]);
    return { ok: true, path: file };
  } catch (err) {
    return { ok: false, code: err.code || 'EWRITE', name: path.basename(file) };
  }
});

/** Save a copy in a chosen format and place; the open document is left as it is. */
ipcMain.handle('dialog:saveAs', async (e, name, text, encoding, dir) => {
  if (!trusted(e) || typeof name !== 'string') return refuse;
  const own = path.extname(name).slice(1).toLowerCase();
  // The format of the current file comes first, so it is the dialog's default.
  const formats = [...FORMATS].sort((a, b) => Number(b[1].includes(own)) - Number(a[1].includes(own)));
  const result = await dialog.showSaveDialog(win, {
    title: T('Сохранить как…'),
    // The name is offered without its extension: the format is chosen with the file-type list and added on save.
    defaultPath: path.join(typeof dir === 'string' && path.isAbsolute(dir) ? dir : app.getPath('documents'), path.basename(name, path.extname(name))),
    filters: formats.map(([label, exts]) => ({ name: `${label} (.${exts[0]})`, extensions: exts })),
  });
  if (result.canceled || !result.filePath) return { ok: false, code: 'ECANCEL' };
  let file = result.filePath;
  if (!EXTENSIONS.includes(path.extname(file).slice(1).toLowerCase())) {
    file += '.' + formats[0][1][0];
    if (fs.existsSync(file)) return { ok: false, code: 'EEXIST' };
  }
  const toRtf = path.extname(file).toLowerCase() === '.rtf';
  // Text formats keep the source encoding; RTF is its own container and RTF sources become UTF-8.
  let enc = toRtf ? 'RTF' : (encoding === 'RTF' ? 'UTF-8' : encoding);
  try {
    let data;
    try { data = encodeText(String(text), enc, file); } catch (err) {
      if (err.code !== 'EENCODE' || enc === 'UTF-8') throw err;
      enc = 'UTF-8';
      data = encodeText(String(text), enc, file);
    }
    fs.writeFileSync(file, data);
    approve([file]);
    return { ok: true, path: file, encoding: enc };
  } catch (err) {
    return { ok: false, code: err.code || 'EWRITE' };
  }
});

ipcMain.handle('dialog:confirmSave', async (e, name) => {
  if (!trusted(e)) return 'cancel';
  const { response } = await dialog.showMessageBox(win, {
    type: 'warning',
    message: T('Сохранить изменения в «%@»?').replace('%@', name),
    detail: T('Изменения будут потеряны, если их не сохранить.'),
    buttons: [T('Сохранить'), T('Не сохранять'), T('Отмена')],
    defaultId: 0,
    cancelId: 2,
    noLink: true,
  });
  return ['save', 'discard', 'cancel'][response];
});

let hasUnsaved = false;
ipcMain.on('app:dirty', (e, dirty) => { if (trusted(e)) hasUnsaved = !!dirty; });

ipcMain.handle('file:mtimes', (e, files) => {
  const out = {};
  if (!trusted(e) || !Array.isArray(files)) return out;
  for (const f of files) {
    if (!validPath(f)) { out[f] = null; continue; }
    try { out[f] = fs.statSync(f).mtimeMs; } catch { out[f] = null; }
  }
  return out;
});

ipcMain.handle('shell:reveal', (e, file) => { if (trusted(e) && typeof file === 'string' && path.isAbsolute(file) && !file.includes('\0')) shell.showItemInFolder(file); });
ipcMain.handle('shell:external', (e, url) => { if (trusted(e)) openExternal(String(url)); });

ipcMain.handle('dialog:confirmUtf8', async (e, name, encoding) => {
  if (!trusted(e)) return false;
  const { response } = await dialog.showMessageBox(win, {
    type: 'warning',
    message: T('В тексте есть символы (например, эмодзи), которых нет в кодировке %@.').replace('%@', String(encoding)),
    detail: T('Сохранить файл «%@» в кодировке UTF-8?').replace('%@', String(name)),
    buttons: [T('Сохранить в UTF-8'), T('Отмена')],
    defaultId: 0,
    cancelId: 1,
    noLink: true,
  });
  return response === 0;
});

ipcMain.handle('app:emoji', (e) => { if (trusted(e)) app.showEmojiPanel(); });

/** Called by the page once every unsaved file was saved or its edits were dropped on purpose. */
ipcMain.handle('app:closeWindow', (e) => {
  if (!trusted(e) || !win) return;
  forceClose = true;
  win.close();
});

// ---- Updates ----------------------------------------------------------------

let pendingRelease = null; // what the page may install; the page never supplies a download address
let downloadedUpdate = null;

ipcMain.handle('update:check', async (e) => {
  if (!trusted(e)) return { ok: false };
  const current = app.getVersion();
  try {
    const release = await updater.fetchLatest(current);
    if (release && updater.isNewer(release.version, current)) {
      pendingRelease = release;
      return { ok: true, available: true, current, version: release.version, notes: release.notes };
    }
    pendingRelease = null;
    return { ok: true, available: false, current };
  } catch {
    return { ok: false, current };
  }
});

ipcMain.handle('update:download', async (e) => {
  if (!trusted(e) || !pendingRelease) return { ok: false };
  try {
    downloadedUpdate = await updater.download(pendingRelease, app.getVersion(), (progress) => {
      if (win) win.webContents.send('update:progress', progress);
    });
    return { ok: true };
  } catch (err) {
    return { ok: false, code: err.code || 'EDOWNLOAD' };
  }
});

/** Replaces the portable exe once the app has exited (a helper script waits for it), then starts the new version. */
ipcMain.handle('update:apply', (e) => {
  if (!trusted(e) || !downloadedUpdate) return { ok: false };
  const target = process.env.PORTABLE_EXECUTABLE_FILE;
  if (process.platform !== 'win32' || !target) {
    // Not the portable build: leave the downloaded file for the user to run.
    shell.showItemInFolder(downloadedUpdate);
    return { ok: false, code: 'MANUAL' };
  }
  try {
    const script = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'grizzly-upd-')), 'replace.cmd');
    fs.writeFileSync(script, updater.REPLACE_SCRIPT);
    spawn('cmd.exe', ['/c', script, downloadedUpdate, target], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  } catch {
    shell.showItemInFolder(downloadedUpdate);
    return { ok: false, code: 'MANUAL' };
  }
  forceClose = true;
  setTimeout(() => app.quit(), 100);
  return { ok: true };
});

// What was open when an update restarted the app; the new copy takes it once and puts it back.
const sessionPath = () => path.join(app.getPath('userData'), 'session.json');

ipcMain.handle('session:save', (e, session) => {
  if (!trusted(e) || !session || typeof session !== 'object') return false;
  try {
    const json = JSON.stringify({ ...session, date: Date.now() });
    if (json.length > 1024 * 1024) return false;
    fs.writeFileSync(sessionPath(), json);
    return true;
  } catch { return false; }
});

ipcMain.handle('session:take', (e) => {
  if (!trusted(e)) return null;
  try {
    const session = JSON.parse(fs.readFileSync(sessionPath(), 'utf8'));
    fs.rmSync(sessionPath(), { force: true });
    return Date.now() - session.date < 10 * 60 * 1000 ? session : null;
  } catch { return null; }
});

const libraryPath = () => path.join(app.getPath('userData'), 'library.json');

ipcMain.handle('library:load', (e) => {
  if (!trusted(e)) return null;
  try { return fs.readFileSync(libraryPath(), 'utf8'); } catch { return null; }
});

ipcMain.handle('library:save', (e, json) => {
  if (!trusted(e) || typeof json !== 'string' || json.length > 20 * 1024 * 1024) return false;
  const tmp = libraryPath() + '.tmp';
  try {
    fs.writeFileSync(tmp, json);
    fs.renameSync(tmp, libraryPath());
    return true;
  } catch { return false; }
});

// ---- Lifecycle ----------------------------------------------------------

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => {
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
    deliver(filesFromArgv(argv));
  });

  app.whenReady().then(() => {
    pendingFiles = filesFromArgv(process.argv);
    approve(pendingFiles);
    languagePref = loadLanguage();
    buildMenu();
    createWindow();
    app.on('activate', () => { if (!BrowserWindow.getAllWindows().length) createWindow(); });
  });

  app.on('window-all-closed', () => app.quit());
}
