/** 自研主循环的手动模型流；测试决定每个事件何时到达，不访问网络或 Claude 假端点。 */
import { afterEach } from 'bun:test';
import { readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { FileJournal } from '../src/harness/journal.ts';
import { HarnessRunner } from '../src/harness/runner.ts';
import type { ContextSource } from '../src/harness/context/types.ts';
import type {
  Input, Journal, JournalRecord, Model, ModelEvent, ModelItem, ModelRequest,
  HarnessEvent, HarnessOptions, Tool, ToolResult,
} from '../src/harness/types.ts';
import { makeTemp } from './util.ts';

export function deferred<T = void>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

/** 按事实等待，已发生的事实也能查询。 */
export class Seen<T> {
  readonly values: T[] = [];
  private waiters: Array<{ predicate: (value: T) => boolean; resolve: (value: T) => void }> = [];
  add(value: T): void {
    this.values.push(value);
    for (const waiter of [...this.waiters]) {
      if (!waiter.predicate(value)) continue;
      this.waiters.splice(this.waiters.indexOf(waiter), 1);
      waiter.resolve(value);
    }
  }
  wait(predicate: (value: T) => boolean): Promise<T> {
    const found = this.values.find(predicate);
    if (found !== undefined) return Promise.resolve(found);
    return new Promise((resolve) => { this.waiters.push({ predicate, resolve }); });
  }
}

export function aborted(signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => { signal.addEventListener('abort', () => resolve(), { once: true }); });
}

export function withAbort<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(new Error('已取消'));
  return new Promise((resolve, reject) => {
    const cancel = () => reject(new Error('已取消'));
    signal.addEventListener('abort', cancel, { once: true });
    void promise.then(resolve, reject).finally(() => { signal.removeEventListener('abort', cancel); });
  });
}

export class ManualResponse {
  private queue: Array<{ event: ModelEvent; consumed: ReturnType<typeof deferred<void>> }> = [];
  private wake = deferred();
  private ended = false;

  /** 消费者再次拉取时才确认上一事件已交给内核处理。 */
  emit(event: ModelEvent): Promise<void> {
    const consumed = deferred();
    this.queue.push({ event, consumed });
    this.wake.resolve();
    return consumed.promise;
  }
  finish(): void { this.ended = true; this.wake.resolve(); }
  complete(responseId = 'response'): void {
    void this.emit({ type: 'completed', responseId });
    this.finish();
  }
  async *events(signal: AbortSignal): AsyncIterable<ModelEvent> {
    let current: { event: ModelEvent; consumed: ReturnType<typeof deferred<void>> } | undefined;
    try {
      while (true) {
        if (signal.aborted) throw new Error('模型已取消');
        current = this.queue.shift();
        if (current) {
          yield current.event;
          current.consumed.resolve();
          current = undefined;
        } else if (this.ended) return;
        else {
          this.wake = deferred();
          await withAbort(this.wake.promise, signal);
        }
      }
    } finally {
      current?.consumed.resolve();
      for (const pending of this.queue.splice(0)) pending.consumed.resolve();
    }
  }
}

export class ManualModel implements Model {
  readonly calls = new Seen<{ number: number; request: ModelRequest; response: ManualResponse; signal: AbortSignal }>();
  stream(request: ModelRequest, signal: AbortSignal): AsyncIterable<ModelEvent> {
    const response = new ManualResponse();
    this.calls.add({ number: this.calls.values.length + 1, request, response, signal });
    return response.events(signal);
  }
  call(number: number) { return this.calls.wait((call) => call.number === number); }
}

export const input = (id: string): Input => ({ id, text: `输入 ${id}`, source: 'human' });
export const success = (output: string): ToolResult => ({ status: 'success', output });
export const item = (id: string, name?: string): ModelItem => ({
  id,
  raw: { type: name ? 'function_call' : 'message', opaque: { reasoning: `保留 ${id}`, bytes: [0, 255] } },
  ...(name ? { call: { id, name, arguments: { id } } } : {}),
});
export const tool = (name: string, execute: Tool['execute'], parallel = false): Tool => ({
  name, description: '测试工具', parameters: { type: 'object' }, parallel,
  validate() {}, execute,
});

type RunnerOptions = Partial<Pick<HarnessOptions,
  'journal' | 'startPaused' | 'onEvent' | 'afterTools' | 'afterTurn' | 'beforeStop' | 'compactionFiles'
>> & {
  model?: Model;
  tools?: Tool[];
  instructions?: string | ContextSource | (() => ContextSource);
  maxRequestsPerTurn?: number;
  prepareRequest?: HarnessOptions['prepareRequest'];
};

/** 每个测试自建文件；失败也先释放宿主闸门，再关闭主循环并删目录。 */
export function useHarness() {
  const runners: HarnessRunner[] = [];
  const journals: Journal[] = [];
  const roots: string[] = [];
  const releases: Array<() => void> = [];
  afterEach(async () => {
    for (const release of releases.splice(0)) release();
    await Promise.all(runners.splice(0).map((runner) => runner.shutdown().catch(() => {})));
    for (const journal of journals.splice(0)) journal.close();
    for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
  });
  return {
    gate<T>(cleanupValue: T) {
      const gate = deferred<T>();
      releases.push(() => gate.resolve(cleanupValue));
      return gate;
    },
    root() { const root = makeTemp('harness-'); roots.push(root); return root; },
    open(path: string) { const journal = new FileJournal(path); journals.push(journal); return journal; },
    runner(root: string, options: RunnerOptions = {}) {
      const path = join(root, 'journal.jsonl');
      const journal = options.journal ?? this.open(path);
      const model = options.model ?? new ManualModel();
      const events = new Seen<HarnessEvent>();
      const runner = new HarnessRunner({
        cwd: root, journal,
        prepareRequest: options.prepareRequest ?? (() => ({
          model,
          tools: options.tools ?? [],
          instructions: typeof options.instructions === 'function'
            ? options.instructions() : options.instructions ?? '测试主循环',
          settings: { maxRequestsPerTurn: options.maxRequestsPerTurn },
        })),
        startPaused: options.startPaused,
        afterTools: options.afterTools,
        afterTurn: options.afterTurn,
        beforeStop: options.beforeStop,
        compactionFiles: options.compactionFiles,
        onEvent(event) { events.add(event); options.onEvent?.(event); },
      });
      runners.push(runner);
      return { runner, journal, model, events, path };
    },
  };
}

export const diskRecords = (path: string): JournalRecord[] => readFileSync(path, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line) as JournalRecord);
export const waitRecord = (events: Seen<HarnessEvent>, predicate: (record: JournalRecord) => boolean) =>
  events.wait((event) => event.type === 'record' && predicate(event.record));
