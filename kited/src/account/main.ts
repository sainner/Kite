import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { createAccountService } from './service.ts';

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`缺少 ${name}`);
  return value;
}
const databasePath = process.env.KITE_ACCOUNT_DATABASE ?? '/data/account.sqlite';
mkdirSync(dirname(databasePath), { recursive: true, mode: 0o700 });
const service = await createAccountService({
  databasePath, baseURL: required('KITE_ACCOUNT_URL'), secret: required('KITE_ACCOUNT_SECRET'),
  headscale: {
    url: required('HEADSCALE_API_URL'), apiKey: required('HEADSCALE_API_KEY'), controlURL: required('KITE_ACCOUNT_URL'),
  },
});
const server = Bun.serve({ hostname: '0.0.0.0', port: Number(process.env.PORT ?? 5484), maxRequestBodySize: 2 * 1024 * 1024, fetch: service.fetch });
console.log(`Kite 账号服务监听 ${server.port}`);
async function stop() { await server.stop(); await service.close(); process.exit(0); }
process.on('SIGTERM', () => void stop());
process.on('SIGINT', () => void stop());
