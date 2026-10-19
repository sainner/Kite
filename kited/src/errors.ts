/** 给调用方看的错误：消息是说给人听的，status 对应 HTTP 状态码。 */
export class KiteError extends Error {
  constructor(message: string, readonly status = 400) { super(message); }
  /** 错误体里 error 以外的字段，App 据此分情况处理。 */
  details(): Record<string, unknown> { return {}; }
}

/**
 * HTTPS 远程要账号或拒绝了访问令牌：错误体带上 gitLogin（主机），App 据此让用户就地绑定令牌，写到出错的那台工作机后重试。
 * 经另一台工作机转交时（见 PeerError）另带 gitLoginMachine，是真正访问远程、令牌该写到的那台。
 */
export class GitLoginRequired extends KiteError {
  constructor(message: string, readonly host: string) { super(message, 409); }
  override details() { return { gitLogin: this.host }; }
}

/** 集成父工作区之前还有子工作区没合回或放弃：错误体带上 children（ID 与名称），App 据此让用户逐个合回、放弃或暂不集成。 */
export class ChildrenPending extends KiteError {
  constructor(readonly children: Array<{ id: string; name: string }>) {
    super(`还有子工作区没合回：${children.map((child) => `「${child.name}」`).join('、')}；先合回或放弃，再集成`, 409);
  }
  override details() { return { children: this.children }; }
}

/** extra 是原来的错误给 App 分情况处理的字段（如 gitLogin），经操作收据转成操作错误时保留。 */
export class OperationError extends KiteError {
  constructor(message: string, readonly outcome: 'denied' | 'failed' | 'cancelled' | 'unknown', status = 409,
    private readonly extra: Record<string, unknown> = {}) { super(message, status); }
  override details() { return { ...this.extra, outcome: this.outcome }; }
}

export const operationError = (error: unknown): OperationError => error instanceof OperationError ? error : error instanceof KiteError
  ? new OperationError(error.message, 'failed', error.status, error.details())
  : new OperationError(`操作结果尚未确认：${String(error)}`, 'unknown');
