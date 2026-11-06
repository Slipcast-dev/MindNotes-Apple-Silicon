// Tests the main-process helpers (encoding round trips, path validation) without launching Electron.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const src = fs.readFileSync(path.join(__dirname, '..', 'electron', 'main.js'), 'utf8');
const stub = new Proxy(() => stub, { get: () => stub, apply: () => stub });
const app = {
  getPath: () => require('node:os').tmpdir(), getLocale: () => 'en', requestSingleInstanceLock: () => true,
  on() {}, quit() {}, whenReady: () => ({ then() {} }), setPath() {}, getVersion: () => '0',
};
const sandboxRequire = (name) => (name === 'fs' || name === 'path' ? require(name) : (name === './strings-en.json' ? {} : { app, BrowserWindow: stub, Menu: stub, dialog: stub, ipcMain: { handle() {}, on() {} }, shell: stub, nativeTheme: stub }));
const ctx = { require: sandboxRequire, process, console, Buffer, TextDecoder, __dirname: path.join(__dirname, '..', 'electron') };
vm.createContext(ctx);
let api;
try {
  // main.js touches `app` at load time; the stub swallows it. Helpers are read from the same script scope.
  api = vm.runInContext(`${src}\n({ encodeText, readText, validPath, rtfToText, textToRtf, templateFor, EXTENSIONS })`, ctx);
} catch (err) { console.error('main.js did not load:', err); api = null; }

test('main.js helpers load', () => assert.ok(api.encodeText));

test('path validation rejects relative paths and unsupported types', () => {
  assert.strictEqual(api.validPath('/etc/passwd'), false);
  assert.strictEqual(api.validPath('relative.md'), false);
  assert.strictEqual(api.validPath('/tmp/a.md'), true);
  assert.strictEqual(api.validPath('/tmp/a.md\0.exe'), false);
});

test('encodings round trip', () => {
  const tmp = path.join(require('node:os').tmpdir(), 'grizzly-enc-' + process.pid);
  for (const [enc, text] of [['UTF-8', 'Привет, мир'], ['Windows-1251', 'Привет'], ['UTF-16', 'Привет']]) {
    fs.writeFileSync(tmp + '.txt', api.encodeText(text, enc, tmp + '.txt'));
    const back = api.readText(tmp + '.txt');
    assert.strictEqual(back.text, text, enc);
    assert.strictEqual(back.encoding, enc);
  }
  assert.throws(() => api.encodeText('日本', 'Windows-1251', tmp), /unmappable/);
  fs.rmSync(tmp + '.txt', { force: true });
});

test('rtf text survives a round trip', () => {
  assert.strictEqual(api.rtfToText(api.textToRtf('Hello {x}\nПривет')).trim(), 'Hello {x}\nПривет');
});

test('new file templates and code extensions', () => {
  assert.strictEqual(api.templateFor('json'), '{\n  \n}\n');
  assert.strictEqual(api.templateFor('xyz'), '');
  assert.ok(api.templateFor('html').startsWith('<!DOCTYPE html>'));
  for (const ext of ['py', 'swift', 'cpp', 'cs', 'js', 'ts', 'css', 'php']) assert.ok(api.EXTENSIONS.includes(ext), ext);
});
