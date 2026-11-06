// Unit tests for the Electron port's parsers (electron/renderer/core.js). Run: node --test tests/
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const src = fs.readFileSync(path.join(__dirname, '..', 'electron', 'renderer', 'core.js'), 'utf8');
const ctx = { crypto: { randomUUID: () => 'id' }, console };
vm.createContext(ctx);
// Top-level const/function declarations are exposed through a trailing expression.
const api = vm.runInContext(`${src}\n({ fileTypeOf, baseName, MarkdownParser, CSV, makeDocument, plain, Syntax, fenceType, Searcher })`, ctx);

test('file types by extension', () => {
  assert.strictEqual(api.fileTypeOf('a/b/Notes.MD'), 'markdown');
  assert.strictEqual(api.fileTypeOf('x.yml'), 'yaml');
  assert.strictEqual(api.fileTypeOf('x.tsv'), 'csv');
  assert.strictEqual(api.fileTypeOf('x.unknown'), 'text');
  assert.strictEqual(api.baseName('C:\\dir\\file.txt'), 'file.txt');
});

test('markdown blocks', () => {
  const blocks = api.MarkdownParser.parse(['# Title', '', '- a', '- b', '', '```js', 'x < 1', '```', '', '---']);
  const kinds = blocks.map((b) => b.type || b.kind);
  assert.ok(blocks.length >= 4, JSON.stringify(kinds));
  assert.ok(JSON.stringify(blocks).includes('Title'));
  assert.ok(JSON.stringify(blocks).includes('x < 1'));
});

test('csv delimiter detection and quoted cells', () => {
  const lines = ['id;name;note', '1;Anna;"a;b"', '2;Boris;ok'];
  const delim = api.CSV.detectDelimiter('x.csv', lines);
  assert.strictEqual(delim, ';');
  const table = api.CSV.parse(lines, delim);
  assert.ok(JSON.stringify(table).includes('a;b'));
});

test('document keeps CRLF text but splits lines', () => {
  const doc = api.makeDocument('/tmp/a.md', { text: 'a\r\nb', encoding: 'UTF-8', mtimeMs: 1 });
  assert.deepStrictEqual(Array.from(doc.lines), ['a', 'b']);
  assert.ok(doc.text.includes('\r\n'));
});

// Syntax highlighting of programming languages (mirrors tests/swift/main.swift)
const roles = (line, type, state = 0) => api.Syntax.spans(line, type, state).map((s) => [line.slice(s.start, s.end).trim(), s.role]);
const has = (list, text, role) => list.some(([t, r]) => t === text && r === role);
const states = (lines, type) => Array.from(api.Syntax.states(lines, type));

test('code extensions map to types', () => {
  assert.strictEqual(api.fileTypeOf('x.py'), 'python');
  assert.strictEqual(api.fileTypeOf('x.hpp'), 'cpp');
  assert.strictEqual(api.fileTypeOf('x.tsx'), 'typescript');
  assert.strictEqual(api.fileTypeOf('x.cs'), 'csharp');
});

test('python keyword, comment and multi-line string', () => {
  const py = roles('def run(x): # go', 'python');
  assert.ok(has(py, 'def', 'keyword') && has(py, '# go', 'comment'));
  assert.deepStrictEqual(states(['x = """doc', 'more', 'end"""', 'y = 1'], 'python'), [0, 1, 1, 0]);
});

test('C-style block comments span lines', () => {
  assert.deepStrictEqual(states(['a /* b', 'c */ d', 'e'], 'cpp'), [0, 1, 0]);
  assert.ok(has(roles('c */ d', 'cpp', 1), 'c */', 'comment'));
  assert.ok(has(roles('#include <vector>', 'cpp'), '#include', 'keyword'));
  assert.ok(has(roles('int x = 0x1F;', 'cpp'), '0x1F', 'number'));
});

test('comment marker inside a string is not a comment', () => {
  const r = roles('let s = "a // b" // c', 'swift');
  assert.ok(has(r, '"a // b"', 'string') && has(r, '// c', 'comment'));
});

test('C#, JS/TS, CSS and PHP basics', () => {
  const cs = roles('public class Foo : Bar', 'csharp');
  assert.ok(has(cs, 'class', 'keyword') && has(cs, 'Foo', 'key'));
  assert.deepStrictEqual(states(['const a = `x', 'y`;', 'z'], 'javascript'), [0, 1, 0]);
  assert.ok(has(roles('const n = null;', 'typescript'), 'null', 'number') && has(roles('interface A {}', 'typescript'), 'interface', 'keyword'));
  assert.ok(has(roles('  color: #fff;', 'css'), 'color', 'key') && has(roles('  color: #fff;', 'css'), '#fff', 'number'));
  assert.ok(!has(roles('a:hover {', 'css'), 'a', 'key'));
  assert.ok(has(roles('$x = 1; // c', 'php'), '$x', 'key') && has(roles('$x = 1; // c', 'php'), '// c', 'comment'));
});

