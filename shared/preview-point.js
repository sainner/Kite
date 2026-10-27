/*
 * 预览的指认脚本（docs/实例操作.md「指认」）：给视口里的一点，取那里最上层的元素，返回它的位置、种类、文字、标识与源码位置。
 * App 在设备网页视图里、kited 在工作机上的浏览器里执行同一份。文件是一个函数表达式，调用方传 x、y：视图里的点，
 * 页面被捏合缩放时按视觉视口换算；返回的位置也换回视图里的点。那一点没有元素时返回 null。
 * 结果：{x, y, width, height, tag, text, id?, testId?, component?, file?, line?, page}；file 是开发构建给的原样，
 * 可能是工作机上的绝对路径，换成工作区里的相对路径由 App 做。
 */
(function (x, y) {
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

  // React 开发模式：元素上挂着 fiber。React 18 及以前 _debugSource 是写这个元素的 JSX 所在；
  // React 19 只有组件名，调用栈指向开发服务器上的源文件（Vite）时取出文件，行号是编译后的、不要
  let component;
  const fiberKey = Object.keys(element).find((key) => key.startsWith('__reactFiber$') || key.startsWith('__reactInternalInstance$'));
  if (fiberKey) {
    const fiber = element[fiberKey];
    const debug = fiber?._debugSource;
    if (!source && debug?.fileName) source = { file: debug.fileName, line: debug.lineNumber };
    for (let owner = fiber?.return; owner && !component; owner = owner.return) {
      const type = owner.type;
      if (typeof type === 'function') component = type.displayName || type.name;
      else if (type && typeof type === 'object') component = type.displayName || type.render?.name || type.type?.name;
    }
    const stack = !source && fiber?._debugStack && String(fiber._debugStack.stack || '');
    if (stack) {
      for (const match of stack.matchAll(/(https?:\/\/[^\s()]+?):\d+:\d+/g)) {
        let url;
        try { url = new URL(match[1]); } catch { continue; }
        if (url.origin !== location.origin || url.pathname.includes('/node_modules/') || url.pathname.startsWith('/@')) continue;
        if (!/\.(jsx?|tsx?|mjs|mts|vue|svelte)$/.test(url.pathname)) continue;
        source = { file: decodeURIComponent(url.pathname).replace(/^\//, '') };
        break;
      }
    }
  }
  // Vue 3 开发模式：元素所在组件的 __file，只有文件
  const vue = element.__vueParentComponent;
  if (vue?.type) {
    if (!source && vue.type.__file) source = { file: vue.type.__file };
    if (!component) component = vue.type.name || vue.type.__name;
  }

  const rect = element.getBoundingClientRect();
  const result = {
    x: (rect.left - left) * scale, y: (rect.top - top) * scale, width: rect.width * scale, height: rect.height * scale,
    tag: element.tagName.toLowerCase(), text, page: location.pathname + location.search,
  };
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
