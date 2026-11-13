'use strict';
// Договор об API плагинов (ADR-0019, contracts/plugin-api.json): код MindNotes совпадает с ним. Плагины живут в своих
// репозиториях, держат копию договора и проверяют себя по ней — поэтому любое изменение здесь меняет и договор.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const contract = JSON.parse(read('contracts/plugin-api.json'));
const localAPI = read('Sources/MindNotes/Workspace/Domain/LocalAPI.swift');
const plugins = read('Sources/MindNotes/Workspace/Domain/Plugins.swift');

test('адрес, порт и версия API', () => {
  assert.strictEqual(/static let host = "([^"]+)"/.exec(localAPI)[1], contract.host);
  assert.strictEqual(Number(/static let port: UInt16 = (\d+)/.exec(localAPI)[1]), contract.port);
  assert.strictEqual(Number(/static let apiVersion = (\d+)/.exec(plugins)[1]), contract.api);
  const schemes = /let schemes = \[([^\]]+)\]/.exec(localAPI)[1].match(/"([^"]+)"/g).map((s) => s.slice(1, -1));
  assert.deepStrictEqual(schemes, contract.allowedOrigins, 'запросы принимаются только от страниц расширений');
});

test('разрешения и возможности', () => {
  const known = [...plugins.matchAll(/case \w+ = "([a-z.]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(known, contract.permissions);
  const features = /static let features = \[([^\]]*)\]/.exec(localAPI)[1].match(/"([^"]+)"/g).map((s) => s.slice(1, -1));
  assert.deepStrictEqual(features, contract.features, 'новая возможность — новая запись в договоре');
});

test('маршруты и их разрешения', () => {
  const permissionCase = Object.fromEntries([...plugins.matchAll(/case (\w+) = "([a-z.]+)"/g)].map((m) => [m[2], m[1]]));
  const routeCase = { '/v1/status': 'status', '/v1/pair': 'pair', '/v1/targets': 'targets', '/v1/clips': 'clips', '/v1/pages/{id}/open': 'openPage' };
  for (const r of contract.routes) {
    const name = routeCase[r.path];
    assert.ok(name, `маршрут ${r.path} описан в тесте`);
    if (!r.path.includes('{')) assert.ok(localAPI.includes(`case ("${r.method}", "${r.path}"): return .${name}`), r.path);
    else assert.ok(/request\.method == "POST", parts\.count == 4, parts\[0\] == "v1", parts\[1\] == "pages", parts\[3\] == "open"/.test(localAPI), r.path);
    const rule = new RegExp(`case [^:]*\\.${name}\\b[^:]*: return ${r.permission ? '\\.' + permissionCase[r.permission] : 'nil'}`);
    assert.ok(rule.test(localAPI), `${r.path}: разрешение ${r.permission}`);
  }
});

test('идентификаторы приложения, типа пакета и установщиков плагинов', () => {
  assert.strictEqual(/static let bundleID = "([^"]+)"/.exec(read('Sources/MindNotes/Core/AppEdition.swift'))[1], contract.app.bundleID);
  const build = read('scripts/build-app.sh');
  assert.ok(build.includes(`<key>UTTypeIdentifier</key><string>${contract.app.pluginTypeIdentifier}</string>`), 'тип .mnplugin');
  const host = read('Sources/MindNotes/Shell/Plugins/PluginHost.swift');
  assert.ok(host.includes(`clientsKey = "${contract.app.pluginClientsDefaultsKey}"`), 'установщик читает подключения отсюда');
  assert.strictEqual(/installerBundleID = "([^"]+)"/.exec(host)[1], contract.plugins['minerva.webclipper'].installerBundleID, 'MindNotes находит установщик Web Clipper');
  const updater = read('Sources/MindNotes/Shell/Network/PluginUpdater.swift');
  assert.strictEqual(/static let appRepository = "([^"]+)"/.exec(updater)[1], contract.app.repository);
  assert.ok(/releasesURL\(fallback: Self\.appRepository\)/.test(updater), 'выпуски — из репозитория плагина, без поля — отсюда');
});

test('известные репозитории плагинов в коде совпадают с договором', () => {
  const map = /static let knownRepositories = \[([^\]]*)\]/.exec(plugins)[1];
  const known = Object.fromEntries([...map.matchAll(/"([^"]+)": "([^"]+)"/g)].map((m) => [m[1], m[2]]));
  const expected = Object.fromEntries(Object.entries(contract.plugins).map(([id, p]) => [id, p.repository]));
  assert.deepStrictEqual(known, expected, 'плагин, поставленный до переезда, ищет выпуски в своём репозитории');
});

test('репозитории плагинов проходят ту же проверку, что в MindNotes', () => {
  const rule = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/;
  assert.match(contract.app.repository, rule);
  for (const [id, p] of Object.entries(contract.plugins)) {
    assert.match(p.repository, rule, id);
    assert.match(p.updates, /^[a-z0-9-]{1,38}-v$/, id);
  }
});
