'use strict';
// Клиент локального API MindNotes (ADR-0019). Приложение слушает только 127.0.0.1; ключ подключения выдаёт
// MindNotes после вашего согласия и хранится в chrome.storage.local этого браузера.

const MN_API = 'http://127.0.0.1:27183';
const MN_PLUGIN = 'minerva.webclipper';

class MNError extends Error {
  constructor(code, message, status) { super(message); this.code = code; this.status = status || 0; }
}

async function mnToken() {
  const { token } = await chrome.storage.local.get('token');
  return token || null;
}

async function mnRequest(method, path, body) {
  const headers = { 'Content-Type': 'application/json' };
  const token = await mnToken();
  if (token) headers.Authorization = 'Bearer ' + token;
  let response;
  try {
    response = await fetch(MN_API + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch (e) {
    throw new MNError('offline', chrome.i18n.getMessage('errOffline'));
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const code = data.error?.code || 'http';
    if (code === 'unpaired') await chrome.storage.local.remove('token');
    throw new MNError(code, data.error?.message || ('HTTP ' + response.status), response.status);
  }
  return data;
}

const mnAPI = {
  status: () => mnRequest('GET', '/v1/status'),
  /// silent — фоновая попытка: MindNotes ответит без вопроса, только если открыто окно автоподключения.
  async pair(silent = false) {
    const data = await mnRequest('POST', '/v1/pair', { plugin: MN_PLUGIN, silent });
    await chrome.storage.local.set({ token: data.token });
    return data;
  },
  targets: () => mnRequest('GET', '/v1/targets'),
  saveClip: (clip) => mnRequest('POST', '/v1/clips', clip),
  /// Подключается само, если в MindNotes открыто окно автоподключения (сразу после установки). Иначе — ничего.
  async autoPair() {
    let status;
    try { status = await mnRequest('GET', '/v1/status'); } catch (e) { return false; }
    if (status.paired) return true;
    if (!(status.pairing || []).includes(MN_PLUGIN)) return false;
    try { await this.pair(true); return true; } catch (e) { return false; }
  },
  openPage: (id) => mnRequest('POST', `/v1/pages/${encodeURIComponent(id)}/open`, {}),
};

if (typeof module !== 'undefined') module.exports = { MN_API, MN_PLUGIN, MNError, mnAPI };
