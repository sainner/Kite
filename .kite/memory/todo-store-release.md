---
name: todo-store-release
description: 上架 App Store 前要补的版本做法：kited 兼容在用的旧版 App、先 App 后 kited、公共下载点、Mac App 签名后自更新
metadata:
  type: todo
---

来源：2026-10-16 做自动更新时，用户问上架后能不能用 devicectl 给 iPhone 自动装。不能：devicectl 只装开发签名的包，App Store 版只能由商店更新、要过审核，时机由用户与系统决定。现行做法（开发期按协议号严格一致，不符就锁定；iOS 只锁定）见 docs/App.md「版本」，用户当时选的是这个。

未解决：
- kited 至少兼容 App Store 上当前那一版 App 的协议号，App 声明自己支持的范围；锁定只留给太旧的 App，并给跳 App Store 的入口。可以用苹果公开的 iTunes lookup 区分「新版还没上架」与「还没更新」。
- 发布顺序：改了接口的版本先上架能兼容新旧协议的 App，多数用户更新后再发布要求新协议的 kited；kited 自动更新几分钟就传开，不能跑在 App 前面。
- 用户手里没有源码，kited 新版要有公共下载点（例如 GitHub Releases），工作机之间的传播照用。
- Mac App 用 Developer ID 签名、公证后自更新，签名固定后系统权限与钥匙串不再因每次构建重新授权。

完成条件：准备上架时（与 [[decentralized-direction]] 里加入付费开发者账号同期）逐项定下并实施，或另立记忆后删除本条。
