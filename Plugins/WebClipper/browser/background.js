'use strict';
// Фон расширения: контекстное меню, горячая клавиша и сама вырезка. Окно расширения (popup) закрывается при потере
// фокуса, поэтому извлечение, загрузка картинок и отправка идут здесь.

importScripts('api.js', 'extract.js');

const LIMITS = { images: 40, imageBytes: 8 * 1024 * 1024, totalBytes: 30 * 1024 * 1024 };
const ACCEPTED = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp' };
const t = (key, ...subs) => chrome.i18n.getMessage(key, subs) || key;

// Самонастройка: пока нет ключа, раз в минуту проверяем, не открыто ли в MindNotes окно автоподключения.
// Одна попытка за раз: при установке подключение запрашивали фон, окно и таймер одновременно,
// и MindNotes выдавала несколько ключей одному браузеру.
let pairing = null;
function autoPairOnce() {
  pairing = pairing || mnAPI.autoPair().finally(() => { pairing = null; });
  return pairing;
}
async function ensurePaired() {
  if (await autoPairOnce()) chrome.alarms.clear('mn-pair');
  else chrome.alarms.create('mn-pair', { periodInMinutes: 1 });
}
// Самообновление: установщик кладёт новые файлы на диск, а браузер держит в памяти старые. Расширение сравнивает
// свою версию со сборкой на диске и перезапускается само — нажимать «Обновить» в браузере не нужно.
async function reloadIfUpdated() {
  try {
    const response = await fetch(chrome.runtime.getURL('manifest.json'), { cache: 'no-store' });
    const onDisk = await response.json();
    const running = chrome.runtime.getManifest();
    if ((onDisk.version_name || onDisk.version) !== (running.version_name || running.version)) chrome.runtime.reload();
  } catch (e) { /* файла нет — браузер сам сообщит об ошибке расширения */ }
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'mn-pair') ensurePaired();
  if (alarm.name === 'mn-update') reloadIfUpdated();
});
chrome.runtime.onStartup.addListener(() => { ensurePaired(); reloadIfUpdated(); });
chrome.alarms.create('mn-update', { periodInMinutes: 15 });

chrome.runtime.onInstalled.addListener(() => {
  ensurePaired();
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: 'mn-article', title: t('menuArticle'), contexts: ['page'] });
    chrome.contextMenus.create({ id: 'mn-selection', title: t('menuSelection'), contexts: ['selection'] });
    chrome.contextMenus.create({ id: 'mn-link', title: t('menuLink'), contexts: ['link'] });
    chrome.contextMenus.create({ id: 'mn-image', title: t('menuImage'), contexts: ['image'] });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const mode = { 'mn-article': 'article', 'mn-selection': 'selection', 'mn-link': 'link', 'mn-image': 'image' }[info.menuItemId];
  if (!mode || !tab) return;
  runAndReport(tab, { mode, linkUrl: info.linkUrl, linkText: info.selectionText, srcUrl: info.srcUrl });
});

chrome.commands.onCommand.addListener(async (command, tab) => {
  if (command !== 'clip-article') return;
  tab = tab || (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
  if (tab) runAndReport(tab, { mode: 'article' });
});

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message?.type === 'checkUpdate') { reloadIfUpdated(); return false; }
  if (message?.type === 'autoPair') {
    autoPairOnce().then((ok) => reply({ ok })).catch(() => reply({ ok: false }));
    return true;
  }
  if (message?.type !== 'clip') return false;
  chrome.tabs.get(message.tabId)
    .then((tab) => clip(tab, message))
    .then((result) => reply({ ok: true, page: result.page }))
    .catch((e) => reply({ ok: false, code: e.code || 'error', message: e.message }));
  return true; // ответ асинхронный
});

