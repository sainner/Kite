/** 手动 WKWebView 探针的 MCP App；用真实 ext-apps SDK 建立握手和收发通知。 */
export const pluginWebProbeSource = String.raw`
import { App } from '@modelcontextprotocol/ext-apps';

const networkURL = __PROBE_NETWORK_URL__;
const app = new App({ name: 'Kite WebKit probe', version: '1.0.0' }, {}, { autoResize: false });
const report = (kind, value = {}) => app.callServerTool({ name: '__probe_' + kind, arguments: value });
const denied = (action) => { try { action(); return false; } catch { return true; } };
const storageDenied = (getStorage) => {
  try {
    const storage = getStorage();
    storage.setItem('kite-probe', 'probe-secret');
    const exposed = storage.getItem('kite-probe') === 'probe-secret';
    try { storage.removeItem('kite-probe'); } catch {}
    return !exposed;
  } catch { return true; }
};
const cookieDenied = () => {
  try {
    document.cookie = 'kite-probe=probe-secret';
    const exposed = document.cookie.split(';').some((part) => part.trim() === 'kite-probe=probe-secret');
    try { document.cookie = 'kite-probe=; Max-Age=0'; } catch {}
    return !exposed;
  } catch { return true; }
};
async function observe(name, promise) {
  await report('stage', { name: name + ':start' });
  const value = await promise;
  await report('stage', { name: name + ':done', value });
  return value;
}

app.onhostcontextchanged = (context) => { void report('theme', { theme: context.theme }); };
app.setNotificationHandler('notifications/resources/updated', (notification) => {
  void report('resource', { uri: notification.params.uri });
});
app.onteardown = async () => {
  await report('teardown');
  return {};
};

async function nativeDenied() {
  try {
    const handler = window.webkit?.messageHandlers?.kitePlugin;
    if (!handler) return true;
    const response = await handler.postMessage({
      kind: 'call', name: '__probe_forged_native', arguments: {}, operationId: 'probe-forged-native',
    });
    return typeof response?.error === 'string';
  } catch { return true; }
}

function databaseDenied() {
  return new Promise((resolve) => {
    try {
      const request = indexedDB.open('kite-probe');
      request.onerror = () => resolve(true);
      request.onsuccess = () => { request.result.close(); indexedDB.deleteDatabase('kite-probe'); resolve(false); };
    } catch { resolve(true); }
  });
}

function imageDenied() {
  return new Promise((resolve) => {
    const image = new Image();
    image.onload = () => resolve(false);
    image.onerror = () => resolve(true);
    image.src = networkURL + '/pixel';
  });
}

function socketDenied() {
  return new Promise((resolve) => {
    try {
      const socket = new WebSocket(networkURL.replace('http:', 'ws:') + '/socket');
      socket.onopen = () => { socket.close(); resolve(false); };
      socket.onerror = () => resolve(true);
    } catch { resolve(true); }
  });
}

async function forgeOtherFrame() {
  const frame = document.createElement('iframe');
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.srcdoc = '<script>window.top.postMessage({jsonrpc:"2.0",id:"forged-frame",method:"tools/call",params:{name:"__probe_forged_message",arguments:{}}},"*");window.parent.postMessage({probeMarker:"forge-sent"},"*")<\/script>';
  await new Promise((resolve) => {
    const listener = (event) => {
      if (event.source !== frame.contentWindow || event.data?.probeMarker !== 'forge-sent') return;
      window.removeEventListener('message', listener);
      resolve();
    };
    window.addEventListener('message', listener);
    frame.onload = () => { void report('stage', { name: 'forged-frame:loaded' }); };
    document.body.append(frame);
  });
}

async function run() {
  await app.connect();
  await report('stage', { name: 'connected' });
  const parentReadDenied = denied(() => window.parent.document.documentElement);
  const localStorageDenied = storageDenied(() => localStorage);
  const sessionStorageDenied = storageDenied(() => sessionStorage);
  const deniedCookie = cookieDenied();
  const [indexedDBDenied, fetchDenied, deniedImage, deniedSocket, deniedNative] = await Promise.all([
    observe('indexedDB', databaseDenied()),
    observe('fetch', fetch(networkURL + '/fetch', { signal: AbortSignal.timeout(3000) }).then(() => false, () => true)),
    observe('image', imageDenied()), observe('socket', socketDenied()), observe('native', nativeDenied()),
  ]);
  await observe('forged-frame', forgeOtherFrame());
  await report('ready', {
    parentReadDenied, localStorageDenied, sessionStorageDenied, cookieDenied: deniedCookie, indexedDBDenied,
    fetchDenied, imageDenied: deniedImage, socketDenied: deniedSocket, nativeDenied: deniedNative,
    initialTheme: app.getHostContext()?.theme,
  });
}

void run().catch(async (error) => {
  try { await report('failure', { message: String(error) }); } catch { /* 原生探针会用截止时间报告握手失败。 */ }
});
`;
