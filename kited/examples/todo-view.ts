import { App, PostMessageTransport } from '@modelcontextprotocol/ext-apps';

const app = new App({ name: 'Kite 待办', version: '1.0.0' }, {}, { autoResize: false });
const form = document.querySelector<HTMLFormElement>('form')!;
const input = document.querySelector<HTMLInputElement>('input')!;
const list = document.querySelector<HTMLUListElement>('ul')!;
const status = document.querySelector<HTMLElement>('#status')!;
const error = document.querySelector<HTMLElement>('#error')!;
let busy = false;
let pendingRefresh = false;
let closed = false;

function setBusy(value: boolean) {
  busy = value;
  for (const button of document.querySelectorAll<HTMLButtonElement>('button')) button.disabled = value || button.dataset.completed === 'true';
}
function render(value: Record<string, unknown>) {
  const tasks = (value.value as { tasks?: { id: string; title: string; completed: boolean }[] }).tasks ?? [];
  list.replaceChildren();
  status.textContent = tasks.length ? `${tasks.filter((task) => !task.completed).length} 项未完成` : '还没有待办';
  for (const task of tasks) {
    const row = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = task.completed ? '✓' : '○';
    button.setAttribute('aria-label', task.completed ? '已完成' : `完成 ${task.title}`);
    button.disabled = task.completed;
    button.dataset.completed = String(task.completed);
    button.onclick = () => { if (!task.completed) void run('todo_complete', { id: task.id }); };
    const title = document.createElement('span');
    title.textContent = task.title;
    if (task.completed) row.className = 'completed';
    row.append(button, title);
    list.appendChild(row);
  }
}
async function run(name: string, args: Record<string, unknown> = {}) {
  if (busy || closed) { if (name === 'todo_list') pendingRefresh = true; return; }
  setBusy(true);
  error.textContent = '';
  try {
    const result = await app.callServerTool({ name, arguments: args });
    if (result.isError || !result.structuredContent) {
      throw new Error(result.content.filter((part) => part.type === 'text').map((part) => part.text).join('\n') || '待办操作失败');
    }
    render(result.structuredContent as Record<string, unknown>);
    if (name === 'todo_add' && input.value.trim() === args.title) input.value = '';
  } catch (failure) { error.textContent = String(failure); }
  finally {
    setBusy(false);
    if (pendingRefresh) { pendingRefresh = false; void run('todo_list'); }
  }
}
form.onsubmit = (event) => { event.preventDefault(); if (input.value.trim()) void run('todo_add', { title: input.value.trim() }); };
document.querySelector<HTMLButtonElement>('#refresh')!.onclick = () => { void run('todo_list'); };
app.setNotificationHandler('notifications/resources/updated', () => { void run('todo_list'); });
const theme = (value: string | undefined) => { document.documentElement.style.colorScheme = value ?? 'light dark'; };
app.onhostcontextchanged = (context) => { if (context.theme) theme(context.theme); };
app.onteardown = async () => { closed = true; return {}; };
async function start() {
  await app.connect(new PostMessageTransport(window.parent, window.parent));
  theme(app.getHostContext()?.theme);
  await run('todo_list');
}
void start().catch((failure) => { error.textContent = String(failure); });
