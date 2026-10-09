/**
 * 点阵签名的表达式：一行算式，App 每帧按格求值，结果在 −1 到 1 之间，绝对值是点的大小、正负选两种颜色。
 * 只解析、求值，不执行代码。语法与 App 的 DotExpression.swift 保持一致，改动须两边同步。
 */

/** v 是声音的响度（0～1），来自语音输入或系统播放的声音；音源接入前 App 恒给 0。 */
export const emblemVariables = ['t', 'x', 'y', 'i', 'w', 'h', 'r', 'a', 'px', 'py', 'd', 'k', 'v', 'pi', 'tau'] as const;
const arities: Record<string, number[]> = {
  sin: [1], cos: [1], tan: [1], abs: [1], floor: [1], ceil: [1], round: [1], sqrt: [1], exp: [1], log: [1],
  sign: [1], fract: [1], min: [2], max: [2], pow: [2], hypot: [2], atan2: [2], mod: [2], clamp: [3], mix: [3],
  noise: [2, 3],
};
export const emblemFunctions = Object.keys(arities);
export const maxExpressionLength = 240;
const maxNodes = 160;

type Node =
  | { type: 'number'; value: number }
  | { type: 'variable'; name: string }
  | { type: 'unary'; op: string; operand: Node }
  | { type: 'binary'; op: string; left: Node; right: Node }
  | { type: 'ternary'; test: Node; yes: Node; no: Node }
  | { type: 'call'; name: string; args: Node[] };

export type EmblemScope = Partial<Record<(typeof emblemVariables)[number], number>>;

const tokenPattern = /\s*(?:(\d+\.?\d*(?:e[+-]?\d+)?|\.\d+(?:e[+-]?\d+)?)|([a-z_][a-z0-9_]*)|(<=|>=|==|!=|&&|\|\||[-+*/%^()<>!?:,]))/iy;

function tokenize(source: string): string[] {
  const tokens: string[] = [];
  tokenPattern.lastIndex = 0;
  while (tokenPattern.lastIndex < source.length) {
    if (!source.slice(tokenPattern.lastIndex).trim()) break;
    const at = tokenPattern.lastIndex;
    const match = tokenPattern.exec(source);
    if (!match) throw new Error(`第 ${at + 1} 个字符无法识别`);
    tokens.push(match[1] ?? match[2] ?? match[3]!);
  }
  return tokens;
}

/** 解析失败时抛出带位置说明的错误。 */
export function parseEmblemExpression(source: string): Node {
  if (source.length > maxExpressionLength) throw new Error(`表达式不能超过 ${maxExpressionLength} 个字符`);
  const tokens = tokenize(source);
  let index = 0;
  let nodes = 0;
  const peek = () => tokens[index];
  const take = (expected?: string) => {
    const token = tokens[index];
    if (token === undefined) throw new Error('表达式不完整');
    if (expected !== undefined && token !== expected) throw new Error(`应为「${expected}」，实际是「${token}」`);
    index++;
    return token;
  };
  const node = <T extends Node>(value: T): T => {
    if (++nodes > maxNodes) throw new Error('表达式过于复杂');
    return value;
  };
  const binary = (next: () => Node, ops: string[]) => (): Node => {
    let left = next();
    while (ops.includes(peek() ?? '')) {
      const op = take();
      left = node({ type: 'binary', op, left, right: next() });
    }
    return left;
  };
  const primary = (): Node => {
    const token = take();
    if (token === '(') {
      const value = expression();
      take(')');
      return value;
    }
    if (/^[\d.]/.test(token)) return node({ type: 'number', value: Number(token) });
    if (/^[a-z_]/i.test(token)) {
      const name = token.toLowerCase();
      if (peek() === '(') {
        take('(');
        const args: Node[] = [];
        if (peek() !== ')') {
          do { args.push(expression()); } while (peek() === ',' && take(','));
        }
        take(')');
        const allowed = arities[name];
        if (!allowed) throw new Error(`不支持函数 ${name}`);
        if (!allowed.includes(args.length)) throw new Error(`函数 ${name} 的参数个数不对`);
        return node({ type: 'call', name, args });
      }
      if (!(emblemVariables as readonly string[]).includes(name)) throw new Error(`不支持变量 ${name}`);
      return node({ type: 'variable', name });
    }
    throw new Error(`「${token}」不能出现在这里`);
  };
  const unary = (): Node => {
    const token = peek();
    if (token === '-' || token === '+' || token === '!') {
      take();
      return node({ type: 'unary', op: token, operand: unary() });
    }
    return power();
  };
  const power = (): Node => {
    const base = primary();
    if (peek() !== '^') return base;
    take();
    return node({ type: 'binary', op: '^', left: base, right: unary() });
  };
  const product = binary(unary, ['*', '/', '%']);
  const sum = binary(product, ['+', '-']);
  const comparison = binary(sum, ['<', '>', '<=', '>=', '==', '!=']);
  const and = binary(comparison, ['&&']);
  const or = binary(and, ['||']);
  const expression = (): Node => {
    const test = or();
    if (peek() !== '?') return test;
    take();
    const yes = expression();
    take(':');
    return node({ type: 'ternary', test, yes, no: expression() });
  };
  if (!tokens.length) throw new Error('表达式为空');
  const result = expression();
  if (index < tokens.length) throw new Error(`多余的「${tokens[index]}」`);
  return result;
}

