/*
 * Shared helpers for the DSH service cards (mini / wide / large).
 *
 * Extracted so the three card pages do not each declare their own copies of
 * TaskItem and the task-picking helpers — ArkTS rejects duplicate top-level
 * declarations across the module (arkts-no-decl-merging).
 */

/** Shape of one entry in the shared `tasks` JSON array. */
export interface TaskItem {
  title: string;
  status: string;
  detail: string;
}

/** Status dot colour, shared by every card size. */
export function statusColor(status: string): string {
  switch (status) {
    case 'running': return '#4CAF50';
    case 'waiting': return '#FF9800';
    case 'error': return '#F44336';
    case 'done': return '#2196F3';
    default: return '#9E9E9E';
  }
}

/** Human-readable status label shown next to the dot. */
export function statusLabel(status: string): string {
  switch (status) {
    case 'running': return 'Running';
    case 'waiting': return 'Waiting';
    case 'error': return 'Error';
    case 'done': return 'Done';
    default: return 'Idle';
  }
}

/**
 * Parse the `tasks` binding value into a TaskItem array.
 * Returns [] when the value is empty, malformed, or not an array.
 */
export function parseTasks(raw: string): TaskItem[] {
  try {
    const arr: Array<Record<string, Object>> = JSON.parse(raw);
    if (!Array.isArray(arr)) {
      return [];
    }
    return arr.map((item: Record<string, Object>) => {
      const title = typeof item['title'] === 'string' ? item['title'] as string : '';
      const s = typeof item['status'] === 'string' ? item['status'] as string : 'idle';
      const detail = typeof item['detail'] === 'string' ? item['detail'] as string : '';
      return { title, status: s, detail } as TaskItem;
    });
  } catch {
    return [];
  }
}

/**
 * Pick the task that should represent the whole run on a compact card:
 * the first `running` entry, else the first entry. null when there is none,
 * so the caller can fall back to the scalar binding fields.
 */
export function parsePrimaryTask(raw: string): TaskItem | null {
  const list = parseTasks(raw);
  if (list.length === 0) {
    return null;
  }
  for (const item of list) {
    if (item.status === 'running') {
      return item;
    }
  }
  return list[0];
}
