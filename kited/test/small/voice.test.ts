import { afterEach, expect, test } from 'bun:test';
import type { Server, ServerWebSocket } from 'bun';
import type { DisplayRecord, History } from '../../src/transcript/protocol.ts';
import { defaultSpeechModel } from '../../src/voice/models.ts';
import { VoiceSessions, voiceTemplate, type VoiceSocket } from '../../src/voice/sessions.ts';

type Event = { type: string; event_id?: string; [key: string]: unknown };
type Pushed = { type: 'partial' | 'final' | 'error'; text?: string; message?: string };

const servers: Server<unknown>[] = [];
afterEach(async () => { await Promise.all(servers.splice(0).map((server) => server.stop(true))); });

/** 计数到某个值时放行；已经到过的值直接放行。 */
function counter() {
  let count = 0;
  const waiters: { at: number; resolve(): void }[] = [];
  return {
    add() {
      count += 1;
      for (const waiter of waiters.filter((w) => w.at <= count)) {
        waiters.splice(waiters.indexOf(waiter), 1);
        waiter.resolve();
      }
    },
    reach(at: number) {
      return at <= count ? Promise.resolve() : new Promise<void>((resolve) => { waiters.push({ at, resolve }); });
    },
  };
}

const history = (records: DisplayRecord[]): History =>
  ({ version: 1, threadId: 'thread-voice', cursor: '', records, pending: [], state: {} as History['state'] });

/** 工作机这一跳：按 http.ts 的接法把 Bun 的 WebSocket 服务端交给 VoiceSessions；每一帧交给它之后记一次数。 */
function startKited(options: { upstream: number; thread?: string; history?(thread: string): Promise<History> }) {
  const delivered = counter();
  const sessions = new VoiceSessions({
    keys: async () => [{ provider: 'dashscope', key: 'voice-key' }],
    template: () => ({ definition: voiceTemplate, model: defaultSpeechModel, revision: '' }),
    history: options.history ?? (async () => history([])),
    variables: () => ({}),
    url: `ws://127.0.0.1:${options.upstream}/`,
  });
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch(request, server: Server<VoiceSocket>) {
      return server.upgrade(request, { data: { thread: options.thread } }) ? undefined : new Response('需要 WebSocket', { status: 400 });
    },
    websocket: {
      open: (socket: ServerWebSocket<VoiceSocket>) => sessions.open(socket),
      message: (socket: ServerWebSocket<VoiceSocket>, message: string | Buffer) => { sessions.message(socket, message); delivered.add(); },
      close: (socket: ServerWebSocket<VoiceSocket>) => sessions.close(socket),
    },
  });
  servers.push(server as Server<unknown>);
  return { port: server.port, delivered };
}

/** App 这一跳：连上就推 onOpen 里的内容，收集推回的消息，等连接被关闭。 */
function connectApp(port: number, onOpen: (socket: WebSocket) => void) {
  const pushed: Pushed[] = [];
  const socket = new WebSocket(`ws://127.0.0.1:${port}/`);
  const closed = new Promise<void>((resolve) => { socket.onclose = () => resolve(); });
  socket.onopen = () => onOpen(socket);
  socket.onmessage = (event) => { pushed.push(JSON.parse(String(event.data)) as Pushed); };
  return { socket, pushed, closed };
}

const chunk = (index: number) => Uint8Array.from({ length: 3200 }, (_, j) => (index * 37 + j * 7) & 0xff);

