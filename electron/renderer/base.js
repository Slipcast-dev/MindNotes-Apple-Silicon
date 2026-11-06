/* Localization, themes and preferences. Port of Localization.swift, Theme.swift and Settings.swift. */

// ---- Localization ----------------------------------------------------------
// Keys are the Russian source strings; English lives in strings-en.js (generated from en.lproj).

let LANG = 'ru';
let languagePref = 'auto'; // auto | ru | en, kept by the main process

function setLocale(locale) {
  LANG = String(locale || '').toLowerCase().startsWith('ru') ? 'ru' : 'en';
  document.documentElement.lang = LANG;
}

/** Windows shortcuts: the macOS glyphs become Ctrl / Shift / Alt. */
function keyNames(s) {
  return s
    .replace(/⌥(?![A-Za-z0-9\\])/g, 'Alt')
    .replace(/⌘/g, 'Ctrl+').replace(/⇧/g, 'Shift+').replace(/⌥/g, 'Alt+');
}

function t(key, ...args) {
  const raw = LANG === 'ru' ? key : ((window.STRINGS_EN || {})[key] || key);
  let i = 0;
  const formatted = args.length ? raw.replace(/%(?:@|d|lld)/g, () => String(args[i++])).replace(/%%/g, '%') : raw;
  return keyNames(formatted);
}

// ---- Themes ----------------------------------------------------------------

const PALETTE_ORDER = ['background', 'text', 'secondary', 'accent', 'heading', 'codeText', 'codeBackground', 'gutter', 'rule',
  'key', 'string', 'number', 'keyword', 'comment', 'error', 'warning', 'success'];

function makeTheme(dark, p) {
  const theme = { isDark: dark };
  PALETTE_ORDER.forEach((name, i) => {
    theme[name] = '#' + p[i].toString(16).padStart(6, '0').toUpperCase();
  });
  theme.match = dark ? 'rgba(255,214,10,0.38)' : 'rgba(255,214,10,0.5)';
  theme.currentMatch = '#FF9F0A';
  theme.bookmark = '#FF9F0A';
  return theme;
}

const THEME_SETS = [
  {
    id: 'xcode', name: 'Xcode',
    light: makeTheme(false, [0xFFFFFF, 0x24292F, 0x6E7781, 0x0A64D6, 0x0B7A6B, 0xB3361E, 0xF1F1F3, 0xB0B5BB, 0xD0D4D9,
      0x0550AE, 0xA3410F, 0x6F42C1, 0xC2185B, 0x6E7781, 0xCF222E, 0x9A6700, 0x1A7F37]),
    dark: makeTheme(true, [0x1E1F22, 0xD8D8D8, 0x8A8A8E, 0x4A9EFF, 0x7FD4C1, 0xE0A3A3, 0x2B2B2D, 0x5C5C60, 0x4A4A4E,
      0x6CB6FF, 0xE59F7B, 0xC9B6F5, 0xFF7AB2, 0x7F8C98, 0xFF6B6B, 0xFFB454, 0x6FCF97]),
  },
  {
    id: 'github', name: 'GitHub',
    light: makeTheme(false, [0xFFFFFF, 0x1F2328, 0x57606A, 0x0969DA, 0x0550AE, 0x953800, 0xF6F8FA, 0x8C959F, 0xD0D7DE,
      0x0550AE, 0x0A3069, 0x8250DF, 0xCF222E, 0x6E7781, 0xCF222E, 0x9A6700, 0x1A7F37]),
    dark: makeTheme(true, [0x0D1117, 0xC9D1D9, 0x8B949E, 0x58A6FF, 0x79C0FF, 0xFFA657, 0x161B22, 0x484F58, 0x30363D,
      0x79C0FF, 0xA5D6FF, 0xD2A8FF, 0xFF7B72, 0x8B949E, 0xFF7B72, 0xD29922, 0x3FB950]),
  },
  {
    id: 'solarized', name: 'Solarized',
    light: makeTheme(false, [0xFDF6E3, 0x586E75, 0x93A1A1, 0x268BD2, 0xCB4B16, 0x2AA198, 0xEEE8D5, 0x93A1A1, 0xD6CFB8,
      0x268BD2, 0x2AA198, 0xD33682, 0x859900, 0x93A1A1, 0xDC322F, 0xB58900, 0x859900]),
    dark: makeTheme(true, [0x002B36, 0x93A1A1, 0x657B83, 0x268BD2, 0xCB4B16, 0x2AA198, 0x073642, 0x586E75, 0x094352,
      0x268BD2, 0x2AA198, 0xD33682, 0x859900, 0x586E75, 0xDC322F, 0xB58900, 0x859900]),
  },
  {
    id: 'dracula', name: 'Dracula', light: null,
    dark: makeTheme(true, [0x282A36, 0xF8F8F2, 0x6272A4, 0xBD93F9, 0xBD93F9, 0xFF79C6, 0x343746, 0x6272A4, 0x44475A,
      0x8BE9FD, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x6272A4, 0xFF5555, 0xFFB86C, 0x50FA7B]),
  },
  {
    id: 'monokai', name: 'Monokai', light: null,
    dark: makeTheme(true, [0x272822, 0xF8F8F2, 0x90908A, 0x66D9EF, 0xA6E22E, 0xE6DB74, 0x33342C, 0x75715E, 0x49483E,
      0xA6E22E, 0xE6DB74, 0xAE81FF, 0xF92672, 0x75715E, 0xF92672, 0xFD971F, 0xA6E22E]),
  },
  {
    id: 'nord', name: 'Nord',
    light: makeTheme(false, [0xECEFF4, 0x2E3440, 0x4C566A, 0x5E81AC, 0x5E81AC, 0xD08770, 0xE5E9F0, 0x9AA3B5, 0xD8DEE9,
      0x5E81AC, 0x6A8F4E, 0x8C5E8F, 0x4C6F9E, 0x7B88A1, 0xBF616A, 0xC79A2E, 0x6A8F4E]),
    dark: makeTheme(true, [0x2E3440, 0xD8DEE9, 0x7B88A1, 0x88C0D0, 0x88C0D0, 0xEBCB8B, 0x3B4252, 0x616E88, 0x434C5E,
      0x8FBCBB, 0xA3BE8C, 0xB48EAD, 0x81A1C1, 0x616E88, 0xBF616A, 0xEBCB8B, 0xA3BE8C]),
  },
  {
    id: 'onedark', name: 'One Dark',
    light: makeTheme(false, [0xFAFAFA, 0x383A42, 0x696C77, 0x4078F2, 0xE45649, 0xC18401, 0xF0F0F1, 0x9D9D9F, 0xDBDBDC,
      0xE45649, 0x50A14F, 0xC18401, 0xA626A4, 0xA0A1A7, 0xE45649, 0xC18401, 0x50A14F]),
    dark: makeTheme(true, [0x282C34, 0xABB2BF, 0x7F848E, 0x61AFEF, 0xE06C75, 0xD19A66, 0x21252B, 0x4B5263, 0x3E4451,
      0xE06C75, 0x98C379, 0xD19A66, 0xC678DD, 0x5C6370, 0xE06C75, 0xE5C07B, 0x98C379]),
  },
];

