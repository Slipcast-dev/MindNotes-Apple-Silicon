'use strict';
// Личная сборка не должна пересекаться с установленным Grizzly: идентификатор, каталог данных, обновления.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

test('идентификатор сборки совпадает с AppEdition и отличается от оригинала', () => {
  const edition = read('Sources/Grizzly/Core/AppEdition.swift');
  const id = /bundleID = "([^"]+)"/.exec(edition)[1];
  const build = read('scripts/build-app.sh');
  assert.ok(build.includes(`<key>CFBundleIdentifier</key><string>${id}</string>`));
  assert.ok(!build.includes('app.grizzly.Grizzly'));
  assert.ok(read('QuickLook/Info.plist').includes(`<string>${id}.QuickLook</string>`));
});

test('обновления выключены, каталог данных отдельный', () => {
  const edition = read('Sources/Grizzly/Core/AppEdition.swift');
  assert.ok(edition.includes('updatesEnabled = false'));
  assert.ok(edition.includes('migratesLegacyLibrary = false'));
  assert.ok(!/supportDirectoryName = "Grizzly"/.test(edition));
  assert.ok(read('Sources/Grizzly/Library/LibraryStore.swift').includes('AppEdition.supportDirectoryName'));
});

test('сборка не заявляет себя обработчиком по умолчанию', () => {
  assert.ok(!read('scripts/build-app.sh').includes('<key>LSHandlerRank</key><string>Default</string>'));
});
