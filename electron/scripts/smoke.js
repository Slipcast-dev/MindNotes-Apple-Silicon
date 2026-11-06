// Launches the real app, waits for it to settle and prints what the renderer ended up with.
// Run: npx electron scripts/smoke.js <files...>
const { app } = require('electron');
require('../main.js');

app.on('browser-window-created', (_e, win) => {
  win.webContents.on('console-message', (_ev, level, message, line, source) => {
    console.log(`[renderer:${level}] ${message} (${source}:${line})`);
  });
  win.webContents.on('did-fail-load', (_ev, code, desc) => console.log('did-fail-load', code, desc));
  win.webContents.on('preload-error', (_ev, p, err) => console.log('preload-error', p, err));
  setTimeout(async () => {
    try {
      const state = await win.webContents.executeJavaScript(`(async () => JSON.stringify({
        docs: App.documents.map(d => d.name + ':' + d.type + ':' + d.encoding),
        library: Library.data.files.map(f => f.path),
        title: document.title,
        errors: App.errorMessage,
        direct: await window.api.readFile(Library.data.files[1].path).then(r => r.ok ? r.encoding + ':' + r.text.length : r.code),
      }))()`);
      console.log('STATE', state);
    } catch (err) {
      console.log('STATE failed', err.message);
    }
    app.exit(0);
  }, 6000);
});