const findThemeSet = (id) => THEME_SETS.find((s) => s.id === id) || THEME_SETS[0];
/** Themes without a light variant stay dark in light mode. */
const themeVariant = (set, dark) => (dark ? set.dark : (set.light || set.dark));

// ---- Preferences -----------------------------------------------------------

const SYSTEM_FONT = 'system';
const FONTS = [SYSTEM_FONT, 'Georgia', 'Palatino Linotype', 'Times New Roman', 'Segoe UI', 'Calibri', 'Cambria', 'Consolas'];
// Color emoji fonts come last so emoji render the same everywhere.
const EMOJI = "'Segoe UI Emoji', 'Apple Color Emoji', 'Noto Color Emoji'";
const SANS_STACK = `system-ui, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif, ${EMOJI}`;
const MONO_STACK = `'Cascadia Mono', Consolas, Menlo, 'SF Mono', 'Courier New', monospace, ${EMOJI}`;

const darkQuery = window.matchMedia('(prefers-color-scheme: dark)');

const Prefs = {
  values: {
    appearance: 'system', // system | light | dark
    themeID: 'xcode',
    fontName: SYSTEM_FONT,
    fontSize: 15,
    headingSpacing: 1,
    showLineNumbers: true,
    autoReload: false,
    spellCheck: true, // spelling check of prose in Edit mode (Russian and English)
    syntaxOn: true,
    syntaxOff: [], // file types with highlighting switched off
  },
  listeners: [],

  load() {
    try {
      Object.assign(this.values, JSON.parse(localStorage.getItem('grizzly.prefs') || localStorage.getItem('mdreader.prefs') || '{}'));
    } catch { /* first launch or storage unavailable */ }
    darkQuery.addEventListener('change', () => this.emit());
  },

  set(patch) {
    Object.assign(this.values, patch);
    try { localStorage.setItem('grizzly.prefs', JSON.stringify(this.values)); } catch { /* ignore */ }
    this.emit();
  },

  emit() { this.listeners.forEach((fn) => fn()); },
  onChange(fn) { this.listeners.push(fn); },

  get wantsDark() {
    const a = this.values.appearance;
    return a === 'system' ? darkQuery.matches : a === 'dark';
  },

  get theme() { return themeVariant(findThemeSet(this.values.themeID), this.wantsDark); },

  resizeFont(delta) {
    this.set({ fontSize: Math.min(28, Math.max(10, this.values.fontSize + delta)) });
  },

  /** CSS font-family for reading text. */
  get fontFamily() {
    const n = this.values.fontName;
    return n === SYSTEM_FONT ? SANS_STACK : `'${n}', ${SANS_STACK}`;
  },
};

/** Pushes the active theme and font settings into CSS custom properties. */
function applyTheme() {
  const th = Prefs.theme;
  const root = document.documentElement;
  const vars = {
    bg: th.background, text: th.text, secondary: th.secondary, accent: th.accent, heading: th.heading,
    codetext: th.codeText, codebg: th.codeBackground, gutter: th.gutter, rule: th.rule,
    key: th.key, string: th.string, number: th.number, keyword: th.keyword, comment: th.comment,
    error: th.error, warning: th.warning, success: th.success,
    match: th.match, current: th.currentMatch, bookmark: th.bookmark,
  };
  for (const [k, v] of Object.entries(vars)) root.style.setProperty('--' + k, v);
  root.style.setProperty('--reading-font', Prefs.fontFamily);
  root.style.setProperty('--mono-font', MONO_STACK);
  root.style.colorScheme = th.isDark ? 'dark' : 'light';
  root.dataset.dark = th.isDark ? '1' : '0';
}