test('stateless formats carry no state; fence tags resolve', () => {
  assert.strictEqual(states(['a', 'b'], 'json').length, 0);
  assert.strictEqual(api.fenceType('Python title=x'), 'python');
  assert.strictEqual(api.fenceType('c++'), 'cpp');
  assert.strictEqual(api.fenceType('nope'), null);
  const doc = api.makeDocument('/tmp/a.cpp', { text: '/* a\nb */', encoding: 'UTF-8', mtimeMs: 1 });
  assert.deepStrictEqual(Array.from(doc.syntaxStates), [0, 1]);
});

test('highlighting can be switched off, altogether or per language', () => {
  assert.ok(api.Syntax.spans('def x(): pass', 'python').length > 0);
  ctx.Prefs = { values: { syntaxOn: true, syntaxOff: ['python'] } };
  assert.strictEqual(api.Syntax.spans('def x(): pass', 'python').length, 0);
  assert.ok(api.Syntax.spans('const a = 1;', 'javascript').length > 0);
  ctx.Prefs = { values: { syntaxOn: false, syntaxOff: [] } };
  assert.strictEqual(api.Syntax.spans('const a = 1;', 'javascript').length, 0);
  delete ctx.Prefs;
});

test('file search matches the beginning of the name or of any word', () => {
  const m = api.Searcher.nameMatches;
  assert.ok(m('Read Me.md', 'read') && m('Read Me.md', 'me') && m('Read Me.md', 'read m') && m('Гризли заметки.md', 'гриз'));
  assert.ok(m('Гризли заметки.md', 'ЗАМ') && m('notes', ''));
  assert.ok(!m('Read Me.md', 'ead') && !m('Read Me.md', 'xyz'));
});

test('find in edited text counts hits per line', () => {
  const hits = api.Searcher.matchesInLines('ab', ['ab AB', 'x', 'cab']);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(hits)), [{ unit: 0, occurrence: 0 }, { unit: 0, occurrence: 1 }, { unit: 2, occurrence: 0 }]);
});

test('tags: create, assign, rename, delete', () => {
  const stateSrc = fs.readFileSync(path.join(__dirname, '..', 'electron', 'renderer', 'state.js'), 'utf8');
  const c = { crypto: { randomUUID: (() => { let n = 0; return () => 'id' + ++n; })() }, window: { api: { saveLibrary() {}, mtimes: async () => ({}), loadLibrary: async () => null } },
    console, setTimeout, clearTimeout, baseName: (p) => p.split('/').pop(), Intl };
  vm.createContext(c);
  const lib = vm.runInContext(`${stateSrc}\nLibrary`, c);
  const file = lib.add('/a/x.md');
  assert.strictEqual(lib.createTag('#Работа'), 'Работа');
  assert.strictEqual(lib.createTag('работа'), 'Работа');
  assert.strictEqual(lib.createTag('  '), null);
  lib.toggleTag(file.id, 'Работа');
  assert.strictEqual(lib.filesWithTag('РАБОТА').length, 1);
  lib.renameTag('Работа', 'Дом');
  assert.strictEqual(lib.filesWithTag('Дом').length, 1);
  assert.strictEqual(lib.filesWithTag('Работа').length, 0);
  assert.deepStrictEqual(Array.from(lib.extractTags('# T\n#12 и #работа, #Work-1 a#b http://x/#frag')), ['12', 'работа', 'Work-1']);
  assert.deepStrictEqual(Array.from(lib.extractTags('#🍕 и #идея💡 и #a_b, 😀#x')), ['🍕', 'идея💡', 'a_b', 'x']);
  assert.strictEqual(lib.replaceTag('🍕', 'пицца', 'ем #🍕 и #🍕х'), 'ем #пицца и #🍕х');
  lib.setInlineTags(file.id, ['идея']);
  assert.strictEqual(lib.filesWithTag('Идея').length, 1);
  assert.strictEqual(lib.replaceTag('work', 'дом', '#Work and #workshop, a#work, #work.\n#WORK'), '#дом and #workshop, a#work, #дом.\n#дом');
  assert.strictEqual(lib.replaceTag('work', null, 'x #work y, #work'), 'x y, ');
  assert.strictEqual(lib.countTag('work', '#work #Work #works'), 2);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(lib.tagMatches('a #one-, #два'))), [{ index: 2, length: 4, tag: 'one' }, { index: 9, length: 4, tag: 'два' }]);
  const f2 = lib.add('/a/y.md'); lib.setInlineTags(f2.id, ['идея', 'план']); lib.setInlineTags(file.id, ['идея']);
  assert.strictEqual(lib.filesWithAllTags(['идея']).length, 2);
  assert.strictEqual(lib.filesWithAllTags(['идея', 'план']).length, 1);
  assert.strictEqual(lib.filesWithAllTags([]).length, 0);
  lib.setInlineTags(f2.id, []);
  lib.setInlineTags(file.id, []);
  lib.deleteTag('Дом');
  assert.strictEqual(lib.allTags.length, 0);
  assert.strictEqual(lib.filesWithTag('Дом').length, 0);
});
