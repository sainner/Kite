/*
 * 预览的指认脚本（docs/实例操作.md「指认」）：给视口里的一点，取那里最上层的元素，返回它的位置、种类、文字、标识与源码位置。
 * App 在设备网页视图里、kited 在工作机上的浏览器里执行同一份。文件是一个异步函数表达式，调用方传 x、y 并等它的结果：视图里的点，
 * 页面被捏合缩放时按视觉视口换算；返回的位置也换回视图里的点。那一点没有元素时返回 null。
 * 结果：{x, y, width, height, radius?, tag, text, color?, font, id?, testId?, component?, file?, line?, page}；file 是开发构建给的原样，
 * 可能是工作机上的绝对路径，换成工作区里的相对路径由 App 做。
 */
(async function (x, y) {
  const view = window.visualViewport;
  const scale = view?.scale ?? 1, left = view?.offsetLeft ?? 0, top = view?.offsetTop ?? 0;
  const cx = x / scale + left, cy = y / scale + top;
  let element = document.elementFromPoint(cx, cy);
  // 开着的 Shadow DOM 往里找到真正在那一点上的元素
  while (element && element.shadowRoot) {
    const inner = element.shadowRoot.elementFromPoint(cx, cy);
    if (!inner || inner === element) break;
    element = inner;
  }
  if (!element || element === document.documentElement) return null;
  // 图标里的路径、形状算整个图标
  let svg = element.closest('svg');
  while (svg && svg.ownerSVGElement) svg = svg.ownerSVGElement;
  if (svg) element = svg;

  // 可见文字：没有子元素时用 innerText；有子元素的（常是布局容器）沿文字节点收够 200 个字就停，悬停时不为整棵子树排版、拼长串
  const visibleText = (node) => {
    if (!node.childElementCount && node.innerText !== undefined) return node.innerText;
    let out = '';
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
    while (out.length < 200 && walker.nextNode()) {
      if (!walker.currentNode.parentElement?.closest('script, style, template, noscript')) out += walker.currentNode.data + ' ';
    }
    return out;
  };
  // 截到 200 个码元，切开的半个 emoji 去掉：单个的代理项 App 那边的 JSON 解不出来
  const text = (element.getAttribute('aria-label') || element.getAttribute('alt') || element.getAttribute('placeholder')
    || element.getAttribute('title') || visibleText(element)).replace(/\s+/g, ' ').trim().slice(0, 200).replace(/[\ud800-\udbff]$/, '');

  // 打包插件写的位置属性：code-inspector-plugin 是「文件:行:列:标签」，TanStack Devtools 是「文件:行:列」
  const attributeSource = (node) => {
    const value = node.getAttribute('data-insp-path') || node.getAttribute('data-tsd-source');
    const match = value && /^(.*?):(\d+)(?::\d+)?(?::[^:]*)?$/.exec(value);
    return match ? { file: match[1], line: Number(match[2]) } : undefined;
  };
  // Svelte 开发模式：Svelte 5 的行号从 1 起；Svelte 4 的从 0 起，带 char
  const svelteSource = (node) => {
    const loc = node.__svelte_meta?.loc;
    return loc?.file ? { file: loc.file, line: loc.line + ('char' in loc ? 1 : 0) } : undefined;
  };
  let source;
  for (let node = element; node && node.nodeType === 1 && !source; node = node.parentElement) {
    source = attributeSource(node) || svelteSource(node);
  }

  // 脚本地址对应的 source map 与解析其中源文件的基准地址，取过的留在页面里，悬停时不重取；没有或取不到时为 null。
  // 基准是 source map 自己的地址，内嵌在 data: 里的（Vite）用脚本的地址
  const maps = globalThis[Symbol.for('kite.preview-point.maps')] ??= new Map();
  // 只留查找用得到的，sourcesContent 这类大块不留在页面里
  const slim = (map) => map.sections
    ? { sections: map.sections.map(({ offset, map }) => ({ offset, map: map && slim(map) })) }
    : { mappings: map.mappings, sources: map.sources, sourceRoot: map.sourceRoot };
  const sourceMap = (url) => {
    if (!maps.has(url)) {
      const load = async () => {
        const code = await (await fetch(url, { signal: AbortSignal.timeout?.(5000) })).text();
        const at = code.lastIndexOf('sourceMappingURL=');
        if (at < 0) return null;
        const mapURL = new URL(code.slice(at + 17).split(/\s/, 1)[0], url);
        const map = await (await fetch(mapURL, { signal: AbortSignal.timeout?.(5000) })).json();
        return { map: slim(map), base: mapURL.protocol === 'data:' ? url : mapURL };
      };
      // 取不到的（.map 404、不是 JSON、被跨域拦下、超时）过半分钟再试：开发服务器可能还在编译，又不能指针每动一下都重下整个脚本
      maps.set(url, load().catch(() => { setTimeout(() => maps.delete(url), 30_000); return null; }));
    }
    return maps.get(url);
  };
  // 生成代码里的一处（行、列从 0 起）在原文件里的地址与行（从 1 起）。分段式的（Turbopack）先找到那一段；
  // mappings 是 Base64 VLQ，行间分号、段间逗号，每段的生成列在行内累加，源序号、原行、原列全程累加，只解到要的那一行
  const lookup = (map, base, line, column) => {
    if (map.sections) {
      let section;
      for (const s of map.sections) {
        if (s.offset.line > line || (s.offset.line === line && s.offset.column > column)) break;
        section = s;
      }
      if (!section?.map) return;
      const inner = line - section.offset.line;
      return lookup(section.map, base, inner, inner ? column : column - section.offset.column);
    }
    const mappings = map.mappings || '';
    let generatedLine = 0, generatedColumn = 0, sourceIndex = 0, originalLine = 0, value = 0, shift = 0, fields = [], best;
    for (let i = 0; i <= mappings.length; i++) {
      const char = mappings[i];
      if (char === ',' || char === ';' || char === undefined) {
        if (fields.length) {
          generatedColumn += fields[0];
          if (fields.length >= 4) {
            sourceIndex += fields[1];
            originalLine += fields[2];
            // 取这一行上不超过那一列的最后一段，那一列在第一段之前就取第一段
            if (generatedLine === line && (generatedColumn <= column || !best)) best = { sourceIndex, originalLine };
          }
        }
        fields = [];
        if (char !== ',') {
          if (generatedLine === line) break;
          generatedLine++;
          generatedColumn = 0;
        }
        continue;
      }
      const digit = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'.indexOf(char);
      value += (digit & 31) << shift;
      if (digit & 32) shift += 5;
      else { fields.push(value & 1 ? -(value >>> 1) : value >>> 1); value = shift = 0; }
    }
    const name = best && map.sources?.[best.sourceIndex];
    if (name == null) return;
    try {
      return { url: new URL((map.sourceRoot ? map.sourceRoot.replace(/\/?$/, '/') : '') + name, base), line: best.originalLine + 1 };
    } catch { return; }
  };
  // 项目里的源文件：工作机上的给绝对路径，同一开发服务器上的给路径；依赖包里的、打包工具自己的（turbopack:// 等）不算
  const projectFile = (url) => {
    if (url.pathname.includes('/node_modules/')) return;
    if (url.protocol === 'file:') return decodeURIComponent(url.pathname);
    if (url.origin === location.origin && !url.pathname.startsWith('/@')) return decodeURIComponent(url.pathname).replace(/^\//, '');
  };
  // 调用栈里第一处在项目里的源码，到 React 的底帧为止，再往后是 React 自己在渲染。有 source map 的换回原文件与行；
  // 没有的只认开发服务器原样给的源文件（Vite 这类），只有文件，行号是编译后的、不要；打包出来的块（.js）不算源文件
  const stackSource = async (stack) => {
    for (const frame of stack.split('\n')) {
      if (/react[-_]stack[-_]bottom[-_]frame/.test(frame)) break;
      const match = /(https?:\/\/[^\s()]+):(\d+):(\d+)\)?$/.exec(frame.trim());
      if (!match) continue;
      let url;
      try { url = new URL(match[1]); } catch { continue; }
      const found = await sourceMap(url.href);
      if (found) {
        const hit = lookup(found.map, found.base, Number(match[2]) - 1, Number(match[3]) - 1);
        const file = hit && projectFile(hit.url);
        if (file) return { file, line: hit.line };
      } else if (/\.(tsx?|jsx|mts|vue|svelte)$/.test(url.pathname)) {
        const file = projectFile(url);
        if (file) return { file };
      }
    }
  };

  // React 开发模式：元素上挂着 fiber。React 18 及以前 _debugSource 是写这个元素的 JSX 所在；React 19 去掉了它，
  // 只有 _debugStack（写这个元素的 JSX 执行时的调用栈），按开发服务器的 source map 换回源文件与行。
  // 元素是依赖包里的组件画的，就沿 _debugOwner 往上，找项目里用这个组件的地方
  let component;
  const fiberKey = Object.keys(element).find((key) => key.startsWith('__reactFiber$') || key.startsWith('__reactInternalInstance$'));
  if (fiberKey) {
    const fiber = element[fiberKey];
    for (let owner = fiber?.return; owner && !component; owner = owner.return) {
      const type = owner.type;
      if (typeof type === 'function') component = type.displayName || type.name;
      else if (type && typeof type === 'object') component = type.displayName || type.render?.name || type.type?.name;
    }
    for (let node = fiber, depth = 0; node && !source && depth < 20; node = node._debugOwner, depth++) {
      const debug = node._debugSource;
      if (debug?.fileName) {
        if (!debug.fileName.includes('/node_modules/')) source = { file: debug.fileName, line: debug.lineNumber };
      } else if (node._debugStack) source = await stackSource(String(node._debugStack.stack || ''));
    }
  }
  // Vue 3 开发模式：元素所在组件的 __file，只有文件
  const vue = element.__vueParentComponent;
  if (vue?.type) {
    if (!source && vue.type.__file) source = { file: vue.type.__file };
    if (!component) component = vue.type.name || vue.type.__name;
  }

  const rect = element.getBoundingClientRect();
  // 外观：文字颜色写成 #RRGGBB（半透明的接上透明度），oklch 这类别的色彩空间经画布换成 sRGB；字号与字体；
  // 左上角的圆角（百分比按宽度算）换成视图里的点，框按它画
  const style = getComputedStyle(element);
  const hex = (value) => {
    const canvas = globalThis[Symbol.for('kite.preview-point.canvas')] ??= Object.assign(document.createElement('canvas'), { width: 1, height: 1 });
    const context = canvas.getContext('2d', { willReadFrequently: true });
    if (!context) return;
    // 画布留着复用，先擦掉上次的，半透明的颜色才不叠在上面
    context.clearRect(0, 0, 1, 1);
    context.fillStyle = value;
    context.fillRect(0, 0, 1, 1);
    const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data;
    return '#' + (a < 255 ? [r, g, b, a] : [r, g, b]).map((n) => n.toString(16).padStart(2, '0')).join('').toUpperCase();
  };
  const corner = parseFloat(style.borderTopLeftRadius) || 0;
  const radius = Math.min(style.borderTopLeftRadius.endsWith('%') ? corner / 100 * rect.width : corner, rect.width / 2, rect.height / 2) * scale;
  const result = {
    x: (rect.left - left) * scale, y: (rect.top - top) * scale, width: rect.width * scale, height: rect.height * scale,
    tag: element.tagName.toLowerCase(), text, page: location.pathname + location.search,
    font: `${style.fontSize} ${style.fontFamily.replace(/["']/g, '')}`.slice(0, 200),
  };
  const color = hex(style.color);
  if (color) result.color = color;
  if (radius > 0) result.radius = radius;
  if (element.id) result.id = element.id;
  const testId = element.getAttribute('data-testid');
  if (testId) result.testId = testId;
  if (component) result.component = component;
  if (source?.file) {
    result.file = String(source.file);
    if (Number.isFinite(source.line) && source.line > 0) result.line = source.line;
  }
  return result;
})
