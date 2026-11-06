// Update check against GitHub releases, shared by the main process and the tests (no Electron imports here).
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const REPOSITORY = 'Slipcast-dev/Grizzly';
const LATEST_URL = `https://api.github.com/repos/${REPOSITORY}/releases/latest`;
const ASSET_SUFFIX = '-portable.exe';

const normalize = (tag) => String(tag || '').trim().replace(/^v/i, '');

function parts(version) {
  return normalize(version).split('.').map((p) => parseInt(p, 10) || 0);
}

/** Numeric comparison of dotted versions: 1.10.0 is newer than 1.9.0, 1.2 equals 1.2.0. */
function isNewer(candidate, current) {
  const a = parts(candidate);
  const b = parts(current);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] || 0;
    const y = b[i] || 0;
    if (x !== y) return x > y;
  }
  return false;
}

/** Downloads only come from GitHub itself, over HTTPS. */
function isTrustedDownload(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' && (u.hostname === 'github.com' || u.hostname.endsWith('.githubusercontent.com'));
  } catch { return false; }
}

/** Finds a 64-digit hex string on the line of the release notes that names the asset. */
function checksumInNotes(notes, assetName) {
  for (const line of String(notes || '').split(/\r?\n/)) {
    if (!line.includes(assetName)) continue;
    const m = /(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])/.exec(line);
    if (m) return m[0].toLowerCase();
  }
  return null;
}

/** Reads the `releases/latest` answer. Returns null when the release has no file for this app. */
function parseRelease(json, suffix = ASSET_SUFFIX) {
  if (!json || typeof json.tag_name !== 'string') throw new Error('unexpected release data');
  const notes = typeof json.body === 'string' ? json.body : '';
  for (const asset of Array.isArray(json.assets) ? json.assets : []) {
    if (typeof asset.name !== 'string' || !asset.name.endsWith(suffix)) continue;
    if (!isTrustedDownload(asset.browser_download_url)) continue;
    return {
      version: normalize(json.tag_name), notes, assetName: asset.name, assetURL: asset.browser_download_url,
      sha256: checksumInNotes(notes, asset.name),
    };
  }
  return null;
}

async function fetchLatest(currentVersion) {
  const res = await fetch(LATEST_URL, {
    headers: { Accept: 'application/vnd.github+json', 'User-Agent': `Grizzly/${currentVersion}` },
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
  return parseRelease(await res.json());
}

const MAX_DOWNLOAD = 500 * 1024 * 1024;

/** Follows redirects by hand so that every hop stays on a trusted GitHub host. */
async function fetchTrusted(url, headers) {
  for (let hop = 0; hop < 5; hop++) {
    if (!isTrustedDownload(url)) throw new Error('untrusted download address');
    const res = await fetch(url, { headers, redirect: 'manual' });
    if (res.status >= 300 && res.status < 400 && res.headers.get('location')) {
      url = new URL(res.headers.get('location'), url).href;
      continue;
    }
    return res;
  }
  throw new Error('too many redirects');
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** SHA-256 of a finished file, read in a stream. */
function hashFile(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    fs.createReadStream(file).on('data', (c) => hash.update(c)).on('error', reject).on('end', () => resolve(hash.digest('hex')));
  });
}

/** Downloads the release file into a temporary folder, reporting progress. A dropped connection is retried and
 *  continues where it stopped (HTTP Range). A published SHA-256 is mandatory and checked over the finished file. */
async function download(release, currentVersion, onProgress) {
  if (!isTrustedDownload(release.assetURL)) throw new Error('untrusted download address');
  if (!release.sha256) throw Object.assign(new Error('no checksum published for this release'), { code: 'ENOCHECKSUM' });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'grizzly-update-'));
  const file = path.join(dir, path.basename(release.assetName));
  const fail = (err) => { fs.rmSync(dir, { recursive: true, force: true }); throw err; };
  let received = 0;
  let total = 0;
  let finished = false;
  let lastError = null;

  for (let attempt = 0; attempt < 5 && !finished; attempt++) {
    if (attempt) await sleep(attempt * 1500);
    try {
      const headers = { 'User-Agent': `Grizzly/${currentVersion}` };
      if (received) headers.Range = `bytes=${received}-`;
      const res = await fetchTrusted(release.assetURL, headers);
      if (!(res.status === 200 || res.status === 206) || !res.body) throw new Error(`download failed (${res.status})`);
      if (res.status === 200) received = 0; // the server sent the whole file again
      const length = Number(res.headers.get('content-length')) || 0;
      total = received + length;
      if (total > MAX_DOWNLOAD) throw Object.assign(new Error('download too large'), { code: 'ETOOLARGE' });
      const out = fs.createWriteStream(file, { flags: received ? 'a' : 'w' });
      let writeError = null; // a full disk must fail the download, not crash the app or hang on 'drain'
      out.on('error', (err) => { writeError = err; });
      try {
        for await (const chunk of res.body) {
          if (writeError) throw writeError;
          received += chunk.length;
          if (received > MAX_DOWNLOAD) throw Object.assign(new Error('download too large'), { code: 'ETOOLARGE' });
          if (!out.write(chunk)) {
            await new Promise((r) => {
              const done = () => { out.off('drain', done); out.off('error', done); r(); };
              out.once('drain', done); out.once('error', done);
            });
          }
          if (total) onProgress(received / total);
        }
      } finally {
        await new Promise((resolve) => out.end(resolve));
      }
      if (writeError) throw writeError;
      if (length && received !== total) throw new Error('connection lost');
      finished = true;
    } catch (err) {
      if (err.code === 'ETOOLARGE' || err.code === 'ENOSPC' || err.message === 'untrusted download address') fail(err);
      lastError = err;
      // Keep only what was really written, so the next attempt resumes from there.
      try { received = fs.statSync(file).size; } catch { received = 0; }
    }
  }
  if (!finished) fail(Object.assign(new Error(lastError ? lastError.message : 'download failed'), { code: 'ENETWORK' }));
  if ((await hashFile(file)) !== release.sha256) fail(Object.assign(new Error('checksum mismatch'), { code: 'ECHECKSUM' }));
  return file;
}

/** Windows batch script: waits until the running exe can be replaced (it is locked while the app runs), swaps it, starts it. */
const REPLACE_SCRIPT = [
  '@echo off',
  'set "SRC=%~1"',
  'set "DST=%~2"',
  'set /a n=0',
  ':retry',
  'move /Y "%SRC%" "%DST%" >nul 2>&1',
  'if not errorlevel 1 goto done',
  'set /a n+=1',
  'if %n% GEQ 90 exit /b 1',
  'timeout /t 1 /nobreak >nul',
  'goto retry',
  ':done',
  'start "" "%DST%"',
  '(goto) 2>nul & del "%~f0"',
  '',
].join('\r\n');

module.exports = { REPOSITORY, ASSET_SUFFIX, normalize, isNewer, isTrustedDownload, checksumInNotes, parseRelease, fetchLatest, download, REPLACE_SCRIPT };
