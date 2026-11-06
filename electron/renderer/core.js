/* Document model: file types, Markdown / CSV parsing, syntax rules and search.
   A direct port of Core/*.swift from the macOS app. */

// ---- File types ------------------------------------------------------------

const EXTENSION_TYPES = {
  md: 'markdown', markdown: 'markdown', mdown: 'markdown',
  txt: 'text', text: 'text',
  json: 'json',
  yaml: 'yaml', yml: 'yaml',
  csv: 'csv', tsv: 'csv',
  log: 'log',
  xml: 'xml',
  html: 'html', htm: 'html',
  ini: 'config', conf: 'config', toml: 'config',
  tex: 'tex',
  rtf: 'rtf',
  py: 'python', pyw: 'python',
  swift: 'swift',
  c: 'cpp', h: 'cpp', cpp: 'cpp', cc: 'cpp', cxx: 'cpp', hpp: 'cpp', hh: 'cpp', hxx: 'cpp',
  cs: 'csharp',
  js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript',
  ts: 'typescript', tsx: 'typescript',
  css: 'css', scss: 'css',
  php: 'php',
};

/** Language names after the opening ``` of a Markdown code block. */
const FENCE_TAGS = {
  python: 'python', py: 'python', python3: 'python', swift: 'swift',
  c: 'cpp', h: 'cpp', cpp: 'cpp', 'c++': 'cpp', cc: 'cpp', cxx: 'cpp', hpp: 'cpp',
  cs: 'csharp', csharp: 'csharp', 'c#': 'csharp',
  js: 'javascript', javascript: 'javascript', jsx: 'javascript', mjs: 'javascript', node: 'javascript',
  ts: 'typescript', typescript: 'typescript', tsx: 'typescript',
  css: 'css', scss: 'css', php: 'php',
  json: 'json', yaml: 'yaml', yml: 'yaml', xml: 'xml', html: 'html', htm: 'html',
  ini: 'config', toml: 'config', tex: 'tex', latex: 'tex', log: 'log',
};
const fenceType = (tag) => FENCE_TAGS[(String(tag || '').split(/[\s{]/)[0] || '').toLowerCase()] || null;

const TYPE_TITLES = {
  markdown: 'Markdown', text: 'Text', json: 'JSON', yaml: 'YAML', csv: 'CSV', log: 'Log',
  xml: 'XML', html: 'HTML', config: 'INI / TOML', tex: 'TeX', rtf: 'RTF',
  python: 'Python', swift: 'Swift', cpp: 'C / C++', csharp: 'C#', javascript: 'JavaScript', typescript: 'TypeScript', css: 'CSS', php: 'PHP',
};

const TYPE_ICONS = {
  markdown: 'docRich', rtf: 'docRich', json: 'braces', yaml: 'doc', config: 'doc', xml: 'doc',
  html: 'doc', tex: 'doc', csv: 'table', log: 'list', text: 'docPlain',
  python: 'code', swift: 'code', cpp: 'code', csharp: 'code', javascript: 'code', typescript: 'code', css: 'code', php: 'code',
};

const baseName = (p) => p.split(/[\\/]/).pop();
const extOf = (p) => { const m = /\.([^.\\/]+)$/.exec(p); return m ? m[1].toLowerCase() : ''; };
const fileTypeOf = (p) => EXTENSION_TYPES[extOf(p)] || 'text';

// ---- Inline Markdown -------------------------------------------------------

/** Parses inline Markdown into a small tree: text, code, strong, em, del, link. */
function parseInline(s) {
  const out = [];
  let buf = '';
  let i = 0;
  const n = s.length;
  const flush = () => { if (buf) { out.push({ t: 'text', v: buf }); buf = ''; } };
  const isAlnum = (ch) => !!ch && /[\p{L}\p{N}]/u.test(ch);

  while (i < n) {
    const c = s[i];

    if (c === '\\' && i + 1 < n && /[\\`*_{}[\]()#+\-.!|~<>]/.test(s[i + 1])) {
      buf += s[i + 1]; i += 2; continue;
    }

    if (c === '`') {
      let run = 1;
      while (s[i + run] === '`') run++;
      const fence = '`'.repeat(run);
      const close = s.indexOf(fence, i + run);
      if (close > i + run) {
        flush();
        out.push({ t: 'code', v: s.slice(i + run, close).replace(/^ (.*) $/, '$1') });
        i = close + run;
        continue;
      }
      buf += fence; i += run; continue;
    }

    if (c === '*' || c === '_') {
      const prev = s[i - 1];
      const intraword = c === '_' && isAlnum(prev);
      if (!intraword) {
        const dbl = c + c;
        if (s.startsWith(dbl, i) && !/\s/.test(s[i + 2] || ' ')) {
          let close = s.indexOf(dbl, i + 2);
          while (close > 0 && /\s/.test(s[close - 1])) close = s.indexOf(dbl, close + 1);
          if (close > 0 && s[close + 2] === c) close++; // ***both*** closes the inner run first
          if (close > i + 2) {
            flush();
            out.push({ t: 'strong', c: parseInline(s.slice(i + 2, close)) });
            i = close + 2;
            continue;
          }
        } else if (!/\s/.test(s[i + 1] || ' ')) {
          let close = i + 1;
          for (;;) {
            close = s.indexOf(c, close);
            if (close < 0) break;
            const bad = /\s/.test(s[close - 1]) || s[close + 1] === c || (c === '_' && isAlnum(s[close + 1]));
            if (!bad && close > i + 1) break;
            close++;
          }
          if (close > i + 1) {
            flush();
            out.push({ t: 'em', c: parseInline(s.slice(i + 1, close)) });
            i = close + 1;
            continue;
          }
        }
      }
      buf += c; i++; continue;
    }

    if (c === '~' && s[i + 1] === '~') {
      const close = s.indexOf('~~', i + 2);
      if (close > i + 2) {
        flush();
        out.push({ t: 'del', c: parseInline(s.slice(i + 2, close)) });
        i = close + 2;
        continue;
      }
    }

    if (c === '[' || (c === '!' && s[i + 1] === '[')) {
      const image = c === '!';
      const open = image ? i + 1 : i;
      let depth = 0;
      let close = -1;
      for (let k = open; k < n; k++) {
        if (s[k] === '\\') { k++; continue; }
        if (s[k] === '[') depth++;
        else if (s[k] === ']' && --depth === 0) { close = k; break; }
      }
      if (close > 0 && s[close + 1] === '(') {
        const end = s.indexOf(')', close + 2);
        if (end > 0) {
          flush();
          const url = s.slice(close + 2, end).trim().split(/\s+/)[0] || '';
          const inner = parseInline(s.slice(open + 1, close));
          out.push(image ? { t: 'em', c: inner } : { t: 'link', c: inner, url });
          i = end + 1;
          continue;
        }
      }
    }

    if (c === '<') {
      const m = /^<((?:https?:\/\/|mailto:)[^>\s]+)>/.exec(s.slice(i));
      if (m) {
        flush();
        out.push({ t: 'link', c: [{ t: 'text', v: m[1] }], url: m[1] });
        i += m[0].length;
        continue;
      }
    }

    buf += c; i++;
  }
  flush();
  return out;
}

function inlinePlain(nodes) {
  let s = '';
  for (const n of nodes) s += n.t === 'text' || n.t === 'code' ? n.v : inlinePlain(n.c);
  return s;
}

const plain = (s) => inlinePlain(parseInline(s));

function inlineToDom(nodes, parent) {
  for (const n of nodes) {
    let el;
    switch (n.t) {
      case 'text': parent.appendChild(document.createTextNode(n.v)); continue;
      case 'code': el = document.createElement('code'); el.textContent = n.v; break;
      case 'strong': el = document.createElement('strong'); inlineToDom(n.c, el); break;
      case 'em': el = document.createElement('em'); inlineToDom(n.c, el); break;
      case 'del': el = document.createElement('del'); inlineToDom(n.c, el); break;
      case 'link':
        el = document.createElement('a');
        el.dataset.url = n.url;
        el.title = n.url;
        inlineToDom(n.c, el);
        break;
    }
    parent.appendChild(el);
  }
  return parent;
}

// ---- Markdown blocks -------------------------------------------------------

const MarkdownParser = (() => {
  const heading = (s) => {
    let level = 0;
    while (s[level] === '#') level++;
    if (level < 1 || level > 6 || s[level] !== ' ') return null;
    return [level, s.slice(level).trim()];
  };

  const isRule = (s) => {
    const compact = s.replace(/ /g, '');
    if (compact.length < 3 || !'-*_'.includes(compact[0])) return false;
    return [...compact].every((ch) => ch === compact[0]);
  };

  const bullet = (s) => {
    if (s.length <= 2 || !'-*+'.includes(s[0]) || s[1] !== ' ') return null;
    let t = s.slice(2);
    if (t.startsWith('[ ] ')) t = '☐ ' + t.slice(4);
    else if (t.toLowerCase().startsWith('[x] ')) t = '☑ ' + t.slice(4);
    return t;
  };

  const numberedItem = (s) => {
    const dot = s.indexOf('.');
    if (dot <= 0 || !/^\p{N}+$/u.test(s.slice(0, dot)) || s[dot + 1] !== ' ') return null;
    return s.slice(dot + 2);
  };

  const isTableSeparator = (s) => {
    const t = s.trim();
    return t.includes('-') && t.includes('|') && /^[|\-: ]+$/.test(t);
  };

  const cells = (s) => {
    let t = s.trim();
    if (t.startsWith('|')) t = t.slice(1);
    if (t.endsWith('|')) t = t.slice(0, -1);
    return t.split('|').map((c) => c.trim());
  };

  function parse(lines) {
    const blocks = [];
    let i = 0;
    while (i < lines.length) {
      const trimmed = lines[i].trim();
      if (!trimmed) { i++; continue; }

      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        const fence = trimmed.slice(0, 3);
        const lang = trimmed.slice(3).trim();
        const body = [];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith(fence)) { body.push(lines[i]); i++; }
        i++;
        blocks.push({ type: 'code', lang, code: body.join('\n') });
        continue;
      }

      const h = heading(trimmed);
      if (h) { blocks.push({ type: 'heading', level: h[0], text: h[1] }); i++; continue; }

      if (isRule(trimmed)) { blocks.push({ type: 'rule' }); i++; continue; }

      if (trimmed.startsWith('>')) {
        const q = [];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          let t = lines[i].trim().slice(1);
          if (t.startsWith(' ')) t = t.slice(1);
          q.push(t); i++;
        }
        blocks.push({ type: 'quote', text: q.join('\n') });
        continue;
      }

      if (bullet(trimmed) !== null) {
        const items = [];
        for (let b; i < lines.length && (b = bullet(lines[i].trim())) !== null; i++) items.push(b);
        blocks.push({ type: 'bullets', items });
        continue;
      }

      if (numberedItem(trimmed) !== null) {
        const items = [];
        for (let b; i < lines.length && (b = numberedItem(lines[i].trim())) !== null; i++) items.push(b);
        blocks.push({ type: 'numbered', items });
        continue;
      }

      if (trimmed.includes('|') && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
        const header = cells(trimmed);
        const rows = [];
        i += 2;
        while (i < lines.length && lines[i].includes('|') && lines[i].trim()) { rows.push(cells(lines[i])); i++; }
        blocks.push({ type: 'table', header, rows });
        continue;
      }

      const para = [];
      while (i < lines.length) {
        const t = lines[i].trim();
        if (!t || t.startsWith('```') || t.startsWith('>') || heading(t) || bullet(t) !== null
          || numberedItem(t) !== null || isRule(t)) break;
        para.push(t); i++;
      }
      if (!para.length) i++;
      else blocks.push({ type: 'paragraph', text: para.join(' ') });
    }
    return blocks;
  }

  return { parse };
})();

