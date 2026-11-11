'use strict';
// MindNotes не должна пересекаться с установленным Grizzly: идентификатор, данные, обработчик файлов.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

test('идентификатор сборки совпадает с AppEdition и отличается от оригинала', () => {
  const id = /bundleID = "([^"]+)"/.exec(read('Sources/MindNotes/Core/AppEdition.swift'))[1];
  const build = read('scripts/build-app.sh');
  assert.ok(build.includes(`<key>CFBundleIdentifier</key><string>${id}</string>`));
  assert.ok(!build.includes('app.grizzly.Grizzly'));
});

test('каталог данных отдельный, сборка не заявляет себя обработчиком по умолчанию', () => {
  assert.strictEqual(/officialSupportDirectoryName = "([^"]+)"/.exec(read('Sources/MindNotes/Core/AppEdition.swift'))[1], 'MindNotes');
  assert.ok(!read('scripts/build-app.sh').includes('<key>LSHandlerRank</key><string>Default</string>'));
});

test('сборка только для Apple Silicon: одна цель во всех скриптах', () => {
  assert.ok(/TARGET="arm64-apple-macos/.test(read('scripts/target.sh')));
  for (const script of ['scripts/build-app.sh', 'scripts/test-notes.sh', 'scripts/check-layers.sh']) {
    const text = read(script);
    assert.ok(text.includes('source scripts/target.sh'), script);
    assert.ok(!/x86_64|uname -m|ARCH=/.test(text), script);
  }
});

test('AT-15: сеть только в Shell/Network (ADR-0011), нет ИИ, моделей и аккаунтов', () => {
  const files = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
      const rel = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(rel); else if (rel.endsWith('.swift')) files.push(rel);
    }
  };
  walk('Sources');
  const forbidden = /\b(URLSession|NSURLConnection|NWConnection|NWPathMonitor|import Network|CFNetwork|WKWebView|import CoreML|MLModel|NaturalLanguage|import FoundationModels|LanguageModelSession|OpenAI|Anthropic|apiKey|api_key|Sparkle|GoogleSignIn|CloudKit|CKContainer)\b/;
  const network = /\b(URLSession|WKWebView)\b/;
  for (const file of files) {
    const text = read(file).split('\n').filter((line) => !line.trim().startsWith('//')).join('\n');
    // Сеть для превью ссылок и окна встраивания — только в одном файле оболочки (ADR-0011).
    const allowed = file === path.join('Sources', 'MindNotes', 'Shell', 'Network', 'LinkPreviewFetcher.swift');
    const checked = allowed ? text.replace(/\b(URLSession|URLSessionConfiguration|WKWebView|WKWebViewConfiguration)\b/g, '') : text;
    assert.ok(!forbidden.test(checked), `${file}: ${checked.match(forbidden)?.[0]}`);
    if (!allowed) assert.ok(!network.test(text), `${file}: сеть вне Shell/Network`);
  }
  const fetcher = read('Sources/MindNotes/Shell/Network/LinkPreviewFetcher.swift');
  assert.ok(/guard isEnabled, url\.scheme\?\.lowercased\(\) == "https"/.test(fetcher), 'запрос только при включённом превью и по https');
  assert.ok(/guard isEnabled else \{\s*NSWorkspace\.shared\.open\(url\)/.test(fetcher), 'окно встраивания только при включённом превью');
  assert.ok(files.length > 50, 'исходники найдены');
});

test('MindNotes: перенос сначала с Minerva Noema, затем с Grizzly Notes, у каждого своя отметка', () => {
  const edition = read('Sources/MindNotes/Core/AppEdition.swift');
  const minerva = edition.indexOf('("local.personal.MinervaNoema", "MinervaNoema", "migratedFromMinervaNoema")');
  const grizzly = edition.indexOf('("local.personal.GrizzlyNotes", "GrizzlyNotes", LegacyDataMigration.marker)');
  assert.ok(minerva > 0 && grizzly > minerva);
  assert.ok(/bundleID = "local\.personal\.MindNotes"/.test(edition));
  assert.ok(/displayName = "MindNotes"/.test(edition));
  const shell = read('Sources/MindNotes/Shell/ShellModel.swift');
  assert.ok(shell.includes('[backupExtension, "minervabackup", "grizzlybackup"]'), 'старые архивы открываются');
});
