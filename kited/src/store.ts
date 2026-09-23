/**
 * Kite 自己的事实：登记了哪些项目，每个会话的工作树和它续接的原生会话。
 * 快照在项目仓库的 refs/kite/ 里，会话记录在 Claude Code 自己的目录里，都不进这里。
 * 进程是否在跑、回合是否进行中是运行时状态，不落库。
 */
import { Database } from 'bun:sqlite';

/** kite：Kite 初始化的文件夹，提交由 Kite 代做；user：已有仓库，提交归用户。 */
export type CommitOwner = 'kite' | 'user';

export interface Project {
  id: string;
  path: string;
  commits: CommitOwner;
  createdAt: number;
}

/**
 * preparing：正在建工作树、跑初始化脚本；prepare_failed：这两步失败了，不启动 agent；
 * open：可以对话；archived：工作树已删，快照引用保留。
 */
export type SessionStatus = 'preparing' | 'prepare_failed' | 'open' | 'archived';

export interface Session {
  id: string;
  projectId: string;
  title: string;
  worktree: string;
  branch: string;
  /** 建工作树时的起点 commit。 */
  base: string;
  runtime: 'claude';
  /** 当前续接的原生会话 id（Claude Code 的 session id）。 */
  nativeId: string;
  status: SessionStatus;
  createdAt: number;
}

const SCHEMA = `
create table if not exists projects (
  id text primary key,
  path text not null unique,
  commits text not null check (commits in ('kite', 'user')),
  created_at integer not null
);
create table if not exists sessions (
  id text primary key,
  project_id text not null references projects(id),
  title text not null,
  worktree text not null,
  branch text not null,
  base text not null,
  runtime text not null,
  native_id text not null,
  status text not null,
  created_at integer not null
);
`;

const projectOf = (r: any): Project => ({ id: r.id, path: r.path, commits: r.commits, createdAt: r.created_at });
const sessionOf = (r: any): Session => ({
  id: r.id, projectId: r.project_id, title: r.title, worktree: r.worktree, branch: r.branch, base: r.base,
  runtime: r.runtime, nativeId: r.native_id, status: r.status, createdAt: r.created_at,
});

export class Store {
  private db: Database;
  constructor(path: string) {
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec('pragma journal_mode = wal; pragma foreign_keys = on;');
    this.db.exec(SCHEMA);
  }

  projects(): Project[] {
    return this.db.query('select * from projects order by created_at').all().map(projectOf);
  }
  project(id: string): Project | null {
    const r = this.db.query('select * from projects where id = ?').get(id);
    return r ? projectOf(r) : null;
  }
  addProject(p: Project): void {
    this.db.query('insert into projects (id, path, commits, created_at) values (?, ?, ?, ?)').run(p.id, p.path, p.commits, p.createdAt);
  }

  sessions(projectId?: string): Session[] {
    const rows = projectId
      ? this.db.query('select * from sessions where project_id = ? order by created_at').all(projectId)
      : this.db.query('select * from sessions order by created_at').all();
    return rows.map(sessionOf);
  }
  session(id: string): Session | null {
    const r = this.db.query('select * from sessions where id = ?').get(id);
    return r ? sessionOf(r) : null;
  }
  addSession(s: Session): void {
    this.db.query(
      `insert into sessions (id, project_id, title, worktree, branch, base, runtime, native_id, status, created_at)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(s.id, s.projectId, s.title, s.worktree, s.branch, s.base, s.runtime, s.nativeId, s.status, s.createdAt);
  }
  setStatus(id: string, status: SessionStatus): void {
    this.db.query('update sessions set status = ? where id = ?').run(status, id);
  }
  close(): void { this.db.close(); }
}