/// Вырезка без окна (меню, клавиша): итог — значок на кнопке расширения.
async function runAndReport(tab, options) {
  badge(tab.id, '…', '#888888');
  try {
    const { lastParent } = await chrome.storage.local.get('lastParent');
    await clip(tab, { ...options, parent: lastParent || null });
    badge(tab.id, '✓', '#2E7D32');
  } catch (e) {
    badge(tab.id, '!', '#C0392B');
    chrome.action.setTitle({ tabId: tab.id, title: t('actionFailed', e.message) });
  }
  setTimeout(() => badge(tab.id, '', '#000000'), 4000);
}

function badge(tabId, text, color) {
  chrome.action.setBadgeText({ tabId, text }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color }).catch(() => {});
}

const isWeb = (url) => /^https?:\/\//i.test(url || '');

async function clip(tab, options) {
  const mode = options.mode || 'article';
  const body = { mode, title: options.title || '', url: isWeb(tab.url) ? tab.url : undefined, markdown: '', note: options.note || '',
    tags: options.tags || [], parent: options.parent || undefined, images: [] };

  if (mode === 'screenshot') {
    const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
    body.title = body.title || tab.title || '';
    body.images = [{ name: 'screenshot.png', mime: 'image/png', data: dataUrl.split(',')[1] }];
  } else if (mode === 'image') {
    const picture = await download(options.srcUrl);
    if (!picture) throw new MNError('image', t('errImage'));
    body.title = body.title || tab.title || '';
    body.images = [{ name: 'image.' + ACCEPTED[picture.mime], ...picture }];
  } else if (mode === 'link') {
    body.mode = 'bookmark';
    body.url = options.linkUrl;
    body.title = body.title || options.linkText || options.linkUrl;
  } else {
    if (!isWeb(tab.url)) throw new MNError('page', t('errPage'));
    let result;
    try {
      [{ result }] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: mnExtractPage, args: [mode] });
    } catch (e) {
      throw new MNError('page', t('errPage'));
    }
    if (!result) throw new MNError('page', t('errPage'));
    if (result.error === 'no_selection') throw new MNError('selection', t('errSelection'));
    body.title = body.title || result.title;
    body.excerpt = result.excerpt;
    body.siteName = result.siteName;
    const withImages = options.withImages !== false;
    const fetched = withImages ? await downloadAll(result.images) : [];
    body.markdown = mnPlaceImages(result.markdown, result.images, fetched, t('imageLink'));
    body.images = fetched.filter(Boolean);
  }
  return mnAPI.saveClip(body);
}

async function downloadAll(list) {
  const out = [];
  let total = 0;
  for (let i = 0; i < list.length && i < LIMITS.images; i += 1) {
    const picture = await download(list[i].src).catch(() => null);
    if (picture && total + picture.size <= LIMITS.totalBytes) {
      total += picture.size;
      out[i] = { name: `clip-${i + 1}.${ACCEPTED[picture.mime]}`, mime: picture.mime, data: picture.data };
    } else out[i] = null;
  }
  return out;
}

/// Картинка в base64. Без разрешения на все сайты браузер отдаст только картинки самой страницы — это нормально.
async function download(src) {
  if (!src) return null;
  let blob;
  if (src.startsWith('data:image/')) blob = await (await fetch(src)).blob();
  else {
    const response = await fetch(src, { credentials: 'omit' });
    if (!response.ok) return null;
    blob = await response.blob();
  }
  if (!blob.size || blob.size > LIMITS.imageBytes) return null;
  let mime = (blob.type || '').split(';')[0].toLowerCase();
  if (!ACCEPTED[mime]) {
    // AVIF, BMP и прочее — в PNG, если браузер умеет их декодировать. SVG не берём.
    if (mime.includes('svg') || typeof createImageBitmap !== 'function' || typeof OffscreenCanvas === 'undefined') return null;
    try {
      const bitmap = await createImageBitmap(blob);
      const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
      canvas.getContext('2d').drawImage(bitmap, 0, 0);
      blob = await canvas.convertToBlob({ type: 'image/png' });
      mime = 'image/png';
    } catch (e) { return null; }
  }
  return { mime, data: await base64(blob), size: blob.size };
}

async function base64(blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

