'use strict';
// Окно расширения: состояние подключения, выбор режима и папки, отправка вырезки через фон.

const $ = (id) => document.getElementById(id);
const t = (key, ...subs) => chrome.i18n.getMessage(key, subs) || key;
let tab = null;
let mode = 'article';
let savedPage = null;

for (const el of document.querySelectorAll('[data-i18n]')) el.textContent = t(el.dataset.i18n);
for (const el of document.querySelectorAll('[data-i18n-placeholder]')) el.placeholder = t(el.dataset.i18nPlaceholder);

// Видна ровно одна панель. Скрытие задаётся и атрибутом, и стилем: так окно не покажет все состояния сразу,
// даже если браузер держит старую таблицу стилей.
function setVisible(el, visible) {
  el.hidden = !visible;
  el.style.display = visible ? '' : 'none';
}

function show(section) {
  for (const id of ['offline', 'unpaired', 'noWorkspace', 'clip', 'done']) setVisible($(id), id === section);
}

function error(message) {
  setVisible($('error'), Boolean(message));
  $('error').textContent = message || '';
}

// Отметка сборки во всплывающей подсказке: видно, свежая ли копия расширения открыта.
const manifest = chrome.runtime.getManifest();
$('brand').title = 'Web Clipper ' + (manifest.version_name || manifest.version);
show(null);

function setMode(next) {
  mode = next;
  for (const b of document.querySelectorAll('.modes button')) b.setAttribute('aria-checked', String(b.dataset.mode === mode));
  setVisible($('images').closest('label'), mode === 'article' || mode === 'selection');
}

async function refresh() {
  error('');
  $('state').textContent = '';
  $('state').className = 'state';
  let status;
  try { status = await mnAPI.status(); } catch (e) { show('offline'); return; }
  if (!status.paired) {
    if ((status.pairing || []).includes(MN_PLUGIN) && (await chrome.runtime.sendMessage({ type: 'autoPair' }))?.ok) return refresh();
    show('unpaired');
    return;
  }
  if (status.active === false) { show('offline'); error(t('errDisabled')); return; }
  $('state').textContent = t('connected');
  $('state').className = 'state ok';
  if (!status.workspace) { show('noWorkspace'); return; }
  await fillForm();
  show('clip');
}

async function fillForm() {
  [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const stored = await chrome.storage.local.get(['lastParent', 'lastMode', 'withImages']);
  $('title').value = tab?.title || '';
  $('images').checked = stored.withImages !== false;
  let selected = false;
  try {
    const [{ result }] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: () => !window.getSelection().isCollapsed });
    selected = result;
  } catch (e) { /* служебная страница браузера */ }
  setMode(selected ? 'selection' : (stored.lastMode === 'bookmark' || stored.lastMode === 'screenshot' ? stored.lastMode : 'article'));

  const select = $('parent');
  select.textContent = '';
  try {
    const { targets, defaultFolder } = await mnAPI.targets();
    select.append(new Option(t('defaultFolder', defaultFolder), ''));
    for (const target of targets) select.append(new Option((target.folder ? '📁 ' : '') + target.path, target.id));
    if (stored.lastParent && targets.some((x) => x.id === stored.lastParent)) select.value = stored.lastParent;
  } catch (e) {
    select.append(new Option(t('defaultFolderPlain'), ''));
  }
}

$('retry').onclick = refresh;
$('retry2').onclick = refresh;
for (const b of document.querySelectorAll('.modes button')) b.onclick = () => setMode(b.dataset.mode);

$('pair').onclick = async () => {
  error('');
  $('pair').disabled = true;
  setVisible($('pairWait'), true);
  try { await mnAPI.pair(); await refresh(); }
  catch (e) { error(e.message); }
  finally { $('pair').disabled = false; setVisible($('pairWait'), false); }
};

$('images').onchange = async () => {
  // Картинки с других сайтов (CDN) браузер отдаёт только с разрешением на все сайты; без него — только со страницы.
  if ($('images').checked && chrome.permissions?.request) {
    try { await chrome.permissions.request({ origins: ['<all_urls>'] }); } catch (e) { /* Safari спрашивает сам */ }
  }
  chrome.storage.local.set({ withImages: $('images').checked });
};

$('clip').onsubmit = async (event) => {
  event.preventDefault();
  error('');
  $('save').disabled = true;
  $('save').textContent = t('saving');
  const parent = $('parent').value || null;
  const tags = $('tags').value.split(',').map((s) => s.trim()).filter(Boolean);
  await chrome.storage.local.set({ lastParent: parent, lastMode: mode });
  const reply = await chrome.runtime.sendMessage({ type: 'clip', tabId: tab.id, mode, title: $('title').value.trim(), parent, tags,
    note: $('note').value.trim(), withImages: $('images').checked });
  $('save').disabled = false;
  $('save').textContent = t('save');
  if (!reply?.ok) {
    if (reply?.code === 'unpaired') { show('unpaired'); }
    error(reply?.message || t('errUnknown'));
    return;
  }
  savedPage = reply.page;
  $('doneText').textContent = t('saved', reply.page.title);
  show('done');
};

$('open').onclick = async () => {
  if (!savedPage) return;
  try { await mnAPI.openPage(savedPage.id); window.close(); } catch (e) { error(e.message); }
};
$('again').onclick = refresh;

refresh();
