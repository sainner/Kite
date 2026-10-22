/**
 * 工作机浏览器的出口代理：每个预览的浏览器上下文都经它连出去，宿主在这里核对每一条连接的目标。
 * 跳转后的每一跳、WebSocket、iframe 都是新连接，同样经过这里（Playwright 的请求拦截只管跳转链的第一个地址，拦不住跳转）。
 * 普通 HTTP 请求一条连接只转一个，转给目标时要求它答完就断开；CONNECT（HTTPS、WebSocket）核对后原样搭桥。
 */
import { lookup } from 'node:dns/promises';
import { connect, createServer, isIP, type Socket } from 'node:net';
import { localHost, privateAddress } from '../execution/local-address.ts';

/**
 * 能不能连这个目标，能的话返回实际要连的地址：本机（回环与本机网卡的地址，见 localHost）只放行 ports 里的端口，一律连回环，依次试 127.0.0.1 和 ::1；
 * 单段名字、.local、.ts.net 这类本地与组网的名字直接拦下；其余解析出的地址都是公网才放行，连解析出的地址，不再解析第二次。
 */
export async function resolveTarget(rawHost: string, port: number, ports: () => number[]): Promise<string[] | null> {
  const host = rawHost.replace(/^\[|\]$/g, '').toLowerCase();
  if (localHost(host)) return ports().includes(port) ? ['127.0.0.1', '::1'] : null;
  if (isIP(host)) return privateAddress(host) ? null : [host];
  if (!host.includes('.') || /\.(local|lan|internal|home\.arpa|ts\.net)$/.test(host)) return null;
  try {
    const addresses = await lookup(host, { all: true });
    return addresses.length && addresses.every(({ address }) => !privateAddress(address)) ? addresses.map(({ address }) => address) : null;
  } catch { return null; }
}

/** 依次试几个地址，连上一个就交给 ready。 */
function dial(addresses: string[], port: number, ready: (socket: Socket) => void, failed: () => void): void {
  const [first, ...rest] = addresses;
  if (first === undefined) { failed(); return; }
  const socket = connect({ host: first, port });
  socket.once('connect', () => { socket.removeAllListeners('error'); ready(socket); });
  socket.once('error', () => { socket.destroy(); dial(rest, port, ready, failed); });
}

/** 拦下：不回应就断开，页面看到的是连接失败（同直接连不上），不是一个能读的响应。 */
function refuse(client: Socket): void {
  client.destroy();
}

/** 两头接上：任一头断开就都断开。 */
function bridge(client: Socket, upstream: Socket): void {
  const close = () => { client.destroy(); upstream.destroy(); };
  client.on('error', close).on('close', close);
  upstream.on('error', close).on('close', close);
  upstream.pipe(client);
  client.pipe(upstream);
  client.resume();
}

/** 开一个只听本机回环的代理，ports 是本工作区运行中终端此刻监听的端口。 */
export async function startProxy(ports: () => number[]): Promise<{ port: number; close(): void }> {
  const clients = new Set<Socket>();
  const handle = async (client: Socket, head: string, rest: Buffer) => {
    const [requestLine = '', ...lines] = head.split('\r\n').filter(Boolean);
    const [method = '', target = '', version = 'HTTP/1.1'] = requestLine.split(' ');
    if (method === 'CONNECT') {
      const colon = target.lastIndexOf(':');
      const host = target.slice(0, colon), port = Number(target.slice(colon + 1));
      const addresses = Number.isInteger(port) && port > 0 ? await resolveTarget(host, port, ports) : null;
      if (!addresses) { refuse(client); return; }
      dial(addresses, port, (upstream) => {
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        if (rest.length) upstream.write(rest);
        bridge(client, upstream);
      }, () => refuse(client));
      return;
    }
    let url: URL;
    try { url = new URL(target); } catch { refuse(client); return; }
    const port = Number(url.port || 80);
    const addresses = url.protocol === 'http:' ? await resolveTarget(url.hostname, port, ports) : null;
    if (!addresses) { refuse(client); return; }
    // 一条连接只转这一个请求：要求目标答完就断开，下一个请求是新连接、重新核对。升级成 WebSocket 的照原样。
    const upgrade = lines.some((line) => /^upgrade:/i.test(line));
    const headers = lines.filter((line) => !/^proxy-(connection|authorization):/i.test(line) && (upgrade || !/^(connection|keep-alive):/i.test(line)));
    if (!upgrade) headers.push('Connection: close');
    dial(addresses, port, (upstream) => {
      upstream.write(`${method} ${url.pathname}${url.search} ${version}\r\n${headers.join('\r\n')}\r\n\r\n`, 'latin1');
      if (rest.length) upstream.write(rest);
      bridge(client, upstream);
    }, () => refuse(client));
  };
  const server = createServer((client) => {
    clients.add(client);
    client.on('close', () => clients.delete(client));
    client.on('error', () => client.destroy());
    let buffered = Buffer.alloc(0);
    const read = (chunk: Buffer) => {
      buffered = Buffer.concat([buffered, chunk]);
      const end = buffered.indexOf('\r\n\r\n');
      if (end < 0) { if (buffered.length > 64 * 1024) client.destroy(); return; }
      client.off('data', read);
      client.pause();
      void handle(client, buffered.subarray(0, end).toString('latin1'), buffered.subarray(end + 4)).catch(() => client.destroy());
    };
    client.on('data', read);
  });
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', () => resolve()));
  const address = server.address();
  return {
    port: typeof address === 'object' && address ? address.port : 0,
    close: () => { server.close(); for (const client of clients) client.destroy(); },
  };
}
