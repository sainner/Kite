import { Seen } from './harness-loop.ts';

/** 测试共用的 JSON SSE 消费器；等待时报告读流错误，调用方在 finally 或 afterEach 里关闭连接。 */
export async function connectSse<T>(url: string, machineId: string) {
  const controller = new AbortController();
  const response = await fetch(url, {
    headers: { 'X-Kite-Machine': machineId }, signal: controller.signal,
  });
  if (response.status !== 200 || !response.body) {
    controller.abort();
    throw new Error(`连接 SSE 失败：${response.status}`);
  }
  const events = new Seen<T>();
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let failure: unknown;
  const reading = (async () => {
    let buffer = '';
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) return;
        buffer += value;
        let end: number;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const data = frame.split('\n').filter((line) => line.startsWith('data: ')).map((line) => line.slice(6)).join('\n');
          if (data) events.add(JSON.parse(data) as T);
        }
      }
    } catch (error) {
      if (!controller.signal.aborted) failure = error;
    } finally {
      reader.releaseLock();
    }
  })();
  return {
    events: {
      values: events.values,
      wait(predicate: (event: T) => boolean): Promise<T> {
        return Promise.race([
          events.wait(predicate),
          reading.then(() => { throw failure ?? new Error('SSE 在等到事件前关闭'); }),
        ]);
      },
    },
    async close() {
      controller.abort();
      await reading;
      if (failure) throw failure;
    },
  };
}
