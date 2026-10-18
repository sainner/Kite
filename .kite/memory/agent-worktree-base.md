---
name: agent-worktree-base
description: Claude Code 子 agent 的 worktree 隔离从 origin/main 建，本地没推送的提交不在里面；派之前要让它先快进到 main
metadata:
  node_type: memory
  type: context
  originSessionId: 05c1a88c-1691-44b0-92e5-dabc3bfabd7c
  modified: 2026-10-18T04:14:05.642Z
---

Claude Code 用 `isolation: "worktree"` 派的子 agent，worktree 分支从 `origin/main` 建出来，不是本地 main。本仓库常在本地 main 上连续提交、不推送，于是 agent 拿到的是旧代码（2026-10-18 那次停在 9773203，比本地 main 落后好几个提交），在旧代码上做的判断和改动都会错位。

**Why:** 当次派出的四个 agent 全部从旧提交起步，靠一个 agent 自己发现后才逐个补救。
**How to apply:** 派 worktree 子 agent 时，在任务说明开头写明先 `git log --oneline -1` 核对，不是本地 main 的头或其后代就 `git merge --ff-only main` 再开工，回报里注明父提交。合回 main 时，如果工作区里有别的会话没提交的改动，用 `git apply --cached` 加 `git apply` 分别打进暂存区和工作区再提交，不要整份 merge 或 stash。
