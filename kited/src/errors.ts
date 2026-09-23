/** 给调用方看的错误：消息是说给人听的，status 对应 HTTP 状态码。 */
export class KiteError extends Error {
  constructor(message: string, readonly status = 400) { super(message); }
}
