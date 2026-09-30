import { AppBridge, PostMessageTransport } from '@modelcontextprotocol/ext-apps/app-bridge';

// 可信主 frame 只持有转发能力；插件脚本永远在 opaque-origin iframe 内运行。
const native = (window as any).webkit.messageHandlers.kite;
const result: Record<string, unknown> = { phases: [], resizeCount: 0, teardownCount: 0 };
let current: { iframe: HTMLIFrameElement; bridge: AppBridge } | undefined;
let phase = '';
let resolveEvent: ((message: any) => void) | undefined;
let expectedEvent = '';

const deadline = window.setTimeout(() => finish({ error: '20 秒内没有完成完整场景' }), 20_000);

function finish(extra: Record<string, unknown> = {}) {
  window.clearTimeout(deadline);
  void native.postMessage({ kind: 'report', ...result, ...extra });
}

function waitFor(kind: string) {
  expectedEvent = kind;
  return new Promise<any>(resolve => { resolveEvent = resolve; });
}

window.addEventListener('message', event => {
  if (event.source !== current?.iframe.contentWindow || !event.data?.kiteProbe || event.data.phase !== phase) return;
  if (event.data.kind === 'failure') { finish({ error: event.data.error }); return; }
  if (event.data.kind === 'teardown') result.teardownCount = Number(result.teardownCount) + 1;
  if (event.data.kind === expectedEvent) {
    const resolve = resolveEvent;
    resolveEvent = undefined;
    expectedEvent = '';
    resolve?.(event.data);
  }
});

async function load(phaseName: string) {
  phase = phaseName;
  const { html } = await native.postMessage({ kind: 'resource' });
  if (typeof html !== 'string') throw new Error('缺少插件 UI 资源');
  const iframe = document.createElement('iframe');
  iframe.name = phaseName;
  iframe.sandbox.add('allow-scripts');
  iframe.title = '待办插件';
  document.getElementById('app')!.appendChild(iframe);
  const bridge = new AppBridge(null, { name: 'Kite 探针', version: '0.1.0' }, { serverTools: {} },
    { hostContext: { theme: 'light' } });
  current = { iframe, bridge };
  bridge.oncalltool = async ({ name, arguments: args }) => {
    const response = await native.postMessage({ kind: 'call', name, arguments: args ?? {} });
    if (response?.error) return { isError: true, content: [{ type: 'text', text: String(response.error) }] };
    return response;
  };
  bridge.onsizechange = () => { result.resizeCount = Number(result.resizeCount) + 1; };
  await bridge.connect(new PostMessageTransport(iframe.contentWindow!, iframe.contentWindow!));
  const ready = waitFor('ready');
  iframe.srcdoc = html;
  const state = await ready;
  (result.phases as any[]).push({ phase: phaseName, handshake: state.handshake,
    added: state.added, retained: state.retained, displayed: state.displayed });
  return bridge;
}

async function unload() {
  if (!current) return;
  const { bridge, iframe } = current;
  await bridge.teardownResource({});
  await bridge.close();
  iframe.remove();
  current = undefined;
}

async function main() {
  await load('first');
  await unload();
  await load('second');
  await unload();
  const restart = await native.postMessage({ kind: 'restart' });
  result.restart = !restart?.error;
  const bridge = await load('third');
  const security = await waitFor('security');
  result.security = security;
  const theme = waitFor('theme');
  bridge.setHostContext({ theme: 'dark' });
  result.theme = (await theme).theme === 'dark';
  await unload();
  const phases = result.phases as any[];
  const checks = phases.length === 3 && phases.every(p => p.handshake && p.retained && p.displayed)
    && phases[0].added && result.restart === true && result.theme === true
    && Number(result.resizeCount) >= 3 && Number(result.teardownCount) === 3
    && ['parentDenied', 'storageDenied', 'nativeDenied', 'networkDenied', 'unknownDenied', 'workspaceRead', 'traversalDenied']
      .every(key => security[key] === true);
  finish({ pass: checks });
}

main().catch(error => finish({ error: String(error), pass: false }));
