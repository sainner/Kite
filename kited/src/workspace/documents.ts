/** read 的非文本分支：按文件头识别图片与 PDF，图片缩放后附给模型，PDF 由 macOS Vision 转 Markdown 后按页读取。 */
import { createHash, randomUUID } from 'node:crypto';
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, renameSync, rmSync, statSync } from 'node:fs';
import { release, tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { ToolImage } from '../harness/types.ts';

export type FileKind = 'text' | 'image' | 'pdf';

/** 长边上限与 OpenAI high 细节的缩放一致；字节上限保证 base64 后低于 Claude 单图 5 MB。 */
const MAX_EDGE = 2048;
const MAX_IMAGE_BYTES = 3_750_000;
const MAX_IMAGE_FILE = 32 * 1024 * 1024;
const MAX_PDF_FILE = 100 * 1024 * 1024;
/** 一次最多读取的页数和附带的扫描页图片数。 */
export const PDF_PAGE_SPAN = 20;
const PDF_IMAGE_CAP = 5;
const HEIF_BRANDS = new Set(['heic', 'heix', 'heim', 'heis', 'hevc', 'mif1', 'msf1', 'avif']);

export function fileKind(path: string): FileKind {
  if (!statSync(path).isFile()) throw new KiteError('目标不是普通文件');
  const head = Buffer.alloc(16);
  const fd = openSync(path, 'r');
  let size: number;
  try { size = readSync(fd, head, 0, head.length, 0); } finally { closeSync(fd); }
  const bytes = head.subarray(0, size);
  const ascii = (start: number, end: number) => bytes.subarray(start, end).toString('latin1');
  if (ascii(0, 5) === '%PDF-') return 'pdf';
  if (bytes.subarray(0, 4).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47]))) return 'image';
  if (bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))) return 'image';
  if (ascii(0, 4) === 'GIF8' || (ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP')) return 'image';
  if (ascii(0, 4) === 'II*\0' || ascii(0, 4) === 'MM\0*') return 'image';
  // BMP 头的第 6–9 字节保留为 0，文本文件不会出现，避免把以 BM 开头的文本误判成图片。
  if (ascii(0, 2) === 'BM' && size >= 10 && bytes.readUInt32LE(6) === 0) return 'image';
  if (ascii(4, 8) === 'ftyp' && HEIF_BRANDS.has(ascii(8, 12))) return 'image';
  return 'text';
}

function readLimited(path: string, max: number, label: string): Buffer {
  const stat = statSync(path);
  if (!stat.isFile()) throw new KiteError('目标不是普通文件');
  if (stat.size > max) throw new KiteError(`${label}超过 ${Math.round(max / 1024 / 1024)} MiB，无法直接读取`);
  return readFileSync(path);
}

export interface ModelImage { image: ToolImage; width: number; height: number; source: { width: number; height: number; format: string } }

/** 尺寸与格式已合适时原样附上，否则缩放并重新编码；有损格式只在 PNG 等仍超限时才用。 */
export async function modelImage(bytes: Uint8Array): Promise<ModelImage> {
  const source = await new Bun.Image(bytes).metadata();
  const scale = Math.min(1, MAX_EDGE / Math.max(source.width, source.height));
  const width = Math.max(1, Math.round(source.width * scale));
  const height = Math.max(1, Math.round(source.height * scale));
  const result = (data: Uint8Array, format: 'png' | 'jpeg' | 'webp'): ModelImage =>
    ({ image: { mediaType: `image/${format}`, data: Buffer.from(data).toString('base64') }, width, height, source });
  const native = source.format === 'png' || source.format === 'jpeg' || source.format === 'webp' ? source.format : undefined;
  if (native && scale === 1 && bytes.length <= MAX_IMAGE_BYTES) return result(bytes, native);
  const resized = () => new Bun.Image(bytes).resize(width, height, { fit: 'inside' });
  const format = native ?? (['heic', 'avif'].includes(source.format) ? 'jpeg' : 'png');
  if (format !== 'jpeg') {
    const encoded = await (format === 'png' ? resized().png() : resized().webp({ quality: 90 })).bytes();
    if (encoded.length <= MAX_IMAGE_BYTES) return result(encoded, format);
  }
  const encoded = await resized().jpeg({ quality: 85 }).bytes();
  if (encoded.length > MAX_IMAGE_BYTES) throw new KiteError('图片压缩后仍然过大，无法附给模型');
  return result(encoded, 'jpeg');
}

export async function readImage(path: string): Promise<ModelImage> {
  const bytes = readLimited(path, MAX_IMAGE_FILE, '图片');
  try { return await modelImage(bytes); }
  catch (error) {
    if (error instanceof KiteError) throw error;
    throw new KiteError(`图片无法解码：${error instanceof Error ? error.message : String(error)}`);
  }
}

const HELPER_SOURCE = fileURLToPath(new URL('./kite-pdf.swift', import.meta.url));
const builds = new Map<string, Promise<string>>();

/** 转换程序按源码哈希编译到用户临时目录，首次读取 PDF 时构建；程序名固定为 kite-pdf，Vision 的模型缓存跨版本复用。 */
function helper(env: NodeJS.ProcessEnv): Promise<string> {
  // macOS 26 对应 Darwin 25；更早的系统没有 Vision 的文档识别。
  if (process.platform !== 'darwin' || Number(release().split('.')[0]) < 25) {
    return Promise.reject(new KiteError('读取 PDF 需要 macOS 26 或更新版本'));
  }
  const hash = createHash('sha256').update(readFileSync(HELPER_SOURCE)).digest('hex').slice(0, 16);
  let build = builds.get(hash);
  if (!build) {
    build = (async () => {
      const directory = join(tmpdir(), `kite-pdf-${hash}`);
      const binary = join(directory, 'kite-pdf');
      if (existsSync(binary)) return binary;
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      const output = join(directory, `.build-${randomUUID()}`);
      const child = Bun.spawn(['/usr/bin/swiftc', '-O', '-module-name', 'KitePDF', HELPER_SOURCE, '-o', output],
        { env, stdout: 'ignore', stderr: 'pipe' });
      const [log, code] = await Promise.all([new Response(child.stderr).text(), child.exited]);
      if (code !== 0) {
        rmSync(output, { force: true });
        throw new KiteError(`PDF 转换程序编译失败，需要 Xcode 命令行工具：${log.trim().split('\n').slice(-3).join('\n')}`);
      }
      renameSync(output, binary);
      return binary;
    })();
    builds.set(hash, build);
    build.catch(() => builds.delete(hash));
  }
  return build;
}

const headerLine = z.object({ pages: z.number().int().nonnegative() });
const pageLine = z.object({ page: z.number().int().positive(), markdown: z.string(), textLayer: z.boolean(), image: z.string().nullable().optional() });
interface PdfPage { markdown: string; image?: Uint8Array }

/** 一次转换进程：逐页输出，读够了就停止，剩余页不再识别。 */
class Conversion {
  private lines: AsyncIterator<string>;
  private errors = '';
  private exited: Promise<number>;
  private constructor(private child: Bun.Subprocess<'ignore', 'pipe', 'pipe'>) {
    this.lines = Conversion.split(child.stdout);
    this.exited = child.exited;
    // PDFKit 会向 stderr 打大量调试日志，只保留末尾用于报错，同时持续读取避免管道写满。
    void (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of child.stderr) this.errors = (this.errors + decoder.decode(chunk, { stream: true })).slice(-4096);
    })().catch(() => {});
  }

  static async start(binary: string, path: string, first: number, last: number, env: NodeJS.ProcessEnv): Promise<Conversion> {
    return new Conversion(Bun.spawn([binary, path, String(first), String(last)], { env, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }));
  }

  private static async *split(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
    const decoder = new TextDecoder();
    let buffer = '';
    for await (const chunk of stream) {
      buffer += decoder.decode(chunk, { stream: true });
      for (let end = buffer.indexOf('\n'); end >= 0; end = buffer.indexOf('\n')) {
        yield buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
      }
    }
  }

  async next<T>(schema: z.ZodType<T>): Promise<T> {
    const { value, done } = await this.lines.next();
    if (!done) return schema.parse(JSON.parse(value));
    const code = await this.exited;
    // 自身的错误信息不带时间戳，系统框架的日志行带，借此滤掉后者。
    const message = this.errors.split('\n').filter((line) => line.trim() && !/^\d{4}-\d\d-\d\d /.test(line)).at(-1);
    throw new KiteError(code === 0 ? 'PDF 转换提前结束' : message ?? `PDF 转换失败（退出码 ${code}）`);
  }

  async stop(): Promise<void> {
    this.child.kill();
    await this.exited;
  }
}

