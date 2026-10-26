---
name: todo-web-tools
description: web_search、web_fetch 接 DeepSeek、Tavily、Exa 后还没用真 Key 验的接口格式、凭据页合并后的 API Key 窗口验收，以及用户还没确认的实现取舍
metadata:
  node_type: memory
  type: todo
  originSessionId: 2f85b960-2efb-46c3-b434-483e7fa9a664
  modified: 2026-10-26T05:50:40.994Z
---

**来源：** 2026-10-26 用户要接搜索和 fetch 工具，选定「多做几个搜索服务」，第一批 DeepSeek、Tavily、Exa；fetch 按网络许可把关是我给的默认，用户没反对。现行契约在 [harness 主循环](../../docs/harness-主循环.md#web_search) 与 kited.md「凭据」，这里不重复。

**未验证：** 三家的请求与响应字段都是照 2026-10-26 的官方文档写的（`kited/src/web/services.ts`），没用真 Key 跑过；DeepSeek 的 Search、Fetch 是 10-17 才上线的接口。App 里合并后的「API Key」凭据窗口（10-26 用户定：模型、语音、搜索三类合成一个，每把用标签写用途；同时去掉 OpenAI、Anthropic 的 API Key）、审批卡片「要读 … 上的网页」、工具行的显示没在真机上看过。

**我定的、用户还没确认：** 换家顺序固定为 DeepSeek → Tavily → Exa，不能自己排；Tavily、Exa 在凭据页没有品牌图标；Line 和审查角色的工具白名单没加这两个工具；已有代理要在配置里手动打开。

**完成条件：** 每家用真 Key 各跑通一次搜索和读网页，换家与报错的说法看过；App 窗口验收过；上面几项取舍用户点头或改掉后删掉本条。
