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
 * DSH service card — 2x2 mini.
 * Status dot + task title + one-line detail.
 *
 * Data model: the scalar fields (taskStatus/taskTitle/taskDetail) are the
 * primary source. When the shared `tasks` array is present it wins, so a
 * single updateCard call keeps every card size consistent.
 *
 * IMPORTANT — ArkUI constraint: state must be bound directly in build().
 * Reading state inside a getter is NOT tracked by the framework, so derived
 * values are pushed into @State fields by refresh() instead.
 */
import { TaskItem, statusColor, parsePrimaryTask } from './CardShared';

// postCardAction is a global ArkUI function (declared in the ArkUI common
// runtime), not an import from @kit.FormKit.

@Entry
@Component
struct DshCard {
  @LocalStorageProp('taskStatus') taskStatus: string = 'idle';
  @LocalStorageProp('taskTitle') taskTitle: string = 'DSH';
  @LocalStorageProp('taskDetail') taskDetail: string = 'No active task';
  @LocalStorageProp('tasks') @Watch('onTasksChanged') tasksJson: string = '[]';

  // Values actually rendered — written by refresh(), never read via a getter.
  @State dispTitle: string = '';
  @State dispDetail: string = '';
  @State dispStatus: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  onTasksChanged(): void {
    this.refresh();
  }

  /** Recompute the displayed values from the current binding data. */
  refresh(): void {
    const picked: TaskItem | null = parsePrimaryTask(this.tasksJson);
    if (picked === null) {
      this.dispTitle = this.taskTitle;
      this.dispDetail = this.taskDetail;
      this.dispStatus = this.taskStatus;
      return;
    }
    this.dispTitle = picked.title !== '' ? picked.title : this.taskTitle;
    this.dispDetail = picked.detail !== '' ? picked.detail : this.taskDetail;
    this.dispStatus = picked.status !== '' ? picked.status : this.taskStatus;
  }

  build() {
    Column({ space: 4 }) {
      Row() {
        Circle({ width: 8, height: 8 })
          .fill(statusColor(this.dispStatus))
          .margin({ right: 6 })
        Text(this.dispTitle)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E0E0E0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      Text(this.dispDetail)
        .fontSize(12)
        .fontColor('#B0B0B0')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(10)
    .backgroundColor('#1A1A2E')
    .borderRadius(12)
    .onClick(() => {
      postCardAction(this, {
        action: 'call',
        abilityName: 'EntryAbility',
        params: { method: 'onCardClick' }
      });
    })
  }
}