export interface PdfPages { output: string; images: ToolImage[] }

/** 识别结果按文件内容哈希和页码缓存，分页续读时只识别新页。 */
export class PdfReader {
  private totals = new Map<string, number>();
  private pages = new Map<string, PdfPage>();
  constructor(private env: NodeJS.ProcessEnv) {}

  async read(path: string, pages: string | undefined, limit: number, signal: AbortSignal): Promise<PdfPages> {
    const key = createHash('sha256').update(readLimited(path, MAX_PDF_FILE, 'PDF ')).digest('hex');
    const [first, last] = pageRange(pages);
    let total = this.totals.get(key);
    let conversion: Conversion | undefined;
    const stop = () => { void conversion?.stop(); };
    signal.addEventListener('abort', stop, { once: true });
    const selected: { number: number; page: PdfPage; text: string }[] = [];
    let truncated = false;
    try {
      let used = 0;
      for (let number = first; number <= last; number++) {
        if (total !== undefined && number > total) break;
        let page = this.pages.get(`${key}:${number}`);
        // 命中缓存时结束旧流，后续缺页从自身页码重新转换，避免沿用停在缓存页前的游标。
        if (page && conversion) {
          await conversion.stop();
          conversion = undefined;
        }
        if (!page) {
          if (!conversion) {
            conversion = await Conversion.start(await helper(this.env), path, number, last, this.env);
            signal.throwIfAborted();
            total = (await conversion.next(headerLine)).pages;
            this.totals.set(key, total);
            if (number > total) break;
          }
          const line = await conversion.next(pageLine);
          if (line.page !== number) throw new KiteError('PDF 转换输出的页码顺序不符');
          page = { markdown: line.markdown, ...(line.image ? { image: Buffer.from(line.image, 'base64') } : {}) };
          this.pages.set(`${key}:${number}`, page);
          if (this.pages.size > 32) this.pages.delete(this.pages.keys().next().value!);
        }
        // 上限按每页完整内容计，含页标记与扫描页说明；开头说明和续读提示很短，不计入。
        let text = page.markdown.trim();
        const scans = selected.filter((entry) => entry.page.image).length;
        const size = render(number, page, text).length;
        if (selected.length && ((page.image && scans >= PDF_IMAGE_CAP) || used + size > limit)) break;
        if (size > limit) { text = text.slice(0, Math.max(0, text.length - (size - limit))); truncated = true; }
        selected.push({ number, page, text });
        used += render(number, page, text).length;
      }
    } finally {
      signal.removeEventListener('abort', stop);
      await conversion?.stop();
    }
    signal.throwIfAborted();
    if (!total) throw new KiteError('PDF 没有页面');
    if (first > total) throw new KiteError(`PDF 共 ${total} 页，起始页超出范围`);
    const images: ToolImage[] = [];
    for (const entry of selected) if (entry.page.image) images.push((await modelImage(entry.page.image)).image);
    const end = selected.at(-1)!.number;
    const body = selected.map(({ number, page, text }) => render(number, page, text));
    const notes = [`PDF 共 ${total} 页，以下是第 ${first === end ? first : `${first}-${end}`} 页。版面由 macOS Vision 识别后转为 Markdown，标题层级和表格可能有误。`];
    if (truncated) notes.push(`第 ${first} 页过长，只返回前 ${limit} 个字符。`);
    if (end < total) notes.push(`后面还有内容，继续读取请用 pages: "${end + 1}-${Math.min(total, end + PDF_PAGE_SPAN)}"。`);
    return { output: [...notes, '', ...body].join('\n'), images };
  }
}

function render(number: number, page: PdfPage, text: string): string {
  return `<!-- 第 ${number} 页 -->\n${page.image
    ? `${text || '（未识别到文字）'}\n（本页没有文本层，以上是 OCR 结果，可能有错字；已附上页面图片）`
    : text || '（本页没有可识别的内容）'}`;
}

function pageRange(pages: string | undefined): [number, number] {
  if (pages === undefined) return [1, PDF_PAGE_SPAN];
  const [start, end = start] = pages.split('-').map(Number) as [number, number?];
  if (start < 1 || end < start) throw new KiteError('pages 须为从 1 开始的页码或递增范围，如 "3" 或 "3-5"');
  if (end - start + 1 > PDF_PAGE_SPAN) throw new KiteError(`一次最多读取 ${PDF_PAGE_SPAN} 页`);
  return [start, end];
}
