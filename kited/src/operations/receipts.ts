/** 业务宿主判定执行结果；收据只负责同一调用的合流与持久化。 */
import { OperationError, operationError } from '../errors.ts';
import type { Store } from '../store.ts';

export class OperationReceipts {
  private active = new Map<string, Promise<unknown>>();

  constructor(private store: Pick<Store, 'operationReceipt' | 'beginOperation' | 'finishOperation'>) {}

  async run<T>({ actor, id, request, execute, onPersistenceFailure }: {
    actor: string;
    id: string;
    request: string;
    execute(): Promise<T>;
    onPersistenceFailure?(): Promise<void>;
  }): Promise<T> {
    const key = JSON.stringify([actor, id]);
    const saved = this.store.operationReceipt(actor, id);
    if (saved) {
      if (saved.request !== request) throw new OperationError('operationId 已用于其他参数', 'denied');
      const active = this.active.get(key);
      if (active) return active as Promise<T>;
      if (saved.result === null) throw new OperationError('上次操作结果尚未确认；请先查询状态，不能自动重放', 'unknown');
      const result = JSON.parse(saved.result);
      if ('error' in result) throw new OperationError(result.error, result.outcome, result.status);
      return result.value;
    }
    this.store.beginOperation(actor, id, request);
    // 先登记进行中的请求，再执行回调，同步抛错和重入调用也走同一收据。
    const execution = Promise.resolve().then(async () => {
      let result: { value: T } | { error: OperationError };
      try { result = { value: await execute() }; } catch (error) { result = { error: operationError(error) }; }
      try {
        this.store.finishOperation(actor, id, 'error' in result
          ? { error: result.error.message, outcome: result.error.outcome, status: result.error.status } : result);
      } catch (error) {
        // 写入失败不覆盖开始记录；副作用可能已发生，须先等宿主完成善后。
        let message = `操作收据保存失败，结果尚未确认：${String(error)}`;
        try { await onPersistenceFailure?.(); } catch (cleanupError) { message += `；${String(cleanupError)}`; }
        throw new OperationError(message, 'unknown');
      }
      if ('error' in result) throw result.error;
      return result.value;
    });
    this.active.set(key, execution);
    try { return await execution; } finally { this.active.delete(key); }
  }
}