const fract = (v: number) => v - Math.floor(v);
const hash = (x: number, y: number, z: number) => fract(Math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453);
const smooth = (v: number) => v * v * (3 - 2 * v);
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/** 三维值噪声，输出 −1 到 1。 */
export function emblemNoise(x: number, y: number, z = 0): number {
  const ix = Math.floor(x), iy = Math.floor(y), iz = Math.floor(z);
  const fx = smooth(x - ix), fy = smooth(y - iy), fz = smooth(z - iz);
  const layer = (zz: number) => lerp(
    lerp(hash(ix, iy, zz), hash(ix + 1, iy, zz), fx),
    lerp(hash(ix, iy + 1, zz), hash(ix + 1, iy + 1, zz), fx), fy);
  return lerp(layer(iz), layer(iz + 1), fz) * 2 - 1;
}

function evaluate(node: Node, scope: EmblemScope): number {
  switch (node.type) {
    case 'number': return node.value;
    case 'variable':
      if (node.name === 'pi') return Math.PI;
      if (node.name === 'tau') return Math.PI * 2;
      return scope[node.name as keyof EmblemScope] ?? 0;
    case 'unary': {
      const v = evaluate(node.operand, scope);
      return node.op === '-' ? -v : node.op === '!' ? (v === 0 ? 1 : 0) : v;
    }
    case 'ternary': return evaluate(node.test, scope) !== 0 ? evaluate(node.yes, scope) : evaluate(node.no, scope);
    case 'binary': {
      const a = evaluate(node.left, scope), b = evaluate(node.right, scope);
      switch (node.op) {
        case '+': return a + b;
        case '-': return a - b;
        case '*': return a * b;
        case '/': return a / b;
        case '%': return a - b * Math.floor(a / b);
        case '^': return Math.pow(a, b);
        case '<': return a < b ? 1 : 0;
        case '>': return a > b ? 1 : 0;
        case '<=': return a <= b ? 1 : 0;
        case '>=': return a >= b ? 1 : 0;
        case '==': return a === b ? 1 : 0;
        case '!=': return a !== b ? 1 : 0;
        case '&&': return a !== 0 && b !== 0 ? 1 : 0;
        default: return a !== 0 || b !== 0 ? 1 : 0;
      }
    }
    case 'call': {
      const v = node.args.map((arg) => evaluate(arg, scope));
      const [a = 0, b = 0, c = 0] = v;
      switch (node.name) {
        case 'sin': return Math.sin(a);
        case 'cos': return Math.cos(a);
        case 'tan': return Math.tan(a);
        case 'abs': return Math.abs(a);
        case 'floor': return Math.floor(a);
        case 'ceil': return Math.ceil(a);
        case 'round': return Math.round(a);
        case 'sqrt': return Math.sqrt(a);
        case 'exp': return Math.exp(a);
        case 'log': return Math.log(a);
        case 'sign': return Math.sign(a);
        case 'fract': return fract(a);
        case 'min': return Math.min(a, b);
        case 'max': return Math.max(a, b);
        case 'pow': return Math.pow(a, b);
        case 'hypot': return Math.hypot(a, b);
        case 'atan2': return Math.atan2(a, b);
        case 'mod': return a - b * Math.floor(a / b);
        case 'clamp': return Math.min(Math.max(a, b), c);
        case 'mix': return a + (b - a) * c;
        default: return emblemNoise(a, b, c);
      }
    }
  }
}

/** 一格的取值，非有限数按 0，结果截到 −1 到 1。 */
export function evaluateEmblem(node: Node, scope: EmblemScope): number {
  const value = evaluate(node, scope);
  return Number.isFinite(value) ? Math.max(-1, Math.min(1, value)) : 0;
}

/**
 * 在一块画面上抽几帧，确认图案既不是一片空白、也不是整片铺满，并且会动。签名默认按 32 × 20 格查，头像按它的 9 × 9 小画布查。
 * everyFrame 时每一帧都不能是空白：头像空闲时停在随机的时刻。通过时返回 undefined，否则返回说明，供模型重试时参考。
 */
export function checkEmblemExpression(source: string, { w, h, everyFrame = false } = { w: 32, h: 20 }): string | undefined {
  let node: Node;
  try { node = parseEmblemExpression(source); } catch (error) { return error instanceof Error ? error.message : String(error); }
  const frames = [0, 0.7, 1.9, 4.3].map((t) => {
    const values: number[] = [];
    for (let row = 0; row < h; row++) {
      for (let column = 0; column < w; column++) {
        const x = column - Math.floor(w / 2), y = row - Math.floor(h / 2);
        values.push(evaluateEmblem(node, {
          t, x, y, i: row * w + column, w, h, r: Math.hypot(x, y), a: Math.atan2(y, x), px: 999, py: 999, d: 999, k: 0, v: 0,
        }));
      }
    }
    return values;
  });
  const all = frames.flat().map(Math.abs);
  const mean = all.reduce((sum, v) => sum + v, 0) / all.length;
  if (Math.max(...all) < 0.3) return '图案几乎是空白，最大值应至少到 0.3';
  if (everyFrame && frames.some((frame) => Math.max(...frame.map(Math.abs)) < 0.3)) {
    return '有的时刻几乎是空白；头像会停在随机的时刻，每一刻的最大值都应至少到 0.3';
  }
  if (mean > 0.85) return '图案几乎整片铺满，平均绝对值应低于 0.85';
  const moving = frames.slice(1).some((frame) => frame.some((v, index) => Math.abs(v - frames[0]![index]!) > 0.05));
  if (!moving) return '图案不随 t 变化，应当是动画';
  return undefined;
}
