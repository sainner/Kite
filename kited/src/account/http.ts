/** 账号接口共用的错误、认证头读取和不缓存响应。 */
export class RequestError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

export const result = (body: unknown, status = 200) => Response.json(body, { status, headers: { 'cache-control': 'no-store' } });
export const bearerToken = (request: Request) => request.headers.get('authorization')?.replace(/^Bearer /, '') ?? '';
