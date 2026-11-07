'use strict';
// Minerva Noema не должна пересекаться с установленным Grizzly: идентификатор, данные, обработчик файлов.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

test('идентификатор сборки совпадает с AppEdition и отличается от оригинала', () => {
  const id = /bundleID = "([^"]+)"/.exec(read('Sources/MinervaNoema/Core/AppEdition.swift'))[1];
  const build = read('scripts/build-app.sh');
  assert.ok(build.includes(`<key>CFBundleIdentifier</key><string>${id}</string>`));
  assert.ok(!build.includes('app.grizzly.Grizzly'));
});

test('каталог данных отдельный, сборка не заявляет себя обработчиком по умолчанию', () => {
  assert.strictEqual(/officialSupportDirectoryName = "([^"]+)"/.exec(read('Sources/MinervaNoema/Core/AppEdition.swift'))[1], 'MinervaNoema');
  assert.ok(!read('scripts/build-app.sh').includes('<key>LSHandlerRank</key><string>Default</string>'));
});
