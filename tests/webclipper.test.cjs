'use strict';
// Плагин WebClipper (ADR-0019): описание пакета и расширения согласованы, переводы полные, метки картинок.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const dir = path.join(root, 'Plugins/WebClipper');
const json = (p) => JSON.parse(fs.readFileSync(path.join(dir, p), 'utf8'));
const read = (p) => fs.readFileSync(path.join(dir, p), 'utf8');

test('версии и id плагина и расширения согласованы', () => {
  const plugin = json('manifest.json');
  const browser = json('browser/manifest.json');
  assert.strictEqual(plugin.kind, 'plugin');
  assert.strictEqual(plugin.version, browser.version);
  assert.strictEqual(plugin.api, 1);
  assert.strictEqual(plugin.author, 'MindNotes', 'в настройках плагин подписан именем приложения');
  assert.ok(read('browser/api.js').includes(`const MN_PLUGIN = '${plugin.id}'`), 'расширение называет себя id плагина');
});

test('разрешения плагина известны приложению, порт один и тот же', () => {
  const swift = fs.readFileSync(path.join(root, 'Sources/MindNotes/Workspace/Domain/Plugins.swift'), 'utf8');
  const known = [...swift.matchAll(/case \w+ = "([a-z.]+)"/g)].map((m) => m[1]);
  for (const p of json('manifest.json').permissions) assert.ok(known.includes(p), p);
  const api = fs.readFileSync(path.join(root, 'Sources/MindNotes/Workspace/Domain/LocalAPI.swift'), 'utf8');
  const port = /static let port: UInt16 = (\d+)/.exec(api)[1];
  assert.ok(read('browser/api.js').includes(`http://127.0.0.1:${port}`));
  assert.deepStrictEqual(json('browser/manifest.json').host_permissions, ['http://127.0.0.1/*'], 'постоянный доступ — только к MindNotes');
});

test('файлы из манифеста расширения на месте (значки кладёт сборка)', () => {
  const m = json('browser/manifest.json');
  for (const f of [m.action.default_popup, m.background.service_worker, 'api.js', 'extract.js', 'popup.js', 'popup.css']) {
    assert.ok(fs.existsSync(path.join(dir, 'browser', f)), f);
  }
  assert.ok(fs.readFileSync(path.join(root, 'scripts/build-webclipper.sh'), 'utf8').includes('icon-$size.png'));
});

test('переводы ru и en полные, все ключи из кода есть', () => {
  const ru = json('browser/_locales/ru/messages.json');
  const en = json('browser/_locales/en/messages.json');
  assert.deepStrictEqual(Object.keys(ru).sort(), Object.keys(en).sort());
  const code = ['popup.html', 'popup.js', 'background.js', 'api.js', 'manifest.json'].map((f) => read('browser/' + f)).join('\n');
  const used = new Set([...code.matchAll(/(?:data-i18n(?:-placeholder)?="|\bt\('|getMessage\('|__MSG_)([A-Za-z0-9]+)/g)].map((m) => m[1]));
  for (const key of used) assert.ok(ru[key], key);
});

test('метки картинок: скачанные — вложения, с других сайтов — скачает MindNotes, data: — подпись', () => {
  const { mnPlaceImages } = require(path.join(dir, 'browser/extract.js'));
  const md = 'А\n\n![Схема](mnimg-1)\n\n![](mnimg-2)\n\n![Встроенная](mnimg-3)';
  const sources = [{ src: 'https://a.com/1.png' }, { src: 'https://cdn.com/x(1).jpg' }, { src: 'data:image/png;base64,AAAA' }];
  const out = mnPlaceImages(md, sources, [{ name: 'clip-1.png' }, null, null], 'Картинка');
  assert.strictEqual(out.markdown, 'А\n\n![Схема](clip-1.png)\n\n![](remote-2.img)\n\nВстроенная', 'картинку с CDN скачает MindNotes');
  assert.deepStrictEqual(out.remote, [{ name: 'remote-2.img', url: 'https://cdn.com/x(1).jpg' }]);
  const off = mnPlaceImages(md, sources, [], 'Картинка', false);
  assert.strictEqual(off.markdown, 'А\n\n[Схема](https://a.com/1.png)\n\n[Картинка](https://cdn.com/x%281%29.jpg)\n\nВстроенная', 'без «Сохранять картинки» — ссылки');
  assert.deepStrictEqual(off.remote, []);
});

test('установщик: идентификаторы MindNotes, Safari и типа пакета согласованы', () => {
  const browsers = read('Installer/Browsers.swift');
  const build = fs.readFileSync(path.join(root, 'scripts/build-webclipper.sh'), 'utf8');
  const appBuild = fs.readFileSync(path.join(root, 'scripts/build-app.sh'), 'utf8');
  const edition = fs.readFileSync(path.join(root, 'Sources/MindNotes/Core/AppEdition.swift'), 'utf8');
  const host = fs.readFileSync(path.join(root, 'Sources/MindNotes/Shell/Plugins/PluginHost.swift'), 'utf8');
  const container = /BUNDLE_ID=(\S+)/.exec(build)[1];
  assert.strictEqual(/mindNotesBundleID = "([^"]+)"/.exec(browsers)[1], /bundleID = "([^"]+)"/.exec(edition)[1], 'установщик ищет ту же MindNotes');
  assert.ok(/safariExtensionID = "([^"]+)"/.exec(browsers)[1].startsWith(container + '.'), 'id расширения Safari начинается с id программы');
  assert.strictEqual(/installerBundleID = "([^"]+)"/.exec(host)[1], container, 'MindNotes находит установщик');
  const uti = /"UTTypeIdentifier"\] as\? String\) == "([^"]+)"/.exec(browsers)[1];
  assert.ok(appBuild.includes(`<key>UTTypeIdentifier</key><string>${uti}</string>`), 'проверка поддержки плагинов смотрит на объявленный тип');
});

