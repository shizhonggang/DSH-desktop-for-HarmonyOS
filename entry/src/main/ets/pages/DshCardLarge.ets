/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * DSH service card — 4x4 large.
 *
 * Layout:
 *   ┌─────────────────────────┐
 *   │  ● DSH Tasks    3 active│
 *   │  ┌───────────────────┐  │
 *   │  │ ● 任务一  Running │  │
 *   │  │ ● 任务二  Waiting │  │
 *   │  │ ● 任务三  Done    │  │
 *   │  └───────────────────┘  │
 *   │  ─────────────────────  │
 *   │  29轮 680步 · 107tok/s  │
 *   │  156M tok · 命中98%  ◌60%│
 *   └─────────────────────────┘
 *
 * tasks is a JSON string: [{"title":"...","status":"running","detail":"..."}]
 * Bottom bar mirrors the DSH Web UI status strip.
 */

interface TaskItem {
  title: string;
  status: string;
  detail: string;
}

function statusColorLarge(status: string): string {
  switch (status) {
    case 'running': return '#4CAF50';
    case 'waiting': return '#FF9800';
    case 'error': return '#F44336';
    case 'done': return '#2196F3';
    default: return '#9E9E9E';
  }
}

function statusLabelLarge(status: string): string {
  switch (status) {
    case 'running': return 'Running';
    case 'waiting': return 'Waiting';
    case 'error': return 'Error';
    case 'done': return 'Done';
    default: return 'Idle';
  }
}

/** Parse the tasks JSON safely; returns [] on any failure. */
function parseTasksLarge(raw: string): TaskItem[] {
  try {
    const arr: Array<Record<string, Object>> = JSON.parse(raw);
    if (!Array.isArray(arr)) return [];
    return arr.map((item: Record<string, Object>) => {
      const title = typeof item['title'] === 'string' ? item['title'] as string : '';
      const status = typeof item['status'] === 'string' ? item['status'] as string : 'idle';
      const detail = typeof item['detail'] === 'string' ? item['detail'] as string : '';
      return { title, status, detail } as TaskItem;
    });
  } catch {
    return [];
  }
}

@Entry
@Component
struct DshCardLarge {
  @LocalStorageProp('tasks') tasksJson: string = '[]';
  @LocalStorageProp('runningCount') runningCount: number = 0;
  @LocalStorageProp('rounds') rounds: number = 0;
  @LocalStorageProp('steps') steps: number = 0;
  @LocalStorageProp('tokRate') tokRate: string = '';
  @LocalStorageProp('tokTotal') tokTotal: string = '';
  @LocalStorageProp('cacheRate') cacheRate: string = '';
  @LocalStorageProp('progress') progress: number = 0;
  @LocalStorageProp('updatedAt') updatedAt: string = '';

  private tasks: TaskItem[] = [];

  /** Re-parse whenever tasksJson changes (called from build). */
  private get parsedTasks(): TaskItem[] {
    return parseTasksLarge(this.tasksJson);
  }

  @Builder
  TaskRow(task: TaskItem) {
    Row({ space: 6 }) {
      Circle({ width: 6, height: 6 })
        .fill(statusColorLarge(task.status))
      Text(task.title)
        .fontSize(12)
        .fontColor('#E0E0E0')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (task.detail !== '') {
        Text(task.detail)
          .fontSize(10)
          .fontColor('#808080')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text(statusLabelLarge(task.status))
        .fontSize(10)
        .fontColor(statusColorLarge(task.status))
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
  }

  @Builder
  BottomBar() {
    Column({ space: 2 }) {
      // Divider line
      Divider()
        .color('#333344')
        .strokeWidth(0.5)
        .margin({ top: 4, bottom: 4 })

      // Row 1: rounds / steps / tok/s
      Row({ space: 4 }) {
        Text(`${this.rounds}轮 ${this.steps}步`)
          .fontSize(10)
          .fontColor('#A0A0A0')
        Text('·')
          .fontSize(10)
          .fontColor('#606060')
        Text(this.tokRate)
          .fontSize(10)
          .fontColor('#A0A0A0')
      }
      .width('100%')

      // Row 2: tokens / cache / last refresh / refresh button / progress ring
      Row({ space: 4 }) {
        Text(this.tokTotal)
          .fontSize(10)
          .fontColor('#A0A0A0')
        Text('·')
          .fontSize(10)
          .fontColor('#606060')
        Text(`命中 ${this.cacheRate}`)
          .fontSize(10)
          .fontColor('#A0A0A0')
        Blank()
        if (this.updatedAt !== '') {
          Text(this.updatedAt)
            .fontSize(9)
            .fontColor('#606060')
        }
        // Manual refresh button
        Button() {
          Text('⟳')
            .fontSize(10)
            .fontColor('#808080')
        }
        .width(20)
        .height(20)
        .backgroundColor('#2A2A3E')
        .borderRadius(10)
        .padding(0)
        .onClick(() => {
          postCardAction(this, {
            action: 'call',
            abilityName: 'EntryAbility',
            params: { method: 'onCardRefresh' }
          });
        })
        // Mini progress ring
        Stack() {
          Progress({ value: this.progress, total: 100, type: ProgressType.Ring })
            .width(18)
            .height(18)
            .color('#E64340')
            .backgroundColor('#333344')
            .style({ strokeWidth: 2 })
          Text(`${this.progress}%`)
            .fontSize(7)
            .fontColor('#E0E0E0')
        }
      }
      .width('100%')
    }
    .width('100%')
  }

  /** Parse tasks in build() so @LocalStorageProp updates re-trigger rendering. */
  build() {
    Column({ space: 2 }) {
      // Header
      Row() {
        Circle({ width: 8, height: 8 })
          .fill('#4CAF50')
          .margin({ right: 6 })
        Text('DSH Tasks')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E0E0E0')
          .layoutWeight(1)
        if (this.runningCount > 0) {
          Text(`${this.runningCount} active`)
            .fontSize(10)
            .fontColor('#4CAF50')
        }
      }
      .width('100%')
      .margin({ bottom: 4 })

      // Task list (scrollable if too many)
      List({ space: 0 }) {
        ForEach(this.parsedTasks, (task: TaskItem) => {
          ListItem() {
            this.TaskRow(task)
          }
        }, (task: TaskItem) => task.title)
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)

      // Bottom status bar
      this.BottomBar()
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#1A1A2E')
    .borderRadius(14)
    .onClick(() => {
      postCardAction(this, {
        action: 'call',
        abilityName: 'EntryAbility',
        params: { method: 'onCardClick' }
      });
    })
  }
}
