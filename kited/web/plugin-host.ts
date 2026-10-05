import { AppBridge, PostMessageTransport } from '@modelcontextprotocol/ext-apps/app-bridge';
import type { McpUiHostContext } from '@modelcontextprotocol/ext-apps';

declare global {
  interface Window {
    webkit: { messageHandlers: { kitePlugin: { postMessage(value: unknown): Promise<any> } } };
    kitePluginHost: { update(theme: 'light' | 'dark', revision: number): void; close(): Promise<void> };
  }
}

const native = window.webkit.messageHandlers.kitePlugin;
const frame = document.createElement('iframe');
frame.sandbox.add('allow-scripts');
frame.title = '插件内容';
document.body.appendChild(frame);
const hostContext: McpUiHostContext = { theme: 'light', displayMode: 'inline', availableDisplayModes: ['inline'] };
const bridge = new AppBridge(null, { name: 'Kite', version: '0.1.0' }, { serverTools: {} }, { hostContext });
const updateContext = () => {
  // setHostContext 接受完整上下文；只传尺寸会让下一次握手丢失主题和显示模式。
  if (bridge.transport) bridge.setHostContext({ ...hostContext,
    containerDimensions: { width: window.innerWidth, height: window.innerHeight } });
};
let uri: string | undefined;
let initialized = false;
let closed = false;
let revision = -1;
// 自定义 WebKit scheme 不属于安全上下文，不能依赖 crypto.randomUUID。
const operationPrefix = Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, '0')).join('');
let callId = 0;
const report = (error: unknown) => { void native.postMessage({ kind: 'error', message: String(error) }).catch(() => {}); };
const initializationDeadline = setTimeout(() => report('插件界面未在 10 秒内完成握手，请重新加载'), 10_000);
const changed = async () => {
  if (initialized && uri && !closed) await bridge.notification({ method: 'notifications/resources/updated', params: { uri } });
};
bridge.oncalltool = async ({ name, arguments: args }) => {
  try { return await native.postMessage({ kind: 'call', name, arguments: args ?? {}, operationId: `${operationPrefix}:${++callId}` }); }
  catch (error) { return { isError: true, content: [{ type: 'text', text: String(error) }] }; }
};
bridge.oninitialized = () => {
  initialized = true;
  clearTimeout(initializationDeadline);
  void native.postMessage({ kind: 'ready' }).catch(report);
};
bridge.onerror = report;
// 工作区决定窗口尺寸；插件可以报告内容尺寸，但不能改变工作区布局。
bridge.onsizechange = () => {};
window.kitePluginHost = {
  update(theme, nextRevision) {
    hostContext.theme = theme;
    updateContext();
    if (nextRevision !== revision) { revision = nextRevision; void changed().catch(report); }
  },
  async close() {
    if (closed) return;
    closed = true;
    clearTimeout(initializationDeadline);
    try { if (initialized) await bridge.teardownResource({}, { timeout: 500 }); }
    finally { await bridge.close(); frame.remove(); }
  },
};
new ResizeObserver(updateContext).observe(document.documentElement);

async function start() {
  const resource = await native.postMessage({ kind: 'load' });
  if (closed) return;
  uri = resource.resourceUri;
  await bridge.connect(new PostMessageTransport(frame.contentWindow!, frame.contentWindow!));
  window.kitePluginHost.update(resource.theme, resource.revision);
  frame.srcdoc = resource.html;
}
void start().catch((error) => { clearTimeout(initializationDeadline); report(error); });
