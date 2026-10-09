---
name: project-constraints-direction
description: 项目约束存于账号服务的项目登记，由 kited 执行并缓存，收紧时运行中的代理立即生效，不放仓库文件
metadata:
  node_type: memory
  type: decision
  originSessionId: 7c9639e3-0374-46e3-81b4-3a82c2c97cb6
  modified: 2026-10-09T06:04:30.942Z
---

2026-10-09 用户确定：项目级的代理约束（首先是工具黑白名单）以项目 ID 保存在账号服务，与项目专用密钥相邻，随账号分发到各工作机；kited 在创建代理和每次调用工具时检查，并缓存最近一份，离线时沿用。约束收紧时，正在运行的代理也立即生效。约束只在 App 的项目设置里由用户修改，代理没有修改它的操作。

**Why:** 项目以远程为身份、跨工作机共用（[[project-remote-identity]]），按机器保存会不一致；放在仓库文件里，有 patch 工具的代理能删掉限制自己的条目。角色是创建时拷贝的模板，约束是边界，二者生效时机不同。
**How to apply:** 约束与角色、实例选择的求交规则见 [[agent-role-direction]]。执行授权（文件、网络）以后可用同一算法设项目上限，首期只做工具。
