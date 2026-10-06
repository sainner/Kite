# 手动验证

这些验证需要 Swift 编译器、原生界面或 WKWebView，不计入 `small` / `medium` 的数量与耗时预算；其中哪些由 `.kite/check` 自动运行见 `kited/scripts/check.ts`。以下命令从仓库根目录运行；需要 macOS 和 Xcode 开发工具。

先按 [工作机开发入口](../../README.md#启动服务) 安装依赖，再在仓库根目录选择项目固定的 Bun：

```bash
export PATH="$PWD/kited/node_modules/.bin:$PATH"
```

| 入口 | 验证内容 | 命令 |
| --- | --- | --- |
| `verify-plugin-management.ts` | Swift 配置编辑与真实后端往返、授权和版本冲突 | `bun kited/test/manual/verify-plugin-management.ts` |
| `verify-remote-workspace-swift.ts` | 真实后端工作区 JSON 的 Swift 解码和目录同步 | `bun kited/test/manual/verify-remote-workspace-swift.ts` |
| `verify-resource-reference-swift.ts` | 文件、diff 和网页引用经过 Markdown 与编码转换后仍正确 | `bun kited/test/manual/verify-resource-reference-swift.ts` |
| `verify-thread-draft-swift.ts` | 停止退回草稿与发送淡出回调交错时不丢字、不重复 | `bun kited/test/manual/verify-thread-draft-swift.ts` |
| `verify-transcript-scroll-swift.ts` | SwiftUI 动画收起与滚动阶段的定位交接 | `bun kited/test/manual/verify-transcript-scroll-swift.ts` |
| `verify-transcript-swift.ts` | 显示投影 JSON 的 Swift 解码、思考和工具结果关联 | `bun kited/test/manual/verify-transcript-swift.ts` |
| `verify-window-dock.ts` | 窗口拖动、停靠、预设切换与状态恢复 | `bun kited/test/manual/verify-window-dock.ts` |
| `verify-plugin-web.ts` | 真实 WKWebView 与 MCP Apps SDK 的隔离和生命周期 | `bun kited/test/manual/verify-plugin-web.ts`；iOS 加 `--ios <模拟器 UDID>` |

`PluginWebProbe.swift` 是 `verify-plugin-web.ts` 编译和启动的原生探针，不单独运行。其余 Swift 文件是同名验证使用的夹具；`command.ts` 提供共用子进程执行入口。
