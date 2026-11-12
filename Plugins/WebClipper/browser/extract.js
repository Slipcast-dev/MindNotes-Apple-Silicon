'use strict';
// Извлечение содержимого страницы. Функция выполняется на самой странице через chrome.scripting.executeScript,
// поэтому она самодостаточна: всё нужное объявлено внутри. Результат — Markdown в том диалекте, который
// понимает импорт MindNotes (заголовки до ###, списки, задачи, цитаты, код, таблицы, картинки отдельной строкой).
// Картинки не скачиваются здесь: в тексте остаётся метка ![подпись](mnimg-N), адреса — в `images`.

function mnExtractPage(mode) {
  const MAX_IMAGES = 40;
  const MAX_CHARS = 2000000;
  const doc = document;

  const meta = (selector) => (doc.querySelector(selector)?.getAttribute('content') || '').trim();
  const title = meta('meta[property="og:title"]') || (doc.title || '').trim() || location.hostname;
  const siteName = meta('meta[property="og:site_name"]');
  const excerpt = meta('meta[property="og:description"]') || meta('meta[name="description"]');
  const pageURL = location.href;

  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'IFRAME', 'OBJECT', 'EMBED', 'CANVAS', 'SVG', 'FORM',
    'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'NAV', 'ASIDE', 'FOOTER', 'DIALOG', 'MENU', 'LINK', 'META', 'VIDEO', 'AUDIO', 'MAP']);
  const BLOCK = new Set(['P', 'DIV', 'SECTION', 'ARTICLE', 'MAIN', 'HEADER', 'FIGURE', 'FIGCAPTION', 'UL', 'OL', 'LI',
    'BLOCKQUOTE', 'PRE', 'TABLE', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HR', 'DL', 'DT', 'DD', 'DETAILS', 'SUMMARY',
    'ADDRESS', 'CENTER', 'PICTURE', 'IMG']);
  const JUNK = /(^|[\s_-])(comments?|share|sharing|social|related|recommend\w*|promo|advert\w*|ads?|sponsor\w*|newsletter|subscribe|cookie\w*|banner|popup|modal|breadcrumbs?|sidebar|widget|toolbar|pagination|disqus)([\s_-]|$)/i;

  const images = [];
  const abs = (u) => { try { return new URL(u, doc.baseURI).href; } catch (e) { return ''; } };

  function hidden(el) {
    if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
    if (el.isConnected && typeof el.checkVisibility === 'function') return !el.checkVisibility();
    return /display\s*:\s*none|visibility\s*:\s*hidden/i.test(el.getAttribute('style') || '');
  }
  function junk(el, root) {
    if (el === root || el.contains(root)) return false;
    const label = (el.id || '') + ' ' + (typeof el.className === 'string' ? el.className : '') + ' ' + (el.getAttribute('role') || '');
    return JUNK.test(label) || el.getAttribute('role') === 'navigation' || el.getAttribute('role') === 'complementary';
  }

  // Символы разметки в тексте экранируются: импорт MindNotes снимает экранирование и показывает их как есть.
  const escapeText = (t) => t.replace(/([\\`*_\[\]|~<>])/g, '\\$1');
  // Строка, похожая на разметку блока, не должна превращаться в заголовок или цитату.
  const guardLine = (line) => line.replace(/^(\s*)(#{1,6} |> )/, '$1\\$2');
  const oneLine = (t) => t.replace(/\s+/g, ' ').trim();
  // Заголовок — без ссылок: у статей в заголовках обычно якоря на самих себя.
  const unlink = (t) => t.replace(/\[((?:[^\]\\]|\\.)*)\]\((?:[^()]|\([^()]*\))*\)/g, '$1');

  function image(el) {
    if (images.length >= MAX_IMAGES) return '';
    let src = el.currentSrc || el.getAttribute('src') || el.getAttribute('data-src') || el.getAttribute('data-original') || '';
    if (!src && el.tagName === 'PICTURE') {
      const inner = el.querySelector('img');
      if (inner) return image(inner);
      return '';
    }
    src = src.startsWith('data:') ? src : abs(src);
    if (!src || !(src.startsWith('http') || src.startsWith('data:image/'))) return '';
    const w = el.naturalWidth || Number(el.getAttribute('width')) || 0;
    const h = el.naturalHeight || Number(el.getAttribute('height')) || 0;
    if ((w && w < 48) || (h && h < 48)) return ''; // значки и счётчики
    const alt = (el.getAttribute('alt') || '').replace(/[\[\]\n\r]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
    images.push({ src, alt });
    return `\n![${alt}](mnimg-${images.length})\n`;
  }

  function wrap(el, mark, root) {
    const inner = inline(el, root);
    const t = inner.trim();
    if (!t || t.includes('\n')) return inner;
    const lead = inner.match(/^\s*/)[0], trail = inner.match(/\s*$/)[0];
    return lead + mark + t + mark + trail;
  }

  function inline(node, root) {
    let out = '';
    for (const ch of node.childNodes) {
      if (ch.nodeType === Node.TEXT_NODE) { out += escapeText(ch.nodeValue.replace(/\s+/g, ' ')); continue; }
      if (ch.nodeType !== Node.ELEMENT_NODE) continue;
      const tag = ch.tagName;
      if (SKIP.has(tag) || hidden(ch)) continue;
      switch (tag) {
        case 'BR': out += '\n'; break;
        case 'STRONG': case 'B': out += wrap(ch, '**', root); break;
        case 'EM': case 'I': case 'CITE': out += wrap(ch, '*', root); break;
        case 'DEL': case 'S': case 'STRIKE': out += wrap(ch, '~~', root); break;
        case 'CODE': case 'KBD': case 'SAMP': {
          const t = ch.textContent.replace(/`/g, "'").replace(/\s+/g, ' ');
          if (t.trim()) out += '`' + t + '`';
          break;
        }
        case 'A': {
          const text = oneLine(inline(ch, root));
          const href = abs(ch.getAttribute('href') || '');
          // Якорь на эту же страницу и адрес-простыня (отчёты, трекеры) остаются текстом.
          const samePage = href.split('#')[0] === pageURL.split('#')[0] && href.includes('#');
          if (text && /^(https?:|mailto:)/i.test(href) && !samePage && href.length <= 2000 && !text.includes('![')) {
            out += `[${text}](${href.replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29')})`;
          } else out += text;
          break;
        }
        case 'IMG': case 'PICTURE': out += image(ch); break;
        case 'SUP': case 'SUB': out += inline(ch, root); break;
        default:
          out += BLOCK.has(tag) ? ' ' + inline(ch, root) + ' ' : inline(ch, root);
      }
    }
    return out;
  }

  function paragraph(text) {
    const lines = text.split('\n').map((l) => l.replace(/[ \t]+/g, ' ').trim());
    return lines.filter((l, i) => l || (i > 0 && lines[i - 1])).map(guardLine).join('\n').trim();
  }

  function list(el, out, root) {
    let n = 0;
    for (const li of el.children) {
      if (li.tagName !== 'LI' || hidden(li)) continue;
      n += 1;
      const box = li.querySelector(':scope > input[type="checkbox"], :scope > p > input[type="checkbox"]');
      const nested = [];
      const clone = li.cloneNode(true);
      for (const sub of clone.querySelectorAll('ul, ol')) sub.remove();
      const text = oneLine(inline(clone, root));
      const marker = box ? (box.checked ? '- [x] ' : '- [ ] ') : (el.tagName === 'OL' ? `${n}. ` : '- ');
      if (text) out.push(marker + text);
      for (const sub of li.querySelectorAll(':scope > ul, :scope > ol')) list(sub, nested, root);
      out.push(...nested);
    }
  }

  function table(el, out, root) {
    const rows = [];
    for (const tr of el.querySelectorAll('tr')) {
      if (rows.length >= 300) break;
      const cells = [...tr.children].filter((c) => c.tagName === 'TD' || c.tagName === 'TH').map((c) => oneLine(inline(c, root)).replace(/!\[[^\]]*\]\(mnimg-\d+\)/g, ''));
      if (cells.some((c) => c)) rows.push(cells);
    }
    if (!rows.length) return;
    if (rows.length === 1 && rows[0].length === 1) { out.push(paragraph(rows[0][0])); return; } // таблица ради вёрстки
    const width = Math.max(...rows.map((r) => r.length));
    const line = (r) => '| ' + Array.from({ length: width }, (_, i) => r[i] || '').join(' | ') + ' |';
    out.push([line(rows[0]), '| ' + Array(width).fill('---').join(' | ') + ' |', ...rows.slice(1).map(line)].join('\n'));
  }

  function blocks(node, out, root) {
    let buffer = '';
    const flush = () => { const t = paragraph(buffer); if (t) out.push(t); buffer = ''; };
    for (const ch of node.childNodes) {
      if (ch.nodeType === Node.TEXT_NODE) { buffer += escapeText(ch.nodeValue.replace(/\s+/g, ' ')); continue; }
      if (ch.nodeType !== Node.ELEMENT_NODE) continue;
      const tag = ch.tagName;
      if (SKIP.has(tag) || hidden(ch) || junk(ch, root)) continue;
      if (!BLOCK.has(tag)) { buffer += inline({ childNodes: [ch] }, root); continue; }
      flush();
      switch (tag) {
        case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': {
          const level = Math.min(3, Number(tag[1]));
          const text = unlink(oneLine(inline(ch, root)).replace(/!\[[^\]]*\]\(mnimg-\d+\)/g, '')).trim();
          if (text) out.push('#'.repeat(level) + ' ' + text);
          break;
        }
        case 'P': case 'DT': case 'DD': case 'SUMMARY': case 'ADDRESS': case 'FIGCAPTION': {
          const t = paragraph(inline(ch, root));
          if (t) out.push(tag === 'FIGCAPTION' && !t.includes('\n') && !t.includes('![') ? `*${t}*` : t);
          break;
        }
        case 'UL': case 'OL': list(ch, out, root); break;
        case 'BLOCKQUOTE': {
          const inner = [];
          blocks(ch, inner, root);
          for (const l of inner.join('\n').split('\n')) if (l.trim() && !l.startsWith('![')) out.push('> ' + l.replace(/^> /, ''));
          break;
        }
        case 'PRE': {
          const code = (ch.innerText || ch.textContent || '').replace(/```/g, "'''").replace(/\n+$/, '');
          if (code.trim()) out.push('```\n' + code + '\n```');
          break;
        }
        case 'TABLE': table(ch, out, root); break;
        case 'HR': out.push('---'); break;
        case 'IMG': case 'PICTURE': { const md = image(ch).trim(); if (md) out.push(md); break; }
        default: blocks(ch, out, root);
      }
    }
    flush();
  }

  // Основной текст: элемент, где больше всего абзацев (упрощённая идея Readability).
  function articleRoot() {
    const articles = [...doc.querySelectorAll('article')].filter((a) => !hidden(a) && (a.innerText || '').length > 600);
    if (articles.length === 1) return articles[0];
    const scores = new Map();
    const add = (el, value) => { if (el && el !== doc.documentElement) scores.set(el, (scores.get(el) || 0) + value); };
    for (const p of doc.querySelectorAll('p, pre, blockquote')) {
      if (hidden(p)) continue;
      const text = (p.innerText || p.textContent || '').trim();
      if (text.length < 25) continue;
      const value = 1 + text.split(/[,،，]/).length + Math.min(3, Math.floor(text.length / 100));
      add(p.parentElement, value);
      add(p.parentElement?.parentElement, value / 2);
    }
    let best = null, bestScore = 0;
    for (const [el, raw] of scores) {
      const label = (el.id || '') + ' ' + (typeof el.className === 'string' ? el.className : '');
      let score = raw;
      if (/article|body|content|entry|main|post|text|story|blog|markdown|prose/i.test(label)) score *= 1.25;
      if (JUNK.test(label) || /comment|meta|footnote/i.test(label)) score *= 0.4;
      if (el.tagName === 'ARTICLE' || el.tagName === 'MAIN') score *= 1.2;
      // Ссылочные блоки (меню, списки статей) — не основной текст.
      const textLength = (el.innerText || '').length || 1;
      const linkLength = [...el.querySelectorAll('a')].reduce((s, a) => s + (a.innerText || '').length, 0);
      score *= 1 - Math.min(0.9, linkLength / textLength);
      if (score > bestScore) { best = el; bestScore = score; }
    }
    return best || doc.querySelector('main') || doc.body;
  }

  function toMarkdown(root) {
    const out = [];
    blocks(root, out, root);
    // Первый заголовок, совпадающий с названием, не повторяется: название станет заголовком страницы.
    if (out.length && /^# /.test(out[0]) && out[0].slice(2).trim().toLowerCase() === escapeText(title).toLowerCase()) out.shift();
    let md = out.join('\n\n').replace(/\n{3,}/g, '\n\n');
    if (md.length > MAX_CHARS) md = md.slice(0, MAX_CHARS);
    return md;
  }

  if (mode === 'bookmark') return { title, url: pageURL, siteName, excerpt, markdown: '', images: [] };

  if (mode === 'selection') {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return { error: 'no_selection' };
    const box = doc.createElement('div');
    for (let i = 0; i < selection.rangeCount; i += 1) box.appendChild(selection.getRangeAt(i).cloneContents());
    let markdown = toMarkdown(box);
    if (!markdown.trim()) markdown = escapeText(selection.toString());
    return { title, url: pageURL, siteName, excerpt, markdown, images };
  }

  return { title, url: pageURL, siteName, excerpt, markdown: toMarkdown(articleRoot()), images };
}

// Метки mnimg-N после загрузки: скачанная браузером картинка получает имя вложения; картинку с другого сайта (https)
// скачает MindNotes — она получает имя remote-N.img и попадает в `remote`; остальные (http, встроенные) — ссылка или подпись.
function mnPlaceImages(markdown, sources, fetched, label, remoteAllowed = true) {
  const remote = [];
  const text = markdown.replace(/!\[([^\]]*)\]\(mnimg-(\d+)\)/g, (_, alt, n) => {
    const got = fetched[Number(n) - 1];
    if (got) return `![${alt}](${got.name})`;
    const src = sources[Number(n) - 1]?.src || '';
    if (remoteAllowed && /^https:/i.test(src)) {
      const name = `remote-${n}.img`;
      if (!remote.some((r) => r.name === name)) remote.push({ name, url: src });
      return `![${alt}](${name})`;
    }
    if (!/^https?:/i.test(src)) return alt;
    return `[${alt || label}](${src.replace(/\(/g, '%28').replace(/\)/g, '%29')})`;
  });
  return { markdown: text, remote };
}

if (typeof module !== 'undefined') module.exports = { mnExtractPage, mnPlaceImages };