// ---- CSV -------------------------------------------------------------------

const CSV = (() => {
  function parseLine(line, delimiter) {
    const cells = [];
    const starts = [];
    let current = '';
    let inQuotes = false;
    let cellStart = 0;
    const n = line.length;
    for (let i = 0; i < n; i++) {
      const c = line[i];
      if (inQuotes) {
        if (c === '"') {
          if (line[i + 1] === '"') { current += '"'; i++; } else inQuotes = false;
        } else current += c;
      } else if (c === '"' && current === '') {
        inQuotes = true;
      } else if (c === delimiter) {
        cells.push(current); starts.push(cellStart);
        current = ''; cellStart = i + 1;
      } else current += c;
    }
    cells.push(current); starts.push(cellStart);
    return { line, cells, starts };
  }

  function detectDelimiter(path, lines) {
    if (extOf(path) === 'tsv') return '\t';
    const sample = lines.slice(0, 5).join('\n');
    const count = (d) => sample.split(d).length - 1;
    return [',', ';', '\t', '|'].reduce((best, d) => (count(d) > count(best) ? d : best), ',');
  }

  /** Row i is line i of the document, so search and scrolling keep using line numbers. */
  function parse(lines, delimiter) {
    let end = lines.length;
    while (end > 1 && !lines[end - 1].trim()) end--;
    const rows = lines.slice(0, end).map((l) => parseLine(l, delimiter));
    const columns = Math.max(0, ...rows.map((r) => r.cells.length));
    const widths = new Array(columns).fill(3);
    for (const row of rows.slice(0, 500)) {
      row.cells.forEach((cell, i) => { widths[i] = Math.min(40, Math.max(widths[i], cell.length)); });
    }
    return { rows, widths };
  }

  return { parse, detectDelimiter };
})();

