import { App, PostMessageTransport } from '@modelcontextprotocol/ext-apps';

// 实测 SDK 握手、宿主通知和 WebKit 的沙箱/CSP，而非重复检查网关内部逻辑。
const app = new App({ name: 'Kite 待办样例', version: '0.1.0' }, {}, { autoResize: false, strict: true });
const phase = window.name;
const send = (kind: string, detail: Record<string, unknown> = {}) => {
  window.parent.postMessage({ kiteProbe: true, phase, kind, ...detail }, '*');
};

app.onteardown = async () => {
  send('teardown');
  return {};
};
app.onhostcontextchanged = context => send('theme', { theme: context.theme });

async function call(name: string, args: Record<string, unknown> = {}) {
  return app.callServerTool({ name, arguments: args });
}

async function run() {
  await app.connect(new PostMessageTransport(window.parent, window.parent));
  const handshake = app.getHostVersion()?.name === 'Kite 探针';
  let added = false;
  if (phase === 'first') {
    const result = await call('todo_add', { title: '检查工作区' });
    added = !result.isError && Array.isArray(result.structuredContent?.tasks);
  }
  const listed = await call('todo_list');
  const tasks = listed.structuredContent?.tasks;
  const retained = Array.isArray(tasks) && tasks.some((task: any) => task.title === '检查工作区');
  document.getElementById('app')!.textContent = retained ? '检查工作区' : '待办丢失';
  await app.sendSizeChanged({ width: 360, height: 240 });
  send('ready', { handshake, added, retained, displayed: document.getElementById('app')!.textContent === '检查工作区' });

  if (phase !== 'third') return;
  let parentDenied = false;
  try { void window.parent.document.body.textContent; } catch { parentDenied = true; }
  let storageDenied = false;
  try { window.localStorage.setItem('probe', '1'); } catch { storageDenied = true; }
  let nativeDenied = false;
  try {
    const native = (window as any).webkit?.messageHandlers?.kite;
    const answer = await native?.postMessage({ kind: 'call', name: 'todo_list', arguments: {} });
    nativeDenied = !native || !!answer?.error;
  } catch { nativeDenied = true; }
  const blockedURL = 'http://127.0.0.1:9/probe-blocked';
  const cspEvent = new Promise<boolean>(resolve => {
    document.addEventListener('securitypolicyviolation', event => {
      resolve(event.effectiveDirective === 'connect-src' && event.blockedURI === blockedURL);
    }, { once: true });
  });
  let fetchRejected = false;
  try { await fetch(blockedURL); } catch { fetchRejected = true; }
  const cspBlocked = await Promise.race([cspEvent, new Promise<boolean>(resolve => setTimeout(() => resolve(false), 500))]);
  const networkDenied = fetchRejected && cspBlocked;
  let unknownDenied = false;
  try {
    const result = await call('agent_stop');
    unknownDenied = !!result.isError;
  } catch { unknownDenied = true; }
  const validRead = await call('todo_read_workspace', { path: 'sample.txt' });
  let traversalDenied = false;
  try {
    const result = await call('todo_read_workspace', { path: '../outside.txt' });
    traversalDenied = !!result.isError;
  } catch { traversalDenied = true; }
  send('security', {
    parentDenied, storageDenied, nativeDenied, networkDenied, unknownDenied,
    workspaceRead: !validRead.isError, traversalDenied,
  });
}

run().catch(error => send('failure', { error: String(error) }));
