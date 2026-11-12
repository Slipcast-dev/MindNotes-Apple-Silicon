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

test('AT-15: сеть только в Shell/Network (ADR-0011), ИИ только необязательный модуль (ADR-0016), нет моделей и аккаунтов', () => {
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
    // ADR-0011 (превью ссылок) и ADR-0014 (обновления): сеть только в Shell/Network.
    const allowed = file.startsWith(path.join('Sources', 'MindNotes', 'Shell', 'Network') + path.sep);
    // ADR-0016: ИИ-ассистент — только в Shell/AI и в своих файлах сети; локальных моделей и других провайдеров нет.
    const aiFile = file.startsWith(path.join('Sources', 'MindNotes', 'Shell', 'AI') + path.sep)
      || ['AIClient.swift', 'AIKeychain.swift'].some((name) => file === path.join('Sources', 'MindNotes', 'Shell', 'Network', name))
      || file === path.join('Sources', 'MindNotes', 'Workspace', 'Domain', 'AIProviders.swift');
    let checked = allowed ? text.replace(/\b(URLSession|URLSessionConfiguration|WKWebView|WKWebViewConfiguration)\b/g, '') : text;
    // ADR-0019: слушатель локального API плагинов — единственный файл с Network.framework, только 127.0.0.1.
    if (file === path.join('Sources', 'MindNotes', 'Shell', 'Network', 'LocalAPIServer.swift')) checked = checked.replace(/\b(import Network|NWConnection)\b/g, '');
    // ADR-0018: названия провайдеров — только в файлах ИИ.
    if (aiFile) checked = checked.replace(/\b(Anthropic|OpenAI)\b/g, '');
    if (!aiFile) assert.ok(!/\bAIClient\b/.test(text), `${file}: запросы ИИ только из Shell/AI`);
    assert.ok(!forbidden.test(checked), `${file}: ${checked.match(forbidden)?.[0]}`);
    if (!allowed) assert.ok(!network.test(text), `${file}: сеть вне Shell/Network`);
  }
  const listener = read('Sources/MindNotes/Shell/Network/LocalAPIServer.swift');
  assert.ok(/acceptLocalOnly = true/.test(listener) && /requiredLocalEndpoint = \.hostPort\(host: NWEndpoint\.Host\(LocalAPI\.host\)/.test(listener), 'API плагинов слушает только этот Mac');
  assert.ok(/static let host = "127\.0\.0\.1"/.test(read('Sources/MindNotes/Workspace/Domain/LocalAPI.swift')), 'адрес — 127.0.0.1, не 0.0.0.0');
  const fetcher = read('Sources/MindNotes/Shell/Network/LinkPreviewFetcher.swift');
  assert.ok(/guard isEnabled, url\.scheme\?\.lowercased\(\) == "https"/.test(fetcher), 'запрос только при включённом превью и по https');
  assert.ok(/guard isEnabled else \{\s*NSWorkspace\.shared\.open\(url\)/.test(fetcher), 'окно встраивания только при включённом превью');
  const updater = read('Sources/MindNotes/Shell/Network/Updater.swift');
  const hosts = updater.match(/https:\/\/[a-z0-9.-]+/g) || [];
  assert.deepStrictEqual([...new Set(hosts)], ['https://api.github.com'], 'обновления — только API выпусков GitHub');
  assert.ok(updater.includes('releases/latest') && updater.includes('Slipcast-dev/MindNotes-Apple-Silicon'), 'только свой репозиторий');
  assert.ok(/guard actual == expected/.test(updater), 'установка только после сверки SHA-256');
  // ИИ (ADR-0016, ADR-0018): адреса только из каталога провайдеров, запрос только при включённом ИИ
  // с согласием, адрес https или http только на этот Mac, ключ из Keychain; по умолчанию выключен.
  const ai = read('Sources/MindNotes/Shell/Network/AIClient.swift');
  assert.deepStrictEqual(ai.match(/https?:\/\/[a-z0-9.-]+/g) || [], [], 'в клиенте нет своих адресов: только из каталога');
  const catalog = read('Sources/MindNotes/Workspace/Domain/AIProviders.swift');
  const allowedHosts = ['https://api.anthropic.com', 'https://api.openai.com', 'https://openrouter.ai', 'https://api.deepseek.com',
    'https://generativelanguage.googleapis.com', 'https://api.mistral.ai', 'https://api.x.ai', 'https://api.groq.com',
    'http://localhost', 'https://example.com'];
  for (const host of new Set(catalog.match(/https?:\/\/[a-z0-9.-]+/g) || [])) assert.ok(allowedHosts.includes(host), `неизвестный адрес провайдера: ${host}`);
  assert.ok(/guard AISettings\.isEnabled else \{ throw AIFailure\.disabled \}/.test(ai), 'запрос только при включённом ИИ');
  assert.ok(/guard AIProvider\.isAllowedBaseURL\(provider\.baseURL\)/.test(ai), 'адрес провайдера проверяется перед запросом');
  assert.ok(/AIKeychain\.read\(provider: provider\.id\)/.test(ai), 'ключ только из Keychain');
  assert.ok(/scheme == "https" \|\| \(scheme == "http" && isLocalHost\(host\)\)/.test(catalog), 'http только на этот Mac');
  const settings = read('Sources/MindNotes/Shell/AI/AISettings.swift');
  assert.ok(/UserDefaults\.standard\.bool\(forKey: enabledKey\) && UserDefaults\.standard\.bool\(forKey: consentKey\)/.test(settings), 'включение требует согласия');
  assert.ok(/enabled = d\.bool\(forKey: Self\.enabledKey\)/.test(settings), 'по умолчанию ИИ выключен');
  assert.ok(!/forKey: "?(apiKey|aiKey|anthropicKey)/i.test(settings), 'ключ не хранится в UserDefaults');
  for (const file of files.filter((f) => !f.includes(path.join('Shell', 'AI')) && !f.endsWith('AIClient.swift'))) {
    assert.ok(!/AIKeychain\.read\(\)/.test(read(file)), `${file}: ключ читает только клиент ИИ`);
  }
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