// ---- Document --------------------------------------------------------------

function makeDocument(path, loaded) {
  const type = fileTypeOf(path);
  const lines = loaded.text.replace(/\r\n/g, '\n').split('\n');
  return {
    id: crypto.randomUUID(),
    libraryID: null,
    path,
    name: baseName(path),
    type,
    encoding: loaded.encoding,
    text: loaded.text,
    lines,
    syntaxStates: Syntax.states(lines, type),
    blocks: type === 'markdown' ? MarkdownParser.parse(lines) : [],
    csv: type === 'csv' ? CSV.parse(lines, CSV.detectDelimiter(path, lines)) : null,
    modified: loaded.mtimeMs,
    wordCount: loaded.text.split(/\s+/).filter(Boolean).length,
  };
}

// ---- Syntax coloring -------------------------------------------------------

const Syntax = (() => {
  // \w is ASCII-only in JavaScript; the macOS rules (ICU) treat Cyrillic letters as word characters.
  const WORD = '\\p{L}\\p{N}_';
  const unicodeWord = (pattern) => {
    let out = '';
    let inClass = false;
    for (let i = 0; i < pattern.length; i++) {
      const c = pattern[i];
      if (c === '\\') {
        const n = pattern[++i];
        out += n === 'w' ? (inClass ? WORD : '[' + WORD + ']') : '\\' + n;
      } else {
        if (c === '[') inClass = true;
        else if (c === ']') inClass = false;
        out += c;
      }
    }
    return out;
  };
  const rule = (pattern, role) => ({ re: new RegExp(unicodeWord(pattern), 'gu'), role });

  const stringRule = rule('"(?:[^"\\\\]|\\\\.)*"|\'[^\']*\'', 'string');
  const numberRule = rule('(?<![\\w.])-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?(?![\\w.])', 'number');

  const markup = [
    rule('<!--.*?-->|<!--.*$|^.*?-->', 'comment'),
    rule('"[^"]*"|\'[^\']*\'', 'string'),
    rule('<[!?/]?[A-Za-z][\\w:\\-.]*|<[!?]\\w+', 'keyword'),
    rule('[\\w:\\-.]+(?==)', 'key'),
    rule('/?\\??>', 'keyword'),
    rule('&\\w+;|&#\\d+;', 'number'),
  ];

  const RULES = {
    json: [
      rule('"(?:[^"\\\\]|\\\\.)*"(?=\\s*:)', 'key'),
      stringRule, numberRule,
      rule('\\b(?:true|false|null)\\b', 'keyword'),
    ],
    yaml: [
      rule('(?:^|\\s)#.*$', 'comment'),
      rule('^\\s*(?:-\\s+)?(?:"[^"]*"|\'[^\']*\'|[\\w.\\-/ ]+?)(?=:(?:\\s|$))', 'key'),
      stringRule, numberRule,
      rule('\\b(?:true|false|null|yes|no|on|off)\\b|(?<=\\s)~(?=\\s|$)', 'keyword'),
      rule('^(?:---|\\.\\.\\.)\\s*$', 'secondary'),
      rule('[&*]\\w+|![\\w!]+', 'keyword'),
    ],
    config: [
      rule('^\\s*[;#].*$', 'comment'),
      rule('^\\s*\\[[^\\]]*\\]', 'keyword'),
      rule('^\\s*[\\w.\\-"]+(?=\\s*[=:])', 'key'),
      stringRule, numberRule,
      rule('\\b(?:true|false)\\b', 'keyword'),
      rule('\\s[;#].*$', 'comment'),
    ],
    xml: markup,
    html: markup,
    tex: [
      rule('(?<!\\\\)%.*$', 'comment'),
      rule('\\$\\$?[^$]*\\$\\$?', 'string'),
      rule('\\\\(?:begin|end)\\{[^}]*\\}', 'keyword'),
      rule('\\\\[A-Za-z]+\\*?', 'key'),
      rule('[{}\\[\\]]', 'secondary'),
    ],
    log: [
      rule('\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?', 'secondary'),
      rule('\\b\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?\\b', 'secondary'),
      rule('\\b(?:ERROR|ERR|FATAL|CRITICAL|SEVERE|PANIC|EXCEPTION|FAILED)\\b', 'error'),
      rule('\\b(?:WARN|WARNING)\\b', 'warning'),
      rule('\\b(?:INFO|NOTICE|SUCCESS|OK)\\b', 'success'),
      rule('\\b(?:DEBUG|TRACE|VERBOSE)\\b', 'secondary'),
      rule('\\[[^\\]\\n]{1,40}\\]', 'key'),
    ],
  };

  // ---- Programming languages: comments and strings are scanned first (they can span lines), then rules apply.
  const block = (open, close, role) => ({ open, close, role });
  const words = (list, role) => rule('\\b(?:' + list.split(' ').join('|') + ')\\b', role);
  const codeNumber = rule('\\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)[uUlLfFdDmMzZ]*\\b', 'number');
  const typeName = rule('\\b[A-Z][A-Za-z0-9_]*\\b', 'key');
  const cBlock = block('/*', '*/', 'comment');
  const QUOTES = '"\'';

  const jsRules = (extra) => [
    rule('@\\w+', 'key'),
    words('async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield ' + extra, 'keyword'),
    words('true false null undefined NaN Infinity', 'number'),
    codeNumber, typeName,
  ];

  const CODE = {
    python: {
      lineComments: ['#'], blocks: [block('"""', '"""', 'string'), block("'''", "'''", 'string')], quotes: QUOTES,
      rules: [
        rule('^\\s*@[\\w.]+|(?<=\\s)@[\\w.]+$', 'key'),
        words('and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case', 'keyword'),
        words('True False None self cls', 'number'),
        codeNumber, typeName,
      ],
    },
    swift: {
      lineComments: ['//'], blocks: [block('"""', '"""', 'string'), cBlock], quotes: '"',
      rules: [
        rule('@\\w+|#\\w+', 'key'),
        words('actor associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough fileprivate final for func guard if import in indirect init inout internal is lazy let mutating nonisolated nonmutating open operator override private protocol public repeat rethrows return static struct subscript super switch throw throws try typealias var weak where while some any willSet didSet get set self Self', 'keyword'),
        words('true false nil', 'number'),
        codeNumber, typeName,
      ],
    },
    cpp: {
      lineComments: ['//'], blocks: [cBlock], quotes: QUOTES,
      rules: [
        rule('^\\s*#\\s*\\w+', 'keyword'),
        rule('(?<=include )<[^>]*>|(?<=include)<[^>]*>', 'string'),
        words('alignas alignof auto bool break case catch char class concept const consteval constexpr const_cast continue co_await co_return co_yield decltype default delete do double dynamic_cast else enum explicit extern final float for friend goto if inline int long mutable namespace new noexcept operator override private protected public register reinterpret_cast requires return short signed sizeof static static_assert static_cast struct switch template this thread_local throw try typedef typeid typename union unsigned using virtual void volatile while', 'keyword'),
        words('true false NULL nullptr', 'number'),
        codeNumber, typeName,
      ],
    },
    csharp: {
      lineComments: ['//'], blocks: [cBlock], quotes: QUOTES,
      rules: [
        rule('^\\s*#\\s*\\w+', 'keyword'),
        words('abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double dynamic else enum event explicit extern finally fixed float for foreach get goto if implicit in init int interface internal is lock long nameof namespace new object operator out override params partial private protected public readonly record ref required return sbyte sealed set short sizeof stackalloc static string struct switch this throw try typeof uint ulong unchecked unsafe ushort using var virtual void volatile when where while with yield', 'keyword'),
        words('true false null', 'number'),
        codeNumber, typeName,
      ],
    },
    javascript: { lineComments: ['//'], blocks: [block('`', '`', 'string'), cBlock], quotes: QUOTES, rules: jsRules('') },
    typescript: {
      lineComments: ['//'], blocks: [block('`', '`', 'string'), cBlock], quotes: QUOTES,
      rules: jsRules('abstract any as asserts bigint boolean declare enum implements infer interface is keyof module namespace never number object override private protected public readonly satisfies string symbol type unknown'),
    },
    css: {
      lineComments: [], blocks: [cBlock], quotes: QUOTES,
      rules: [
        rule('@[\\w-]+', 'keyword'),
        rule('!important', 'error'),
        rule('^\\s*[\\w-]+(?=\\s*:\\s*[^;{]*[;}]?\\s*$)', 'key'),
        rule('(?<=[:\\s,(])#[0-9a-fA-F]{3,8}\\b', 'number'),
        rule('(?<![\\w-])-?(?:\\d+\\.?\\d*|\\.\\d+)(?:px|em|rem|%|vh|vw|vmin|vmax|ch|ex|pt|cm|mm|in|s|ms|deg|rad|turn|fr)?(?![\\w-])', 'number'),
        rule('[\\w-]+(?=\\()', 'key'),
        rule('::?[a-zA-Z-]+(?![\\w-]*\\s*:\\s)', 'keyword'),
        rule('[.#][A-Za-z_][\\w-]*', 'keyword'),
      ],
    },
    php: {
      lineComments: ['//', '#'], blocks: [cBlock], quotes: QUOTES,
      rules: [
        rule('<\\?php|<\\?=|\\?>', 'keyword'),
        rule('\\$\\w+', 'key'),
        words('abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield', 'keyword'),
        rule('\\b(?:true|false|null|TRUE|FALSE|NULL)\\b', 'number'),
        codeNumber, typeName,
      ],
    },
  };

  /** Comments and strings of one line. `start` is the open block (index + 1) carried from the previous line. */
  function scan(line, lang, start) {
    const out = [];
    const n = line.length;
    let state = start;
    let i = 0;
    const find = (pat, from, escapes) => {
      for (let j = from; j + pat.length <= n; j++) {
        if (escapes && line[j] === '\\') { j++; continue; }
        if (line.startsWith(pat, j)) return j;
      }
      return -1;
    };
    const add = (from, to, role) => { if (to > from) out.push({ start: from, end: to, role }); };

    while (i < n) {
      if (state > 0) {
        const b = lang.blocks[state - 1];
        const e = find(b.close, i, b.role === 'string');
        if (e >= 0) { add(i, e + b.close.length, b.role); i = e + b.close.length; state = 0; } else { add(i, n, b.role); i = n; }
        continue;
      }
      const bi = lang.blocks.findIndex((b) => line.startsWith(b.open, i));
      if (bi >= 0) {
        const b = lang.blocks[bi];
        const from = i;
        i += b.open.length;
        const e = find(b.close, i, b.role === 'string');
        if (e >= 0) { i = e + b.close.length; add(from, i, b.role); } else { add(from, n, b.role); i = n; state = bi + 1; }
        continue;
      }
      if (lang.lineComments.some((c) => line.startsWith(c, i))) { add(i, n, 'comment'); break; }
      if (lang.quotes.includes(line[i])) {
        const q = line[i];
        let j = i + 1;
        while (j < n && line[j] !== q) j += line[j] === '\\' ? 2 : 1;
        const end = Math.min(j + 1, n);
        add(i, end, 'string');
        i = end;
        continue;
      }
      i++;
    }
    return { spans: out, next: state };
  }

  const MAX_LENGTH = 2000;

  const hasHighlighting = (type) => !!RULES[type] || !!CODE[type];

  /** Scanner state at the start of every line (0 = nothing open); empty for formats without carried state. */
  function states(lines, type) {
    const lang = CODE[type];
    if (!lang) return [];
    const out = [];
    let state = 0;
    for (const line of lines) {
      out.push(state);
      state = scan(line, lang, state).next;
    }
    return out;
  }

  /** Settings: highlighting can be switched off altogether or per language. */
  const isOn = (type) => typeof Prefs === 'undefined'
    || (Prefs.values.syntaxOn !== false && !(Prefs.values.syntaxOff || []).includes(type));

  /** Returns [{start, end, role}] for a single line. A character claimed by an earlier rule is never recolored. */
  function spans(line, type, state = 0) {
    if (!isOn(type)) return [];
    const lang = CODE[type];
    const rules = lang ? lang.rules : RULES[type];
    if (!rules || !line || line.length > MAX_LENGTH) return [];
    const claimed = new Array(line.length).fill(false);
    const out = [];
    if (lang) {
      for (const s of scan(line, lang, state).spans) {
        out.push(s);
        for (let k = s.start; k < s.end; k++) claimed[k] = true;
      }
    }
    for (const { re, role } of rules) {
      re.lastIndex = 0;
      for (const m of line.matchAll(re)) {
        if (!m[0].length) continue;
        const end = m.index + m[0].length;
        let runStart = -1;
        for (let i = m.index; i <= end; i++) {
          const free = i < end && !claimed[i];
          if (free && runStart < 0) runStart = i;
          if (!free && runStart >= 0) {
            out.push({ start: runStart, end: i, role });
            for (let k = runStart; k < i; k++) claimed[k] = true;
            runStart = -1;
          }
        }
      }
    }
    return out.sort((a, b) => a.start - b.start);
  }

  /** Fills `parent` with the line's text, colored with `tok-*` classes. */
  function render(line, type, parent, state = 0) {
    const list = spans(line, type, state);
    let pos = 0;
    for (const s of list) {
      if (s.start > pos) parent.appendChild(document.createTextNode(line.slice(pos, s.start)));
      const span = document.createElement('span');
      span.className = 'tok-' + s.role;
      span.textContent = line.slice(s.start, s.end);
      parent.appendChild(span);
      pos = s.end;
    }
    if (pos < line.length) parent.appendChild(document.createTextNode(line.slice(pos)));
    return parent;
  }

  /** A multi-line code block (Markdown fence) as colored rows joined by newlines. */
  function renderBlock(code, type, parent) {
    const lines = code.split('\n');
    const st = states(lines, type);
    lines.forEach((line, i) => {
      if (i > 0) parent.appendChild(document.createTextNode('\n'));
      render(line, type, parent, st.length ? st[i] : 0);
    });
    return parent;
  }

  return { hasHighlighting, isOn, render, renderBlock, states, spans };
})();

