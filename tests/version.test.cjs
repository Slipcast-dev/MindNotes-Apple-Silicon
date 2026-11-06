// VERSION is the single source of truth; the build script and the Electron package must follow it.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim();

test('electron/package.json matches VERSION', () => {
  assert.strictEqual(JSON.parse(fs.readFileSync(path.join(root, 'electron', 'package.json'), 'utf8')).version, version);
});
test('build-app.sh reads VERSION instead of hard-coding it', () => {
  assert.ok(fs.readFileSync(path.join(root, 'scripts', 'build-app.sh'), 'utf8').includes('VERSION'));
});
test('CHANGELOG has an entry for VERSION', () => {
  assert.ok(fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8').includes(`## [${version}]`));
});
