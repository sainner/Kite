/** 场景及可用变量的唯一目录。这里只描述契约；触发、取值和投递由业务调用方负责。 */
export const contextScenes = {
  'session.create': {
    title: '创建会话',
    variables: [
      { name: 'environment.cwd', title: '工作目录' },
      { name: 'environment.date', title: '当前日期（UTC）' },
      { name: 'project.documents', title: '项目规则与记忆索引' },
    ],
  },
  'session.file_changes': {
    title: '会话中文件变化',
    variables: [
      { name: 'files.changes', title: '变化文件列表' },
      { name: 'files.origin', title: '变化来源' },
    ],
  },
} as const;

export type ContextScene = keyof typeof contextScenes;
export type ContextVariable<S extends ContextScene> = (typeof contextScenes)[S]['variables'][number]['name'];
