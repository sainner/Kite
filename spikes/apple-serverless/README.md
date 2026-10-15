# Apple 端无服务器实验（2026-10-15）

验证分布式架构在 Apple 设备上的两件事：iPhone 内嵌 TailscaleKit 用官方服务登录并访问 Mac 节点；CloudKit 订阅推送与带版本条件的写入（执行权租约）。结论见 [官方组网实测](../../docs/research/2026-10-15-官方组网实测.md)。

工程由 xcodegen 从 `project.yml` 生成，生成物不入库：

```sh
xcodegen generate
xcodebuild -project KiteSpike.xcodeproj -scheme KiteSpike -destination 'id=<设备 ID>' -derivedDataPath ../../build/spike-apple -allowProvisioningUpdates build
```

| target | 内容 |
|---|---|
| `KiteSpike`（iOS） | 「组网」页：用官方服务上线、打开登录地址、连访 Mac 实验节点（[tailscale-official](../tailscale-official/README.md)）；「iCloud」页：开通知、订阅提醒记录、记下送达耗时 |
| `KiteSpikeMac`（macOS，带 iCloud 权限的 App 包，从终端运行可执行文件） | `status`、`notify <文字>`、`lease-race [次数]`（同一版本上两个写入同时比较后更新）、`lease-renew [次数]`、`cleanup` |

当时的签名团队是个人（免费）开发者团队，不能开 iCloud 与推送：iOS target 的相关权限已注释掉，`KiteSpikeMac` 签不出描述文件。加入付费的 Apple Developer Program 后恢复 `project.yml` 里的权限再做 CloudKit 部分。