// 两跳 WebSocket 的时序：App 一连上就推音频，工作机还在取历史、连上游、等 session.updated；
// 上游配好之前到的音频和 finish 要攒着，配好后按原顺序原样转上去，再 commit、session.finish。
// 依赖 Bun：ServerWebSocket 收二进制帧给 Buffer；WebSocket 客户端能带 Authorization 请求头；客户端收到 ping 自动回 pong，
// 且 pong 排在它收到 ping 之前发出的帧之后，所以假上游在 pong 之后才算「配好」：工作机连上就发攒着的音频、或 App 的音频随到随转，都会被记成配好之前到的。
test('上游配好之前到的音频和 finish 先攒着，配好后按原顺序原样转上去，中间结果和整理后的定稿推回 App 后关闭', async () => {
  const chunks = [0, 1, 2, 3, 4].map(chunk);
  const received: { event: Event; configured: boolean }[] = [];
  let request: { authorization: string | null; model: string | null } | undefined;
  let configured = false;
  let partialSent = false;
  let app: ReturnType<typeof connectApp>;

  const upstream = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch(incoming, server: Server<undefined>) {
      request = { authorization: incoming.headers.get('authorization'), model: new URL(incoming.url).searchParams.get('model') };
      return server.upgrade(incoming, { data: undefined }) ? undefined : new Response('需要 WebSocket', { status: 400 });
    },
    websocket: {
      async message(socket: ServerWebSocket<undefined>, raw: string | Buffer) {
        const event = JSON.parse(String(raw)) as Event;
        received.push({ event, configured });
        if (event.type === 'session.update') {
          // 上游已经连上但还没配好：App 再推两段音频和 finish，等它们都交到工作机手里才开始配好。
          app.socket.send(chunks[3]!);
          app.socket.send(chunks[4]!);
          app.socket.send(JSON.stringify({ type: 'finish' }));
          await kited.delivered.reach(6);
          socket.ping();
        } else if (event.type === 'input_audio_buffer.append' && !partialSent) {
          partialSent = true;
          socket.send(JSON.stringify({ type: 'conversation.item.input_audio_transcription.text', text: '已确认', stash: '待定' }));
        } else if (event.type === 'input_audio_buffer.commit') {
          socket.send(JSON.stringify({ type: 'conversation.item.input_audio_transcription.completed', transcript: '把 thread 点 messages 换成最近十条' }));
        } else if (event.type === 'session.finish') {
          socket.send(JSON.stringify({ type: 'session.finished' }));
        }
      },
      pong(socket: ServerWebSocket<undefined>) {
        configured = true;
        socket.send(JSON.stringify({ type: 'session.updated' }));
      },
    },
  });
  servers.push(upstream as Server<unknown>);

  const asked: string[] = [];
  const kited = startKited({
    upstream: upstream.port!, thread: 'thread-voice',
    // 取历史时 App 的前三段音频已经到了工作机。
    history: async (thread) => {
      asked.push(thread);
      await kited.delivered.reach(3);
      return history([
        { id: 'h1', at: 1, generation: 'complete', block: { type: 'human', id: 'h1', text: '把 thread.messages 换成最近十条对话', midTurn: false } },
        { id: 'a1', at: 2, generation: 'complete', block: { type: 'text', text: '好的，我去改语音模板引用的变量。' } },
      ]);
    },
  });
  app = connectApp(kited.port!, (socket) => { for (const data of chunks.slice(0, 3)) socket.send(data); });
  await app.closed;

  expect(asked).toEqual(['thread-voice']);
  expect(request).toEqual({ authorization: 'Bearer voice-key', model: defaultSpeechModel.model });

  const types = received.map(({ event }) => event.type);
  expect(types[0]).toBe('session.update');
  expect(types.slice(-2)).toEqual(['input_audio_buffer.commit', 'session.finish']);
  expect(types.slice(1, -2).length).toBeGreaterThan(0);
  expect(types.slice(1, -2).every((type) => type === 'input_audio_buffer.append')).toBe(true);
  for (const { event } of received) expect(event.event_id).toBeTruthy();
  // 配好之前上游只收到 session.update。
  expect(received.filter(({ configured }) => !configured).map(({ event }) => event.type)).toEqual(['session.update']);

  const session = received[0]!.event.session as { turn_detection?: unknown; input_audio_transcription?: { corpus?: { text?: string } } };
  expect(session.turn_detection).toBeNull();
  expect(session.input_audio_transcription?.corpus?.text).toContain('把 thread.messages 换成最近十条对话');

  const forwarded = Buffer.concat(received.filter(({ event }) => event.type === 'input_audio_buffer.append')
    .map(({ event }) => Buffer.from(event.audio as string, 'base64')));
  expect(forwarded.equals(Buffer.concat(chunks))).toBe(true);

  expect(app.pushed.some((message) => message.type === 'error')).toBe(false);
  expect(app.pushed.some((message) => message.type === 'partial' && message.text?.includes('已确认'))).toBe(true);
  const final = app.pushed.at(-1)!;
  expect(final.type).toBe('final');
  expect(final.text).toContain('thread.messages');
  expect(final.text).not.toContain('点');
}, 1000);

// 上游没发 session.finished 就断开：工作机要把错误推给 App 并关掉这一跳，不能让 App 一直等定稿。
test('音频推到一半上游断开时 App 收到 error 并被关闭连接', async () => {
  const upstream = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch(incoming, server: Server<undefined>) {
      return server.upgrade(incoming, { data: undefined }) ? undefined : new Response('需要 WebSocket', { status: 400 });
    },
    websocket: {
      message(socket: ServerWebSocket<undefined>, raw: string | Buffer) {
        const event = JSON.parse(String(raw)) as Event;
        if (event.type === 'session.update') socket.send(JSON.stringify({ type: 'session.updated' }));
        else if (event.type === 'input_audio_buffer.append') socket.close();
      },
    },
  });
  servers.push(upstream as Server<unknown>);

  const kited = startKited({ upstream: upstream.port! });
  const app = connectApp(kited.port!, (socket) => { socket.send(chunk(0)); socket.send(chunk(1)); });
  await app.closed;

  expect(app.pushed.map((message) => message.type)).not.toContain('final');
  const error = app.pushed.find((message) => message.type === 'error');
  expect(error?.message).toBeTruthy();
}, 1000);
