/** 给调用方看的错误：消息是说给人听的，status 对应 HTTP 状态码。 */
export class KiteError extends Error {
  constructor(message: string, readonly status = 400) { super(message); }
}

export class OperationError extends KiteError {
  constructor(message: string, readonly outcome: 'denied' | 'failed' | 'cancelled' | 'unknown', status = 409) { super(message, status); }
}

export const operationError = (error: unknown): OperationError => error instanceof OperationError ? error : error instanceof KiteError
  ? new OperationError(error.message, 'failed', error.status)
  : new OperationError(`操作结果尚未确认：${String(error)}`, 'unknown');
