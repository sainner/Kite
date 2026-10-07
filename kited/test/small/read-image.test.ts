/**
 * read 工具的图片分支：夹具在测试里生成（手写 BMP）。PDF 转换依赖 Vision，冷启动慢，按用户要求不进检查。
 */
import { describe, expect, test } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { localTools } from '../../src/execution/local-tools.ts';
import type { Tool } from '../../src/harness/types.ts';
import { useTemp } from '../util.ts';

const temp = useTemp();
const BunImage = (Bun as any).Image;
const decoded = (data: string) => new BunImage(Buffer.from(data, 'base64')).metadata() as Promise<{ width: number; height: number }>;

function readTool(cwd: string, outputLimit?: number): Tool {
  const tool = localTools({ cwd, logDir: join(cwd, '.logs'), env: { PATH: process.env.PATH }, outputLimit })
    .find((candidate) => candidate.name === 'read');
  if (!tool) throw new Error('缺少 read 工具');
  return tool;
}

function read(tool: Tool, cwd: string, args: Record<string, string | number>, signal = new AbortController().signal) {
  tool.validate(args);
  return tool.execute(args, { cwd, signal });
}

/** 24 位自底向上的 BMP，像素随坐标变化，避免被编码器压成单色。 */
function bmp(width: number, height: number): Buffer {
  const row = (width * 3 + 3) & ~3;
  const buf = Buffer.alloc(54 + row * height);
  buf.write('BM', 0);
  buf.writeUInt32LE(buf.length, 2);
  buf.writeUInt32LE(54, 10);
  buf.writeUInt32LE(40, 14);
  buf.writeInt32LE(width, 18);
  buf.writeInt32LE(height, 22);
  buf.writeUInt16LE(1, 26);
  buf.writeUInt16LE(24, 28);
  buf.writeUInt32LE(row * height, 34);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const o = 54 + y * row + x * 3;
      buf[o] = x & 255; buf[o + 1] = y & 255; buf[o + 2] = (x + y) & 255;
    }
  }
  return buf;
}

describe('read 读取图片', () => {
  // Bun 1.4 的 Bun.Image：metadata、resize（fit inside）与编码的运行时行为。
  test('长边超过 2048 的图片按比例缩到 2048 并说明尺寸，小 PNG 原样附上', async () => {
    const cwd = temp();
    const pngBytes = Buffer.from(await new BunImage(bmp(3000, 1500)).png().bytes());
    writeFileSync(join(cwd, 'big.png'), pngBytes);
    const small = Buffer.from(await new BunImage(bmp(64, 40)).png().bytes());
    writeFileSync(join(cwd, 'small.png'), small);
    const tool = readTool(cwd);

    const big = await read(tool, cwd, { path: 'big.png' });
    expect(big.status).toBe('success');
    expect(big.images).toHaveLength(1);
    const size = await decoded(big.images![0]!.data);
    expect({ width: size.width, height: size.height }).toEqual({ width: 2048, height: 1024 });
    expect(big.output).toMatch(/3000\s*[x×]\s*1500/);
    expect(big.output).toMatch(/2048\s*[x×]\s*1024/);

    const kept = await read(tool, cwd, { path: 'small.png' });
    expect(kept.status).toBe('success');
    expect(kept.images).toHaveLength(1);
    expect(kept.images![0]!.mediaType).toBe('image/png');
    expect(kept.images![0]!.data).toBe(small.toString('base64'));
  });
});
