// Update check logic (electron/updater.js): version order, release parsing, checksums, trusted hosts.
const test = require('node:test');
const assert = require('node:assert');
const u = require('../electron/updater.js');

test('newer versions are detected numerically', () => {
  assert.ok(u.isNewer('1.2.0', '1.1.0'));
  assert.ok(u.isNewer('v1.10.0', '1.9.9'));
  assert.ok(u.isNewer('2.0', '1.99.9'));
  assert.ok(!u.isNewer('1.1.0', '1.1.0'));
  assert.ok(!u.isNewer('1.1', '1.1.0'));
  assert.ok(!u.isNewer('1.0.9', '1.1.0'));
});

test('checksum is read from the line that names the file', () => {
  const notes = `## SHA-256\n\`${'A'.repeat(64)}\`  Grizzly-1.2.0-portable.exe\n${'b'.repeat(64)} Grizzly-1.2.0-arm64.dmg`;
  assert.strictEqual(u.checksumInNotes(notes, 'Grizzly-1.2.0-portable.exe'), 'a'.repeat(64));
  assert.strictEqual(u.checksumInNotes(notes, 'Grizzly-1.2.0-arm64.dmg'), 'b'.repeat(64));
  assert.strictEqual(u.checksumInNotes(notes, 'other.exe'), null);
});

test('release JSON: version and the Windows asset', () => {
  const base = 'https://github.com/Slipcast-dev/Grizzly/releases/download/v1.2.0/';
  const json = { tag_name: 'v1.2.0', body: 'notes', assets: [
    { name: 'Grizzly-1.2.0-arm64.dmg', browser_download_url: base + 'Grizzly-1.2.0-arm64.dmg' },
    { name: 'Grizzly-1.2.0-portable.exe', browser_download_url: base + 'Grizzly-1.2.0-portable.exe' },
  ] };
  const r = u.parseRelease(json);
  assert.strictEqual(r.version, '1.2.0');
  assert.strictEqual(r.assetName, 'Grizzly-1.2.0-portable.exe');
  assert.strictEqual(u.parseRelease({ tag_name: 'v1', assets: [] }), null);
  assert.throws(() => u.parseRelease({}));
});

test('downloads are limited to GitHub over HTTPS', () => {
  assert.ok(u.isTrustedDownload('https://github.com/a/b.exe'));
  assert.ok(u.isTrustedDownload('https://objects.githubusercontent.com/a.exe'));
  assert.ok(!u.isTrustedDownload('http://github.com/a.exe'));
  assert.ok(!u.isTrustedDownload('https://evil.example/a.exe'));
  assert.ok(!u.isTrustedDownload('https://github.com.evil.example/a.exe'));
  assert.ok(!u.isTrustedDownload('not a url'));
});

test('a release without a published checksum is refused before any download', async () => {
  await assert.rejects(
    u.download({ assetURL: 'https://github.com/a/b/c-portable.exe', assetName: 'c-portable.exe', sha256: null }, '1.0.0', () => {}),
    { code: 'ENOCHECKSUM' });
});

test('a dropped connection is resumed with a Range request and the checksum is verified', async () => {
  const crypto = require('node:crypto');
  const fs = require('node:fs');
  const data = crypto.randomBytes(400_000);
  const sha = crypto.createHash('sha256').update(data).digest('hex');
  const realFetch = global.fetch;
  let calls = 0;
  global.fetch = async (_url, opts) => {
    calls++;
    const range = opts.headers.Range;
    const start = range ? Number(/bytes=(\d+)-/.exec(range)[1]) : 0;
    const body = data.subarray(start);
    const failAt = calls === 1 ? 150_000 : Infinity;
    const stream = new ReadableStream({
      start(c) {
        let off = 0;
        const push = () => {
          if (off >= failAt) return c.error(new Error('connection reset'));
          if (off >= body.length) return c.close();
          c.enqueue(body.subarray(off, Math.min(off + 50_000, body.length)));
          off += 50_000;
          setImmediate(push);
        };
        push();
      },
    });
    return new Response(stream, { status: range ? 206 : 200, headers: { 'content-length': String(body.length) } });
  };
  try {
    const file = await u.download({ assetURL: 'https://github.com/a/b/c-portable.exe', assetName: 'c-portable.exe', sha256: sha }, '1.0.0', () => {});
    assert.strictEqual(calls, 2);
    assert.ok(fs.readFileSync(file).equals(data));
    fs.rmSync(require('node:path').dirname(file), { recursive: true, force: true });
    await assert.rejects(
      u.download({ assetURL: 'https://github.com/a/b/c-portable.exe', assetName: 'c-portable.exe', sha256: '0'.repeat(64) }, '1.0.0', () => {}),
      { code: 'ECHECKSUM' });
  } finally { global.fetch = realFetch; }
});
