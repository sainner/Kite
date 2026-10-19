---
name: agent-worktree-base
description: Claude Code 子 agent 的 worktree 隔离默认从 origin/main 建，本地没推送的提交不在里面；可设 worktree.baseRef=head，否则派之前要让它先快进到 main
metadata:
  node_type: memory
  type: context
  originSessionId: 05c1a88c-1691-44b0-92e5-dabc3bfabd7c
  modified: 2026-10-19T05:43:05.418Z
---

Claude Code 用 `isolation: "worktree"` 派的子 agent，worktree 分支从 `origin/main` 建出来，不是本地 main。本仓库常在本地 main 上连续提交、不推送，于是 agent 拿到的是旧代码（2026-10-18 那次停在 9773203，比本地 main 落后好几个提交），在旧代码上做的判断和改动都会错位。

**Why:** 当次派出的四个 agent 全部从旧提交起步，靠一个 agent 自己发现后才逐个补救。
起点由设置 `worktree.baseRef` 决定：`fresh`（默认）从 `origin/<默认分支>` 开，`head` 从当前本地 HEAD 开，对 `--worktree`、EnterWorktree 和 agent 隔离都生效（2026-10-19 在 2.1.303 的设置说明里核对）。`head` 只带已提交的，工作树里没提交的改动仍不在里面。

**How to apply:** 想让子 agent 默认带上本地提交，可以在本仓库设置里把 `worktree.baseRef` 设为 `head`（要不要设先问用户）。没设的时候，派 worktree 子 agent 在任务说明开头写明先 `git log --oneline -1` 核对，不是本地 main 的头或其后代就 `git merge --ff-only main` 再开工，回报里注明父提交。合回 main 时，如果工作区里有别的会话没提交的改动，用 `git apply --cached` 加 `git apply` 分别打进暂存区和工作区再提交，不要整份 merge 或 stash。