// ---- Search ----------------------------------------------------------------

const Searcher = (() => {
  /** Case-insensitive, non-overlapping hits as [start, end) pairs. */
  function ranges(query, text) {
    if (!query) return [];
    const q = query.toLowerCase();
    const t = text.toLowerCase();
    const out = [];
    let start = 0;
    while (start < t.length) {
      const i = t.indexOf(q, start);
      if (i < 0) break;
      out.push([i, i + q.length]);
      start = i + Math.max(q.length, 1);
    }
    return out;
  }

  /** Markdown reading mode is searched per rendered block; every other view per line. */
  const usesBlocks = (doc, mode) => mode === 'reading' && doc.type === 'markdown';

  /** Visible text pieces of a block, in the order the reading view draws them. */
  function segments(block) {
    switch (block.type) {
      case 'heading': case 'paragraph': case 'quote': return [plain(block.text)];
      case 'bullets': case 'numbered': return block.items.map(plain);
      case 'code': return [block.code];
      case 'rule': return [];
      case 'table': return [...block.header, ...block.rows.flat()].map(plain);
    }
    return [];
  }

  /** Number of hits before each segment, so a segment knows its first occurrence index. */
  function offsets(block, query) {
    let running = 0;
    return segments(block).map((text) => {
      const before = running;
      running += ranges(query, text).length;
      return before;
    });
  }

  /** Hits in plain lines (the text being edited), one unit per line. */
  function matchesInLines(query, lines) {
    const result = [];
    if (!query) return result;
    lines.forEach((line, unit) => { ranges(query, line).forEach((_, occurrence) => result.push({ unit, occurrence })); });
    return result;
  }

  /**
   * File and folder names: every word typed has to be the beginning of the name or of one of its words,
   * so "гриз", "read me" and "me" all find "Read Me.md".
   */
  function nameMatches(name, query) {
    const typed = String(query).toLowerCase().split(/\s+/).filter(Boolean);
    if (!typed.length) return true;
    const low = String(name).toLowerCase();
    const words = low.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
    return typed.every((q) => low.startsWith(q) || words.some((w) => w.startsWith(q)));
  }

  function matches(query, doc, mode) {
    if (!query) return [];
    const result = [];
    const collect = (unit, texts) => {
      let occurrence = 0;
      for (const text of texts) {
        for (let k = ranges(query, text).length; k > 0; k--) result.push({ unit, occurrence: occurrence++ });
      }
    };
    if (usesBlocks(doc, mode)) doc.blocks.forEach((b, i) => collect(i, segments(b)));
    else doc.lines.forEach((l, i) => collect(i, [l]));
    return result;
  }

  /**
   * Wraps the hits inside `el` in <mark>. `offset` is the index of the element's first hit within its unit;
   * the hit equal to `highlight.current` gets the "current" class.
   */
  function paint(el, highlight, unit, offset) {
    if (!highlight || !highlight.query) return;
    if (!el.textContent.toLowerCase().includes(highlight.query.toLowerCase())) return;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const nodes = [];
    let text = '';
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      nodes.push({ node: n, start: text.length });
      text += n.nodeValue;
    }
    const found = ranges(highlight.query, text);
    const cur = highlight.current;
    for (let k = found.length - 1; k >= 0; k--) {
      const [from, to] = found[k];
      const isCurrent = !!cur && cur.unit === unit && cur.occurrence === offset + k;
      for (let j = nodes.length - 1; j >= 0; j--) {
        const { node, start } = nodes[j];
        const len = node.nodeValue.length;
        const a = Math.max(from - start, 0);
        const b = Math.min(to - start, len);
        if (a >= b || start >= to || start + len <= from) continue;
        const mid = node.splitText(a);
        mid.splitText(b - a);
        const mark = document.createElement('mark');
        if (isCurrent) mark.className = 'current';
        mid.parentNode.insertBefore(mark, mid);
        mark.appendChild(mid);
      }
    }
  }

  return { ranges, matches, matchesInLines, nameMatches, offsets, usesBlocks, paint };
})();