test('самонастройка: расширение подключается само только в окне автоподключения', () => {
  const api = read('browser/api.js');
  const bg = read('browser/background.js');
  assert.ok(/pair\(true\)/.test(api) && /status\.pairing/.test(api), 'тихая привязка только когда MindNotes открыл окно');
  assert.ok(/chrome\.alarms\.create\('mn-pair'/.test(bg) && /onInstalled\.addListener\(\(\) => \{\s*ensurePaired\(\)/.test(bg));
  assert.ok(json('browser/manifest.json').permissions.includes('alarms'));
});

test('окно расширения: скрытые панели не показываются, даже если у них свой display', () => {
  const css = read('browser/popup.css');
  assert.ok(/\[hidden\]\s*\{\s*display:\s*none\s*!important;?\s*\}/.test(css), 'без этого правила окно показывает все состояния сразу');
  const html = read('browser/popup.html');
  for (const id of ['offline', 'unpaired', 'noWorkspace', 'clip', 'done', 'error']) {
    assert.ok(new RegExp(`id="${id}"[^>]*hidden`).test(html), `${id} скрыт до проверки`);
  }
});

test('автоподключение идёт только из фона и по одному запросу', () => {
  const bg = read('browser/background.js');
  assert.ok(/pairing = pairing \|\| mnAPI\.autoPair\(\)/.test(bg), 'одна попытка за раз');
  assert.ok(!/mnAPI\.autoPair\(/.test(read('browser/popup.js')), 'окно не подключается само, а просит фон');
});

test('окно расширения прячет панели и стилем из кода, а не только атрибутом', () => {
  const js = read('browser/popup.js');
  assert.ok(/el\.style\.display = visible \? '' : 'none'/.test(js), 'скрытие не зависит от таблицы стилей');
  assert.ok(!/\.hidden = /.test(js.replace(/el\.hidden = !visible/, '')), 'все показы и скрытия идут через setVisible');
  const html = read('browser/popup.html');
  for (const id of ['offline', 'unpaired', 'noWorkspace', 'clip', 'done', 'error']) {
    assert.ok(new RegExp(`id="${id}"[^>]*style="display:none"`).test(html), `${id} скрыт до проверки состояния`);
  }
});

test('выпуски плагина отдельно от приложения и не мешают его обновлениям', () => {
  const plugin = json('manifest.json');
  assert.strictEqual(plugin.updates, 'webclipper-v', 'свой префикс тегов');
  const changelog = read('CHANGELOG.md');
  assert.ok(changelog.includes(`## [${plugin.version}]`), 'у текущей версии плагина есть запись в журнале');
  const release = fs.readFileSync(path.join(root, 'scripts/release-webclipper.sh'), 'utf8');
  assert.ok(release.includes('--latest=false'), 'выпуск плагина не становится «последним»: по нему MindNotes ищет свои обновления');
  assert.ok(/minApp/.test(release) && /releases\/latest/.test(release), 'плагин не выходит раньше подходящей MindNotes');
  assert.ok(/<!-- minApp: %s -->/.test(release), 'MindNotes узнаёт совместимость из описания выпуска');
  const bg = read('browser/background.js');
  assert.ok(/chrome\.runtime\.reload\(\)/.test(bg) && /cache: 'no-store'/.test(bg), 'расширение подхватывает новую версию с диска само');
});

test('расширению не нужен доступ ко всем сайтам', () => {
  const m = json('browser/manifest.json');
  assert.ok(!m.optional_host_permissions && !(m.permissions || []).includes('<all_urls>'), 'картинки с других сайтов скачивает MindNotes');
  assert.ok(!/permissions\.request/.test(read('browser/popup.js')));
  assert.ok(/body\.remoteImages = placed\.remote/.test(read('browser/background.js')));
});

test('плагин обновляется независимо от версии MindNotes', () => {
  const api = read('browser/api.js');
  const bg = read('browser/background.js');
  assert.ok(/features: mnFeatures/.test(api), 'расширение спрашивает возможности MindNotes');
  assert.ok(/let list = \['clips', 'targets', 'openPage'\]/.test(api), 'старая MindNotes без списка — только базовое');
  assert.ok(/includes\('remoteImages'\)/.test(bg), 'картинки с CDN — только если MindNotes умеет');
  const release = fs.readFileSync(path.join(root, 'scripts/release-webclipper.sh'), 'utf8');
  assert.ok(/plugin-manifest\.json/.test(release) && /shasum -a 256 "\$DMG" plugin-manifest\.json/.test(release), 'описание плагина в выпуске и в суммах');
  assert.ok(/minApp=""/.test(release), 'minApp необязателен');
  const swift = fs.readFileSync(path.join(root, 'Sources/MindNotes/Workspace/Domain/LocalAPI.swift'), 'utf8');
  for (const f of ['clips', 'targets', 'openPage', 'remoteImages']) assert.ok(swift.includes(`"${f}"`), f);
});

test('установщик умеет тихое обновление для MindNotes', () => {
  const app = read('Installer/InstallerApp.swift');
  assert.ok(/contains\("--update"\)/.test(app) && /syncChromeFolder/.test(app) && /exit\(/.test(app), 'без окна обновить файлы и выйти');
});

test('готовность к переезду плагина в свой репозиторий', () => {
  const release = fs.readFileSync(path.join(root, 'scripts/release-webclipper.sh'), 'utf8');
  assert.ok(/extract repository raw/.test(release), 'скрипт берёт репозиторий из описания плагина');
  assert.ok(/MIRROR_TO_APP_REPO/.test(release), 'переходный период: копия выпуска в репозитории приложения');
  assert.ok(/latest=\(--latest=false\)/.test(release), 'в репозитории приложения выпуск плагина не «последний»');
  const updater = fs.readFileSync(path.join(root, 'Sources/MindNotes/Shell/Network/PluginUpdater.swift'), 'utf8');
  assert.ok(/releasesURL\(fallback: Self\.appRepository\)/.test(updater), 'MindNotes ищет выпуски в репозитории плагина');
  const plugin = json('manifest.json');
  if (plugin.repository) assert.match(plugin.repository, /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/);
});

test('плагин поддерживает macOS 15 и новее независимо от минимума MindNotes', () => {
  const build = fs.readFileSync(path.join(root, 'scripts/build-webclipper.sh'), 'utf8');
  assert.ok(/PLUGIN_MIN_MACOS=15\.0/.test(build), 'минимум плагина — macOS 15');
  assert.ok(/-target "\$PLUGIN_TARGET"/.test(build), 'установщик собирается для минимума плагина, а не приложения');
  assert.ok(/<string>\$PLUGIN_MIN_MACOS<\/string>/.test(build), 'LSMinimumSystemVersion установщика');
  assert.ok(/MACOSX_DEPLOYMENT_TARGET="\$PLUGIN_MIN_MACOS"/.test(build) && /ARCHS=arm64/.test(build), 'расширение Safari — macOS 15, только Apple Silicon');
  const browsers = read('Installer/Browsers.swift');
  assert.ok(/static func runsHere/.test(browsers) && /LSMinimumSystemVersion/.test(browsers), 'установщик видит, что MindNotes требует более новую macOS');
  // Safari 18 (macOS 15): новые возможности браузера — только с проверкой наличия.
  const extract = read('browser/extract.js');
  assert.ok(/typeof el\.checkVisibility === 'function'/.test(extract));
  assert.ok(/typeof OffscreenCanvas === 'undefined'/.test(read('browser/background.js')));
});
